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


def read_lyrics(path):
    data = open(path, "rb").read()
    try:
        text = data.decode("utf-8-sig")
    except UnicodeDecodeError:
        text = data.decode("cp1252", errors="replace")
    lines = []
    for line in text.splitlines():
        line = line.strip()
        if not line or re.fullmatch(r"[\[(].*[\])]", line):
            continue
        lines.append(line)
    return lines


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
    song_end = max(heard[-1][2], audio_seconds or 0)
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

    result, prev_end = [], 0.0
    for i, line in enumerate(lines):
        start = max(prev_end, spans[i][0] - PAD_SECONDS)
        end = max(start + 0.5, spans[i][1] + PAD_SECONDS)
        result.append({"text": line, "start": start, "end": end})
        prev_end = spans[i][1]
    matched = sum(1 for t in times if t is not None)
    print("[lyrics] %d lines, %d of %d words found in the transcription"
          % (len(lines), matched, len(words)), flush=True)
    return result


def install(lyrics_path):
    import whisperx
    lines = read_lyrics(lyrics_path)
    original_align = whisperx.align

    def align(segments, model, metadata, audio, *args, **kwargs):
        if lines:
            seconds = len(audio) / 16000.0 if hasattr(audio, "__len__") else None
            segments = lyric_segments(lines, segments, seconds)
        return original_align(segments, model, metadata, audio, *args, **kwargs)

    whisperx.align = align


def main():
    lyrics_path, script = sys.argv[1], sys.argv[2]
    install(lyrics_path)
    sys.argv = [script] + sys.argv[3:]
    sys.path.insert(0, os.path.dirname(os.path.abspath(script)))
    runpy.run_path(script, run_name="__main__")


if __name__ == "__main__":
    main()
