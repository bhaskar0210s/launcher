#!/bin/sh
# Installs the latest Pounce and opens it:
#
#   curl -fsSL https://raw.githubusercontent.com/bhaskar0210s/pounce/main/install.sh | sh
#
# The download is checked against the signature of Pounce's release key before anything is installed. Files that
# curl downloads carry no quarantine flag, so macOS opens Pounce without the warning it shows for apps from a
# browser that aren't notarized by Apple.
set -eu

repo="bhaskar0210s/pounce"
id="app.pounce.Pounce"

if [ "$(uname -m)" != "arm64" ] || [ "$(sw_vers -productVersion | cut -d. -f1)" -lt 27 ]; then
    echo "Pounce needs a Mac with Apple silicon and macOS 27 or later." >&2
    exit 1
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$work"

echo "Downloading Pounce…"
curl -fsSL -o Pounce.zip "https://github.com/$repo/releases/latest/download/Pounce.zip"
curl -fsSL -o Pounce.zip.sig "https://github.com/$repo/releases/latest/download/Pounce.zip.sig"

cat > key.pem <<'KEY'
-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEE366oDVUSBMRgXdPjSuQSzgx5eWl
pdYOZWFLup8QUR/VrBHoroVNSB5tSNzoCOst9mK4YG0iC5zRg15W0jvXSQ==
-----END PUBLIC KEY-----
KEY
if ! /usr/bin/openssl dgst -sha256 -verify key.pem -signature Pounce.zip.sig Pounce.zip >/dev/null 2>&1; then
    echo "The download isn't signed by Pounce's release key, so it wasn't installed." >&2
    exit 1
fi

ditto -x -k Pounce.zip unpacked
codesign --verify --deep --strict unpacked/Pounce.app

# /Applications when it can be written to, otherwise the Applications folder in your home folder.
target=/Applications
if [ ! -w "$target" ]; then
    target="$HOME/Applications"
    mkdir -p "$target"
fi
# Other apps are called Pounce too: only this one is replaced.
if [ -d "$target/Pounce.app" ] && [ "$(defaults read "$target/Pounce.app/Contents/Info" CFBundleIdentifier 2>/dev/null)" != "$id" ]; then
    echo "$target already has a different app called Pounce, so Pounce wasn't installed." >&2
    exit 1
fi
pkill -f "$target/Pounce.app/Contents/MacOS/Pounce" 2>/dev/null && sleep 1 || true
rm -rf "$target/Pounce.app"
ditto unpacked/Pounce.app "$target/Pounce.app"
open "$target/Pounce.app"
echo "Pounce is installed in $target. Press ⌘Space to open it, and ⌘, in it to add your apps."
# Pounce was called Launcher before version 1.3. It takes over Launcher's settings by itself.
if [ "$(defaults read "$target/Launcher.app/Contents/Info" CFBundleIdentifier 2>/dev/null)" = "app.launcher.Launcher" ]; then
    echo "Launcher, Pounce's old name, is still in $target. Pounce has taken over its settings, so you can delete Launcher."
fi
