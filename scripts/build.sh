#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

build_dir="${CURSOR_REPLAY_BUILD_DIR:-$HOME/Library/Caches/cursor-replay-cli/swiftpm}"
swift build --scratch-path "$build_dir" -c release --product cursor-replay
binary_dir=$(swift build --scratch-path "$build_dir" -c release --show-bin-path)
mkdir -p bin
install -m 755 "$binary_dir/cursor-replay" bin/cursor-replay
printf '\nReady: ./bin/cursor-replay\n'
