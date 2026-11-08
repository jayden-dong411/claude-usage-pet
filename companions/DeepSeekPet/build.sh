#!/bin/zsh
# Builds "DeepSeek娘.app" into ./build — a DeepSeek Harness desktop pet for this Mac only.
# Artwork: the 8 expressions of ai-chan-sheets #12, set 2 (DeepSeek娘 Q版冬装「冬装小肥鱼2」), cut by
# ../../Tools/make_v3_assets.py into Assets/v3 (sheet completion CC BY-NC-SA 4.0; the source
# picture's author is not credited in the sheet repository).
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(pwd)"
APP="$ROOT/build/DeepSeek娘.app"
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
    ../../Sources/{V3Figure,Peers,PetHub,PetChrome}.swift -o "$TMP/DeepSeekPet-$arch"
done
lipo -create "$TMP/DeepSeekPet-arm64" "$TMP/DeepSeekPet-x86_64" -output "$APP/Contents/MacOS/DeepSeekPet"

echo "• 拷贝素材…"
mkdir -p "$RES/v3" && cp "$ROOT"/Assets/v3/*.png "$ROOT/Assets/v3/SOURCE.txt" "$RES/v3/"

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
  <key>CFBundleName</key><string>DeepSeek娘</string>
  <key>CFBundleDisplayName</key><string>DeepSeek娘</string>
  <key>CFBundleIdentifier</key><string>local.deepseekchan.pet</string>
  <key>CFBundleExecutable</key><string>DeepSeekPet</string>
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
