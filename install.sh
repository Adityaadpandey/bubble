#!/bin/bash
# Installs (or updates) Notchy with one line:
#
#   curl -fsSL https://raw.githubusercontent.com/Adityaadpandey/notchy/main/install.sh | bash
#
# It downloads the latest release, puts Notchy in /Applications (or ~/Applications if you can't write
# there), and opens it. Running it again later updates Notchy in place.
#
# NOTCHY_URL and NOTCHY_DEST swap the download or the folder, e.g. to try a build you made yourself:
#   NOTCHY_URL=file://$PWD/build/Notchy.zip NOTCHY_DEST=~/Desktop bash install.sh
set -euo pipefail

url="${NOTCHY_URL:-https://github.com/Adityaadpandey/notchy/releases/latest/download/Notchy.zip}"

if [[ "$(uname)" != Darwin ]]; then
  echo "Notchy is a Mac app, it won't run here." >&2
  exit 1
fi
if (( $(sw_vers -productVersion | cut -d. -f1) < 14 )); then
  echo "Notchy needs macOS 14 Sonoma or later, this Mac has $(sw_vers -productVersion)." >&2
  exit 1
fi

dest="${NOTCHY_DEST:-/Applications}"
[[ -w "$dest" ]] || dest="$HOME/Applications"
mkdir -p "$dest"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "Downloading Notchy…"
curl -fsSL "$url" -o "$tmp/Notchy.zip"
ditto -x -k "$tmp/Notchy.zip" "$tmp"

# swap out the old copy if there is one, so this doubles as the updater
pkill -x Notchy 2>/dev/null && sleep 1 || true
rm -rf "$dest/Notchy.app"
ditto "$tmp/Notchy.app" "$dest/Notchy.app"
# downloads through curl aren't flagged by macOS, but clear it anyway so Notchy opens without a warning
xattr -dr com.apple.quarantine "$dest/Notchy.app" 2>/dev/null || true

open "$dest/Notchy.app"
echo "Notchy is installed in $dest and running. Hover over your notch to say hi."
