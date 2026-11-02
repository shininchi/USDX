# UltraStar Deluxe

[![Build Status](https://github.com/shininchi/USDX/actions/workflows/main.yml/badge.svg)](https://github.com/shininchi/USDX/actions/workflows/main.yml)
[![License](https://img.shields.io/badge/license-GPLv2-blue.svg)](LICENSE)

This is a fork of [UltraStar Deluxe](https://github.com/UltraStar-Deluxe/USDX) that adds a song generator and a song book guests use from their phones. See [What this fork adds](#what-this-fork-adds).

Official website of the original project: https://usdx.eu/

![UltraStar Deluxe Logo](https://github.com/UltraStar-Deluxe/USDX/blob/master/icons/ultrastardx-icon_256.png)


### 1. About
UltraStar Deluxe (USDX) is a free and open source karaoke game. It allows up to six players to sing along with music using microphones in order to score points, depending on the pitch of the voice and the rhythm of singing.
UltraStar Deluxe is a fork of the original UltraStar (developed by corvus5).
Many features have been added like party mode, theme support and support for more audio and video formats.
The improved stability and code quality of USDX enabled ports to Linux and macOS.

### What this fork adds

#### Song generator
Makes a song with lyrics and notes from an audio file, a video or a YouTube link, inside the game (Tools » Editor » Generate). It needs UltraSinger, which is installed separately: see [Setting up the song generator](#setting-up-the-song-generator).
- **Lyrics:** taken from LRCLIB, then lrcmux, or from your own `letra.txt`, and placed where they are sung. If none are found, it uses what Whisper hears.
- **Notes:** each note gets the pitch sung during it, and Spanish words are split into syllables by their spelling.
- **Backing vocals:** they become freestyle notes, with their own line when they close a line.
- **Golden notes:** placed as in SingStar, about three a minute, spread evenly.
- **Tags:** an instrumental track for karaoke (`#INSTRUMENTAL`), the chorus as preview and medley, and a start after a silent intro.
- **Video:** add one to any song from the song menu or the editor.

#### Cancionero: a song book for guests
Guests scan a QR code and browse the songs on their phones.
- **Requests:** covers, search, filters, previews and a request queue, where repeated requests count as votes. The page can be added to the phone's home screen.
- **Admin page:** protected by a PIN, to manage the queue, users and microphones, with limits against abuse and an activity log.
- **In the game:** `I` shows the QR code, `N` jumps to the next request, `Shift+N` to a random one, and `P` opens the playlists, which include the requests.
- **Jukebox:** a Requests list plays the queue, for a while without singing. In the other lists, requests wait to be sung later.

To turn it on, set `Enabled=On` in the `[SongRequests]` section of `config.ini`. The admin PIN is created the first time. For HTTPS, see [the Caddy example](dists/song-requests/Caddyfile.example).

#### Players and microphones
- **Player boxes:** the song selection shows each player's microphone and name.
- **Mic taps:** tapping a microphone works as a command. This can be set in the game options.
- **Voice:** tap twice and say your nickname to take a microphone, or say goodbye to free it. This needs [whisper.cpp](https://github.com/ggml-org/whisper.cpp): see `[Voice]` in `config.ini`.
- **Phones:** guests can take or free a microphone from the song book.
- **Achievements:** ratings and winning streaks, a crown for the winner, and a chicken for whoever drops the microphone while wearing it.

#### Editor
- **Sung pitch:** the voice is drawn behind the notes. `H` hides the notes.
- **Whole lines:** `Shift+F` and `Shift+G` do what `F` and `G` do, for every note of the line.
- **Help:** each control is explained at the bottom of the screen.

#### Other changes
- During long pauses, only the time left is shown.
- Fatal errors are written to `Crash.log`, with their stack.
- Fixed songs freezing every 5 seconds when no microphone is captured.
- Fixed a crash when jumping around fast in the editor.

### 2. Installation
Download this fork from [the latest release](https://github.com/shininchi/USDX/releases/latest): macOS (Apple Silicon or Intel), Windows (installer or portable) and Linux (AppImage).

The original game, without what this fork adds, is also available from:
- [its releases](https://github.com/UltraStar-Deluxe/USDX/releases/latest)
- flatpak from [flathub](https://flathub.org/apps/eu.usdx.UltraStarDeluxe)
- Arch Linux [AUR](https://aur.archlinux.org/packages/ultrastardx-git)

#### Setting up the song generator
The generator runs [UltraSinger](https://github.com/rakuri255/UltraSinger), which isn't included in the download. It needs Python 3.12, ffmpeg and several GB of disk space, as it downloads its AI models.
1. Clone UltraSinger to `UltraSinger` in your home folder:
   ```bash
   git clone https://github.com/rakuri255/UltraSinger.git ~/UltraSinger
   ```
2. Run the install script for your system from its `install` folder, such as `install/CPU/macos_cpu.sh`. Use `install/CUDA` if you have an NVIDIA graphics card. The script creates the `.venv` folder the game looks for.
3. In the game, open Tools » Editor » Generate, choose a song, or paste a link or drop a file, and press Generate. A song takes a few minutes.

To change the defaults, use this section of `config.ini`:
```ini
  [SongGenerator]
  UltraSingerDir=/path/to/UltraSinger
  Whisper=large-v2
```
It has been tested with UltraSinger commit `e94d942` on macOS. It hasn't been tested on Windows or Linux.

### 3. Configuration
- To set additional song directories change your config.ini like this:
```ini
  [Directories]
  SongDir1=C:\Users\My\Music\MyUSDXSongs
  SongDir2=F:\EvenMoreUSDXSongs
  SongDir...=... (some more directories)
```
- To enable joypad support change config.ini `Joypad=Off` to `Joypad=On`
- To enable 2 or 3 player each on 2 screens, disable the full screen mode, extend your desktop horizontally and set the resolution to fill one screen. Then, in the config.ini set `Screens=2` and restart the game.
- The primary folder for songs on macOS is `$HOME/Music/UltraStar Deluxe`, which is created when UltraStar Deluxe is run for the first time.
- On macOS, by default the `config.ini` file is created in `$HOME/Library/Application Support/UltraStarDeluxe` when UltraStar Deluxe is run for the first time.
- When running in borderless fullscreen mode, the monitor it runs on can be configured by setting `Graphics.PositionX/Y` to an offset in pixels.
- If installed via the flatpak package, the primary song folder is `~/.var/app/eu.usdx.UltraStarDeluxe/.ultrastardx/songs/` and the config.ini is located in `~/.var/app/eu.usdx.UltraStarDeluxe/.ultrastardx/` by default. To configure additional song directories, they first need to be made accessible to the flatpak app using the command: `flatpak override eu.usdx.UltraStarDeluxe --filesystem=/your/new/songfolder` - Afterwards, the directory can be added to the config.ini file as usual.

### 4. Further documentation
The [documentation](https://usdx.eu/docs/) contains more information on:
* [Command-line parameters](https://usdx.eu/docs/command-line-parameters/)
* [Controls](https://usdx.eu/docs/controls/)
* [Customization](https://usdx.eu/docs/customization/)

### 5. Compiling
The game has an Autotools-based buildsystem and can be compiled by running `./autogen.sh && ./configure [--enable-debug] && make`. The executable will be `game/ultrastardx[.exe]`.

For extended information, dependencies, OS-specific notes and configure flags, see [COMPILING.md](COMPILING.md).

### 6. Making a release
See [RELEASING.md](RELEASING.md)

Other useful documents for maintainers: [pipeline info](PIPELINE.md).
