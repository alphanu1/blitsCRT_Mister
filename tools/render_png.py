#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Turn the pixel dump from tb_render into a PNG."""
import sys
from PIL import Image

MODE = sys.argv[1] if len(sys.argv) > 1 else '640x240p60'
# Second argument names the pixel source, which is only the filename prefix --
# the dump is the same shape either way.
SRC = sys.argv[2] if len(sys.argv) > 2 else 'testcard'
# Third argument is the dump to read. Each render target writes its own, so a
# parallel build cannot have two testbenches sharing one file.
DUMP = sys.argv[3] if len(sys.argv) > 3 else 'rtl/render.txt'
W, H = (640, 480) if 'i60' in MODE else ((640, 240) if '240p' in MODE else (640, 480))

img = Image.new('RGB', (W, H))
px = img.load()
n = 0
for line in open(DUMP):
    x, y, r, g, b = map(int, line.split())
    if 0 <= x < W and 0 <= y < H:
        px[x, y] = (r * 255 // 63, g * 255 // 63, b * 255 // 63)
        n += 1

out = 'sim/%s_%s.png' % (SRC, MODE)
img.save(out)
img.resize((W * 2, H * 2), Image.NEAREST).save(out.replace('.png', '_x2.png'))
print("%s: %d of %d pixels" % (out, n, W * H))
