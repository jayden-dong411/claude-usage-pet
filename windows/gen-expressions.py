#!/usr/bin/env python3
"""Regenerates lib/expressions.js from ../Sources/Expressions.swift (face pools and lines per mood)."""
import json, re
from pathlib import Path

src = (Path(__file__).parent / "../Sources/Expressions.swift").read_text(encoding="utf-8")
faces_part = src[src.index("var faces"):src.index("var lines")]
lines_part = src[src.index("var lines"):src.index("static var allFaces")]

def cases(part):
    out = {}
    for m in re.finditer(r"case ((?:\.\w+(?:,\s*)?)+):\s*return\s*\[(.*?)\]", part, re.S):
        names = re.findall(r"\.(\w+)", m.group(1))
        items = re.findall(r'"([^"]*)"', m.group(2))
        for n in names:
            out[n] = items
    return out

data = {"faces": cases(faces_part), "lines": cases(lines_part)}
js = "// Generated from ../Sources/Expressions.swift by gen-expressions.py — the 80 Claude大小姐 head stickers grouped by situation.\nmodule.exports = " + json.dumps(data, ensure_ascii=False, indent=1) + ";\n"
(Path(__file__).parent / "lib/expressions.js").write_text(js, encoding="utf-8")
print({k: len(v) for k, v in data["faces"].items()})
