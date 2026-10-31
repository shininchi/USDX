"""Runs UltraSinger with known lyrics instead of the ones Whisper hears.

Usage: python lyrics_hook.py LYRICS_FILE|- UltraSinger.py [UltraSinger options]

Whisper mishears sung words ("gala bombonera" for "La Rosaleda"). When the
real lyrics are known, whisperx aligns them instead, each line inside a
time window: the line's own time when the lyrics are synced (LRCLIB's),
moved to fit this recording, and otherwise where the transcription heard
the most similar words. Everything else (separation, pitch, writing the
song) is UltraSinger as usual.

The lyrics file is plain text, one sung line per line, with repeated
choruses written out as they are sung. Empty lines and [Chorus]-like tags
are skipped.
"""

import difflib
import os
import re
import runpy
import sys
import unicodedata

PAD_SECONDS = 0.3  # extra time around each line for the aligner
SQUEEZED_WORD_SECONDS = 0.12  # a line heard in less than this per word was squeezed by the aligner
HELD_SECONDS = 2.0  # a word held this long before a squeezed one took the time of the words after it


def normalize(word):
    word = unicodedata.normalize("NFD", word.lower())
    word = "".join(c for c in word if unicodedata.category(c) != "Mn")
    return re.sub(r"[^\w']", "", word)


LRC_TIME = re.compile(r"^\[(\d+):(\d+(?:[.:]\d+)?)\]")


def read_timed_lyrics(path):
    """(seconds or None, text) for each line; LRC files ("[mm:ss.xx] text",
    as LRCLIB's synced lyrics) give the time each line starts, and their
    empty timed lines mark where the singing stops."""
    data = open(path, "rb").read()
    try:
        text = data.decode("utf-8-sig")
    except UnicodeDecodeError:
        text = data.decode("cp1252", errors="replace")
    result = []
    for line in text.splitlines():
        line = line.strip()
        start = None
        match = LRC_TIME.match(line)
        while match:
            start = int(match.group(1)) * 60 + float(match.group(2).replace(":", "."))
            line = line[match.end():].strip()
            match = LRC_TIME.match(line)
        if start is None and (not line or re.fullmatch(r"[\[(].*[\])]", line)):
            continue
        result.append((start, line))
    return result


LRC_LENGTH = re.compile(r"^\[length:\s*(\d+):(\d+(?:\.\d+)?)\]", re.IGNORECASE)
SAME_RECORDING_SECONDS = 2.0


def lyrics_length(path):
    """Length of the recording the synced times are for ("[length: 03:58]"
    in the LRC file), None if it does not say."""
    data = open(path, "rb").read().decode("utf-8", errors="replace")
    for line in data.splitlines():
        match = LRC_LENGTH.match(line.strip())
        if match:
            return int(match.group(1)) * 60 + float(match.group(2))
    return None


def read_lyrics(path):
    return [text for _, text in read_timed_lyrics(path) if text]


def timed_segments(timed, audio_seconds):
    """Segments straight from the line times of synced lyrics, or None."""
    if not timed or any(start is None for start, _ in timed):
        return None
    result = []
    for i, (start, text) in enumerate(timed):
        if not text:
            continue
        end = timed[i + 1][0] if i + 1 < len(timed) else (audio_seconds or start + 8)
        end = min(end, start + 15)  # a long instrumental after the line is not part of it
        result.append({"text": text, "start": max(0.0, start - PAD_SECONDS), "end": end + PAD_SECONDS})
    print("[lyrics] %d lines placed by their synced times" % len(result), flush=True)
    return result


def heard_words(segments):
    """(normalized word, start, end, has a time of its own) of the
    transcription: the aligner's time of each word when the segments went
    through it, else times spread over each segment by character position."""
    result = []
    for seg in segments:
        words = seg.get("text", "").split()
        if not words or "start" not in seg or "end" not in seg:
            continue
        aligned = seg.get("words") or []
        if len(aligned) == len(words):
            spread = heard_words([{k: v for k, v in seg.items() if k != "words"}])
            for w, a, (_, start, end, first) in zip(words, aligned, spread):
                if "start" in a and "end" in a:
                    result.append((normalize(w), a["start"], a["end"], True))
                else:
                    result.append((normalize(w), start, end, False))
            continue
        total = sum(len(w) + 1 for w in words)
        duration = seg["end"] - seg["start"]
        pos = 0
        for w in words:
            start = seg["start"] + duration * pos / total
            pos += len(w) + 1
            end = seg["start"] + duration * pos / total
            result.append((normalize(w), start, end, w is words[0]))
    return result


def line_spans(lines, heard):
    """(start, end) where the transcription heard each line, None if not."""
    words, owner = [], []
    for i, line in enumerate(lines):
        for w in line.split():
            words.append(normalize(w))
            owner.append(i)
    spans = [None] * len(lines)
    matcher = difflib.SequenceMatcher(None, [h[0] for h in heard], words, autojunk=False)
    for a, b, size in matcher.get_matching_blocks():
        for k in range(size):
            i = owner[b + k]
            t0, t1 = heard[a + k][1], heard[a + k][2]
            spans[i] = (t0, t1) if spans[i] is None else (min(spans[i][0], t0), max(spans[i][1], t1))
    return spans


