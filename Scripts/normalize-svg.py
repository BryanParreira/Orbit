#!/usr/bin/env python3
"""Rewrite SVG path data with explicit separators.

SVG allows arc flags to be packed ("a1 1 0 01.5.5"), but Apple's CoreSVG misreads
that form and drops the shape. Run on any logo added to the asset catalog:

    python3 Scripts/normalize-svg.py Orbit/Resources/Assets.xcassets/Logos/*/*.svg
"""
import re
import sys

NUMBER = re.compile(r"[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?")
ARGS = {"m": 2, "l": 2, "h": 1, "v": 1, "c": 6, "s": 4, "q": 4, "t": 2, "a": 7, "z": 0}


def normalize(d: str) -> str:
    out, i, cmd = [], 0, None
    count = 0  # parameters read for the current command repetition
    while i < len(d):
        ch = d[i]
        if ch in " ,\t\r\n":
            i += 1
            continue
        if ch.isalpha():
            cmd = ch
            out.append(ch)
            count = 0
            i += 1
            continue
        if cmd is None:
            raise ValueError(f"number before command at {i}")
        n = ARGS[cmd.lower()]
        index = count % n if n else 0
        if cmd.lower() == "a" and index in (3, 4):
            # large-arc and sweep flags are a single 0 or 1
            if ch not in "01":
                raise ValueError(f"bad arc flag {ch!r} at {i}")
            out.append(ch)
            i += 1
        else:
            m = NUMBER.match(d, i)
            if not m:
                raise ValueError(f"unexpected {ch!r} at {i}")
            out.append(m.group(0))
            i = m.end()
        count += 1
    return " ".join(out)


for path in sys.argv[1:]:
    svg = open(path, encoding="utf-8").read()
    fixed = re.sub(r'( d=")([^"]+)(")', lambda m: m.group(1) + normalize(m.group(2)) + m.group(3), svg)
    if fixed != svg:
        open(path, "w", encoding="utf-8").write(fixed)
        print(f"normalized {path}")
