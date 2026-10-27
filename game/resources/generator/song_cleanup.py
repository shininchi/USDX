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

import bisect
import json
import math

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
    """Moves back a lone note an octave away from the notes on both sides.

    The detected octave is right nearly always (it is what is sung):
    moving every note to the octave closest to the previous one put many
    a fourth or a fifth on the wrong side, so only a note that jumps far
    from both neighbours the same way, the pitch tracker slipping, is
    moved. Notes jumping up and down by an octave are hard to read and
    keep the parts of a syllable from being merged.
    """
    original = [n.pitch for n in notes]
    for i, note in enumerate(notes):
        around = [original[j] for j in (i - 1, i + 1) if 0 <= j < len(notes)]
        if not around:
            continue
        diffs = [original[i] - p for p in around]
        if all(d >= 9 for d in diffs) or all(d <= -9 for d in diffs):
            note.pitch = original[i] - 12 * round(sum(diffs) / len(diffs) / 12.0)


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


BREAK_AFTER_SECONDS = 2.0  # where a line break goes after the line's end


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


def fit_line_end(notes, voiced, gap, beat_seconds):
    """The last syllables of a line that fall after the voice stops (a long
    word split into syllables without looking at the sound) are moved into
    the voice, with the ones before them."""
    if not voiced or len(notes) < 2:
        return
    frame = 0.01
    first = int((gap + notes[0].start * beat_seconds) / frame)
    last = min(len(voiced), int((gap + notes[-1].end * beat_seconds) / frame))
    voice_end = None
    for i in range(last - 1, first - 1, -1):
        if voiced[i]:
            voice_end = (i + 1) * frame
            break
    if voice_end is None:
        return
    k = next((i for i, n in enumerate(notes) if gap + n.start * beat_seconds >= voice_end - 0.02), None)
    if not k:  # none in silence, or all of them
        return
    # the syllables from the last one with voice on are squeezed into what
    # is left of it, keeping their proportions; earlier ones join in until
    # none is shorter than MIN_FITTED_SECONDS
    end_beat = int(round((voice_end - gap) / beat_seconds))
    j = k - 1
    while True:
        begin = notes[j].start
        scale = (end_beat - begin) / float(max(1, notes[-1].end - begin))
        shortest = min(n.length for n in notes[j:]) * scale * beat_seconds
        if shortest >= MIN_FITTED_SECONDS or j == 0:
            break
        j -= 1
    if end_beat - begin < len(notes) - j:
        return
    starts = [begin + int(round((n.start - begin) * scale)) for n in notes[j:]] + [end_beat]
    for i, note in enumerate(notes[j:]):
        note.start = max(starts[i], notes[j + i - 1].end if i else starts[i])
        note.length = max(1, starts[i + 1] - note.start)


MIN_FITTED_SECONDS = 0.1  # syllables fitted into the end of the voice


PITCH_CONFIDENCE = 0.5  # pitch track frames below this are not the voice
PITCH_FRAME = 0.01      # seconds per frame of a pitch track
MIN_STEADY_SECONDS = 0.12  # a steady pitch this long inside a note is a note of its own

# Krumhansl's key profiles, to find the key of the song
KEY_MAJOR = (6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88)
KEY_MINOR = (6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17)


def vocal_pitch(vocals_wav):
    """The sung pitch (MIDI, NaN where none) of each 10 ms of the separated
    vocals, by pyin: against human charts it got more notes right than
    UltraSinger's own pitch track. None if it cannot be had."""
    try:
        import librosa
        import numpy as np
        y, _ = librosa.load(vocals_wav, sr=16000, mono=True)
        f0, voiced, _ = librosa.pyin(y, fmin=65, fmax=1000, sr=16000, frame_length=1024, hop_length=160)
        return librosa.hz_to_midi(np.where(voiced, f0, np.nan))
    except Exception as e:  # UltraSinger's track is used instead
        print("No vocal pitch: %s" % e, flush=True)
        return None


