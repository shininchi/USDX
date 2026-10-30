"""Adds a video to a song: found on YouTube by the song's name, from a
link, or from a file, made into one the game plays smoothly and put in the
song's folder, with the #VIDEOGAP that puts its music where the song's is.
A video that is only a picture with the lyrics on it becomes the song's
background picture instead, without the lyrics; --source still does that
with the video the song has.

Usage: python add_video.py --txt SONG.txt [--source search|still|LINK|FILE]
                           [--ffmpeg DIR] [--write]

Prints progress lines for the game ("@@STAGE search|download|convert|sync")
and at the end "@@DONE <file name>\t<videogap>\t<sure|unsure>\t<video|still>"
or "@@ERROR <reason>". With --write the song's #VIDEO and #VIDEOGAP (or
#BACKGROUND) are set in its txt, and a video replaced by its picture is
deleted; without it (the editor, which saves the song itself) nothing but
the new file is written.
"""

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from usdx_generate import one_video, read_text, say, split_song, tag_of  # noqa: E402
from lyrics_hook import PLAYABLE_VIDEO  # noqa: E402

SEARCH_RESULTS = 5      # YouTube results looked at
LENGTH_SLACK = 0.15     # a result this much longer or shorter than the song is another version
SYNC_RATE = 100         # loudness changes per second compared to find the video gap
MAX_GAP_SECONDS = 120   # the music of a video starts at most this far from the song's
SURE_MATCH = 0.3        # the same recording matches about 1, another song about 0.05
SURE_MARGIN = 1.15      # ...and this much better than at any other moment
SMOOTH_CODECS = ("vp9", "vp8")  # played without stutter; others are converted
STILL_SAMPLES = 15      # frames compared to tell a picture from a filmed video
STILL_CHANGE = 0.05     # a picture with lyrics changes ~0.3% of its pixels, a filmed video over 50%


def tool(ffmpeg_dir, name):
    return os.path.join(ffmpeg_dir, name) if ffmpeg_dir else name


def header_tags(txt):
    header, _ = split_song(read_text(txt))
    return {tag_of(l): l.split(":", 1)[1].strip() for l in header if ":" in l}


def media_seconds(path, ffmpeg_dir):
    try:
        out = subprocess.run([tool(ffmpeg_dir, "ffprobe"), "-v", "error", "-show_entries",
                              "format=duration", "-of", "csv=p=0", path],
                             capture_output=True, text=True, timeout=30).stdout
        return float(out.strip())
    except (ValueError, OSError, subprocess.SubprocessError):
        return None


def video_codec(path, ffmpeg_dir):
    try:
        return subprocess.run([tool(ffmpeg_dir, "ffprobe"), "-v", "error", "-select_streams", "v:0",
                               "-show_entries", "stream=codec_name", "-of", "csv=p=0", path],
                              capture_output=True, text=True, timeout=30).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return ""


def frames(video, ffmpeg_dir, size=None):
    """STILL_SAMPLES frames spread over the video (leaving out its fades in
    and out) as RGB arrays, at their own size or (width, height)."""
    import numpy as np
    seconds = media_seconds(video, ffmpeg_dir) or 0
    if size is None:
        try:
            out = subprocess.run([tool(ffmpeg_dir, "ffprobe"), "-v", "error", "-select_streams", "v:0",
                                  "-show_entries", "stream=width,height", "-of", "csv=p=0", video],
                                 capture_output=True, text=True, timeout=30).stdout
            size = tuple(int(v) for v in out.strip().split(",")[:2])
        except (ValueError, OSError, subprocess.SubprocessError):
            return []
    w, h = size
    result = []
    for i in range(STILL_SAMPLES):
        at = seconds * (0.1 + 0.8 * i / (STILL_SAMPLES - 1))
        try:
            raw = subprocess.run([tool(ffmpeg_dir, "ffmpeg"), "-v", "error", "-ss", "%.2f" % at, "-i", video,
                                  "-frames:v", "1", "-vf", "scale=%d:%d" % (w, h), "-pix_fmt", "rgb24",
                                  "-f", "rawvideo", "-"], capture_output=True, timeout=60).stdout
        except (OSError, subprocess.SubprocessError):
            continue
        if len(raw) == w * h * 3:
            result.append(np.frombuffer(raw, np.uint8).reshape(h, w, 3))
    return result


def is_still(video, ffmpeg_dir):
    """Whether the video is a picture that only the lyrics change on."""
    import numpy as np
    small = frames(video, ffmpeg_dir, (160, 90))
    if len(small) < STILL_SAMPLES // 2:
        return False
    grey = np.stack(small).astype(np.int16).mean(axis=3)
    usual = np.median(grey, axis=0)
    return float(np.median([(np.abs(g - usual) > 30).mean() for g in grey])) < STILL_CHANGE


