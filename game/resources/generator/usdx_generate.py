#!/usr/bin/env python3
"""Generate an UltraStar song with UltraSinger, for the in-game song generator.

The game runs this script with UltraSinger's own Python and reads its output
line by line. Lines starting with "@@" are for the game:

  @@STAGE <name>   a new step started (download, separate, transcribe, pitch, write)
  @@DONE <path>    the song txt that was written
  @@ERROR <text>   generation failed

Modes:
  --input FILE|URL --out DIR       new song folder inside DIR
  --input FILE --replace TXT       write new notes into an existing song txt,
                                   keeping its header (title, artist, cover...)
"""

import argparse
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile

import song_cleanup

STAGES = [
    ("Downloading", "download"),
    ("Separating vocals", "separate"),
    ("Loading whisper", "transcribe"),
    ("Transcribing", "transcribe"),
    ("Pitching", "pitch"),
    ("Creating UltraStar file", "write"),
]

ANSI = re.compile(r"\x1b\[[0-9;]*m")

# header tags whose value comes from the generated file, not the old one
REPLACED_TAGS = {"VERSION", "BPM", "GAP", "ENCODING", "RELATIVE", "NOTESGAP"}

# better word timing than the small default models of whisperx
ALIGN_MODELS = {
    "es": "jonatasgrosman/wav2vec2-large-xlsr-53-spanish",
}

# #LANGUAGE values to the codes Whisper can align without extra models
LANGUAGE_CODES = {
    "es": ["spanish", "español", "espanol", "castellano"],
    "en": ["english", "inglés", "ingles"],
    "fr": ["french", "français", "francais", "francés", "frances"],
    "de": ["german", "deutsch", "alemán", "aleman"],
    "it": ["italian", "italiano"],
    "pt": ["portuguese", "português", "portugues", "portugués"],
    "nl": ["dutch", "nederlands", "holandés", "holandes"],
    "ja": ["japanese", "japonés", "japones"],
    "zh": ["chinese", "chino"],
    "uk": ["ukrainian", "ucraniano"],
}


CHILD = None


def stop(_signum, _frame):
    # the game cancels by terminating this script; take UltraSinger with it
    if CHILD and CHILD.poll() is None:
        CHILD.terminate()
    raise KeyboardInterrupt


def say(line):
    print(line, flush=True)


LYRICS_FILES = ("letra.txt", "lyrics.txt")


def lyrics_in(folder):
    for name in sorted(os.listdir(folder)):
        if name.lower() in LYRICS_FILES or name.lower().endswith(".lyrics.txt"):
            return os.path.join(folder, name)
    return None


MISSING_LINE_SECONDS = 1.2  # voice without lyrics this long is marked in letra.txt


def voiced_spans(vocals_wav, start, end):
    """Share of 0.1 s steps between start and end with the voice singing."""
    try:
        import librosa
        import numpy as np
        y, sr = librosa.load(vocals_wav, sr=16000, mono=True, offset=start, duration=end - start)
        rms = librosa.feature.rms(y=y, hop_length=1600)[0]
        return float((librosa.amplitude_to_db(rms, ref=1.0) > -30).mean()) if len(rms) else 0.0
    except Exception:
        return 0.0


