#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

# Some Command Line Tools releases do not automatically load their Testing plugin.
swiftc_path=$(/usr/bin/xcrun --find swiftc)
toolchain_usr=$(dirname "$(dirname "$swiftc_path")")
plugin="$toolchain_usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
build_dir="${CURSOR_REPLAY_BUILD_DIR:-$HOME/Library/Caches/cursor-replay-cli/swiftpm}"
if [ -f "$plugin" ]; then
    exec swift test --scratch-path "$build_dir" --disable-xctest -Xswiftc -load-plugin-library -Xswiftc "$plugin" "$@"
fi
exec swift test --scratch-path "$build_dir" --disable-xctest "$@"
