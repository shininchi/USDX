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
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request

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

# new songs say in their title which generator made them, what placed
# their lines and where the lyrics came from ("La salvación [A Whisper ·
# letra LRCLIB]", also in #COMMENT), to compare the two generators:
# A places the lines where Whisper hears them, B by LRCLIB's synced times
VARIANT = "B"
PLACED_BY = "Whisper"


def stop(_signum, _frame):
    # the game cancels by terminating this script; take UltraSinger with it
    if CHILD and CHILD.poll() is None:
        CHILD.terminate()
    raise KeyboardInterrupt


def say(line):
    print(line, flush=True)


LYRICS_FILES = ("letra.txt", "lyrics.txt")
LRCLIB = "https://lrclib.net/api/"
LRCLIB_AGENT = "USDX song generator (https://github.com/shininchi/USDX)"


def lrclib_request(path, params):
    """JSON from LRCLIB's public API (None on errors), retrying when busy."""
    url = LRCLIB + path + "?" + urllib.parse.urlencode(params)
    for attempt in range(3):
        try:
            request = urllib.request.Request(url, headers={"User-Agent": LRCLIB_AGENT})
            with urllib.request.urlopen(request, timeout=10) as response:
                return json.loads(response.read().decode("utf-8"))
        except urllib.error.HTTPError as e:
            if e.code == 404:
                return None
            if e.code not in (429, 500, 502, 503, 504):
                print("LRCLIB: %s" % e, flush=True)
                return None
        except Exception as e:
            print("LRCLIB: %s" % e, flush=True)
            return None
        time.sleep(2 + 3 * attempt)
    print("LRCLIB is busy, using what Whisper hears", flush=True)
    return None


def audio_seconds(path, ffmpeg_dir):
    ffprobe = os.path.join(ffmpeg_dir, "ffprobe") if ffmpeg_dir else "ffprobe"
    try:
        out = subprocess.run([ffprobe, "-v", "error", "-show_entries", "format=duration", "-of",
                              "csv=p=0", path], capture_output=True, text=True, timeout=20).stdout
        return float(out.strip())
    except Exception:
        return 0


def fetch_lyrics(artist, title, seconds, folder):
    """The song's lyrics from LRCLIB (https://lrclib.net), the synced ones
    ("[mm:ss.xx] line") when there are, saved in folder; None if not found."""
    found = None
    if seconds:
        found = lrclib_request("get", {"artist_name": artist, "track_name": title,
                                       "duration": int(round(seconds))})
    if not found:
        results = lrclib_request("search", {"artist_name": artist, "track_name": title}) or []
        # the same song: the closest length, within a few seconds
        results = [r for r in results if r.get("plainLyrics") or r.get("syncedLyrics")]
        if seconds:
            results = [r for r in results if abs((r.get("duration") or 0) - seconds) <= 8]
            results.sort(key=lambda r: abs((r.get("duration") or 0) - seconds))
        found = results[0] if results else None
    if not found or found.get("instrumental"):
        return None
    if not found.get("syncedLyrics"):
        # synced lyrics of another version (a videoclip, longer or shorter)
        # still place the lines: lyrics_hook moves them to fit this one, or
        # leaves them out when they do not fit
        synced = [r for r in lrclib_request("search", {"artist_name": artist, "track_name": title}) or []
                  if r.get("syncedLyrics") and not r.get("instrumental")]
        if seconds:
            synced = [r for r in synced if abs((r.get("duration") or 0) - seconds) <= 30]
            synced.sort(key=lambda r: abs((r.get("duration") or 0) - seconds))
        if synced:
            found = synced[0]
    text = found.get("syncedLyrics") or found.get("plainLyrics")
    if not text:
        return None
    path = os.path.join(folder, "lrclib.lyrics.txt")
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(text.strip() + "\n")
    print("Lyrics from LRCLIB (%s): %s - %s" % ("synced" if found.get("syncedLyrics") else "plain",
                                               found.get("artistName"), found.get("trackName")), flush=True)
    return path


def plain_lyrics(path):
    """The lines of a lyrics file without LRC times."""
    lines = []
    for line in read_text(path).splitlines():
        line = re.sub(r"^(\[\d+:\d+(?:[.:]\d+)?\])+", "", line).strip()
        if line:
            lines.append(line)
    return lines


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


AUDIO_EXTS = (".mp3", ".m4a", ".aac", ".ogg", ".opus", ".flac", ".wav")


