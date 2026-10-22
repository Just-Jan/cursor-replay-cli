#!/bin/sh
set -eu

if [ "$#" -ne 2 ]; then
    printf 'Usage: sh scripts/test-homebrew.sh source.tar.gz cursor-replay.rb\n' >&2
    exit 1
fi
archive=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
formula=$(cd "$(dirname "$2")" && pwd)/$(basename "$2")
if [ ! -f "$archive" ] || [ ! -f "$formula" ]; then
    printf 'Both the source archive and generated formula must exist.\n' >&2
    exit 1
fi

export HOMEBREW_NO_AUTO_UPDATE=1
export HOMEBREW_NO_INSTALL_CLEANUP=1
export HOMEBREW_NO_ANALYTICS=1
if [ -n "$(brew list --formula --versions cursor-replay)" ]; then
    printf 'Uninstall the existing Homebrew cursor-replay before running this isolated packaging check.\n' >&2
    exit 1
fi

tap="cursor-replay-test/local-$$"
name="$tap/cursor-replay"
installed=0
brew tap-new --no-git "$tap"
cleanup() {
    status=$?
    trap - 0
    if [ "$installed" -eq 1 ]; then
        if ! brew uninstall --formula "$name"; then
            printf 'Failed to uninstall temporary formula %s\n' "$name" >&2
            status=1
        fi
    fi
    if ! brew untap "$tap"; then
        printf 'Failed to remove temporary tap %s\n' "$tap" >&2
        status=1
    fi
    exit "$status"
}
trap cleanup 0
tap_dir=$(brew --repository "$tap")
export XDG_CONFIG_HOME="$tap_dir/.test-config"
ruby - "$formula" "$tap_dir/Formula/cursor-replay.rb" "$archive" <<'RUBY'
require "uri"
source, destination, archive = ARGV
formula = File.read(source)
url = "file://#{URI::DEFAULT_PARSER.escape(archive)}"
abort "Formula has no stable source URL." unless formula.sub!(/^  url "[^"]+"$/, "  url \"#{url}\"")
File.write(destination, formula)
RUBY
brew style --formula "$name"
installed=1
brew install --build-from-source "$name"
brew test "$name"
"$(brew --prefix "$name")/bin/cursor-replay" --version
