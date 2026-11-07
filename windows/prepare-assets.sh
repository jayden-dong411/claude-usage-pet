#!/bin/zsh
# Copies the 80 outline-stripped Claude大小姐 stickers and the icon into windows/assets.
# Uses the same tool as the macOS build (Tools/strip_outline.swift), so run it on a Mac.
set -euo pipefail
cd "$(dirname "$0")"
ROOT=".."
TMP="$(mktemp -d)"
swiftc -O "$ROOT/Tools/strip_outline.swift" -o "$TMP/strip_outline" 2>/dev/null
rm -rf assets/head && mkdir -p assets build-res
"$TMP/strip_outline" "$ROOT/Assets/daxiaojie/head" assets/head
cp "$ROOT/Assets/daxiaojie/ATTRIBUTION.txt" assets/ATTRIBUTION.txt
sips -p 1024 1024 "$ROOT/Assets/daxiaojie/icon-starry.png" --out "$TMP/icon-square.png" >/dev/null
sips -z 512 512 "$TMP/icon-square.png" --out build-res/icon.png >/dev/null
sips -z 256 256 "$TMP/icon-square.png" --out assets/icon.png >/dev/null
rm -rf "$TMP"
echo "✓ assets ready: $(ls assets/head | wc -l | tr -d ' ') faces"