def write_heard_lyrics(song_txt, vocals=None):
    """Saves the lyrics of the song as letra.txt, to be corrected by hand
    and used in the next generation, unless the folder already has one.

    Where the voice sings but the transcription heard nothing (Whisper skips
    repeated choruses), a "(...)" line marks that a line is missing."""
    folder = os.path.dirname(song_txt)
    if lyrics_in(folder):
        return
    header, body = split_song(read_text(song_txt))
    bpm = tag_value(header, "BPM")
    gap = tag_value(header, "GAP") / 1000.0
    beat = 60.0 / (bpm * 4) if bpm > 0 else 0
    lines = []  # (text, start, end) in seconds
    text, start, end = "", None, None
    for line in body + ["E"]:
        if line[:1] in song_cleanup.NOTE_TYPES:
            parts = line.split(" ", 4)
            text += (parts[4] if len(parts) > 4 else "").replace("~", "")
            if start is None:
                start = gap + int(parts[1]) * beat
            end = gap + (int(parts[1]) + int(parts[2])) * beat
        elif line[:1] in ("-", "E"):
            if text.strip():
                lines.append((" ".join(text.split()), start, end))
            text, start, end = "", None, None

    out = []
    prev_end = 0.0
    for text, start, end in lines:
        if vocals and beat and start - prev_end >= MISSING_LINE_SECONDS \
                and voiced_spans(vocals, prev_end, start) >= 0.6:
            minute, second = divmod(int(prev_end), 60)
            out.append("(¿falta una frase? %d:%02d)" % (minute, second))
        out.append(text)
        prev_end = end
    with open(os.path.join(folder, LYRICS_FILES[0]), "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(out) + "\n")


def find_lyrics(args):
    """A lyrics file next to the song, or the one given with --lyrics."""
    if args.lyrics:
        return args.lyrics if os.path.isfile(args.lyrics) else None
    if args.replace:
        folder = os.path.dirname(args.replace)
    elif os.path.isfile(args.input):
        folder = os.path.dirname(os.path.abspath(args.input))
    else:
        return None
    return lyrics_in(folder)


def run_ultrasinger(args, out_dir, language):
    script = os.path.join(args.ultrasinger, "src", "UltraSinger.py")
    lyrics = find_lyrics(args)
    hook = []
    if lyrics:
        print("Using the lyrics in " + lyrics, flush=True)
        hook = [os.path.join(os.path.dirname(os.path.abspath(__file__)), "lyrics_hook.py"), lyrics]
    cmd = [sys.executable, "-u", "-B"] + hook + [script,
           "-i", args.input, "-o", out_dir,
           "--format_version", "1.0.0",
           "--disable_karaoke",
           "--keep_cache",
           "--whisper", args.whisper]
    if language:
        cmd += ["--language", language]
        if language in ALIGN_MODELS:
            cmd += ["--whisper_align_model", ALIGN_MODELS[language]]
    if args.ffmpeg:
        cmd += ["--ffmpeg", args.ffmpeg]
    env = dict(os.environ, PYTHONUNBUFFERED="1")
    # ffmpeg must be on the PATH for the libraries that do not take a path
    if args.ffmpeg:
        env["PATH"] = args.ffmpeg + os.pathsep + env.get("PATH", "")
    global CHILD
    proc = CHILD = subprocess.Popen(cmd, cwd=os.path.join(args.ultrasinger, "src"),
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            env=env, text=True, errors="replace", bufsize=1)
    last = None
    tail = []
    for raw in proc.stdout:
        line = ANSI.sub("", raw.rstrip("\r\n"))
        print(line, flush=True)
        tail = (tail + [line])[-20:]
        for text, stage in STAGES:
            if text in line and stage != last:
                last = stage
                say("@@STAGE " + stage)
                break
    if proc.wait() != 0:
        errors = [l for l in tail if "Error" in l or "error" in l]
        raise RuntimeError((errors or tail or ["UltraSinger failed"])[-1].strip())


def find_file(out_dir, name):
    for root, _dirs, files in os.walk(out_dir):
        if name in files:
            return os.path.join(root, name)
    return None


def language_code(value):
    value = (value or "").strip().lower()
    for code, names in LANGUAGE_CODES.items():
        if value == code or value in names:
            return code
    return None


def song_language(txt):
    for line in split_song(read_text(txt))[0]:
        if tag_of(line) == "LANGUAGE":
            return language_code(line.split(":", 1)[1].split(",")[0])
    return None


def tag_value(header, tag, default=0.0):
    for line in header:
        if tag_of(line) == tag:
            try:
                return float(line.split(":", 1)[1].strip().replace(",", "."))
            except ValueError:
                pass
    return default


def clean_up_song(txt, vocals, lyrics=None):
    """Rewrites UltraSinger's notes with song_cleanup."""
    header, body = split_song(read_text(txt))
    bpm = tag_value(header, "BPM")
    if bpm <= 0:
        return
    gap = tag_value(header, "GAP")
    onsets = song_cleanup.vocal_onsets(vocals) if vocals else []
    lyric_lines = None
    if lyrics:
        import lyrics_hook
        lyric_lines = lyrics_hook.read_lyrics(lyrics)
    body = song_cleanup.clean_up(body, bpm, gap, onsets, lyric_lines)
    with open(txt, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(header + body) + "\n")


def name_from_file(path):
    """(artist, title) of a file named "Artist - Title.ext", or None."""
    base = os.path.splitext(os.path.basename(path))[0]
    if " - " not in base:
        return None
    artist, title = (p.strip() for p in base.split(" - ", 1))
    return (artist, title) if artist and title else None


def set_artist_title(txt, artist, title):
    """UltraSinger takes them from MusicBrainz, often from another song."""
    header, body = split_song(read_text(txt))
    header = [l for l in header if tag_of(l) not in ("ARTIST", "TITLE")]
    header[1:1] = ["#ARTIST:" + artist, "#TITLE:" + title]
    with open(txt, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(header + body) + "\n")


def find_txt(out_dir):
    for root, _dirs, files in os.walk(out_dir):
        if "cache" in os.path.relpath(root, out_dir).split(os.sep):
            continue
        for name in files:
            if name.lower().endswith(".txt"):
                return os.path.join(root, name)
    raise RuntimeError("UltraSinger did not write a song file")


def read_text(path):
    data = open(path, "rb").read()
    if data.startswith(b"\xef\xbb\xbf"):
        data = data[3:]
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError:
        return data.decode("cp1252", errors="replace")


def split_song(text):
    header, body = [], []
    for line in text.splitlines():
        if not body and line.startswith("#"):
            header.append(line)
        elif line.strip():
            body.append(line)
    return header, body


def tag_of(line):
    return line[1:].split(":", 1)[0].strip().upper()


def replace_notes(old_txt, new_txt):
    old_header, _ = split_song(read_text(old_txt))
    new_header, new_body = split_song(read_text(new_txt))
    if not any(l.startswith((":", "*", "F", "R", "G")) for l in new_body):
        raise RuntimeError("No lyrics were found in the song")

    header = ["#VERSION:1.0.0"]
    tags = set()
    for line in old_header:
        tag = tag_of(line)
        if tag not in REPLACED_TAGS:
            header.append(line)
            tags.add(tag)
    for line in new_header:
        if tag_of(line) in ("BPM", "GAP"):
            header.append(line)
    if "CREATOR" not in tags:
        header.append("#CREATOR:UltraSinger")

    backup = old_txt + ".bak"
    if not os.path.exists(backup):
        shutil.copy2(old_txt, backup)
    tmp = old_txt + ".tmp"
    with open(tmp, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(header + new_body) + "\n")
        if new_body[-1].strip() != "E":
            f.write("E\n")
    os.replace(tmp, old_txt)
    return old_txt


def unique_dir(path):
    candidate, n = path, 2
    while os.path.exists(candidate):
        candidate = "%s (%d)" % (path, n)
        n += 1
    return candidate


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--ultrasinger", required=True)
    p.add_argument("--input", required=True)
    p.add_argument("--out")
    p.add_argument("--replace")
    p.add_argument("--whisper", default="large-v2")
    p.add_argument("--language")
    p.add_argument("--lyrics")
    p.add_argument("--fallback-language", default="es")
    p.add_argument("--ffmpeg")
    args = p.parse_args()
    if not args.out and not args.replace:
        p.error("--out or --replace is needed")
    signal.signal(signal.SIGTERM, stop)

    work_parent = os.path.dirname(args.replace) if args.replace else args.out
    os.makedirs(work_parent, exist_ok=True)
    work = tempfile.mkdtemp(prefix=".usdx-generate-", dir=work_parent)
    try:
        language = language_code(args.language)
        if not language and args.replace:
            language = song_language(args.replace)
        try:
            run_ultrasinger(args, work, language)
        except RuntimeError as e:
            # Whisper sometimes takes a song for a language it cannot align
            # (Latin for a Spanish hymn): try again in the usual language
            if "align-model" not in str(e) or language or not args.fallback_language:
                raise
            print("Retrying in %s" % args.fallback_language, flush=True)
            shutil.rmtree(work, ignore_errors=True)
            os.makedirs(work)
            run_ultrasinger(args, work, language_code(args.fallback_language))
        txt = find_txt(work)
        say("@@STAGE write")
        clean_up_song(txt, find_file(work, "vocals.wav"), find_lyrics(args))
        if args.replace:
            result = replace_notes(args.replace, txt)
        else:
            song_dir = os.path.dirname(txt)
            shutil.rmtree(os.path.join(song_dir, "cache"), ignore_errors=True)
            folder_name = os.path.basename(song_dir)
            names = name_from_file(args.input) if os.path.isfile(args.input) else None
            if names:
                set_artist_title(txt, *names)
                folder_name = "%s - %s" % names
            target = unique_dir(os.path.join(args.out, folder_name))
            shutil.move(song_dir, target)
            result = os.path.join(target, os.path.basename(txt))
            lyrics = find_lyrics(args)
            if lyrics:
                shutil.copy2(lyrics, os.path.join(target, LYRICS_FILES[0]))
        write_heard_lyrics(result, find_file(work, "vocals.wav"))
        say("@@DONE " + result)
    except KeyboardInterrupt:
        say("@@ERROR cancelled")
        sys.exit(2)
    except Exception as e:  # report everything to the game
        say("@@ERROR " + (str(e) or e.__class__.__name__))
        sys.exit(1)
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    main()
