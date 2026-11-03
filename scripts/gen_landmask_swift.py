#!/usr/bin/env python3
"""Embed a packed 720x360 land bitmap (see topophany scripts/gen_landmask.py) as Swift.

Usage: python3 scripts/gen_landmask_swift.py land.bin Sources/SonataCore/LandMaskData.swift
"""
import base64, sys

src, dst = sys.argv[1], sys.argv[2]
s = base64.b64encode(open(src, 'rb').read()).decode()
assert len(base64.b64decode(s)) == 720 * 360 // 8
lines = [s[i:i + 120] for i in range(0, len(s), 120)]
open(dst, 'w').write(
    "// Generated from topophany's internal/tui/land.bin (MIT, github.com/WhitenWhiten/topophany),\n"
    "// itself rasterized from Natural Earth 1:110m land polygons (public domain).\n"
    "// 720x360 cells, 0.5 degree each, row 0 = 90N, column 0 = 180W, MSB first.\n"
    "// Regenerate with scripts/gen_landmask_swift.py.\n\n"
    'let landMaskBase64 = """\n' + "\n".join(lines) + '\n"""\n')
