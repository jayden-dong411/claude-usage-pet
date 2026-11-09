"""Turns a generated v3 portrait (white or transparent background) into a pet expression image:
transparent background, height 440, width ≤ 484 (with a 6 px clear margin on each side), bottom 14 % faded.

    python3 Tools/finish_v3_face.py <generated.png> <out.png>

Background removal floods near-white from the top and the sides. Below the shoulders only pure, untinted white
counts as background, so white clothes (Claude娘's blouse, GPT娘's dress) are not eaten. A generation that already
has a transparent background is used as it is.
"""
import sys
from collections import deque

import numpy as np
from PIL import Image

H, MAXW, MARGIN = 440, 484, 6


def cut_white(img: Image.Image, split=0.58) -> Image.Image:
    a = np.asarray(img.convert("RGB")).astype(np.int16)
    h, w, _ = a.shape
    mn, mx = a.min(axis=2), a.max(axis=2)
    rows = np.arange(h)[:, None]
    cand = np.where(rows < h * split, (mn >= 246) & (mx - mn <= 8), (mn >= 251) & (mx - mn <= 3))
    bg = np.zeros((h, w), bool)
    q = deque()
    for x in range(w):
        if cand[0, x]:
            bg[0, x] = True; q.append((0, x))
    for y in range(h):
        for x in (0, w - 1):
            if cand[y, x] and not bg[y, x]:
                bg[y, x] = True; q.append((y, x))
    while q:
        y, x = q.popleft()
        for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            ny, nx = y + dy, x + dx
            if 0 <= ny < h and 0 <= nx < w and cand[ny, nx] and not bg[ny, nx]:
                bg[ny, nx] = True; q.append((ny, nx))
    alpha = np.where(bg, 0, 255).astype(np.uint8)
    edge = np.zeros_like(bg)
    edge[1:, :] |= bg[:-1, :]; edge[:-1, :] |= bg[1:, :]; edge[:, 1:] |= bg[:, :-1]; edge[:, :-1] |= bg[:, 1:]
    edge &= ~bg
    soft = np.clip((255 - mn) * 255 // 55, 0, 255).astype(np.uint8)
    alpha = np.where(edge, np.minimum(alpha, np.maximum(soft, 90)), alpha)
    return Image.fromarray(np.dstack([a.astype(np.uint8), alpha]), "RGBA")


def finish(path_in: str, path_out: str) -> Image.Image:
    im = Image.open(path_in)
    if im.mode == "RGBA" and np.asarray(im)[:, :, 3].min() < 250:
        rgba = im.convert("RGBA")
    else:
        rgba = cut_white(im)
    rgba = rgba.crop(rgba.getbbox())
    s = min(H / rgba.height, (MAXW - 2 * MARGIN) / rgba.width)      # too wide: scale down, never clip her hair
    rgba = rgba.resize((round(rgba.width * s), round(rgba.height * s)), Image.LANCZOS)
    out = Image.new("RGBA", (rgba.width + 2 * MARGIN, H), (0, 0, 0, 0))
    out.alpha_composite(rgba, (MARGIN, H - rgba.height))             # bottom-aligned like the others
    px = np.asarray(out).copy()
    fade = int(H * 0.14)
    px[-fade:, :, 3] = (px[-fade:, :, 3] * np.linspace(1, 0, fade)[:, None]).astype(np.uint8)
    res = Image.fromarray(px, "RGBA")
    res.save(path_out, optimize=True)
    return res


if __name__ == "__main__":
    finish(sys.argv[1], sys.argv[2])