def audio_only(path, work, ffmpeg_dir):
    """A copy of an audio file without the cover picture inside it.

    UltraSinger takes an mp3 with an embedded cover for a video and then
    fails writing the audio over the file it reads. The audio is copied as
    it is, so the timing does not change."""
    if not os.path.isfile(path) or os.path.splitext(path)[1].lower() not in AUDIO_EXTS:
        return path
    ffmpeg = os.path.join(ffmpeg_dir, "ffmpeg") if ffmpeg_dir else "ffmpeg"
    folder = os.path.join(work, "input")
    os.makedirs(folder, exist_ok=True)
    target = os.path.join(folder, os.path.basename(path))
    result = subprocess.run([ffmpeg, "-nostdin", "-loglevel", "error", "-y", "-i", path,
                             "-map", "0:a:0", "-c", "copy", "-map_metadata", "0", target],
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if result.returncode != 0 or not os.path.isfile(target):
        print("Could not copy the audio: " + result.stdout.strip(), flush=True)
        return path
    return target


def run_ultrasinger(args, out_dir, language, lyrics):
    global PLACED_BY
    PLACED_BY = "Whisper"
    script = os.path.join(args.ultrasinger, "src", "UltraSinger.py")
    if lyrics:
        print("Using the lyrics in " + lyrics, flush=True)
    hook = [os.path.join(os.path.dirname(os.path.abspath(__file__)), "lyrics_hook.py"), lyrics or "-"]
    cmd = [sys.executable, "-u", "-B"] + hook + [script,
           "-i", audio_only(args.input, out_dir, args.ffmpeg), "-o", out_dir,
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
    if os.path.isfile(args.input):
        # its tags and cover are used, not what MusicBrainz says (minutes)
        env["USDX_SKIP_MUSICBRAINZ"] = "1"
    # ffmpeg must be on the PATH for the libraries that do not take a path
    if args.ffmpeg:
        env["PATH"] = args.ffmpeg + os.pathsep + env.get("PATH", "")
    global CHILD
    proc = CHILD = subprocess.Popen(cmd, cwd=os.path.join(args.ultrasinger, "src"),
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            env=env, text=True, errors="replace", bufsize=1)
    last = None
    tail = []
    song_written = False
    for raw in proc.stdout:
        line = ANSI.sub("", raw.rstrip("\r\n"))
        print(line, flush=True)
        tail = (tail + [line])[-20:]
        # what comes after the song file (points, midi, sheet) is extra
        if "Calculating Ultrastar Points" in line:
            song_written = True
        if "lines placed by their synced times" in line:  # lyrics_hook
            PLACED_BY = "LRCLIB"
        for text, stage in STAGES:
            if text in line and stage != last:
                last = stage
                say("@@STAGE " + stage)
                break
    if proc.wait() != 0 and song_written:
        print("UltraSinger failed after writing the song, which is kept", flush=True)
    elif proc.returncode != 0:
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
    voiced = song_cleanup.vocal_activity(vocals) if vocals else []
    body = song_cleanup.clean_up(body, bpm, gap, onsets, lyric_lines, voiced)
    with open(txt, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(header + body) + "\n")


def tags_of(path, ffmpeg_dir):
    """(artist, title) from the file's tags (ID3...), or None."""
    ffprobe = os.path.join(ffmpeg_dir, "ffprobe") if ffmpeg_dir else "ffprobe"
    try:
        out = subprocess.run([ffprobe, "-v", "error", "-show_entries", "format_tags=artist,title",
                              "-of", "json", path], capture_output=True, text=True, timeout=20).stdout
        tags = {k.lower(): v.strip() for k, v in json.loads(out).get("format", {}).get("tags", {}).items()}
    except Exception:
        return None
    if tags.get("artist") and tags.get("title"):
        return tags["artist"], tags["title"]
    return None


def name_from_file(path, ffmpeg_dir=None):
    """(artist, title) of an audio or video file: from its tags, or from a
    name like "02 Artist - Title.ext" (the track number is dropped); None
    if neither says."""
    tags = tags_of(path, ffmpeg_dir)
    if tags:
        return tags
    base = os.path.splitext(os.path.basename(path))[0]
    base = re.sub(r"^\d{1,3}[\s.\-_]+", "", base).strip()
    if " - " not in base:
        return None
    artist, title = (p.strip() for p in base.split(" - ", 1))
    return (artist, title) if artist and title else None


def lyrics_origin(source, lyrics):
    """(short, long) saying where the lyrics came from, for the title and
    the comment of the song."""
    if source == "lrclib":
        synced = any(re.match(r"\[\d+:\d", l) for l in read_text(lyrics).splitlines())
        return ("letra LRCLIB sinc", "letra de LRCLIB, sincronizada") if synced else \
               ("letra LRCLIB", "letra de LRCLIB, sin tiempos")
    if source == "user":
        return "letra propia", "letra de letra.txt"
    return "letra Whisper", "letra oída por Whisper"


COMMENT_PREFIX = "Generada con "


def set_origin_comment(txt, source, lyrics):
    """Says in the song's #COMMENT which generator made it, where the
    lyrics came from and what placed the lines; a comment of someone
    else's is kept."""
    header, body = split_song(read_text(txt))
    old = [l for l in header if tag_of(l) == "COMMENT"]
    if old and old[0].split(":", 1)[1].strip() and \
            not old[0].split(":", 1)[1].strip().startswith((COMMENT_PREFIX, "UltraSinger")):
        return
    comment = "#COMMENT:%s%s: %s; líneas colocadas por %s" % (
        COMMENT_PREFIX, VARIANT, lyrics_origin(source, lyrics)[1], PLACED_BY)
    header = [l for l in header if tag_of(l) != "COMMENT"] + [comment]
    with open(txt, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(header + body) + "\n")


def artist_title(txt):
    """(artist, title) of a song file, None if it lacks them."""
    tags = {tag_of(l): l.split(":", 1)[1].strip() for l in split_song(read_text(txt))[0] if ":" in l}
    if tags.get("ARTIST") and tags.get("TITLE"):
        return tags["ARTIST"], tags["TITLE"]
    return None


def set_artist_title(txt, artist, title):
    """UltraSinger takes them from MusicBrainz, often from another song."""
    header, body = split_song(read_text(txt))
    header = [l for l in header if tag_of(l) not in ("ARTIST", "TITLE")]
    header[1:1] = ["#ARTIST:" + artist, "#TITLE:" + title]
    with open(txt, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(header + body) + "\n")


def rename_song_files(txt, artist, title):
    """Names the files of a new song "Artist - Title.*" (UltraSinger names
    them after its MusicBrainz guess) and points the txt to them."""
    folder = os.path.dirname(txt)
    old = os.path.splitext(os.path.basename(txt))[0]
    new = re.sub(r'[\\/:*?"<>|]', "", "%s - %s" % (artist, title)).strip()
    if not new or new == old:
        return txt
    for name in os.listdir(folder):
        if name.startswith(old):
            os.replace(os.path.join(folder, name), os.path.join(folder, new + name[len(old):]))
    txt = os.path.join(folder, new + ".txt")
    header, body = split_song(read_text(txt))
    header = [l.replace(old, new) if tag_of(l) in ("MP3", "AUDIO", "VIDEO", "COVER", "BACKGROUND",
                                                    "VOCALS", "INSTRUMENTAL") else l for l in header]
    with open(txt, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(header + body) + "\n")
    return txt


def use_file_details(txt, original, ffmpeg_dir):
    """A new song made from a file keeps what that file had: its audio as it
    is (UltraSinger compresses it again, which sounds worse), its embedded
    picture as cover and its year and genre (UltraSinger takes those from
    MusicBrainz, often from another record)."""
    folder = os.path.dirname(txt)
    base = os.path.splitext(os.path.basename(txt))[0]
    header, body = split_song(read_text(txt))
    old_files = {tag_of(l): l.split(":", 1)[1].strip() for l in header
                 if tag_of(l) in ("MP3", "AUDIO", "COVER")}

    # the original audio
    ext = os.path.splitext(original)[1].lower()
    audio = base + ext
    shutil.copy2(original, os.path.join(folder, audio))
    for tag in ("MP3", "AUDIO"):
        old = old_files.get(tag)
        if old and old != audio and os.path.isfile(os.path.join(folder, old)):
            os.remove(os.path.join(folder, old))
    header = [l for l in header if tag_of(l) not in ("MP3", "AUDIO")]
    header.append("#MP3:" + audio)

    # cover, year and genre from the file
    ffprobe = os.path.join(ffmpeg_dir, "ffprobe") if ffmpeg_dir else "ffprobe"
    ffmpeg = os.path.join(ffmpeg_dir, "ffmpeg") if ffmpeg_dir else "ffmpeg"
    try:
        info = json.loads(subprocess.run([ffprobe, "-v", "error", "-show_entries",
            "format_tags:stream=codec_type:stream_disposition=attached_pic", "-of", "json", original],
            capture_output=True, text=True, timeout=20).stdout)
    except Exception:
        info = {}
    tags = {k.lower(): v.strip() for k, v in info.get("format", {}).get("tags", {}).items()}
    has_picture = any(st.get("disposition", {}).get("attached_pic") for st in info.get("streams", []))
    if has_picture:
        cover = base + " [CO].jpg"
        result = subprocess.run([ffmpeg, "-nostdin", "-loglevel", "error", "-y", "-i", original,
                                 "-an", "-map", "0:v:0", "-frames:v", "1", os.path.join(folder, cover)],
                                capture_output=True, text=True)
        if result.returncode == 0:
            old = old_files.get("COVER")
            if old and old != cover and os.path.isfile(os.path.join(folder, old)):
                os.remove(os.path.join(folder, old))
            header = [l for l in header if tag_of(l) != "COVER"]
            header.append("#COVER:" + cover)
    year = re.match(r"\d{4}", tags.get("date", "") or tags.get("year", ""))
    if year:
        header = [l for l in header if tag_of(l) != "YEAR"]
        header.append("#YEAR:" + year.group(0))
    if tags.get("genre"):
        header = [l for l in header if tag_of(l) != "GENRE"]
        header.append("#GENRE:" + tags["genre"])

    with open(txt, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(header + body) + "\n")


def library_language(txt):
    """UltraSinger writes the language in English; the songs of the library
    say "Español" for Spanish."""
    header, body = split_song(read_text(txt))
    changed = False
    for i, line in enumerate(header):
        if tag_of(line) == "LANGUAGE" and line.split(":", 1)[1].strip().lower() == "spanish":
            header[i] = "#LANGUAGE:Español"
            changed = True
    if changed:
        with open(txt, "w", encoding="utf-8", newline="\n") as f:
            f.write("\n".join(header + body) + "\n")


def find_txt(out_dir):
    for root, _dirs, files in os.walk(out_dir):
        if "cache" in os.path.relpath(root, out_dir).split(os.sep):
            continue
        for name in files:
            if name.lower().endswith(".txt") and not name.lower().endswith(".lyrics.txt") \
                    and name.lower() not in LYRICS_FILES:
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
    p.add_argument("--no-lrclib", action="store_true")
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
        # a song being filled in says its language; otherwise the one chosen
        language = song_language(args.replace) if args.replace else None
        if not language:
            language = language_code(args.language)
        # the lyrics: a file next to the song (corrected by hand), or LRCLIB's
        lyrics = find_lyrics(args)
        source = "user" if lyrics else "whisper"
        if not lyrics and not args.no_lrclib:
            names = None
            if args.replace:
                header = split_song(read_text(args.replace))[0]
                values = {tag_of(l): l.split(":", 1)[1].strip() for l in header if ":" in l}
                if values.get("ARTIST") and values.get("TITLE"):
                    names = (values["ARTIST"], values["TITLE"])
            elif os.path.isfile(args.input):
                names = name_from_file(args.input, args.ffmpeg)
            if names:
                lyrics = fetch_lyrics(names[0], names[1], audio_seconds(args.input, args.ffmpeg), work)
                if lyrics:
                    source = "lrclib"
        say("@@LYRICS " + source)
        try:
            run_ultrasinger(args, work, language, lyrics)
        except RuntimeError as e:
            # Whisper sometimes takes a song for a language it cannot align
            # (Latin for a Spanish hymn): try again in the usual language
            if "align-model" not in str(e) or language or not args.fallback_language:
                raise
            print("Retrying in %s" % args.fallback_language, flush=True)
            shutil.rmtree(work, ignore_errors=True)
            os.makedirs(work)
            run_ultrasinger(args, work, language_code(args.fallback_language), lyrics)
        txt = find_txt(work)
        say("@@STAGE write")
        clean_up_song(txt, find_file(work, "vocals.wav"), lyrics)
        if args.replace:
            result = replace_notes(args.replace, txt)
        else:
            song_dir = os.path.dirname(txt)
            shutil.rmtree(os.path.join(song_dir, "cache"), ignore_errors=True)
            folder_name = os.path.basename(song_dir)
            names = name_from_file(args.input, args.ffmpeg) if os.path.isfile(args.input) else None
            if not names:
                names = artist_title(txt)
            if names:
                names = (names[0], "%s [%s %s · %s]" % (names[1], VARIANT, PLACED_BY,
                                                       lyrics_origin(source, lyrics)[0]))
                set_artist_title(txt, *names)
                txt = rename_song_files(txt, *names)
                folder_name = os.path.splitext(os.path.basename(txt))[0]
            if os.path.isfile(args.input):
                use_file_details(txt, args.input, args.ffmpeg)
            library_language(txt)
            target = unique_dir(os.path.join(args.out, folder_name))
            shutil.move(song_dir, target)
            result = os.path.join(target, os.path.basename(txt))
            if source == "user":
                shutil.copy2(lyrics, os.path.join(target, LYRICS_FILES[0]))
        if source == "lrclib" and not lyrics_in(os.path.dirname(result)):
            # LRCLIB's lyrics, to be corrected by hand if needed
            with open(os.path.join(os.path.dirname(result), LYRICS_FILES[0]), "w",
                      encoding="utf-8", newline="\n") as f:
                f.write("\n".join(plain_lyrics(lyrics)) + "\n")
        set_origin_comment(result, source, lyrics)
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
