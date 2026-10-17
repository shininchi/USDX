"""Clean up the notes UltraSinger writes, so the songs are nicer to sing.

UltraSinger makes a new note for every pitch step of the voice: held
syllables with vibrato or choirs turn into dozens of "~" notes. It also
breaks lines at every short pause, which gives lines of one or two words,
and never breaks long choruses sung without a pause.

clean_up() takes the lines of an UltraStar txt body (notes and line breaks)
and returns new lines with:
  - octave jumps of the pitch detection undone (the choir or the
    instruments make it jump an octave up or down every few notes)
  - the notes of each syllable merged when the pitch hardly changes or they
    are too short to sing, and at most MAX_PARTS notes per syllable
  - new line breaks: lines of a sensible length, split at pauses and at the
    end of sentences
  - words moved to where the voice really starts (onsets of the separated
    vocals), as the word times of the transcription are often a bit off
"""

NOTE_TYPES = (":", "*", "F", "R", "G")

MIN_PART_SECONDS = 0.18  # shorter parts of a syllable are merged with a neighbour
PITCH_TOLERANCE = 1      # semitones; closer parts are merged
MAX_PARTS = 3            # notes per syllable at most

LINE_IDEAL_CHARS = 26
LINE_MAX_CHARS = 40      # longer lines always break
LINE_MAX_SECONDS = 8.0
LONG_PAUSE_SECONDS = 1.5 # a pause that always ends a line
SENTENCE_END = (".", "!", "?", ",", ";", ":")
SNAP_SECONDS = 0.3       # words move at most this much to a vocal onset


def starts_sentence(text):
    return text[:1] in ("¡", "¿") or text[:1].isupper()


class Note:
    def __init__(self, kind, start, length, pitch, text):
        self.kind = kind
        self.start = start
        self.length = length
        self.pitch = pitch
        self.text = text

    @property
    def end(self):
        return self.start + self.length

    @property
    def is_continuation(self):
        return self.text.strip().startswith("~") or self.text.strip() == ""

    @property
    def ends_word(self):
        return self.text.endswith(" ")

    def line(self):
        return "%s %d %d %d %s" % (self.kind, self.start, self.length, self.pitch, self.text)


def parse_notes(body):
    notes = []
    for line in body:
        if line[:1] in NOTE_TYPES:
            parts = line.split(" ", 4)
            if len(parts) < 4:
                continue
            text = parts[4] if len(parts) > 4 else ""
            try:
                notes.append(Note(parts[0], int(parts[1]), int(parts[2]), int(parts[3]), text))
            except ValueError:
                continue
    return notes


