#!/usr/bin/env python3
"""Cuts the 8 expression portraits (the "v3" pet look) out of one character's ai-chan-sheets
slices (github.com/lmy414/ai-chan-sheets, CC BY-NC-SA 4.0) and removes their white background.

usage: make_v3_assets.py <repo>/设定图/<NN_角色> <out dir>
"""
import json, sys
from collections import deque
from pathlib import Path
import numpy as np
from PIL import Image

Image.MAX_IMAGE_PIXELS = None
SECTION_TOP_MARGIN, CELL_X_MARGIN = 30, 40          # same as the repo's make_native_slices.py
FACES = {"自然微笑": "smile", "平静": "calm", "惊讶": "surprised", "害羞": "shy",
         "鼓腮": "pout", "闭眼轻笑": "giggle", "认真": "serious", "委屈": "aggrieved"}
# Background: near-white, low-saturation pixels connected to the border. Pale characters (the white
# dragon) need a stricter cut: make_v3_assets.py <dir> <out> 253 3
THR, SPREAD = 246, 8


def regions(idx):
    W, H = idx["board_dimensions"]
    secs = sorted(idx["sections"], key=lambda s: s["y"])
    ys = [s["y"] for s in secs] + [H]
    for i, s in enumerate(secs):
        top = max(0, ys[i] - SECTION_TOP_MARGIN)
        ps = [p for p in idx["placements"] if p["group"] == s["group"]]
        x0 = max(0, min(p["cell"][0] for p in ps) - CELL_X_MARGIN)
        yield s["group"], x0, top, ps


def cut_background(img: Image.Image, thr=236, spread=14) -> Image.Image:
    """Flood-fills near-white, low-saturation pixels from the border; softens the edge."""
    a = np.asarray(img.convert("RGB")).astype(np.int16)
    h, w, _ = a.shape
    mn, mx = a.min(axis=2), a.max(axis=2)
    cand = (mn >= thr) & (mx - mn <= spread)
    bg = np.zeros((h, w), bool)
    q = deque()
    # Seed from the top and the sides only: a portrait is cut off at the bottom edge, where the
    # (often white) clothes touch the border and must not be taken for background.
    for x in range(w):
        for y in (0,):
            if cand[y, x] and not bg[y, x]: bg[y, x] = True; q.append((y, x))
    for y in range(int(h * 0.75)):
        for x in (0, w - 1):
            if cand[y, x] and not bg[y, x]: bg[y, x] = True; q.append((y, x))
    while q:
        y, x = q.popleft()
        for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            ny, nx = y + dy, x + dx
            if 0 <= ny < h and 0 <= nx < w and cand[ny, nx] and not bg[ny, nx]:
                bg[ny, nx] = True; q.append((ny, nx))
    alpha = np.where(bg, 0, 255).astype(np.uint8)
    # Edge pixels next to the background get partial alpha by how white they are.
    edge = np.zeros_like(bg)
    edge[1:, :] |= bg[:-1, :]; edge[:-1, :] |= bg[1:, :]; edge[:, 1:] |= bg[:, :-1]; edge[:, :-1] |= bg[:, 1:]
    edge &= ~bg
    soft = np.clip((255 - mn) * 255 // max(1, 255 - 200), 0, 255).astype(np.uint8)
    alpha = np.where(edge, np.minimum(alpha, np.maximum(soft, 90)), alpha)
    rgba = np.dstack([a.astype(np.uint8), alpha])
    out = Image.fromarray(rgba, "RGBA")
    return out.crop(out.getbbox())


def fade_sides(px: np.ndarray, share=0.14) -> np.ndarray:
    """Fades the outer `share` of the width on both sides to transparent (smoothstep), so hair or sleeves
    that run off the crop don't end in a hard vertical edge."""
    w = px.shape[1]
    n = max(1, int(w * share))
    t = np.linspace(0, 1, n)
    ramp = t * t * (3 - 2 * t)
    a = px[:, :, 3].astype(np.float32)
    a[:, :n] *= ramp[None, :]
    a[:, -n:] *= ramp[::-1][None, :]
    px[:, :, 3] = a.astype(np.uint8)
    return px


def main(char_dir: Path, out: Path):
    idx = json.loads((char_dir / "拼接布局与素材索引.json").read_text())
    out.mkdir(parents=True, exist_ok=True)
    slices = {p.name.split("_")[1]: p for p in (char_dir / "原图切片").glob("*.png")}
    made = []
    for group, x0, top, ps in regions(idx):
        key = group.split("_")[0]
        if key != "02":
            continue
        sheet = Image.open(slices[key]).convert("RGB")
        for p in ps:
            label = p["id"].split("_")[-1].split("v0")[0].rstrip("_")
            box = (p["x"] - x0, p["y"] - top, p["x"] - x0 + p["width"], p["y"] - top + p["height"])
            img = sheet.crop(box)
            if key != "02":
                continue
            name = next((v for k, v in FACES.items() if k in p["id"]), None)
            if not name: continue
            bust = cut_background(img, thr=THR, spread=SPREAD)
            bust.thumbnail((10_000, 440), Image.LANCZOS)
            # Soften the hard cut at the chest: fade the bottom 14 % out.
            px = np.asarray(bust).copy()
            fade = int(px.shape[0] * 0.14)
            ramp = np.linspace(1, 0, fade)[:, None]
            px[-fade:, :, 3] = (px[-fade:, :, 3] * ramp).astype(np.uint8)
            px = fade_sides(px)          # …and the left and right edges, where hair runs off the crop
            bust = Image.fromarray(px, "RGBA")
            bust.save(out / f"face_{name}.png", optimize=True)
            made.append(name)
    (out / "SOURCE.txt").write_text(
        f"{idx['character']} — v3 figure cut from github.com/lmy414/ai-chan-sheets ({char_dir.name}).\n"
        "Character design: ZipZipPipe (space.bilibili.com/4168597). Sheets: lmy414, CC BY-NC-SA 4.0.\n"
        "Background removed and resized for a desktop pet. Non-commercial use only.\n")
    print(char_dir.name, sorted(made))


if __name__ == "__main__":
    # `make_v3_assets.py --fade-sides <dir>`: soften the side edges of already-made face_*.png (run once).
    if sys.argv[1] == "--fade-sides":
        for f in sorted(Path(sys.argv[2]).glob("face_*.png")):
            Image.fromarray(fade_sides(np.asarray(Image.open(f).convert("RGBA")).copy()), "RGBA").save(f, optimize=True)
            print("faded", f)
        sys.exit(0)
    if len(sys.argv) > 4:
        THR, SPREAD = int(sys.argv[3]), int(sys.argv[4])
    main(Path(sys.argv[1]), Path(sys.argv[2]))
