#!/bin/zsh
# Copies the 80 outline-stripped Claude大小姐 stickers, the v3 expressions and the icon into windows/assets.
# Uses the same tool as the macOS build (Tools/strip_outline.swift), so run it on a Mac.
set -euo pipefail
cd "$(dirname "$0")"
ROOT=".."
TMP="$(mktemp -d)"
swiftc -O "$ROOT/Tools/strip_outline.swift" -o "$TMP/strip_outline" 2>/dev/null
rm -rf assets/head && mkdir -p assets build-res
"$TMP/strip_outline" "$ROOT/Assets/daxiaojie/head" assets/head
cp "$ROOT/Assets/daxiaojie/ATTRIBUTION.txt" assets/ATTRIBUTION.txt
rm -rf assets/v3 && mkdir -p assets/v3 && cp "$ROOT"/Assets/v3/face_*.png "$ROOT/Assets/v3/SOURCE.txt" assets/v3/   # v3 look
sips -p 1024 1024 "$ROOT/Assets/daxiaojie/icon-starry.png" --out "$TMP/icon-square.png" >/dev/null
sips -z 512 512 "$TMP/icon-square.png" --out build-res/icon.png >/dev/null
sips -z 256 256 "$TMP/icon-square.png" --out assets/icon.png >/dev/null
cp "$ROOT/Assets/banter.json" assets/banter.json            # what the pets say (same file as the Mac apps)
# GPT龙娘 (GPTDragonPet, main-gpt.js): her v3 expressions and an icon cut from the smiling face.
rm -rf assets/gpt-v3 && mkdir -p assets/gpt-v3 && cp "$ROOT"/companions/ChatGPTPet/Assets/v3/face_*.png "$ROOT/companions/ChatGPTPet/Assets/v3/SOURCE.txt" assets/gpt-v3/
python3 - "$ROOT/companions/ChatGPTPet/Assets/v3/face_smile.png" <<'PY'
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert("RGBA")
bb = im.getbbox(); w = bb[2] - bb[0]
side = int(w * 0.92); cx = (bb[0] + bb[2]) // 2
box = (cx - side // 2, bb[1], cx - side // 2 + side, bb[1] + side)   # head and shoulders
sq = Image.new("RGBA", (side, side), (0, 0, 0, 0)); sq.paste(im.crop(box), (0, 0))
sq.resize((512, 512), Image.LANCZOS).save("build-res/gpt-icon.png")
sq.resize((256, 256), Image.LANCZOS).save("assets/gpt-icon.png")
PY
rm -rf "$TMP"
echo "✓ assets ready: $(ls assets/head | wc -l | tr -d ' ') faces"
