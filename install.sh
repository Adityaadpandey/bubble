#!/bin/bash
# Installs (or updates) Bubble with one line:
#
#   curl -fsSL https://raw.githubusercontent.com/Adityaadpandey/bubble/main/install.sh | bash
#
# It downloads the latest release, puts Bubble in /Applications (or ~/Applications if you can't write
# there), and opens it. Running it again later updates Bubble in place.
#
# BUBBLE_URL and BUBBLE_DEST swap the download or the folder, e.g. to try a build you made yourself:
#   BUBBLE_URL=file://$PWD/build/Bubble.zip BUBBLE_DEST=~/Desktop bash install.sh
set -euo pipefail

url="${BUBBLE_URL:-https://github.com/Adityaadpandey/bubble/releases/latest/download/Bubble.zip}"

if [[ "$(uname)" != Darwin ]]; then
  echo "Bubble is a Mac app, it won't run here." >&2
  exit 1
fi
if (( $(sw_vers -productVersion | cut -d. -f1) < 14 )); then
  echo "Bubble needs macOS 14 Sonoma or later, this Mac has $(sw_vers -productVersion)." >&2
  exit 1
fi

dest="${BUBBLE_DEST:-/Applications}"
[[ -w "$dest" ]] || dest="$HOME/Applications"
mkdir -p "$dest"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "Downloading Bubble…"
curl -fsSL "$url" -o "$tmp/Bubble.zip"
ditto -x -k "$tmp/Bubble.zip" "$tmp"

# swap out the old copy if there is one, so this doubles as the updater
pkill -x Bubble 2>/dev/null && sleep 1 || true
# Bubble used to be called Notchy, so clear out that app too rather than leave two running
pkill -x Notchy 2>/dev/null && sleep 1 || true
rm -rf "$dest/Bubble.app" "$dest/Notchy.app"
ditto "$tmp/Bubble.app" "$dest/Bubble.app"
# downloads through curl aren't flagged by macOS, but clear it anyway so Bubble opens without a warning
xattr -dr com.apple.quarantine "$dest/Bubble.app" 2>/dev/null || true

open "$dest/Bubble.app"
echo "Bubble is installed in $dest and running. Hover over your notch to say hi."