def write_pitch_file(path, track):
    """Leaves the sung pitch next to the song for the editor to draw behind
    the notes: a header line, then the MIDI pitch times 10 every 10 ms, 0
    where nobody sings."""
    try:
        with open(path, "w", encoding="utf-8", newline="\n") as f:
            f.write("# sung pitch: MIDI x10 every 10 ms, 0 = silence\n")
            f.write("\n".join("0" if math.isnan(p) else str(int(round(p * 10))) for p in track) + "\n")
    except Exception as e:  # the song works without it
        print("No pitch file: %s" % e, flush=True)


def read_pitch_track(path):
    """UltraSinger's pitch track (SwiftF0's cache: times, frequencies,
    confidence) as a vocal_pitch() one, None if it cannot be read."""
    try:
        import numpy as np
        data = json.load(open(path))
        times = np.array(data["times"])
        freqs = np.array(data["frequencies"])
        conf = np.array(data["confidence"])
    except Exception as e:  # cleaning up still works without it
        print("No pitch track: %s" % e, flush=True)
        return None
    frames = np.arange(int(times[-1] / PITCH_FRAME) + 1) * PITCH_FRAME
    k = np.clip(np.searchsorted(times, frames), 0, len(times) - 1)
    good = (conf[k] >= PITCH_CONFIDENCE) & (freqs[k] > 65) & (freqs[k] < 1000)
    track = np.full(len(frames), np.nan)
    track[good] = 69 + 12 * np.log2(freqs[k][good] / 440.0)
    return track


def song_scale(track):
    """Pitch classes of the key the song is sung in (major or minor)."""
    import numpy as np
    sung = track[~np.isnan(track)]
    if len(sung) < 100:
        return None
    hist = np.bincount(np.mod(np.round(sung), 12).astype(int), minlength=12)
    _, key, minor = max((np.corrcoef(np.roll(profile, k), hist)[0, 1], k, minor)
                        for k in range(12) for profile, minor in ((KEY_MAJOR, False), (KEY_MINOR, True)))
    steps = (0, 2, 3, 5, 7, 8, 10) if minor else (0, 2, 4, 5, 7, 9, 11)
    return set((key + s) % 12 for s in steps)


def in_key(pitch, scale):
    """The semitone for a sung pitch: the nearest one in the key when the
    nearest of all is out of it (a voice between two notes)."""
    nearest = int(round(pitch))
    if not scale or nearest % 12 in scale:
        return nearest
    around = [c for c in (int(math.floor(pitch)), int(math.ceil(pitch))) if c % 12 in scale]
    return min(around, key=lambda c: abs(c - pitch)) if around else nearest


def steady_runs(semitones, min_frames):
    """[start, end, semitone] of the stretches of one semitone at least
    min_frames long, next ones of the same semitone joined."""
    runs, k = [], 0
    while k < len(semitones):
        j = k
        while j < len(semitones) and semitones[j] == semitones[k]:
            j += 1
        if semitones[k] is not None and j - k >= min_frames:
            if runs and runs[-1][2] == semitones[k]:
                runs[-1][1] = j
            else:
                runs.append([k, j, semitones[k]])
        k = j
    return runs


STRAY_SEMITONES = 12   # a note this far from the singer's usual pitch
STRAY_DB = 6           # and this much quieter than the loudest note around
STRAY_AROUND = 4.0     # seconds on each side, is not the singer