def median(values):
    values = sorted(values)
    return values[len(values) // 2]


def line_starts(lines, heard):
    """When the transcription heard each line begin (its first word), None
    for the lines whose first word it did not hear."""
    words, owner, first = [], [], []
    for i, line in enumerate(lines):
        for k, w in enumerate(line.split()):
            words.append(normalize(w))
            owner.append(i)
            first.append(k == 0)
    starts, opening = [None] * len(lines), [None] * len(lines)
    matcher = difflib.SequenceMatcher(None, [h[0] for h in heard], words, autojunk=False)
    for a, b, size in matcher.get_matching_blocks():
        for k in range(size):
            if first[b + k] and starts[owner[b + k]] is None:
                starts[owner[b + k]] = heard[a + k][1]
                if heard[a + k][3]:
                    opening[owner[b + k]] = heard[a + k][1]
    # only the words that open a segment have a time of their own; the
    # others are spread over it by their length, which is rough
    if sum(1 for s in opening if s is not None) >= 3:
        return opening
    return starts


def fitted_times(timed, segments, same_recording=False, levels=None, audio_seconds=None):
    """Synced times moved to fit this recording. LRCLIB has them for one
    version of the song, and another one (a videoclip) may have a longer
    intro or an extra bit in the middle: the song is cut in stretches with
    one shift each, which the lines Whisper heard tell. Whisper is only
    asked how far the lines are, never where each one goes. None when the
    times do not fit the recording at all.

    The same recording (as long as the one the times are for) has nothing
    added in the middle: one shift for the whole song. Whisper matching a
    repeated chorus to another repetition cut Esa Estrella in two
    stretches, the second one 1.8 s early. Whisper's rough times invent
    stretches in other songs too (Con un Solo Dedo): they are kept only
    when their lines start where the voice does clearly better than with
    one shift for the whole song (levels, of the vocals), and never when
    they cannot be: lines after the end of the recording, or out of order
    (Rocíos' second chorus matched to the third one, 47 s later)."""
    heard = heard_words(segments)
    entries = [k for k, (start, text) in enumerate(timed) if text]
    starts = line_starts([timed[k][1] for k in entries], heard) if heard else []
    deltas = [(n, s - timed[entries[n]][0]) for n, s in enumerate(starts) if s is not None]
    if len(deltas) < 3:
        return timed
    # shift around each heard line (its neighbours too: Whisper's times are
    # rough, and a repeated chorus may be matched to another repetition)
    local = [median([d for _, d in deltas[max(0, m - 3):m + 4]]) for m in range(len(deltas))]
    # stretches: a new one starts where the shift changes and stays changed
    blocks = [[0]]
    for m in range(1, len(deltas)):
        current = median([deltas[x][1] for x in blocks[-1]])
        if abs(local[m] - current) > 1.0 and m + 1 < len(deltas) and abs(local[m + 1] - current) > 1.0:
            blocks.append([m])
        else:
            blocks[-1].append(m)
    if same_recording:
        blocks = [list(range(len(deltas)))]
    # a stretch of one or two lines is Whisper being wrong, not the song
    merged = []
    for block in blocks:
        if merged and len(block) < 3:
            merged[-1] += block
        elif merged and len(merged[-1]) < 3:
            merged[-1] += block
        else:
            merged.append(block)
    shifts = [median([deltas[x][1] for x in block]) for block in merged]
    # the shift around a line lags behind where it changes: the lines at
    # the edge of a stretch go with the shift closer to their own
    for b in range(1, len(merged)):
        before, after = merged[b - 1], merged[b]
        while len(before) > 1 and abs(deltas[before[-1]][1] - shifts[b]) < abs(deltas[before[-1]][1] - shifts[b - 1]):
            after.insert(0, before.pop())
        while len(after) > 1 and abs(deltas[after[0]][1] - shifts[b - 1]) < abs(deltas[after[0]][1] - shifts[b]):
            before.append(after.pop(0))
    spread = median([abs(deltas[x][1] - shift) for block, shift in zip(merged, shifts) for x in block])
    # the same recording fits by itself, however rough Whisper's times are
    if spread > 1.0 and not same_recording:
        print("[lyrics] the synced times do not fit this recording, using what Whisper hears", flush=True)
        return None
    # each line's shift: the one of its stretch; between two stretches the
    # change goes in the longest pause between lines (where a bit was added)
    line_shift = [shifts[0]] * len(entries)
    for b in range(len(merged)):
        first = deltas[merged[b][0]][0]
        for n in range(first, len(entries)):
            line_shift[n] = shifts[b]
        if b:
            last_before = deltas[merged[b - 1][-1]][0]
            if first - last_before > 1:
                gaps = [(timed[entries[n]][0] - timed[entries[n - 1]][0], n) for n in range(last_before + 1, first + 1)]
                cut = max(gaps)[1]
                for n in range(cut, first):
                    line_shift[n] = shifts[b]
    result = moved_times(timed, entries, line_shift)
    if len(merged) > 1:
        # the shift of the longest stretch: the lines Whisper matched to
        # another repetition of a chorus would pull a median of all away
        one = max(zip(merged, shifts), key=lambda b: len(b[0]))[1]
        whole = moved_times(timed, entries, [one] * len(entries))
        starts = [start for start, text in result if text]
        impossible = any(b < a for a, b in zip(starts, starts[1:])) or \
            bool(audio_seconds and starts[-1] > audio_seconds)
        if impossible or (levels and onset_score(whole, levels) + ONSET_MARGIN >= onset_score(result, levels)):
            print("[lyrics] synced times moved to fit this recording: %+.2f s (the stretches Whisper "
                  "suggests %s)" % (one, "cannot be" if impossible else "do not start the lines on the voice better"),
                  flush=True)
            return whole
    print("[lyrics] synced times moved to fit this recording: %s"
          % ", ".join("%+.2f s from line %d" % (shift, deltas[block[0]][0] + 1) if b else "%+.2f s" % shift
                      for b, (block, shift) in enumerate(zip(merged, shifts))), flush=True)
    return result


def moved_times(timed, entries, line_shift):
    result, n = [], 0
    for k, (start, text) in enumerate(timed):
        if text:
            n = entries.index(k)
            result.append((start + line_shift[n], text))
        else:
            # the end of a line: moved as the line before it
            result.append((None if start is None else start + line_shift[n], text))
    return result


ONSET_SECONDS = 0.4  # voice looked for just before and after a line starts
ONSET_MARGIN = 0.05


def onset_score(timed, levels):
    """How much more the voice sounds just after the lines start than just
    before, on average (-1 to 1): the right times start them as it comes in,
    wrong ones in the middle of singing or of a rest."""
    width = int(ONSET_SECONDS * 100)

    def sung(first, last):
        frames = [levels[f] > VOICE_DB for f in range(max(first, 0), min(last, len(levels)))]
        return sum(frames) / float(width)
    starts = [int(start * 100) for start, text in timed if text and start is not None]
    if not starts:
        return 0.0
    return sum(sung(f, f + width) - sung(f - width, f) for f in starts) / len(starts)


def lyric_segments(lines, segments, audio_seconds=None):
    """The time window of each line (or run of repeated lines), and which
    of them Whisper's words were squeezed into (see unsqueezed)."""
    heard = heard_words(segments)
    if not heard:
        return segments, []
    words, owner = [], []
    for i, line in enumerate(lines):
        for w in line.split():
            words.append(normalize(w))
            owner.append(i)

    times = [None] * len(words)
    matcher = difflib.SequenceMatcher(None, [h[0] for h in heard], words, autojunk=False)
    for a, b, size in matcher.get_matching_blocks():
        for k in range(size):
            times[b + k] = (heard[a + k][1], heard[a + k][2])

    # time window of each line from its matched words
    spans = [None] * len(lines)
    for idx, t in enumerate(times):
        if t is None:
            continue
        i = owner[idx]
        spans[i] = (t[0], t[1]) if spans[i] is None else (min(spans[i][0], t[0]), max(spans[i][1], t[1]))

    # runs of lines without a match share the time between their
    # neighbours, by number of words (Whisper skips repeated choruses)
    # the lines at the end that Whisper did not hear go right after the last
    # words it heard, not over the rest of the song (a long outro)
    song_end = heard[-1][2] + 3.0
    if audio_seconds:
        song_end = min(song_end, audio_seconds)
    i = 0
    while i < len(lines):
        if spans[i] is not None:
            i += 1
            continue
        j = i
        while j < len(lines) and spans[j] is None:
            j += 1
        before = spans[i - 1][1] if i > 0 else heard[0][1]
        after = spans[j][0] if j < len(lines) else song_end
        if after - before < 1.0 * (j - i):
            after = before + 1.0 * (j - i)
        counts = [max(1, len(lines[k].split())) for k in range(i, j)]
        total = float(sum(counts))
        t = before
        for k, c in zip(range(i, j), counts):
            length = (after - before) * c / total
            spans[k] = (t, t + length)
            t += length
        i = j

    # lines in a row that repeat the same words (a chorus of "salvación,
    # salvación"): Whisper hears fewer repetitions than are sung, so their
    # windows are wrong one by one; aligned as one block over their whole
    # stretch, the aligner places each repetition by the sound itself
    groups, i = [], 0
    while i < len(lines):
        first = set(normalize(w) for w in lines[i].split())
        j = i + 1
        while j < len(lines) and first and \
                set(normalize(w) for w in lines[j].split()) <= first:
            j += 1
        groups.append((i, j))
        i = j

    result, prev_end, squeezed = [], 0.0, []
    for i, j in groups:
        first = min(spans[k][0] for k in range(i, j))
        start = max(prev_end, first - PAD_SECONDS)
        last = max(spans[k][1] for k in range(i, j))
        end = max(start + 0.5 * (j - i), last + PAD_SECONDS)
        if last - first < SQUEEZED_WORD_SECONDS * sum(len(lines[k].split()) for k in range(i, j)):
            squeezed.append(len(result))
        result.append({"text": " ".join(lines[i:j]), "start": start, "end": end})
        prev_end = last
    repeated = sum(1 for i, j in groups if j - i > 1)
    if repeated:
        print("[lyrics] %d runs of repeated lines aligned as blocks" % repeated, flush=True)
    matched = sum(1 for t in times if t is not None)
    print("[lyrics] %d lines, %d of %d words found in the transcription"
          % (len(lines), matched, len(words)), flush=True)
    return result, squeezed


def held_over(windows, aligned):
    """The windows whose aligned words have one held for seconds and a
    later one squeezed to an instant: the aligner gave the held word the
    time of the words after it (Peregrino: "más" 2.9 s, "río" 0.06 s)."""
    words = [w for seg in aligned for w in seg.get("words", [])]
    result, n = [], 0
    for i, window in enumerate(windows):
        count = len(window["text"].split())
        lengths = [w["end"] - w["start"] for w in words[n:n + count] if "start" in w and "end" in w]
        n += count
        held = [k for k, length in enumerate(lengths) if length >= HELD_SECONDS]
        if held and any(length < SQUEEZED_WORD_SECONDS for length in lengths[held[0] + 1:]):
            result.append(i)
    return result


def unsqueezed(windows, squeezed, align):
    """The windows of the lines Whisper's words were squeezed into, placed
    again. Aligning what it heard, whisperx may hold a word for seconds and
    give the next line an instant (Peregrino: "conmigo" 6 s, "Allá donde
    vaya el agua" 0.4 s after it, sung 3.5 s earlier), and the line's own
    window is then just as wrong. Such a line is aligned in one block with
    the lines around it, which finds where each of them starts; each one
    is then aligned in its own window between those starts, as the block
    alone holds and squeezes other words."""
    windows = [dict(w) for w in windows]
    for i in squeezed:
        a, b = max(0, i - 1), min(len(windows), i + 2)
        block = {"text": " ".join(w["text"] for w in windows[a:b]),
                 "start": windows[a]["start"], "end": windows[b - 1]["end"]}
        try:
            words = [w for seg in align([block]).get("segments", []) for w in seg.get("words", [])]
        except Exception as e:
            print("[lyrics] squeezed line %d not placed again: %s" % (i + 1, e), flush=True)
            continue
        n = 0
        for k in range(a, b):
            if k > a and n < len(words) and "start" in words[n] and \
                    windows[k - 1]["start"] < words[n]["start"] < windows[k]["end"]:
                windows[k - 1]["end"] = words[n]["start"] + PAD_SECONDS
                windows[k]["start"] = words[n]["start"] - PAD_SECONDS
            n += len(windows[k]["text"].split())
    if squeezed:
        print("[lyrics] %d lines squeezed by the aligner placed again" % len(squeezed), flush=True)
    return windows


VOICE_DB = -40  # below this (against the loudest moment) the voice is silent
TAIL_DB = 20    # a syllable ends this far below its own peak: echo, reverb
LEAP_SEMITONES = 9  # a held word that ends this far from its own pitch...
LEAP_SECONDS = 0.3  # ...for this long is an instrument left in the vocals


def pitch_leap(audio, start, end):
    """Where the last word of a line stops being the singer: it ends on a
    steady pitch far from the one it was sung at (an instrument left in the
    separated vocals, held on after the voice). None if not."""
    if audio is None or end - start < 2 * LEAP_SECONDS + 0.3:
        return None
    try:
        import librosa
        import numpy as np
        y = np.asarray(audio[int(start * 16000):int(end * 16000)], dtype=np.float32)
        f0, voiced, _ = librosa.pyin(y, fmin=65, fmax=1000, sr=16000, frame_length=1024, hop_length=160)
    except Exception as e:  # aligning still works without it
        print("[lyrics] no pitch: %s" % e, flush=True)
        return None
    semis = 12 * np.log2(np.where(voiced, f0, np.nan) / 440.0)
    sung = semis[:30][~np.isnan(semis[:30])]  # the first 0.3 s
    tail = semis[~np.isnan(semis)][-30:]  # the last 0.3 s with a pitch
    if len(sung) < 10 or len(tail) < 10:
        return None
    held = np.median(tail)
    if abs(held - np.median(sung)) <= LEAP_SEMITONES:
        return None
    # back from the end while the sound holds that steady pitch (an
    # instrument; a voice wobbles, and the pitch tracker slips octaves)
    k = len(semis)
    while k > 0:
        chunk = semis[max(0, k - 10):k]  # 0.1 s at a time: stray frames do not stop it
        pitched = chunk[~np.isnan(chunk)]
        if len(pitched) and np.count_nonzero(np.abs(pitched - held) <= 1.0) < 0.5 * len(pitched):
            break
        k = max(0, k - 10)
    if k <= 30 or np.count_nonzero(~np.isnan(semis[k:])) < LEAP_SECONDS * 100:
        return None
    return start + k / 100.0


GLUED_SECONDS = 0.5  # a line's last word this close to the next line is on its first syllable
PAUSE_SECONDS = 0.15  # a break in the voice this long ends a sung phrase


def sung_before_pause(audio, start, end):
    """The aligner sometimes puts the last word of a line (sung right after
    the word before it, in a run of notes) on the first syllable of the next
    line, after a pause, and leaves the voice where it is sung to the word
    before. Returns (start, end) of the phrase that ends at that pause, from
    where the voice leaves the held note of the word before; None if the
    last word does not come right after a pause."""
    if audio is None or end - start < 1.0:
        return None
    try:
        import librosa
        import numpy as np
        y = np.asarray(audio[int(start * 16000):int((end + 0.1) * 16000)], dtype=np.float32)
        f0, voiced, _ = librosa.pyin(y, fmin=65, fmax=1000, sr=16000, frame_length=1024, hop_length=160)
    except Exception as e:  # aligning still works without it
        print("[lyrics] no pitch: %s" % e, flush=True)
        return None
    semis = 12 * np.log2(np.where(voiced, f0, np.nan) / 440.0)
    sung = ~np.isnan(semis)
    pause = int(PAUSE_SECONDS * 100)
    # the pause right before the last word
    k = min(len(sung), int((end - start) * 100) + 5)
    while k > 0 and sung[k - 1]:
        k -= 1
    if (end - start) * 100 - k > GLUED_SECONDS * 100:  # the word does not start after the pause
        return None
    stop = k
    while stop > 0:  # a breath in it is not the voice
        if not sung[stop - 1]:
            stop -= 1
            continue
        blip = stop
        while blip > 0 and sung[blip - 1]:
            blip -= 1
        if stop - blip >= 12:
            break
        stop = blip
    if k - stop < pause or stop == 0:
        return None
    # back to a break in the voice, or to a held note at another pitch
    begin = stop
    while begin > 0:
        if not sung[max(0, begin - 8):begin].any():
            break
        tail = semis[begin:stop][~np.isnan(semis[begin:stop])]
        held = semis[max(0, begin - 10):begin][~np.isnan(semis[max(0, begin - 10):begin])]
        if len(tail) >= 10 and len(held) >= 8 and np.ptp(held) <= 1.0 and \
                abs(np.median(held) - np.median(tail)) > 2.5:
            break
        begin -= 1
    if (stop - begin) / 100.0 < 0.25 or begin == 0:
        return None
    return round(start + begin / 100.0, 3), round(start + stop / 100.0, 3)


SQUEEZED_SECONDS = 0.1  # a line's last word given less than this was not found by the aligner
SQUEEZE_LEAP = 5        # semitones: the voice jumping this far starts the next word...
SQUEEZE_HELD = 1.0      # ...when it holds on this long without a break
SYLLABLE_SECONDS = 0.1  # each syllable of the word before is sung at least this long before the leap


def vowel_groups(word):
    """About how many syllables a word has: its groups of vowels."""
    return max(1, len(re.findall(r"[aeiouáéíóúü]+", word.lower())))


def squeezed_word(audio, start, end, before=""):
    """The aligner sometimes leaves a line's last word an instant at the
    line's end, the long note it is sung on ("haciendo tú~~~") given to the
    word before or to nobody. Between start (of the word before) and end
    (of the last word), the last word is sung from where the voice leaps
    away from the word before and holds on, to the next break in the voice,
    once the word before (its text: before) had some time for its
    syllables. What is sung after that break are sounds ("tú~~ ah~ oh~"),
    not the word. Returns (start, end), or None if there is no such leap."""
    if audio is None or end - start < 0.5 + SQUEEZE_HELD:
        return None
    try:
        import librosa
        import numpy as np
        y = np.asarray(audio[int(start * 16000):int(end * 16000)], dtype=np.float32)
        f0, voiced, _ = librosa.pyin(y, fmin=65, fmax=1000, sr=16000, frame_length=1024, hop_length=160)
    except Exception as e:  # aligning still works without it
        print("[lyrics] no pitch: %s" % e, flush=True)
        return None
    semis = 12 * np.log2(np.where(voiced, f0, np.nan) / 440.0)
    sung = ~np.isnan(semis)
    held = int(SQUEEZE_HELD * 100)
    first = max(20, int(vowel_groups(before) * SYLLABLE_SECONDS * 100))

    def voice_after(k):  # the first 0.15 s of voice from k on, over a breath
        b = semis[k:k + 45]
        return b[~np.isnan(b)][:15]

    def leap(k):  # semitones between the voice in the 0.15 s before k and after it
        a = semis[max(0, k - 45):k]
        a, b = a[~np.isnan(a)][-15:], voice_after(k)
        if len(a) < 8 or len(b) < 8:
            return 0
        return abs(np.median(b) - np.median(a))
    k = 15
    while k < len(semis) - held:
        if leap(k) < SQUEEZE_LEAP:
            k += 1
            continue
        # the leap is where the change is largest
        end_of_leap = k
        while end_of_leap < len(semis) and leap(end_of_leap) >= SQUEEZE_LEAP:
            end_of_leap += 1
        at = max(range(k, end_of_leap), key=leap)
        k = end_of_leap
        # the word before is sung before the leap: a leap at its start, or
        # between its syllables, is its own
        if np.count_nonzero(sung[:at]) < first:
            continue
        # from where the new note sounds, past a breath before it
        note = np.median(voice_after(at))
        while at < len(sung) and not (sung[at] and abs(semis[at] - note) <= 2):
            at += 1
        # held on: no break in the voice of 0.1 s
        stop = at
        while stop < len(sung) and sung[stop:stop + 10].any():
            stop += 1
        if stop - at < held:
            continue
        return round(start + at / 100.0, 3), round(start + stop / 100.0, 3)
    return None


VOICE_GONE_SECONDS = 0.5  # the voice silent this long ends a line's last word
BLIP_FRAMES = 5           # voiced runs shorter than this (10 ms frames) are breaths, clicks
BACKING_GAP_SECONDS = 3.0  # backing vocals ("no~, no~") may pause this long between their words


def voiced_runs(audio, start, end):
    """(start, end) in seconds of each stretch the voice sings in, by its
    pitch (the level counts reverb and backing voices); None if unknown."""
    if audio is None or end - start < 0.2:
        return None
    try:
        import librosa
        import numpy as np
        y = np.asarray(audio[int(start * 16000):int(end * 16000)], dtype=np.float32)
        f0, voiced, _ = librosa.pyin(y, fmin=65, fmax=1000, sr=16000, frame_length=1024, hop_length=160)
    except Exception as e:  # aligning still works without it
        print("[lyrics] no pitch: %s" % e, flush=True)
        return None
    sung = list(~np.isnan(np.where(voiced, f0, np.nan)))
    runs, k = [], 0
    while k < len(sung):
        if not sung[k]:
            k += 1
            continue
        a = k
        while k < len(sung) and sung[k]:
            k += 1
        if k - a >= BLIP_FRAMES:
            runs.append((start + a / 100.0, start + k / 100.0))
    return runs


def phrase_end(runs, gap):
    """Where the first of the runs, and those that follow it closer than
    gap seconds, end; None without runs."""
    if not runs:
        return None
    end = runs[0][1]
    for a, b in runs[1:]:
        if a - end >= gap:
            break
        end = b
    return end


def place_backing(main_last, group, runs, next_start):
    """Backing vocals written in parentheses after a line ("acumulan (no lo
    es)"), which the aligner squeezes into an instant at the line's end and
    the last word held over them: the last word ends at the first break in
    its voice, and they are sung from the voice after it to where it stops
    before the next line (or, without voice there, right after the word),
    shared by length."""
    if not runs:
        return
    word_end = phrase_end([r for r in runs if r[1] > main_last["start"] + 0.2], PAUSE_SECONDS)
    if word_end is None or word_end >= next_start - 0.2:
        return
    after = [r for r in runs if r[0] >= word_end + 0.05 and r[0] < next_start - 0.1]
    main_last["end"] = round(max(main_last["start"] + 0.1, word_end), 3)
    begin = after[0][0] if after else main_last["end"] + 0.05
    end = min(phrase_end(after, BACKING_GAP_SECONDS) or begin + 0.4 * len(group), next_start - 0.02)
    if end - begin < 0.1 * len(group):
        end = min(next_start - 0.02, begin + 0.3 * len(group))
    weights = [len(w["word"]) + 1 for w in group]
    t = begin
    for w, weight in zip(group, weights):
        w["start"] = round(t, 3)
        t += (end - begin) * weight / float(sum(weights))
        w["end"] = round(t, 3)


def vocal_levels(audio):
    """Level in dB (0 = the loudest) of each 10 ms of the (16 kHz) vocals."""
    try:
        import librosa
        import numpy as np
        rms = librosa.feature.rms(y=np.asarray(audio, dtype=np.float32), frame_length=640, hop_length=160)[0]
        return list(librosa.amplitude_to_db(rms, ref=np.max))
    except Exception as e:  # aligning still works without it
        print("[lyrics] no vocal activity: %s" % e, flush=True)
        return []


def trim_line_edges(aligned, levels, audio=None):
    """The aligner gives the first word of a line the silence before it
    and stretches the last one to the end of its window, over the start of
    the next line (which UltraSinger then pushes later, word after word):
    they are cut to where the voice sounds. An effect on the voice (echo,
    reverb) sounds on long after the singing: the last word also ends where
    it fades well below its own peak, which a held note does not, and where
    the voice stops for VOICE_GONE_SECONDS (what is sung after that, ad-libs
    or backing voices, is not the word: Collar's "apretado~" took 12 s).
    Backing vocals in parentheses at a line's end go after its last word
    (see place_backing)."""
    def level(t):
        f = int(t * 100)
        return levels[f] if 0 <= f < len(levels) else VOICE_DB - 1

    def sounds(t):
        return level(t) > VOICE_DB
    lines = []
    for seg in aligned:
        words = [w for w in seg.get("words", []) if "start" in w and "end" in w]
        # the aligner cuts lines at their punctuation: "(¿dime por qué?)"
        # alone belongs to the line before it
        if words and lines and words[0].get("word", "").startswith("("):
            lines[-1].extend(words)
        elif words:
            lines.append(words)
    for n, words in enumerate(lines):
        backing = next((k for k, w in enumerate(words) if k and w.get("word", "").startswith("(")), None)
        group = words[backing:] if backing else []
        words = words[:backing] if backing else words
        first, last = words[0], words[-1]
        if len(words) > 1 and last["end"] - last["start"] < SQUEEZED_SECONDS:
            sung = squeezed_word(audio, words[-2]["start"], last["end"], words[-2].get("word", ""))
            if sung is not None:
                words[-2]["end"] = sung[0]
                last["start"], last["end"] = sung
        if levels:
            t = first["start"]
            while t < first["end"] - 0.1 and not (sounds(t) and sounds(t + 0.01) and sounds(t + 0.02)):
                t += 0.01
            first["start"] = round(t, 3)
            t = last["end"]
            while t > last["start"] + 0.1 and not sounds(t):
                t -= 0.01
            peak = max(level(last["start"] + k / 100.0) for k in range(int((t - last["start"]) * 100) + 1))
            while t > last["start"] + 0.1 and level(t) < peak - TAIL_DB:
                t -= 0.01
            leap = pitch_leap(audio, last["start"], t + 0.01)
            if leap is not None:
                t = leap - 0.01
            last["end"] = round(t + 0.01, 3)
        if n + 1 < len(lines) and len(words) > 1 and \
                lines[n + 1][0]["start"] - last["start"] < GLUED_SECONDS:
            # sung on a held note right after the word before, or else in
            # the phrase before the pause
            sung = squeezed_word(audio, words[-2]["start"], last["start"], words[-2].get("word", "")) or \
                sung_before_pause(audio, words[-2]["start"], last["start"])
            if sung is not None:
                last["start"], last["end"] = sung
                for w in words[:-1]:
                    w["end"] = min(w["end"], sung[0])
                    w["start"] = min(w["start"], w["end"] - 0.05)
        next_start = lines[n + 1][0]["start"] if n + 1 < len(lines) else last["end"] + 5.0
        runs = voiced_runs(audio, last["start"], max(last["end"], (group[-1]["end"] if group else 0)) + 0.1)
        if group:
            place_backing(last, group, runs, next_start)
        elif runs:
            sung = phrase_end([r for r in runs if r[1] > last["start"] + 0.1], VOICE_GONE_SECONDS)
            if sung is not None and sung < last["end"]:
                last["end"] = round(max(last["start"] + 0.1, sung + 0.01), 3)
        if n + 1 < len(lines):
            if last["end"] > next_start - 0.02:
                last["end"] = round(max(last["start"] + 0.05, next_start - 0.02), 3)
    return aligned


def install(lyrics_path):
    import whisperx
    timed = read_timed_lyrics(lyrics_path)
    length = lyrics_length(lyrics_path)
    lines = [text for _, text in timed if text]
    original_align = whisperx.align

    def align(segments, model, metadata, audio, *args, **kwargs):
        kwargs["return_char_alignments"] = True
        result = aligned(segments, model, metadata, audio, *args, **kwargs)
        save_char_times(result)
        return result

    def aligned(segments, model, metadata, audio, *args, **kwargs):
        if lines:
            # where each word Whisper heard is sung: the segments only say
            # where a whole sentence is (Peregrino's lines went 2-5 s off)
            try:
                heard = original_align(segments, model, metadata, audio, *args, **kwargs).get("segments")
                segments = heard or segments
            except Exception as e:
                print("[lyrics] Whisper's words not aligned: %s" % e, flush=True)
            seconds = len(audio) / 16000.0 if hasattr(audio, "__len__") else None
            same = bool(length and seconds and abs(length - seconds) <= SAME_RECORDING_SECONDS)
            levels = vocal_levels(audio)
            fitted = fitted_times(timed, segments, same, levels, seconds) if timed and all(t is not None for t, _ in timed) else None
            placed = fitted and timed_segments(fitted, seconds)
            if placed:
                result = original_align(placed, model, metadata, audio, *args, **kwargs)
                trim_line_edges(result.get("segments", []), levels, audio)
                return result
            # lyrics without times: placed where Whisper heard their words,
            # their line edges cut to the voice as the synced ones
            def align_lines(windows):
                return original_align(windows, model, metadata, audio, *args, **kwargs)
            windows, squeezed = lyric_segments(lines, segments, seconds)
            windows = unsqueezed(windows, squeezed, align_lines)
            result = align_lines(windows)
            squeezed = held_over(windows, result.get("segments", []))
            if squeezed:
                windows = unsqueezed(windows, squeezed, align_lines)
                result = align_lines(windows)
            trim_line_edges(result.get("segments", []), levels, audio)
            return result
        return original_align(segments, model, metadata, audio, *args, **kwargs)

    whisperx.align = align


def save_char_times(result):
    """Leaves for the clean-up the time WhisperX found for each letter, word
    by word: UltraSinger shares a word's time evenly among its syllables,
    and the letters say when each one is sung."""
    path = os.environ.get("USDX_CHAR_TIMES")
    if not path:
        return
    words = []
    for segment in result.get("segments", []):
        current = None
        for char in segment.get("chars") or []:
            if char.get("char") == " ":
                current = None
                continue
            if current is None:
                current = []
                words.append(current)
            current.append([char.get("char"), char.get("start")])
    try:
        import json
        with open(path, "w", encoding="utf-8") as f:
            json.dump(words, f, ensure_ascii=False)
    except Exception as e:  # the clean-up shares the time evenly then
        print("No letter times: %s" % e, flush=True)


def keep_words_in_silence():
    """UltraSinger drops the words that fall in what it takes for silence;
    with known lyrics those are real words (quiet line ends, mostly)."""
    from modules.Audio import silence_processing
    original = silence_processing.remove_silence_from_transcription_data

    def remove_silence(audio_path, transcribed_data):
        before = list(transcribed_data)
        result = original(audio_path, transcribed_data)
        kept = {id(d) for d in result}
        dropped = [d for d in before if id(d) not in kept]
        if dropped:
            print("[lyrics] kept %d words UltraSinger took for silence" % len(dropped), flush=True)
            # back where they were in the lyrics, after the word before them
            dropped_ids = {id(d) for d in dropped}
            for i, d in enumerate(before):
                if id(d) not in dropped_ids:
                    continue
                at = 0
                for prev in reversed(before[:i]):
                    if id(prev) in kept:
                        at = next(k for k, r in enumerate(result) if r is prev) + 1
                        # past the pieces UltraSinger split it into
                        while at < len(result) and id(result[at]) not in kept and \
                                str(result[at].word).strip().startswith("~"):
                            at += 1
                        break
                    if id(prev) in dropped_ids and any(r is prev for r in result):
                        at = next(k for k, r in enumerate(result) if r is prev) + 1
                        break
                result.insert(at, d)
        return result

    silence_processing.remove_silence_from_transcription_data = remove_silence


# VP9 up to 1080p: YouTube's best is often AV1 in 4K, which the game
# decodes in software and stutters on, and H.264 has B-frames, which judder
# because the game times frames of .mp4 files by their decoding order
PLAYABLE_VIDEO = ("bestvideo[vcodec^=vp9][height<=1080]+bestaudio"
                  "/bestvideo[vcodec^=vp09][height<=1080]+bestaudio"
                  "/bestvideo[vcodec^=avc1][height<=1080]+bestaudio/best[height<=1080]/best")


def playable_video():
    """Downloads videos the game plays smoothly."""
    from modules.Audio import youtube
    original = getattr(youtube, "__start_download", None)
    if original is None:
        return

    def start_download(ydl_opts, url):
        if str(ydl_opts.get("format", "")).startswith("bestvideo"):
            ydl_opts = dict(ydl_opts, format=PLAYABLE_VIDEO)
        return original(ydl_opts, url)

    setattr(youtube, "__start_download", start_download)


def skip_musicbrainz():
    """UltraSinger looks the song up on MusicBrainz and asks the Cover Art
    Archive for the cover of every release found, which takes minutes;
    for a file, its own tags and cover are used instead (usdx_generate),
    so the song is taken as not found there."""
    from modules import musicbrainz_client

    def not_searched(title, artist):
        return musicbrainz_client.SongInfo(title=title, artist=artist or "Unknown Artist")

    musicbrainz_client.search_musicbrainz = not_searched


def main():
    # "-" for no lyrics: UltraSinger then works as usual
    lyrics_path, script = sys.argv[1], sys.argv[2]
    sys.argv = [script] + sys.argv[3:]
    sys.path.insert(0, os.path.dirname(os.path.abspath(script)))
    if lyrics_path != "-":
        install(lyrics_path)
        keep_words_in_silence()
    if os.environ.get("USDX_SKIP_MUSICBRAINZ"):
        skip_musicbrainz()
    playable_video()
    runpy.run_path(script, run_name="__main__")


if __name__ == "__main__":
    main()
