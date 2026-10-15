#!/bin/bash
# Installs (or updates) Perch with one line:
#
#   curl -fsSL https://raw.githubusercontent.com/Adityaadpandey/notchy/main/install.sh | bash
#
# It downloads the latest release, puts Perch in /Applications (or ~/Applications if you can't write
# there), and opens it. Running it again later updates Perch in place.
#
# PERCH_URL and PERCH_DEST swap the download or the folder, e.g. to try a build you made yourself:
#   PERCH_URL=file://$PWD/build/Perch.zip PERCH_DEST=~/Desktop bash install.sh
set -euo pipefail

url="${PERCH_URL:-https://github.com/Adityaadpandey/notchy/releases/latest/download/Perch.zip}"

if [[ "$(uname)" != Darwin ]]; then
  echo "Perch is a Mac app, it won't run here." >&2
  exit 1
fi
if (( $(sw_vers -productVersion | cut -d. -f1) < 14 )); then
  echo "Perch needs macOS 14 Sonoma or later, this Mac has $(sw_vers -productVersion)." >&2
  exit 1
fi

dest="${PERCH_DEST:-/Applications}"
[[ -w "$dest" ]] || dest="$HOME/Applications"
mkdir -p "$dest"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "Downloading Perch…"
curl -fsSL "$url" -o "$tmp/Perch.zip"
ditto -x -k "$tmp/Perch.zip" "$tmp"

# swap out the old copy if there is one, so this doubles as the updater
pkill -x Perch 2>/dev/null && sleep 1 || true
rm -rf "$dest/Perch.app"
ditto "$tmp/Perch.app" "$dest/Perch.app"
# downloads through curl aren't flagged by macOS, but clear it anyway so Perch opens without a warning
xattr -dr com.apple.quarantine "$dest/Perch.app" 2>/dev/null || true

open "$dest/Perch.app"
echo "Perch is installed in $dest and running. Hover over your notch to say hi."
