#!/usr/bin/env python3
"""Turn the pixel dump from tb_render into a PNG."""
import sys
from PIL import Image

MODE = sys.argv[1] if len(sys.argv) > 1 else '640x240p60'
W, H = (640, 480) if 'i60' in MODE else ((640, 240) if '240p' in MODE else (640, 480))

img = Image.new('RGB', (W, H))
px = img.load()
n = 0
for line in open('rtl/render.txt'):
    x, y, r, g, b = map(int, line.split())
    if 0 <= x < W and 0 <= y < H:
        px[x, y] = (r * 255 // 63, g * 255 // 63, b * 255 // 63)
        n += 1

out = 'sim/testcard_%s.png' % MODE
img.save(out)
img.resize((W * 2, H * 2), Image.NEAREST).save(out.replace('.png', '_x2.png'))
print("%s: %d of %d pixels" % (out, n, W * H))
