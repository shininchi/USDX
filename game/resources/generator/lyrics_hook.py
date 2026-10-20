"""Runs UltraSinger with known lyrics instead of the ones Whisper hears.

Usage: python lyrics_hook.py LYRICS_FILE UltraSinger.py [UltraSinger options]

Whisper mishears sung words ("gala bombonera" for "La Rosaleda"). When the
real lyrics are known, this hook keeps Whisper only for timing: each lyric
line is placed where the transcription heard the most similar words, and
whisperx then aligns the real words inside that time window. Everything
else (separation, pitch, writing the song) is UltraSinger as usual.

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
            result.append((normalize(w), start, end))
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


def checked_times(timed, segments):
    """Synced times as they fit this recording: LRCLIB may have them for
    another one (a longer intro...). The lines Whisper heard tell the shift;
    if they do not agree on one, the times are not used (None)."""
    heard = heard_words(segments)
    lines = [text for _, text in timed if text]
    starts = [start for start, text in timed if text]
    spans = line_spans(lines, heard) if heard else []
    deltas = sorted(span[0] - start for span, start in zip(spans, starts) if span)
    if len(deltas) < 3:
        return timed
    shift = deltas[len(deltas) // 2]
    spread = sorted(abs(d - shift) for d in deltas)[len(deltas) // 2]
    if spread > 1.0:
        print("[lyrics] the synced times do not fit this recording, not using them", flush=True)
        return None
    if abs(shift) > 0.15:
        print("[lyrics] synced times moved %.2f s to fit this recording" % shift, flush=True)
        return [(None if start is None else start + shift, text) for start, text in timed]
    return timed


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


def install(lyrics_path):
    import whisperx
    timed = read_timed_lyrics(lyrics_path)
    lines = [text for _, text in timed if text]
    original_align = whisperx.align

    def align(segments, model, metadata, audio, *args, **kwargs):
        if lines:
            seconds = len(audio) / 16000.0 if hasattr(audio, "__len__") else None
            fitted = checked_times(timed, segments) if timed and all(t is not None for t, _ in timed) else None
            segments = (fitted and timed_segments(fitted, seconds)) or lyric_segments(lines, segments, seconds)
        return original_align(segments, model, metadata, audio, *args, **kwargs)

    whisperx.align = align


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


def main():
    lyrics_path, script = sys.argv[1], sys.argv[2]
    install(lyrics_path)
    sys.argv = [script] + sys.argv[3:]
    sys.path.insert(0, os.path.dirname(os.path.abspath(script)))
    keep_words_in_silence()
    runpy.run_path(script, run_name="__main__")


if __name__ == "__main__":
    main()
