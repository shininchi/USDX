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


LONG_SYLLABLE = 0.8   # seconds: a middle syllable longer than this (and than
                      # 2.5 times the song's usual one) is stretched


def shorten_long_syllables(notes, beat_seconds):
    """Gives back to the last syllable the time UltraSinger spread over the
    others: it shares a word's time, long held last vowel included, among
    its syllables, so in "sal...va...ción" sung slowly "va" comes a second
    or two after it is heard. Sung syllables follow each other and the last
    one holds, so a middle syllable much longer than usual is shortened and
    the next one starts sooner. Returns the new list of notes."""
    sylls_of = []
    lengths = []
    for word in words(notes):
        sylls = []
        for note in word:
            if sylls and note.is_continuation:
                sylls[-1].append(note)
            else:
                sylls.append([note])
        sylls_of.append(sylls)
        for syll, nxt in zip(sylls, sylls[1:]):
            lengths.append((nxt[0].start - syll[0].start) * beat_seconds)
    if not lengths:
        return notes
    usual = sorted(lengths)[len(lengths) // 2]
    too_long = max(LONG_SYLLABLE, 2.5 * usual)
    target = max(0.6, 1.5 * usual)
    target_beats = max(1, round(target / beat_seconds))
    result = []
    for sylls in sylls_of:
        for i, syll in enumerate(sylls):
            if i == len(sylls) - 1:
                result.extend(syll)
                continue
            nxt = sylls[i + 1]
            span = nxt[0].start - syll[0].start
            if span * beat_seconds <= too_long:
                result.extend(syll)
                continue
            # one note of a usual length, the next syllable starts sooner
            main = max(syll, key=lambda n: n.length)
            start = syll[0].start
            result.append(Note(syll[0].kind, start, target_beats, main.pitch, syll[0].text.rstrip(" ")))
            first = nxt[0]
            new_start = start + target_beats
            first.length = first.end - new_start
            first.start = new_start
    return result


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
    """The lines of the given lyrics: each sung word is matched with the
    lyrics, so a word that was lost or split does not shift the lines after
    it; words without a match stay in the line of the word before."""
    import difflib
    ws = words(notes)
    lyric_words, owner = [], []
    for i, line in enumerate(lyric_lines):
        for w in line.split():
            lyric_words.append(Normalize(w))
            owner.append(i)
    sung = [Normalize(word_text(w)) for w in ws]
    line_of = [None] * len(ws)
    matcher = difflib.SequenceMatcher(None, sung, lyric_words, autojunk=False)
    for a, b, size in matcher.get_matching_blocks():
        for k in range(size):
            line_of[a + k] = owner[b + k]
    # words that do not match (a lost syllable changed them): by position
    for tag, a1, a2, b1, b2 in matcher.get_opcodes():
        if tag == "replace":
            for k in range(a1, a2):
                if line_of[k] is None and b1 < b2:
                    line_of[k] = owner[min(b2 - 1, b1 + (k - a1))]
    lines, current, current_line = [], [], None
    for w, line in zip(ws, line_of):
        if line is not None and current and line != current_line:
            lines.append(current)
            current = []
        if line is not None:
            current_line = line
        current.append(w)
    if current:
        lines.append(current)
    return lines


def Normalize(text):
    import unicodedata
    text = unicodedata.normalize("NFD", text.lower())
    return "".join(c for c in text if c.isalnum() and unicodedata.category(c) != "Mn")


LINE_END_MIN = 0.15   # seconds the last syllable of a line keeps at least
VOICE_GONE = 0.12     # seconds of silence that end the voice


def trim_line_end(note, voiced, gap, beat_seconds):
    """Ends the last syllable of a line where the voice stops: the notes
    often hold on over the music after the singer is done."""
    if not voiced:
        return
    start = gap + note.start * beat_seconds
    end = gap + note.end * beat_seconds
    frame = 0.01
    need = int(VOICE_GONE / frame)
    i = int((start + LINE_END_MIN) / frame)
    last = min(len(voiced), int(end / frame))
    while i < last:
        if not voiced[i] and all(not v for v in voiced[i:i + need]):
            new_end = i * frame
            note.length = max(1, int(round((new_end - gap) / beat_seconds)) - note.start)
            return
        i += 1


def clean_up(body, bpm, gap_ms=0, onsets=None, lyric_lines=None, voiced=None):
    beat_seconds = 60.0 / (bpm * 4)
    notes = parse_notes(body)
    if not notes:
        return body

    fold_octaves(notes)
    merged = []
    for group in syllables(notes):
        merged.extend(merge_syllable(group, beat_seconds))
    snap_words(merged, onsets, gap_ms / 1000.0, beat_seconds)
    merged = shorten_long_syllables(merged, beat_seconds)
    # merging and moving may not make a note run into the next one
    for a, b in zip(merged, merged[1:]):
        if a.end > b.start:
            a.length = max(1, b.start - a.start)

    out = []
    # the last syllable of each line ends with the voice
    if voiced:
        for line in (lines_like_lyrics(merged, lyric_lines) if lyric_lines else break_lines(merged, beat_seconds)):
            if line and line[-1]:
                trim_line_end(line[-1][-1], voiced, gap_ms / 1000.0, beat_seconds)
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


def vocal_activity(vocals_wav):
    """For each 10 ms of the separated vocals, whether the voice sounds."""
    try:
        import librosa
        import numpy as np
        y, sr = librosa.load(vocals_wav, sr=16000, mono=True)
        rms = librosa.feature.rms(y=y, frame_length=640, hop_length=160)[0]
        db = librosa.amplitude_to_db(rms, ref=np.max)
        return list(db > -32)
    except Exception as e:  # cleaning up still works without it
        print("No vocal activity: %s" % e, flush=True)
        return []


def vocal_onsets(vocals_wav):
    """Times (seconds) where the voice starts a sound, empty if unknown."""
    try:
        import librosa
        y, sr = librosa.load(vocals_wav, sr=16000, mono=True)
        return list(librosa.onset.onset_detect(y=y, sr=sr, hop_length=160, units="time"))
    except Exception as e:  # cleaning up still works without it
        print("No vocal onsets: %s" % e, flush=True)
        return []