def drop_stray_notes(notes, levels, gap, beat_seconds):
    """Reverb, echoes and backing voices left in the separated vocals make
    notes far above or below the singer and quieter than them, often held
    at the end of a line where nobody is heard. Such a hold is dropped; a
    syllable keeps its note, moved to the singer's octave. Returns the new
    list of notes."""
    if not notes or not levels:
        return notes
    lengths = sorted((n.pitch, n.length) for n in notes)
    half, total, usual = sum(l for _, l in lengths) / 2.0, 0, lengths[0][0]
    for pitch, length in lengths:
        total += length
        if total >= half:
            usual = pitch
            break

    def level(note):
        a = max(0, int((gap + note.start * beat_seconds) / PITCH_FRAME))
        b = min(len(levels), max(a + 1, int((gap + note.end * beat_seconds) / PITCH_FRAME)))
        frames = sorted(levels[a:b])
        return frames[len(frames) // 2] if frames else -100

    loudness = [level(n) for n in notes]
    around = STRAY_AROUND / beat_seconds
    out = []
    for i, note in enumerate(notes):
        loudest = max(loudness[j] for j in range(len(notes))
                      if abs(notes[j].start - note.start) <= around)
        if abs(note.pitch - usual) > STRAY_SEMITONES and loudness[i] < loudest - STRAY_DB:
            if note.is_continuation:
                if note.ends_word and out and not out[-1].ends_word:
                    out[-1].text += " "
                continue
            note.pitch -= 12 * round((note.pitch - usual) / 12.0)
        out.append(note)
    return out


VOWELS = set("aeiouáéíóúü")


def ends_in_vowel(text):
    text = text.strip().lower()
    return text[-1:] in VOWELS or text == "y"


def starts_with_vowel(text):
    """Whether a word sounds from a vowel: "h" is silent, and "y" is a
    vowel alone or before a consonant ("y", "yo" is not)."""
    text = text.strip().lower()
    if text[:1] == "h":
        text = text[1:]
    if text[:1] == "y":
        return len(text) == 1 or text[1:2] not in VOWELS
    return text[:1] in VOWELS and not any(c.isdigit() for c in text)


JOIN_GAP_SECONDS = 0.3  # words further apart are not sung as one syllable


def join_vowel_syllables(notes, beat_seconds):
    """A word ending in a vowel and the next one starting with one are sung
    as one syllable in Spanish ("que‿en", "mi‿objetivo"), and charts write
    them in one note ("que en"): in the human charts tried, 85% of them.
    The text of the first syllable of the second word joins the last note
    of the first word; its note stays, held ("~") at its own pitch, or is
    the same note when the pitch is the same: giving the joined note one
    pitch over both lost notes sung at another. Only inside a line, not
    after a held note. Returns the new list of notes."""
    max_gap = JOIN_GAP_SECONDS / beat_seconds
    out = []
    for note in notes:
        last = out[-1] if out else None
        if (last is not None and last.ends_word and not last.is_continuation
                and not note.is_continuation and ends_in_vowel(last.text)
                and starts_with_vowel(note.text)
                and note.start - last.end <= max_gap):
            last.text = last.text + note.text.rstrip(" ")
            held = "~" + (" " if note.ends_word else "")
            if note.pitch == last.pitch:
                last.length = note.end - last.start
                last.text = last.text.rstrip(" ") + held[1:]
                continue
            note = Note(note.kind, note.start, note.length, note.pitch, held)
        out.append(note)
    return out


MIN_SYLLABLE_SECONDS = 0.08  # syllables split from a joined note last at least this


SPANISH_VOWELS = "aeiouáéíóúü"
SPANISH_STRONG = "aeoáéóíú"  # two of these are sung apart (hiatus): rí-o, ca-er
SPANISH_ONSETS = {"pl", "pr", "bl", "br", "fl", "fr", "cl", "cr", "gl", "gr", "tr", "dr", "kl", "kr"}


def spanish_syllables(word):
    """The syllables of a Spanish word by the rules of its spelling. The
    hyphenation dictionaries never split off one letter at the start or
    the end of a word, which are syllables when sung: e-se, a-mor, o-ro."""
    core = word.strip()
    lead = len(core) - len(core.lstrip("¡¿\"'(«"))
    trail = len(core) - len(core.rstrip("!?.,;:\"')»…"))
    head, body, tail = core[:lead], core[lead:len(core) - trail], core[len(core) - trail:]
    if not body or not body.isalpha():
        return None
    low = body.lower()
    # units: letters, with ch, ll, rr and the qu/gu before e and i as one consonant
    units, i = [], 0
    while i < len(low):
        pair = low[i:i + 2]
        if pair in ("ch", "ll", "rr") or (pair in ("qu", "gu") and low[i + 2:i + 3] in ("e", "i", "é", "í")):
            units.append((body[i:i + 2], False))
            i += 2
            continue
        c = low[i]
        vowel = c in SPANISH_VOWELS
        if c == "y":  # a vowel at the end of a word or before a consonant: hay, rey
            vowel = i + 1 == len(low) or low[i + 1] not in SPANISH_VOWELS
        units.append((body[i], vowel))
        i += 1
    # nuclei: runs of vowels, apart where two strong ones meet
    syllables, current, consonants = [], "", []
    prev_vowel = None
    for text, vowel in units:
        if vowel:
            v = text.lower()
            if prev_vowel is not None and not consonants and \
               prev_vowel in SPANISH_STRONG and v in SPANISH_STRONG:
                syllables.append(current)
                current = ""
            elif prev_vowel is not None and consonants:
                # consonants between two vowels: one goes with the next
                # syllable, two that start syllables (pr, bl...) go together
                n = len(consonants)
                pair = lambda a, b: (consonants[a] + consonants[b]).lower() in SPANISH_ONSETS
                if n == 1:
                    keep = 0
                elif n == 2:
                    keep = 0 if pair(0, 1) else 1
                elif n == 3:
                    keep = 1 if pair(1, 2) else 2
                else:
                    keep = 2
                syllables.append(current + "".join(consonants[:keep]))
                current = "".join(consonants[keep:])
                consonants = []
            current += "".join(consonants) + text
            consonants = []
            prev_vowel = v
        else:
            if prev_vowel is None:
                current += text
            else:
                consonants.append(text)
    current += "".join(consonants)
    syllables.append(current)
    if len(syllables) < 2:
        return None
    syllables[0] = head + syllables[0]
    syllables[-1] = syllables[-1] + tail
    return syllables if "".join(syllables) == core else None


def syllable_splitter(language):
    """A function giving the syllables of a word in the language (a code
    like "es"), None for words of one; None if there is no dictionary."""
    if language == "es":
        return spanish_syllables
    try:
        from hyphen import Hyphenator, dictools
        installed = [d for d in dictools.list_installed() if d.split("_")[0] == language]
        if not installed:
            return None
        hyphenator = Hyphenator(installed[0])
    except Exception as e:  # cleaning up still works without it
        print("No hyphenation: %s" % e, flush=True)
        return None

    def split(word):
        try:
            parts = hyphenator.syllables(word)
        except Exception:
            return None
        return parts if len(parts) > 1 and "".join(parts) == word else None
    return split


def letters_of(text):
    return [c for c in text.lower() if c.isalnum()]


def place_syllables_by_letters(notes, letters, gap, beat_seconds):
    """Starts each syllable inside a word when WhisperX heard its first
    letter, instead of sharing the word's time evenly among its syllables
    ("sal-va-ción" sung slowly on "va" put "va" where "sal" is still sung).
    letters: for each word aligned, [letter, start or None] in order; words
    are matched to them in order by their letters."""
    min_beats = max(1, round(MIN_SYLLABLE_SECONDS / beat_seconds))
    aligned = [(letters_of("".join(c for c, _ in word)), word) for word in letters]
    k = 0
    for word in words(notes):
        sylls = []
        for note in word:
            if sylls and note.is_continuation:
                sylls[-1].append(note)
            else:
                sylls.append([note])
        text = [letters_of(s[0].text) for s in sylls]
        whole = sum(text, [])
        match = next((j for j in range(k, min(k + 4, len(aligned))) if aligned[j][0] == whole), None)
        if match is None:
            continue
        k = match + 1
        times = [t for c, t in aligned[match][1] if c.isalnum() or c.lower() in "áéíóúüñ"]
        if len(sylls) < 2 or len(times) != len(whole):
            continue
        offset = 0
        for i in range(1, len(sylls)):
            offset += len(text[i - 1])
            known = [t for t in times[offset:offset + len(text[i])] if t is not None]
            if not known:
                continue
            new = int(round((known[0] - gap) / beat_seconds))
            prev, cur = sylls[i - 1], sylls[i]
            latest = cur[0].end - min_beats if len(cur) == 1 else cur[1].start - min_beats
            new = max(prev[-1].start + min_beats, min(latest, new))
            if new == cur[0].start:
                continue
            end = cur[0].end
            cur[0].start, cur[0].length = new, end - new
            prev[-1].length = new - prev[-1].start


def split_joined_syllables(notes, beat_seconds, split):
    """UltraSinger joins the syllables of a word it hears on one pitch into
    one note ("resistir"), so the singer gets a single bar for three sung
    syllables. Each joined syllable gets its note again, sharing the time
    evenly: cutting at the consonants instead matched human charts no
    better. Returns the new list of notes."""
    min_beats = max(1, round(MIN_SYLLABLE_SECONDS / beat_seconds))
    out = []
    for word in words(notes):
        groups = []
        for note in word:
            if groups and note.is_continuation:
                groups[-1].append(note)
            else:
                groups.append([note])
        for group in groups:
            text = group[0].text.strip()
            parts = split(text) if text and not group[0].is_continuation else None
            start, end = group[0].start, group[-1].end
            if not parts or end - start < min_beats * len(parts):
                out.extend(group)
                continue
            cuts = [start + int(round((end - start) * i / len(parts))) for i in range(1, len(parts))]
            # the syllable cuts and the pitch changes already there
            bounds = sorted(set([start, end] + cuts + [n.start for n in group[1:]]))
            for s0, s1 in zip(bounds, bounds[1:]):
                source = next(n for n in reversed(group) if n.start <= s0)
                if s0 == start:
                    piece_text = parts[0]
                elif s0 in cuts:
                    piece_text = parts[cuts.index(s0) + 1]
                else:
                    piece_text = "~"
                out.append(Note(source.kind, s0, s1 - s0, source.pitch, piece_text))
            if group[-1].ends_word:
                out[-1].text += " "
    return out


def sung_pitches(notes, track, gap, beat_seconds):
    """Each note takes the pitch sung during it, in the key of the song, and
    a note over several steady pitches (a syllable sung up or down the
    scale) is split into one note per pitch. UltraSinger's notes, and more
    so once merged and moved, are often not what is sung: against the
    human charts of La salvación and Cowboys de la A3, the right pitch
    went from 66% and 73% of the time (median of UltraSinger's track) to
    89% and 93%."""
    import numpy as np
    scale = song_scale(track)
    min_frames = int(round(MIN_STEADY_SECONDS / PITCH_FRAME))
    i = 0
    while i < len(notes):
        note = notes[i]
        a = int((gap + note.start * beat_seconds) / PITCH_FRAME)
        b = int((gap + note.end * beat_seconds) / PITCH_FRAME)
        sung = track[max(0, a):max(0, b)]
        known = sung[~np.isnan(sung)]
        if len(known) < 2:
            i += 1
            continue
        note.pitch = in_key(float(np.median(known)), scale) - 48  # UltraStar 0 = MIDI 48
        runs = steady_runs([None if np.isnan(x) else in_key(x, scale) for x in sung], min_frames) \
            if b - a >= 2 * min_frames else []
        if len(runs) < 2:
            i += 1
            continue
        cuts = [note.start] + [note.start + int(round(r[0] * PITCH_FRAME / beat_seconds)) for r in runs[1:]] + [note.end]
        pieces = []
        for k, run in enumerate(runs):
            if cuts[k + 1] > cuts[k]:
                text = note.text.rstrip(" ") if not pieces else "~"
                pieces.append(Note(note.kind, cuts[k], cuts[k + 1] - cuts[k], run[2] - 48, text))
        if len(pieces) < 2:
            i += 1
            continue
        if note.text.endswith(" "):
            pieces[-1].text += " "
        notes[i:i + 1] = pieces
        i += len(pieces)


SLIDE_SECONDS = 0.03      # a slide this long into or out of a note is left out
MIN_TRIMMED_SECONDS = 0.1 # unless the note would be shorter than this


LEAD_SILENCE_SECONDS = 0.15  # silence longer than a consonant before a syllable
BREATH_SECONDS = 0.2         # a breath between the voice heard and the syllable
STRAY_START_SECONDS = 0.3    # voice before such a breath is the line before


def start_with_voice(notes, track, gap, beat_seconds):
    """Starts each syllable where its voice starts: the word timings often
    begin a line in the music before it, or on the last held note of the
    line before and a breath. A syllable with nothing sung of its own, right
    before its held "~", gives its text to that note."""
    import numpy as np
    out = []
    for i, note in enumerate(notes):
        if note.is_continuation:
            out.append(note)
            continue
        a = int((gap + note.start * beat_seconds) / PITCH_FRAME)
        b = int((gap + note.end * beat_seconds) / PITCH_FRAME)
        voiced = ~np.isnan(track[max(0, a):max(0, b)])
        first = 0
        while first < len(voiced) and not voiced[first]:
            first += 1
        if first * PITCH_FRAME < LEAD_SILENCE_SECONDS:
            first = 0
        # a short bit of voice and a breath: the line before, not this syllable
        while True:
            end = first
            while end < len(voiced) and voiced[end]:
                end += 1
            after = end
            while after < len(voiced) and not voiced[after]:
                after += 1
            if (end - first) * PITCH_FRAME < STRAY_START_SECONDS and \
               (after - end) * PITCH_FRAME >= BREATH_SECONDS and after < len(voiced):
                first = after
            else:
                break
        if first == 0 and voiced.any():
            out.append(note)
            continue
        start = note.start + int(round(first * PITCH_FRAME / beat_seconds))
        if (note.end - start) * beat_seconds < MIN_TRIMMED_SECONDS or not voiced[first:].any():
            following = notes[i + 1] if i + 1 < len(notes) else None
            if following is not None and following.is_continuation and \
               (following.start - note.end) * beat_seconds <= 0.1:
                # sung on the held note: the syllable starts there
                following.text = note.text.rstrip() + following.text.strip()[1:] + \
                    (" " if following.ends_word or note.ends_word else "")
                if voiced[first:].any() and start < following.start:
                    following.length += following.start - start
                    following.start = start
                continue
            out.append(note)
            continue
        if start > note.start:
            note.length = note.end - start
            note.start = start
        out.append(note)
    return out


def trim_to_steady(notes, track, gap, beat_seconds):
    """Starts each note where the voice reaches its pitch and ends it where
    the voice leaves it: the slides into and out of a note are not that
    note, and the singer got no points for them. Gaps are not scored, so
    the voice that was recorded gets the most points; against the human
    charts its score on Hard went from 78% and 75% to 86%, as theirs."""
    import numpy as np
    for note in notes:
        a = int((gap + note.start * beat_seconds) / PITCH_FRAME)
        b = int((gap + note.end * beat_seconds) / PITCH_FRAME)
        sung = track[max(0, a):max(0, b)]
        off = np.abs(np.mod(sung - 48 - note.pitch + 6, 12) - 6)  # octave apart is on pitch
        on = np.where(~np.isnan(sung) & (np.nan_to_num(off, nan=99) <= 0.5))[0]
        if len(on) < 2:
            continue
        start, end = note.start, note.end
        if on[0] * PITCH_FRAME >= SLIDE_SECONDS:
            start = note.start + int(round(on[0] * PITCH_FRAME / beat_seconds))
        if (len(sung) - 1 - on[-1]) * PITCH_FRAME >= SLIDE_SECONDS:
            end = note.start + int(round((on[-1] + 1) * PITCH_FRAME / beat_seconds))
        if end > start and (end - start) * beat_seconds >= MIN_TRIMMED_SECONDS:
            note.start, note.length = start, end - start


def clean_up(body, bpm, gap_ms=0, onsets=None, lyric_lines=None, voiced=None, pitch_track=None, split=None, levels=None, letters=None):
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
    # one note per sung syllable, also where UltraSinger joined them
    if split:
        merged = split_joined_syllables(merged, beat_seconds, split)
    if letters:
        place_syllables_by_letters(merged, letters, gap_ms / 1000.0, beat_seconds)

    out = []
    # the last syllable of each line ends with the voice
    if voiced:
        for line in (lines_like_lyrics(merged, lyric_lines) if lyric_lines else break_lines(merged, beat_seconds)):
            if line and line[-1]:
                fit_line_end([n for word in line for n in word], voiced, gap_ms / 1000.0, beat_seconds)
                trim_line_end(line[-1][-1], voiced, gap_ms / 1000.0, beat_seconds)
    # the pitch of each note, once it is where it is sung
    if pitch_track is not None:
        merged = start_with_voice(merged, pitch_track, gap_ms / 1000.0, beat_seconds)
        sung_pitches(merged, pitch_track, gap_ms / 1000.0, beat_seconds)
        fold_octaves(merged)
        merged = drop_stray_notes(merged, levels, gap_ms / 1000.0, beat_seconds)
        trim_to_steady(merged, pitch_track, gap_ms / 1000.0, beat_seconds)
    if lyric_lines:
        lines = lines_like_lyrics(merged, lyric_lines)
    else:
        lines = break_lines(merged, beat_seconds)
    for i, line in enumerate(lines):
        notes_of_line = [n for word in line for n in word]
        out.extend(n.line() for n in join_vowel_syllables(notes_of_line, beat_seconds))
        if i < len(lines) - 1:
            last = line[-1][-1]
            following = lines[i + 1][0][0]
            # the next line shows up 2 s after this one ends, as in most
            # songs, or halfway through a shorter pause
            pause = max(0, following.start - last.end)
            out.append("- %d" % (last.end + min(pause // 2, round(BREAK_AFTER_SECONDS / beat_seconds))))
    out.append("E")
    return out


def vocal_levels(vocals_wav):
    """For each 10 ms of the separated vocals, its loudness in dB below the
    loudest moment."""
    try:
        import librosa
        import numpy as np
        y, sr = librosa.load(vocals_wav, sr=16000, mono=True)
        rms = librosa.feature.rms(y=y, frame_length=640, hop_length=160)[0]
        return list(librosa.amplitude_to_db(rms, ref=np.max))
    except Exception as e:  # cleaning up still works without it
        print("No vocal levels: %s" % e, flush=True)
        return []


def vocal_activity(vocals_wav, levels=None):
    """For each 10 ms of the separated vocals, whether the voice sounds."""
    if levels is None:
        levels = vocal_levels(vocals_wav)
    return [db > -32 for db in levels]


def vocal_onsets(vocals_wav):
    """Times (seconds) where the voice starts a sound, empty if unknown."""
    try:
        import librosa
        y, sr = librosa.load(vocals_wav, sr=16000, mono=True)
        return list(librosa.onset.onset_detect(y=y, sr=sr, hop_length=160, units="time"))
    except Exception as e:  # cleaning up still works without it
        print("No vocal onsets: %s" % e, flush=True)
        return []