def save_picture(video, target, ffmpeg_dir):
    """The video's picture as a jpg: the frame nearest to the usual colour
    of each pixel, which leaves out the lyrics, as they are there only a
    while (the usual colours themselves lose twinkling stars and such)."""
    import numpy as np
    full = frames(video, ffmpeg_dir)
    if not full:
        raise RuntimeError("the video could not be read")
    stack = np.stack(full)
    usual = np.median(stack, axis=0)
    picture = stack[int(np.argmin([np.abs(f - usual).mean() for f in stack]))]
    h, w = picture.shape[:2]
    subprocess.run([tool(ffmpeg_dir, "ffmpeg"), "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "rgb24",
                    "-s", "%dx%d" % (w, h), "-i", "-", "-q:v", "2", target],
                   input=picture.tobytes(), check=True, capture_output=True, timeout=60)
    return target


def search(artist, title, seconds):
    """The link of the song's video on YouTube: the first result about as
    long as the song (a live or extended version is longer), else the
    first one."""
    import yt_dlp
    query = "ytsearch%d:%s %s" % (SEARCH_RESULTS, artist, title)
    with yt_dlp.YoutubeDL({"quiet": True, "no_warnings": True, "extract_flat": True}) as ydl:
        entries = [e for e in (ydl.extract_info(query, download=False).get("entries") or []) if e]
    if not entries:
        return None
    for e in entries:
        length = e.get("duration")
        if seconds and length and abs(length - seconds) <= seconds * LENGTH_SLACK:
            return e.get("url") or e.get("webpage_url")
    return entries[0].get("url") or entries[0].get("webpage_url")


def download(url, work, ffmpeg_dir):
    """The video with its sound (needed to find the gap), in work."""
    import yt_dlp
    opts = {"quiet": True, "no_warnings": True, "noprogress": True, "noplaylist": True, "format": PLAYABLE_VIDEO,
            "outtmpl": os.path.join(work, "video.%(ext)s"), "merge_output_format": "mkv"}
    if ffmpeg_dir:
        opts["ffmpeg_location"] = ffmpeg_dir
    with yt_dlp.YoutubeDL(opts) as ydl:
        ydl.download([one_video(url)])
    files = [f for f in os.listdir(work) if f.startswith("video.")]
    if not files:
        raise RuntimeError("nothing was downloaded")
    return os.path.join(work, files[0])


def sound(path, ffmpeg_dir):
    """The sound of a file as mono samples at 11025 Hz, None if it has none."""
    import numpy as np
    try:
        raw = subprocess.run([tool(ffmpeg_dir, "ffmpeg"), "-v", "error", "-i", path, "-vn",
                              "-ac", "1", "-ar", "11025", "-f", "s16le", "-"],
                             capture_output=True, timeout=300).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    if len(raw) < 11025 * 2 * 5:
        return None
    return np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0


