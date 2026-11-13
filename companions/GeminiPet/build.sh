#!/bin/zsh
# Builds "Gemini娘.app" into ./build — a Google Antigravity (Gemini) desktop pet for this Mac.
# Artwork: Gemini娘 v3 figure cut from github.com/lmy414/ai-chan-sheets (character design ZipZipPipe,
# CC BY-NC-SA 4.0, non-commercial) by ../../Tools/make_v3_assets.py into Assets/v3.
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(pwd)"
APP="$ROOT/build/Gemini娘.app"
RES="$APP/Contents/Resources"
TMP="$ROOT/build/tmp"

rm -rf "$APP" "$TMP"
mkdir -p "$APP/Contents/MacOS" "$RES" "$TMP"
[[ -f "$ROOT/Assets/v3/face_smile.png" ]] || { echo "缺少 Assets/v3 素材，先运行 ../../Tools/make_v3_assets.py"; exit 1; }

echo "• 编译 Swift…"
for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -parse-as-library \
    -target $arch-apple-macos14.0 \
    -framework AppKit -framework SwiftUI -framework ServiceManagement -framework Charts \
    Sources/*.swift ../Companion/*.swift \
    ../../Sources/{V3Figure,Peers,GeminiLink,GeminiSide,UsageIndex,CodexSide,DashboardView,Heatmap,PetHub,PetChrome,Banter,PetPlay}.swift -o "$TMP/GeminiPet-$arch"
done
lipo -create "$TMP/GeminiPet-arm64" "$TMP/GeminiPet-x86_64" -output "$APP/Contents/MacOS/GeminiPet"

echo "• 拷贝素材…"
mkdir -p "$RES/v3" && cp "$ROOT"/Assets/v3/*.png "$ROOT/Assets/v3/SOURCE.txt" "$RES/v3/"

cp ../../Assets/banter.json "$RES/banter.json"          # what she says (shared by all pets)

echo "• 生成图标（微笑表情）…"
ICONSET="$TMP/AppIcon.iconset"
mkdir -p "$ICONSET"
sips -p 440 440 "$ROOT/Assets/v3/face_smile.png" --out "$TMP/square.png" >/dev/null   # pad to a square
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
  <key>CFBundleName</key><string>Gemini娘</string>
  <key>CFBundleDisplayName</key><string>Gemini娘</string>
  <key>CFBundleIdentifier</key><string>local.geminichan.pet</string>
  <key>CFBundleExecutable</key><string>GeminiPet</string>
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
# One version for every pet (repo-root VERSION), build number = commit count.
VER="$(cat "$ROOT/../../VERSION" 2>/dev/null || echo 0.0.0)"
BUILD="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VER" -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
echo "✓ 完成：$APP"
