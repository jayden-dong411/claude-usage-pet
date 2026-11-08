#!/bin/zsh
# Builds "GPT龙娘.app" into ./build — a ChatGPT / Codex desktop pet.
# Looks: the v3 expressions in Assets/v3 (ai-chan-sheets GPT娘 sheet, CC BY-NC-SA 4.0) are always
# bundled. The animated GPT龙娘 sprite sheet (github.com/tqlearning/ai-girl-chatgpt-pets) has no open
# license, so it is not in this repository: ./fetch-dragon.sh downloads it into the git-ignored
# Assets/gpt-dragon for a local build, and EXCLUDE_DRAGON=1 leaves it out (used for release packages).
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(pwd)"
ART="$ROOT/Assets/gpt-dragon"
APP="$ROOT/build/GPT龙娘.app"
RES="$APP/Contents/Resources"
TMP="$ROOT/build/tmp"

rm -rf "$APP" "$TMP"
mkdir -p "$APP/Contents/MacOS" "$RES" "$TMP"
DRAGON=0
if [[ -f "$ART/spritesheet.png" && "${EXCLUDE_DRAGON:-0}" != "1" ]]; then
  echo "• 校验龙娘精灵图…"
  EXPECT=$(python3 -c "import json;print(json.load(open('$ART/pet.json'))['integrity']['sha256'])")
  GOT=$(shasum -a 256 "$ART/spritesheet.png" | cut -d' ' -f1)
  [[ "$EXPECT" == "$GOT" ]] || { echo "精灵图校验失败"; exit 1; }
  DRAGON=1
fi

echo "• 编译 Swift…"
for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -parse-as-library \
    -target $arch-apple-macos14.0 \
    -framework AppKit -framework SwiftUI -framework ServiceManagement -framework Charts \
    Sources/*.swift ../Companion/*.swift \
    ../../Sources/{V3Figure,Peers,PetHub,PetChrome}.swift -o "$TMP/GPTDragonPet-$arch"
done
lipo -create "$TMP/GPTDragonPet-arm64" "$TMP/GPTDragonPet-x86_64" -output "$APP/Contents/MacOS/GPTDragonPet"

echo "• 拷贝素材…"
if [[ "$DRAGON" == "1" ]]; then
  cp "$ART/spritesheet.png" "$RES/spritesheet.png"
  cp "$ART/ATTRIBUTION.md" "$ART/RIGHTS.md" "$RES/"
  echo "  已包含龙娘精灵图（仅本机）"
fi
if [[ -f "$ROOT/Assets/v3/face_smile.png" ]]; then        # v3 figure (ai-chan-sheets, CC BY-NC-SA 4.0)
  mkdir -p "$RES/v3" && cp "$ROOT"/Assets/v3/*.png "$ROOT/Assets/v3/SOURCE.txt" "$RES/v3/"
fi

echo "• 生成图标…"
ICONSET="$TMP/AppIcon.iconset"
mkdir -p "$ICONSET"
if [[ "$DRAGON" == "1" ]]; then
  # Row 3 (waving), column 1: x = 192, y = 624 in the 1536 × 2288 sheet.
  sips -c 208 192 --cropOffset 624 192 "$ART/spritesheet.png" --out "$TMP/cell.png" >/dev/null
  sips -p 208 208 "$TMP/cell.png" --out "$TMP/square.png" >/dev/null
else
  W=$(sips -g pixelWidth "$ROOT/Assets/v3/face_smile.png" | awk '/pixelWidth/{print $2}')
  sips -p $W $W "$ROOT/Assets/v3/face_smile.png" --out "$TMP/square.png" >/dev/null
fi
for s in 16 32 128 256 512; do
  sips -z $s $s "$TMP/square.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$TMP/square.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$RES/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>GPT龙娘</string>
  <key>CFBundleDisplayName</key><string>GPT龙娘</string>
  <key>CFBundleIdentifier</key><string>local.gptdragon.pet</string>
  <key>CFBundleExecutable</key><string>GPTDragonPet</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

rm -rf "$TMP"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
echo "✓ 完成：$APP"