def video_gap(song_audio, video, ffmpeg_dir):
    """(seconds, sure) to add to the song's time to be at the same moment
    of the video: where the changes in loudness of both match best. sure is
    False when no moment matches clearly (other music in the video)."""
    import librosa
    import numpy as np
    a, b = sound(song_audio, ffmpeg_dir), sound(video, ffmpeg_dir)
    if a is None or b is None:
        return 0.0, False
    hop = 11025 // SYNC_RATE
    ea = librosa.onset.onset_strength(y=a, sr=11025, hop_length=hop)
    eb = librosa.onset.onset_strength(y=b, sr=11025, hop_length=hop)
    ea = (ea - ea.mean()) / (ea.std() or 1)
    eb = (eb - eb.mean()) / (eb.std() or 1)
    n = 1 << int(np.ceil(np.log2(len(ea) + len(eb))))
    # about the correlation coefficient of both at each lag
    corr = np.fft.irfft(np.fft.rfft(eb, n) * np.conj(np.fft.rfft(ea, n)), n) / min(len(ea), len(eb))
    # corr[k]: video k frames later than the song; negative lags wrap around
    lags = np.concatenate([np.arange(0, n // 2), np.arange(-n // 2, 0)])
    near = np.abs(lags) <= MAX_GAP_SECONDS * SYNC_RATE
    corr, lags = corr[near], lags[near]
    best = int(np.argmax(corr))
    # music repeats itself: another lag (a chorus later) must match clearly worse
    elsewhere = corr[np.abs(lags - lags[best]) > SYNC_RATE // 2]
    sure = corr[best] >= SURE_MATCH and corr[best] >= SURE_MARGIN * (elsewhere.max() if len(elsewhere) else 0)
    return round(lags[best] / SYNC_RATE, 2), bool(sure)


def make_playable(video, target_base, ffmpeg_dir):
    """The video, without its sound, as a file the game plays smoothly:
    VP9 kept as it is, anything else converted to VP9 (AV1 stutters, and
    H.264 judders in .mp4). If that fails, the file as it was, sound and
    all (the game does not play a video's sound). Returns its path."""
    codec = video_codec(video, ffmpeg_dir)
    ffmpeg = tool(ffmpeg_dir, "ffmpeg")
    out = target_base + ".webm"
    if codec in SMOOTH_CODECS:
        cmd = [ffmpeg, "-v", "error", "-y", "-i", video, "-map", "0:v:0", "-an", "-c:v", "copy", out]
    else:
        say("@@STAGE convert")
        cmd = [ffmpeg, "-v", "error", "-y", "-i", video, "-map", "0:v:0", "-an",
               "-vf", "scale=-2:'min(1080,ih)'", "-c:v", "libvpx-vp9", "-deadline", "realtime",
               "-cpu-used", "8", "-row-mt", "1", "-crf", "32", "-b:v", "0", out]
    try:
        subprocess.run(cmd, check=True, capture_output=True, timeout=3600)
        if os.path.getsize(out) > 0:
            return out
    except (OSError, subprocess.SubprocessError) as e:
        print("Not converted (%s): copying the video as it is" % e, flush=True)
    if os.path.exists(out):
        os.remove(out)
    copy = target_base + os.path.splitext(video)[1].lower()
    shutil.copyfile(video, copy)
    return copy


def set_video_tags(txt, video_name, gap, still=False):
    """#VIDEO and #VIDEOGAP, or for a picture #BACKGROUND and no video."""
    text = read_text(txt)
    header, body = split_song(text)
    gone = ("VIDEO", "VIDEOGAP", "BACKGROUND") if still else ("VIDEO", "VIDEOGAP")
    header = [l for l in header if tag_of(l) not in gone]
    # after the other files, as the game writes it
    at = max([i + 1 for i, l in enumerate(header) if tag_of(l) in ("MP3", "AUDIO", "COVER", "BACKGROUND")]
             or [len(header)])
    if still:
        header[at:at] = ["#BACKGROUND:" + video_name]
    else:
        header[at:at] = ["#VIDEO:" + video_name, "#VIDEOGAP:%s" % ("%.2f" % gap).rstrip("0").rstrip(".")]
    tmp = txt + ".tmp"
    with open(tmp, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(header + body) + "\n")
    os.replace(tmp, txt)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--txt", required=True)
    parser.add_argument("--source", default="search")
    parser.add_argument("--ffmpeg", default="")
    parser.add_argument("--write", action="store_true")
    args = parser.parse_args()

    folder = os.path.dirname(os.path.abspath(args.txt))
    tags = header_tags(args.txt)
    audio = tags.get("AUDIO") or tags.get("MP3")
    if not audio or not os.path.exists(os.path.join(folder, audio)):
        say("@@ERROR the song has no audio file")
        return 1
    audio = os.path.join(folder, audio)
    work = tempfile.mkdtemp(prefix=".usdx-video-", dir=folder)
    stem = os.path.join(folder, os.path.splitext(os.path.basename(args.txt))[0])
    try:
        source = args.source.strip()
        if source == "still":
            # the video the song has, as its background picture
            old = tags.get("VIDEO") and os.path.join(folder, tags["VIDEO"])
            if not old or not os.path.isfile(old):
                say("@@ERROR the song has no video")
                return 1
            name = os.path.basename(save_picture(old, stem + " [BG].jpg", args.ffmpeg))
            if args.write:
                set_video_tags(args.txt, name, 0, still=True)
                os.remove(old)
            say("@@DONE %s\t0.00\tsure\tstill" % name)
            return 0
        if source == "search":
            say("@@STAGE search")
            source = search(tags.get("ARTIST", ""), tags.get("TITLE", ""), media_seconds(audio, args.ffmpeg))
            if not source:
                say("@@ERROR no video was found")
                return 1
            print("Found " + source, flush=True)
        if re.match(r"https?://", source):
            say("@@STAGE download")
            video = download(source, work, args.ffmpeg)
        elif os.path.isfile(source):
            video = source
        else:
            say("@@ERROR not a link or a file: " + source)
            return 1

        if is_still(video, args.ffmpeg):
            name = os.path.basename(save_picture(video, stem + " [BG].jpg", args.ffmpeg))
            if args.write:
                set_video_tags(args.txt, name, 0, still=True)
            say("@@DONE %s\t0.00\tsure\tstill" % name)
            return 0

        say("@@STAGE sync")
        gap, sure = video_gap(audio, video, args.ffmpeg)
        base = stem + " [VD]"
        for ext in (".webm", ".mkv", ".mp4", ".mov", ".avi"):  # an earlier video of this song
            if os.path.exists(base + ext) and os.path.abspath(base + ext) != os.path.abspath(video):
                os.remove(base + ext)
        result = make_playable(video, base, args.ffmpeg)
        name = os.path.basename(result)
        if args.write:
            set_video_tags(args.txt, name, gap)
        say("@@DONE %s\t%.2f\t%s\tvideo" % (name, gap, "sure" if sure else "unsure"))
        return 0
    except Exception as e:
        say("@@ERROR %s" % e)
        return 1
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
