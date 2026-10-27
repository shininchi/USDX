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
    """(normalized word, start, end) of the transcription, times spread
    over each segment by character position."""
    result = []
    for seg in segments:
        words = seg.get("text", "").split()
        if not words:
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


def fitted_times(timed, segments):
    """Synced times moved to fit this recording. LRCLIB has them for one
    version of the song, and another one (a videoclip) may have a longer
    intro or an extra bit in the middle: the song is cut in stretches with
    one shift each, which the lines Whisper heard tell. Whisper is only
    asked how far the lines are, never where each one goes. None when the
    times do not fit the recording at all."""
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
    if spread > 1.0:
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
    print("[lyrics] synced times moved to fit this recording: %s"
          % ", ".join("%+.2f s from line %d" % (shift, deltas[block[0]][0] + 1) if b else "%+.2f s" % shift
                      for b, (block, shift) in enumerate(zip(merged, shifts))), flush=True)
    result, n = [], 0
    for k, (start, text) in enumerate(timed):
        if text:
            n = entries.index(k)
            result.append((start + line_shift[n], text))
        else:
            # the end of a line: moved as the line before it
            result.append((None if start is None else start + line_shift[n], text))
    return result


def lyric_segments(lines, segments, audio_seconds=None):
    heard = heard_words(segments)
    if not heard:
        return segments
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

    result, prev_end = [], 0.0
    for i, j in groups:
        start = max(prev_end, min(spans[k][0] for k in range(i, j)) - PAD_SECONDS)
        last = max(spans[k][1] for k in range(i, j))
        end = max(start + 0.5 * (j - i), last + PAD_SECONDS)
        result.append({"text": " ".join(lines[i:j]), "start": start, "end": end})
        prev_end = last
    repeated = sum(1 for i, j in groups if j - i > 1)
    if repeated:
        print("[lyrics] %d runs of repeated lines aligned as blocks" % repeated, flush=True)
    matched = sum(1 for t in times if t is not None)
    print("[lyrics] %d lines, %d of %d words found in the transcription"
          % (len(lines), matched, len(words)), flush=True)
    return result


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
    it fades well below its own peak, which a held note does not."""
    def level(t):
        f = int(t * 100)
        return levels[f] if 0 <= f < len(levels) else VOICE_DB - 1

    def sounds(t):
        return level(t) > VOICE_DB
    lines = [[w for w in seg.get("words", []) if "start" in w and "end" in w] for seg in aligned]
    lines = [words for words in lines if words]
    for n, words in enumerate(lines):
        first, last = words[0], words[-1]
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
        if n + 1 < len(lines):
            next_start = lines[n + 1][0]["start"]
            if last["end"] > next_start - 0.02:
                last["end"] = round(max(last["start"] + 0.05, next_start - 0.02), 3)
    return aligned


def install(lyrics_path):
    import whisperx
    timed = read_timed_lyrics(lyrics_path)
    lines = [text for _, text in timed if text]
    original_align = whisperx.align

    def align(segments, model, metadata, audio, *args, **kwargs):
        kwargs["return_char_alignments"] = True
        result = aligned(segments, model, metadata, audio, *args, **kwargs)
        save_char_times(result)
        return result

    def aligned(segments, model, metadata, audio, *args, **kwargs):
        if lines:
            seconds = len(audio) / 16000.0 if hasattr(audio, "__len__") else None
            fitted = fitted_times(timed, segments) if timed and all(t is not None for t, _ in timed) else None
            placed = fitted and timed_segments(fitted, seconds)
            if placed:
                result = original_align(placed, model, metadata, audio, *args, **kwargs)
                trim_line_edges(result.get("segments", []), vocal_levels(audio), audio)
                return result
            segments = lyric_segments(lines, segments, seconds)
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


# H.264 up to 1080p: YouTube's best is often AV1 in 4K, which the game
# decodes in software and stutters on
PLAYABLE_VIDEO = ("bestvideo[vcodec^=avc1][height<=1080]+bestaudio"
                  "/bestvideo[ext=mp4][height<=1080]+bestaudio/best[height<=1080]/best")


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
