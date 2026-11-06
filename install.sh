#!/bin/sh
# Installs the latest Launcher and opens it:
#
#   curl -fsSL https://raw.githubusercontent.com/bhaskar0210s/launcher/main/install.sh | sh
#
# The download is checked against the signature of Launcher's release key before anything is installed. Files that
# curl downloads carry no quarantine flag, so macOS opens Launcher without the warning it shows for apps from a
# browser that aren't notarized by Apple.
set -eu

repo="bhaskar0210s/launcher"
id="app.launcher.Launcher"

if [ "$(uname -m)" != "arm64" ] || [ "$(sw_vers -productVersion | cut -d. -f1)" -lt 27 ]; then
    echo "Launcher needs a Mac with Apple silicon and macOS 27 or later." >&2
    exit 1
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$work"

echo "Downloading Launcher…"
curl -fsSL -o Launcher.zip "https://github.com/$repo/releases/latest/download/Launcher.zip"
curl -fsSL -o Launcher.zip.sig "https://github.com/$repo/releases/latest/download/Launcher.zip.sig"

cat > key.pem <<'KEY'
-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEE366oDVUSBMRgXdPjSuQSzgx5eWl
pdYOZWFLup8QUR/VrBHoroVNSB5tSNzoCOst9mK4YG0iC5zRg15W0jvXSQ==
-----END PUBLIC KEY-----
KEY
if ! /usr/bin/openssl dgst -sha256 -verify key.pem -signature Launcher.zip.sig Launcher.zip >/dev/null 2>&1; then
    echo "The download isn't signed by Launcher's release key, so it wasn't installed." >&2
    exit 1
fi

ditto -x -k Launcher.zip unpacked
codesign --verify --deep --strict unpacked/Launcher.app

# /Applications when it can be written to, otherwise the Applications folder in your home folder.
target=/Applications
if [ ! -w "$target" ]; then
    target="$HOME/Applications"
    mkdir -p "$target"
fi
# Other apps are called Launcher too: only this one is replaced.
if [ -d "$target/Launcher.app" ] && [ "$(defaults read "$target/Launcher.app/Contents/Info" CFBundleIdentifier 2>/dev/null)" != "$id" ]; then
    echo "$target already has a different app called Launcher, so Launcher wasn't installed." >&2
    exit 1
fi
pkill -f "$target/Launcher.app/Contents/MacOS/Launcher" 2>/dev/null && sleep 1 || true
rm -rf "$target/Launcher.app"
ditto unpacked/Launcher.app "$target/Launcher.app"
open "$target/Launcher.app"
echo "Launcher is installed in $target. Press ⌘Space to open it, and ⌘, in it to add your apps."
