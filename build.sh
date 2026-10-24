#!/bin/zsh
set -eu
if [[ "$(uname -s)" != "Darwin" ]]; then
  print -u2 'Small Recorder requires macOS.'
  exit 1
fi
source_dir="${0:A:h}"
app_dir="${APP_DIR:-$HOME/Applications/Small Recorder.app}"
mkdir -p "$app_dir/Contents/MacOS"
cp "$source_dir/Info.plist" "$app_dir/Contents/Info.plist"
xcrun swiftc -parse-as-library -O -target "$(uname -m)-apple-macosx13.0" "$source_dir/main.swift" "$source_dir/CursorFollow.swift" "$source_dir/RecordingSettings.swift" -o "$app_dir/Contents/MacOS/SmallRecorder" -framework SwiftUI -framework AppKit -framework AVFoundation -framework CoreGraphics -framework ScreenCaptureKit -framework CoreMedia
codesign --force --deep --sign "${CODESIGN_IDENTITY:--}" "$app_dir"
print "Built: $app_dir"
