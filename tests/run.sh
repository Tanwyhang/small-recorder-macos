#!/bin/zsh
set -eu
source_dir="${0:A:h:h}"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/small-recorder-tests.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc "$source_dir/CursorFollow.swift" "$source_dir/RecordingSettings.swift" "$source_dir/tests/CursorMotionTests.swift" -o "$test_dir/CursorMotionTests"
"$test_dir/CursorMotionTests" "$test_dir"
python3 "$source_dir/tests/verify_render.py" "$test_dir"
