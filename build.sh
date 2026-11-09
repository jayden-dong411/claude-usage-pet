#!/bin/zsh
# Builds "Claude大小姐.app" into ./build — a standalone menu-less desktop pet.
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(pwd)"
ART="$ROOT/Assets/daxiaojie"         # Claude大小姐 head stickers (CC BY-NC-SA 4.0, see ATTRIBUTION.txt)
APP="$ROOT/build/Claude大小姐.app"
RES="$APP/Contents/Resources"
TMP="$ROOT/build/tmp"

rm -rf "$APP" "$TMP"
mkdir -p "$APP/Contents/MacOS" "$RES" "$TMP"

echo "• 编译 Swift…"
# Universal binary (Apple silicon + Intel) so it runs on any Mac with macOS 14+.
for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -parse-as-library \
    -target $arch-apple-macos14.0 \
    -framework AppKit -framework SwiftUI -framework WebKit -framework ServiceManagement -framework Charts -lsqlite3 \
    Sources/*.swift -o "$TMP/DoroPet-$arch"
done
lipo -create "$TMP/DoroPet-arm64" "$TMP/DoroPet-x86_64" -output "$APP/Contents/MacOS/DoroPet"

echo "• 检查表情是否全部用上…"
python3 -I - "$ROOT" <<'PY'
import os, re, sys
root = sys.argv[1]
src = open(os.path.join(root, "Sources/Expressions.swift"), encoding="utf-8").read()
body = src[src.index("var faces"):src.index("var lines")]
used = set(re.findall(r'"([a-z_]+)"', body))
have = {f[:-4] for f in os.listdir(os.path.join(root, "Assets/daxiaojie/head")) if f.endswith(".png")}
if have - used or used - have:
    sys.exit(f"表情没对上：未使用 {sorted(have - used)}，缺文件 {sorted(used - have)}")
print(f"  {len(have)} 个表情全部用上")
PY

echo "• 拷贝大小姐素材…"
swiftc -O Tools/strip_outline.swift -o "$TMP/strip_outline" 2>/dev/null
"$TMP/strip_outline" "$ART/head" "$RES/head"      # remove the white sticker outline
cp "$ART/ATTRIBUTION.txt" "$RES/ATTRIBUTION.txt"

# Animated-figure sprite sheet (github.com/houn1u/claude-lady-pets-v2). It has no open license, so it
# lives only in the git-ignored Assets/claude-lady and is left out when EXCLUDE_LADY=1 (package.sh).
LADY="$ROOT/Assets/claude-lady/spritesheet-extended.png"
if [[ -f "$LADY" && "${EXCLUDE_LADY:-0}" != "1" ]]; then
  cp "$LADY" "$RES/lady-spritesheet.png"
  echo "  已包含可动小人素材（仅本机）"
fi

# v3 figure (github.com/lmy414/ai-chan-sheets, CC BY-NC-SA 4.0), made by ../Tools/make_v3_assets.py.
if [[ -f "$ROOT/Assets/v3/face_smile.png" ]]; then
  mkdir -p "$RES/v3"
  cp "$ROOT"/Assets/v3/*.png "$ROOT/Assets/v3/SOURCE.txt" "$RES/v3/"
  echo "  已包含 v3 小人素材"
fi

cp "$ROOT/Assets/banter.json" "$RES/banter.json"       # what the pets say (shared by all pets)

echo "• 生成图标…"
ICONSET="$TMP/AppIcon.iconset"
mkdir -p "$ICONSET"
SRC="$TMP/icon-square.png"
sips -p 1024 1024 "$ART/icon-starry.png" --out "$SRC" >/dev/null
for s in 16 32 128 256 512; do
  sips -z $s $s "$SRC" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$SRC" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$RES/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Claude大小姐</string>
  <key>CFBundleDisplayName</key><string>Claude大小姐</string>
  <key>CFBundleIdentifier</key><string>com.djh.doropet</string>
  <key>CFBundleExecutable</key><string>DoroPet</string>
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
VER="$(cat "$ROOT/VERSION" 2>/dev/null || echo 0.0.0)"
BUILD="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VER" -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
echo "✓ 完成：$APP"
