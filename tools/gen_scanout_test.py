#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Generate the scanout memory preload pattern -- rtl/scanout_init.hex.

It is what scanout memory holds before anything is written into it, which exists
to be told apart from the test card at a glance and to make an address or stride
mistake obvious rather than merely wrong:

  2D gradient        red rises with x, blue with y. Any scrambling of the
                     address shows as banding or blocks in a smooth field.
  diagonal           a stride that is off by even one pixel skews a straight
                     diagonal into an obvious lean.
  32-pixel grid      geometry and scaling. Under hdouble the squares stay
                     square only if the doubling is right.
  corner patches     red / green / blue / white, clockwise from top left, so a
                     flip or a rotation is unmistakable.
  border             one pixel, white. Off-by-one at the edges.
  horizontal comb    alternating SINGLE rows. This is the interlace test.
                     With 480 distinct lines in memory the raster interleaves
                     them across fields and the comb resolves as fine lines
                     that flicker at field rate. Were the lines doubled
                     instead, both fields would carry the same content and the
                     comb would sit there as steady two-line bars.
  vertical comb      alternating SINGLE columns. With horizontal doubling on,
                     one source column becomes two raster pixels, so the comb
                     should read as even two-pixel stripes. Uneven stripes mean
                     the doubling drops or repeats a pixel.

Usage:
    python3 tools/gen_scanout_test.py rtl/scanout_init.hex [WxH] [rgb565|rgb332]

Geometry must match SCANOUT_W/SCANOUT_H on blitscrt_top.
"""
import sys

out_path = sys.argv[1] if len(sys.argv) > 1 else 'rtl/scanout_init.hex'
geom = sys.argv[2] if len(sys.argv) > 2 else '320x480'
fmt = sys.argv[3] if len(sys.argv) > 3 else 'rgb565'

W, H = (int(v) for v in geom.lower().split('x'))

GRID = 32
PATCH = 24
COMB_H = 24          # rows in the horizontal comb band
COMB_V = 48          # side of the vertical comb block


def pack(r, g, b):
    """8-bit-per-channel colour into the target format."""
    if fmt == 'rgb332':
        return (r >> 5) << 5 | (g >> 5) << 2 | (b >> 6), 2
    return (r >> 3) << 11 | (g >> 2) << 5 | (b >> 3), 4


def colour(x, y):
    # border
    if x == 0 or y == 0 or x == W - 1 or y == H - 1:
        return 255, 255, 255

    # corner patches, clockwise from top left
    if x < PATCH and y < PATCH:
        return 255, 0, 0
    if x >= W - PATCH and y < PATCH:
        return 0, 255, 0
    if x >= W - PATCH and y >= H - PATCH:
        return 0, 0, 255
    if x < PATCH and y >= H - PATCH:
        return 255, 255, 255

    # horizontal comb: alternating single rows. The interlace test.
    hb = H * 2 // 8
    if hb <= y < hb + COMB_H and PATCH + 8 <= x < W - PATCH - 8:
        return (255, 255, 255) if y & 1 else (0, 0, 0)

    # vertical comb: alternating single columns. The doubling test.
    vb, vx = H * 5 // 8, W // 2 - COMB_V // 2
    if vb <= y < vb + COMB_V and vx <= x < vx + COMB_V:
        return (255, 255, 255) if x & 1 else (0, 0, 0)

    # diagonal, scaled so it crosses the whole buffer
    if abs(x * H - y * W) < max(W, H):
        return 255, 255, 0

    # grid
    if x % GRID == 0 or y % GRID == 0:
        return 0, 255, 255

    # gradient
    return x * 255 // (W - 1), 0, y * 255 // (H - 1)


with open(out_path, 'w') as f:
    for y in range(H):
        for x in range(W):
            v, digits = pack(*colour(x, y))
            f.write('%0*X\n' % (digits, v))

print('%s: %dx%d %s, %d words' % (out_path, W, H, fmt, W * H))