def fold_octaves(notes):
    """Moves each note to the octave closest to the previous notes.

    Singing scores do not care about the octave, but notes jumping up and
    down by an octave are hard to read and keep the parts of a syllable
    from being merged.
    """
    if not notes:
        return
    pitches = sorted(n.pitch for n in notes)
    median = pitches[len(pitches) // 2]
    ref = None
    for note in notes:
        if ref is None:
            ref = median
        candidates = [note.pitch + 12 * k for k in range(-4, 5)]
        note.pitch = min(candidates, key=lambda c: abs(c - ref) + 0.3 * abs(c - median))
        ref = note.pitch


def syllables(notes):
    """Groups of a syllable note and the "~" notes that continue it."""
    groups = []
    for note in notes:
        if groups and note.is_continuation and not groups[-1][-1].ends_word:
            groups[-1].append(note)
        else:
            groups.append([note])
    return groups


def merge_into(target, other):
    """target takes over other (its neighbour); the longer one keeps its pitch."""
    if other.length > target.length:
        target.pitch = other.pitch
    start = min(target.start, other.start)
    end = max(target.end, other.end)
    target.start, target.length = start, end - start


def merge_syllable(group, beat_seconds):
    min_beats = max(1, round(MIN_PART_SECONDS / beat_seconds))
    word_end = group[-1].ends_word
    first_text = group[0].text.rstrip(" ")
    parts = [Note(n.kind, n.start, n.length, n.pitch, n.text) for n in group]

    changed = True
    while changed and len(parts) > 1:
        changed = False
        for i in range(len(parts) - 1):
            a, b = parts[i], parts[i + 1]
            if (abs(a.pitch - b.pitch) <= PITCH_TOLERANCE
                    or a.length < min_beats or b.length < min_beats):
                merge_into(a, b)
                del parts[i + 1]
                changed = True
                break

    # still too many: merge the shortest part into its closest neighbour
    while len(parts) > MAX_PARTS:
        i = min(range(len(parts)), key=lambda k: parts[k].length)
        if i == 0:
            j = 1
        elif i == len(parts) - 1:
            j = i - 1
        else:
            j = min((i - 1, i + 1), key=lambda k: abs(parts[k].pitch - parts[i].pitch))
        merge_into(parts[j], parts[i])
        del parts[i]

    # parts keep touching: the gaps inside a syllable are not pauses
    for a, b in zip(parts, parts[1:]):
        a.length = max(1, b.start - a.start)

    # Whisper writes chants in capitals ("VIVA EL VELEZ")
    if len(first_text) > 1 and first_text.isupper():
        first_text = first_text.lower()
    for i, part in enumerate(parts):
        part.text = first_text if i == 0 else "~"
    if word_end:
        parts[-1].text += " "
    return parts


def words(notes):
    result, current = [], []
    for note in notes:
        current.append(note)
        if note.ends_word:
            result.append(current)
            current = []
    if current:
        result.append(current)
    return result


def word_text(word):
    return "".join(n.text for n in word).replace("~", "").strip()


def snap_words(notes, onsets, gap, beat_seconds):
    """Moves the start of each word to the nearest vocal onset (seconds)."""
    if not onsets:
        return
    onset_beats = [(t - gap) / beat_seconds for t in onsets]
    max_shift = SNAP_SECONDS / beat_seconds
    prev_start = -1  # start of the last note of the previous word
    j = 0
    for word in words(notes):
        first = word[0]
        while j + 1 < len(onset_beats) and onset_beats[j + 1] <= first.start:
            j += 1
        candidates = onset_beats[j:j + 2]
        target = min(candidates, key=lambda b: abs(b - first.start))
        start = int(round(target))
        if (abs(target - first.start) <= max_shift
                and start > prev_start and start < first.end):
            first.length = first.end - start
            first.start = start
        prev_start = word[-1].start


def break_cost(prev_text, next_text, pause, in_exclamation):
    """Cost of a line break between two words; negative = a good place."""
    cost = -4.0 * min(pause, 2.0)
    if prev_text.endswith(SENTENCE_END):
        cost -= 3.0
    if starts_sentence(next_text):
        cost -= 3.0
    if in_exclamation:
        cost += 8.0
    if pause < 0.1:
        cost += 3.0
    return cost


def line_cost(chars, seconds, longest_pause):
    if chars > LINE_MAX_CHARS:
        return 1000.0 + chars
    cost = ((chars - LINE_IDEAL_CHARS) / 8.0) ** 2
    if longest_pause >= LONG_PAUSE_SECONDS:
        cost += 100.0
    if seconds > LINE_MAX_SECONDS:
        cost += 10.0 * (seconds - LINE_MAX_SECONDS)
    return cost


def break_lines(notes, beat_seconds):
    """Splits the words into lines with the lowest total cost."""
    ws = words(notes)
    n = len(ws)
    if n == 0:
        return []
    texts = [word_text(w) for w in ws]
    pauses = [max(0.0, (ws[i + 1][0].start - ws[i][-1].end) * beat_seconds)
              for i in range(n - 1)] + [0.0]
    # inside "¡...!" or "¿...?" after word i
    open_marks, inside = 0, []
    for t in texts:
        open_marks += t.count("¡") + t.count("¿") - t.count("!") - t.count("?")
        open_marks = max(open_marks, 0)
        inside.append(open_marks > 0)

    best = [0.0] + [float("inf")] * n  # best[j]: cost of words[:j]
    back = [0] * (n + 1)
    for j in range(1, n + 1):
        chars, longest = -1, 0.0
        for i in range(j - 1, -1, -1):
            chars += len(texts[i]) + 1
            if i < j - 1:
                longest = max(longest, pauses[i])
            if chars > LINE_MAX_CHARS and i < j - 1:
                break
            seconds = (ws[j - 1][-1].end - ws[i][0].start) * beat_seconds
            cost = best[i] + line_cost(chars, seconds, longest)
            if j < n:
                cost += break_cost(texts[j - 1], texts[j], pauses[j - 1], inside[j - 1])
            if cost < best[j]:
                best[j], back[j] = cost, i

    lines, j = [], n
    while j > 0:
        lines.append(ws[back[j]:j])
        j = back[j]
    return lines[::-1]


def lines_like_lyrics(notes, lyric_lines):
    """Lines with as many words as the lines of the given lyrics."""
    ws = words(notes)
    lines, pos = [], 0
    for line in lyric_lines:
        count = len(line.split())
        if count == 0 or pos >= len(ws):
            continue
        lines.append(ws[pos:pos + count])
        pos += count
    if pos < len(ws):  # words the lyrics do not have
        lines.append(ws[pos:])
    return lines


def clean_up(body, bpm, gap_ms=0, onsets=None, lyric_lines=None):
    beat_seconds = 60.0 / (bpm * 4)
    notes = parse_notes(body)
    if not notes:
        return body

    fold_octaves(notes)
    merged = []
    for group in syllables(notes):
        merged.extend(merge_syllable(group, beat_seconds))
    snap_words(merged, onsets, gap_ms / 1000.0, beat_seconds)
    # merging and moving may not make a note run into the next one
    for a, b in zip(merged, merged[1:]):
        if a.end > b.start:
            a.length = max(1, b.start - a.start)

    out = []
    if lyric_lines:
        lines = lines_like_lyrics(merged, lyric_lines)
    else:
        lines = break_lines(merged, beat_seconds)
    for i, line in enumerate(lines):
        for word in line:
            out.extend(n.line() for n in word)
        if i < len(lines) - 1:
            last = line[-1][-1]
            following = lines[i + 1][0][0]
            # the next line shows up halfway through the pause
            out.append("- %d" % (last.end + max(0, following.start - last.end) // 2))
    out.append("E")
    return out


def vocal_onsets(vocals_wav):
    """Times (seconds) where the voice starts a sound, empty if unknown."""
    try:
        import librosa
        y, sr = librosa.load(vocals_wav, sr=16000, mono=True)
        return list(librosa.onset.onset_detect(y=y, sr=sr, hop_length=160, units="time"))
    except Exception as e:  # cleaning up still works without it
        print("No vocal onsets: %s" % e, flush=True)
        return []
