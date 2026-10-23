# Small Recorder for macOS

**Record your screen. Skip the huge file.**

A simple native Mac app that uses FFmpeg to save compact, shareable MP4 screen recordings.

## Why we made this

You record a quick demo on your Mac, then discover the file is too large to send. Now a simple screen recording needs another app, another export, and another wait.

We built Small Recorder to remove that extra step. It compresses while you record, with sensible resolution and frame-rate limits, so quick walkthroughs and bug reports stay small from the start. Each clip automatically stops near 27 MB, leaving headroom under a 30 MB attachment limit.

The recording that prompted this project was **62.18 MB for just 23 seconds**. A separate FFmpeg compression pass brought it down to **4.14 MB**. Small Recorder brings that small-file approach into a Start/Stop app, rather than making you compress every recording afterward.

## What it does

- Native SwiftUI interface with screen selection and Start / Stop & Save.
- **Small:** up to 720p at 15 fps, with a 900 kbps video bitrate ceiling.
- **Clear:** up to 1080p at 30 fps, with a 2,000 kbps video bitrate ceiling.
- Optional microphone audio, encoded as mono AAC at 64 kbps.
- H.264 MP4 output with the original screen aspect ratio and mouse cursor preserved.
- Automatically stops near 27 MB; start another clip to keep recording.
- Saves locally to `~/Movies/Small Recorder/`. No accounts, uploads, or cloud processing.

File size depends on screen activity and recording length. The size stop leaves room for MP4 finalization; it is not an exact 27 MB export target.

## Requirements

- **macOS 13 or newer.** This is a Mac app; Windows and Linux are not supported.
- Xcode Command Line Tools or Xcode, for compiling the app.
- FFmpeg with AVFoundation, libx264, and AAC support. The Homebrew build works.

The app checks both Apple Silicon (`/opt/homebrew/bin`) and Intel (`/usr/local/bin`) Homebrew locations, followed by its process PATH. Builds target the architecture of the Mac running the build script. Live capture has been tested on Apple Silicon; Intel has not been tested.

## Install from source

Install the [Xcode Command Line Tools](https://developer.apple.com/xcode/resources/) and [Homebrew](https://brew.sh/) if needed, then run:

```sh
xcode-select --install  # Skip if Xcode or its command-line tools are installed.
brew install ffmpeg
git clone https://github.com/Tanwyhang/small-recorder-macos.git
cd small-recorder-macos
./build.sh
open "$HOME/Applications/Small Recorder.app"
```

The script installs the app in your user Applications folder and applies a local ad hoc signature. It does not produce an Apple-notarized release. Quit the app before rebuilding it. Rebuilding may require granting Screen Recording permission again.

To build elsewhere without replacing an installed copy:

```sh
APP_DIR="$PWD/build/Small Recorder.app" ./build.sh
```

## Record

1. Open Small Recorder and select a screen.
2. Choose Small or Clear quality. Select a microphone if you want narration, or keep No audio.
3. Click **Start Recording**.
4. On first use, enable Small Recorder in **System Settings → Privacy & Security → Screen & System Audio Recording** (called Screen Recording on some macOS versions). Quit and reopen the app when requested. macOS may also ask you to allow direct screen access.
5. Minimize the recorder while you work. Bring it back and click **Stop & Save**.
6. Click **Recordings** or **Show Last** to find the MP4.

Microphone narration needs a separate Microphone permission. The app uses the screen permission category named “Screen & System Audio Recording,” but it does **not** capture system audio.

## Limits and troubleshooting

- Captures a whole screen. Region selection, window selection, pause, editing, and system audio capture are not included.
- The size limit stops the recording; it does not automatically start another segment.
- If FFmpeg is missing, install it with `brew install ffmpeg`, then reopen the app.
- If no screen appears, check Screen Recording permission, reopen the app, and click Refresh.
- If recording fails, inspect `~/Movies/Small Recorder/last-recording.log`.
- Keep the app running until Stop & Save has finished finalizing the MP4.

## Verification

Built and tested on an Apple Silicon Mac. Two live screen recordings were saved and decoded successfully. The final test contained 167 frames over 11.07 seconds at 1112 × 720, taking **0.41 MB**; an extracted frame confirmed actual screen content. The app returned to Ready after Stop & Save.

That size came from a short desktop recording, not a benchmark for every kind of content. Microphone capture, Intel Macs, and automatic stopping at the size limit have not been live-tested.

## Source

- `main.swift` — SwiftUI controls, permissions, device discovery, and FFmpeg recording.
- `Info.plist` — app metadata and permission descriptions.
- `build.sh` — native compilation and local app installation.

FFmpeg is installed separately and is not bundled in this repository. Personal recordings, screen images, logs, and local test paths are excluded from Git.
