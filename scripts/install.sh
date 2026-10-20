#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

./scripts/build.sh
mkdir -p "$HOME/.local/bin"
install -m 755 bin/cursor-replay "$HOME/.local/bin/cursor-replay"
printf '\nInstalled: %s/.local/bin/cursor-replay\n' "$HOME"
printf 'If needed, add this directory to PATH: export PATH="$HOME/.local/bin:$PATH"\n'
