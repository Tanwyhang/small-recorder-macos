# Small Recorder for macOS

**Record your screen. Skip the huge file.**

A simple native Mac app that uses FFmpeg to save compact, shareable MP4 screen recordings.

## Why we made this

You record a quick demo on your Mac, then discover the file is too large to send. Now a simple screen recording needs another app, another export, and another wait.

We built Small Recorder to remove that extra step. It compresses while you record, with sensible resolution and frame-rate limits, so quick walkthroughs and bug reports stay small from the start. Each clip automatically stops near 27 MB, leaving headroom under a 30 MB attachment limit.

The recording that prompted this project was **62.18 MB for just 23 seconds**. A separate FFmpeg compression pass brought it down to **4.14 MB**. Small Recorder brings that small-file approach into a Start/Stop app, rather than making you compress every recording afterward.

## What it does

- Native SwiftUI interface with screen selection and Start / Stop & Save.
- **Resolution:** choose 720p, 1080p, or Native independently of frame rate. Native preserves the captured display pixels; an odd dimension is padded by one pixel for H.264 compatibility.
- **Frame rate:** choose 15, 24, 30, or 60 fps, or enter a custom whole-number value from 1–120 fps. Actual capture speed depends on the display and available processing power. Settings are remembered between launches.
- Bitrate ceilings scale with resolution and FPS. Higher settings usually reach the 27 MB clip limit sooner.
- **Follow cursor:** optional 5% zoom with smooth cubic Bézier camera motion, enabled by default.
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

The script installs the app in your user Applications folder and applies a local ad hoc signature. It does not produce an Apple-notarized release. Quit the app before rebuilding it. Rebuilding may require granting Screen Recording permission again. If Settings shows access enabled but the rebuilt app is denied, quit the app and reset only its stale approval with `tccutil reset ScreenCapture local.wy.smallrecorder`, then reopen it and grant access to the current build. For stable permissions across builds, use an existing Apple Development or Developer ID signing identity: `CODESIGN_IDENTITY="Apple Development: Your Name (TEAMID)" ./build.sh`. The build script defaults to ad hoc signing when no identity is provided.

To build elsewhere without replacing an installed copy:

```sh
APP_DIR="$PWD/build/Small Recorder.app" ./build.sh
```

## Record

1. Open Small Recorder and select a screen.
2. Choose Resolution and Frame rate separately. For example, use Native at 30 fps, or 720p at custom 48 fps. Select a microphone if you want narration, or keep No audio.
3. Click **Start Recording**.
4. On first use, enable Small Recorder in **System Settings → Privacy & Security → Screen & System Audio Recording** (called Screen Recording on some macOS versions). Quit and reopen the app when requested. macOS may also ask you to allow direct screen access.
5. Leave **Follow cursor · 5% zoom** enabled for a gentle pan toward your cursor, or turn it off for a normal full-screen recording.
6. Minimize the recorder while you work. Bring it back and click **Stop & Save**. With cursor follow enabled, wait for **Rendering smooth cursor follow…** to finish.
7. Click **Recordings** or **Show Last** to find the MP4.

Microphone narration needs a separate Microphone permission. The app uses the screen permission category named “Screen & System Audio Recording,” but it does **not** capture system audio.

## Smooth cursor follow

Cursor follow zooms the saved video by approximately 5% and eases the view toward the cursor. Your actual Mac display stays unchanged. The camera stays within the selected screen, including on displays with different origins or Retina scaling; moving onto another display holds the camera at the nearest edge.

During recording, the app samples normalized cursor positions locally at 60 Hz on the AVFoundation host clock. The timeline is aligned using FFmpeg’s exact input timestamp offset, rather than encoder progress or the time a log message arrives.

Motion uses two separate easing stages: an intermediate target eases toward the absolute cursor position (100 ms time constant), then the view eases toward that moving target (180 ms time constant). This intentionally gives the view a soft catch-up response. Both stages are integrated using elapsed time, so the feel is consistent at different frame rates. Cubic Bézier interpolation preserves velocity between the resulting positions without adding a third smoothing stage.

Moving the cursor right makes the visible picture glide right; moving it down makes the picture glide down. Crop positions are applied on their intended video frames at double resolution for half-pixel pan steps, then scaled back to the original output dimensions.

This adds a local rendering step after capture. Keep the app open until it reports Saved; quitting during this step waits for completion. The temporary capture and cursor command file are removed after a successful export. If rendering fails, the original capture is kept instead. Cursor data is never uploaded.

## Limits and troubleshooting

- Captures a whole screen. Region selection, window selection, pause, editing, and system audio capture are not included.
- The size limit stops the recording; it does not automatically start another segment.
- If FFmpeg is missing, install it with `brew install ffmpeg`, then reopen the app.
- If no screen appears, check Screen Recording permission, reopen the app, and click Refresh.
- If recording fails, inspect `~/Movies/Small Recorder/last-recording.log`.
- Keep the app running until Stop & Save has finished finalizing the MP4.

## Verification

Built and tested on an Apple Silicon Mac. Two live screen recordings were saved and decoded successfully. The final test contained 167 frames over 11.07 seconds at 1112 × 720, taking **0.41 MB**; an extracted frame confirmed actual screen content. The app returned to Ready after Stop & Save. A subsequent live test with cursor follow enabled successfully rendered 156 frames over 10.40 seconds at 1112 × 720 / 15 fps into a 0.14 MB MP4; the full file decoded cleanly. Screen access is checked through ScreenCaptureKit before FFmpeg capture begins.

That size came from a short desktop recording, not a benchmark for every kind of content. Microphone capture, Intel Macs, and automatic stopping at the size limit have not been live-tested.

## Development checks

```sh
./tests/run.sh
```

The tests check stationary-cursor stability, bounded camera motion, two-stage jump response, frame-rate independence, no anticipation, and continuous Bézier velocity. An FFmpeg integration test verifies exact crop positions and command placement on intermediate video frames; unit checks also verify exact capture-clock parsing. It also confirms that rendering preserves frame count, duration, dimensions, and audio.

Native resolution and independent FPS were additionally tested using a 2560 × 1600 source at custom 48 fps, and a separate 1080p export at 24 fps. A live Native recording with cursor follow preserved all 3420 × 2214 captured pixels at custom 48 fps: 436 frames over 9.08 seconds, 0.97 MB, with the full output decoded successfully. Resolution and FPS preferences were verified as saved between launches.

## Source

- `main.swift` — SwiftUI controls, permissions, device discovery, and FFmpeg recording.
- `RecordingSettings.swift` — independent resolution, FPS validation, and encoding settings.
- `CursorFollow.swift` — display-relative cursor tracking and cubic Bézier motion.
- `tests/` — motion and FFmpeg integration checks.
- `Info.plist` — app metadata and permission descriptions.
- `build.sh` — native compilation and local app installation.

FFmpeg is installed separately and is not bundled in this repository. Personal recordings, screen images, logs, and local test paths are excluded from Git.
