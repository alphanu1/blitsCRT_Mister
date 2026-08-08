/* SPDX-License-Identifier: GPL-2.0-or-later
 *
 * A rect wider than the scanout must crop, not shear.
 *
 * blitscrt_scanout_blit clips w to the scanout width, and used to stride the
 * source by the clipped value -- reading row 0's left half, then row 0's right
 * half as though it were row 1. A 640-wide framebuffer into a 320-wide raster
 * came out squeezed and vertically doubled rather than cropped, which is what
 * an X screen that has not followed a mode change routinely produces.
 *
 * This is the arithmetic on its own, without a fabric to write into.
 */
#include <stdio.h>
#include <string.h>
#include <stdint.h>
int main(void)
{
    printf("scanout blit clipping\n");
    /* source: 8 wide, 3 tall, value = row*100 + col */
    uint16_t src[8*3], dst[4*3];
    unsigned row, col, w = 8, h = 3, sc_w = 4, w_src, fails = 0;

    for (row = 0; row < 3; row++)
        for (col = 0; col < 8; col++) src[row*8+col] = row*100 + col;
    memset(dst, 0xff, sizeof dst);

    w_src = w;
    if (w > sc_w) w = sc_w;

    for (row = 0; row < h; row++)
        memcpy(&dst[row*sc_w], &src[row*w_src], w*sizeof *dst);

    for (row = 0; row < h; row++)
        for (col = 0; col < sc_w; col++)
            if (dst[row*sc_w+col] != row*100 + col) fails++;

    printf("  a rect wider than the scanout crops to the left edge   %s\n",
           fails ? "FAIL" : "ok");
    printf("        row 1 reads %u %u %u %u (want 100 101 102 103)\n",
           dst[4], dst[5], dst[6], dst[7]);
    printf("\n%s\n", fails ? "FAIL" : "PASS");
    return fails ? 1 : 0;
}
