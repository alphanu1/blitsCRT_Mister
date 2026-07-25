/* SPDX-License-Identifier: MIT */
/*
 * blitscrt_regs.h -- the contract between the fabric and the gadget daemon.
 *
 * An Avalon-MM slave hangs off the HPS lightweight bridge, which the ARM sees
 * at 0xFF200000. Every register is 32 bits.
 *
 * Timing registers are the same four-part decomposition the RTL is
 * parameterised with, so what the host asks for, what the fabric generates and
 * what the overlay reports cannot drift apart. Vertical values are PER FIELD;
 * an interlaced frame is 2*V_TOT+1 lines.
 *
 * Writing timing or PLL registers has no effect until PLL_APPLY is written.
 * The fabric latches the whole set on the next vblank, so a modeset never
 * tears or produces a partial frame at a half-applied timing.
 */

#ifndef BLITSCRT_REGS_H
#define BLITSCRT_REGS_H

#define BLITSCRT_LWBRIDGE_BASE   0xFF200000u
#define BLITSCRT_REG_SPAN        0x4000u   /* regs, PLL window, char buffer */

/* ---- identity ---- */
#define BLITSCRT_REG_ID          0x0000u   /* RO, 'B''C''R''T' */
#define BLITSCRT_ID_MAGIC        0x42435254u
#define BLITSCRT_REG_VERSION     0x0004u   /* RO, (major << 16) | minor */

/* ---- control ---- */
#define BLITSCRT_REG_CTRL        0x0008u   /* RW */
#define BLITSCRT_CTRL_ENABLE     (1u << 0) /* scanout running */
#define BLITSCRT_CTRL_TESTCARD   (1u << 1) /* show the card instead of the fb */
#define BLITSCRT_CTRL_OVERLAY    (1u << 2) /* composite the text overlay */
#define BLITSCRT_CTRL_CSYNC      (1u << 3) /* composite sync on the HS pin */
#define BLITSCRT_CTRL_HDMI_EN    (1u << 4)

/* ---- status ---- */
#define BLITSCRT_REG_STATUS      0x000Cu   /* RO */
#define BLITSCRT_STAT_PLL_LOCKED (1u << 0)
#define BLITSCRT_STAT_HDMI_CFG   (1u << 1) /* ADV7513 acked its register table */
#define BLITSCRT_STAT_FIELD      (1u << 2)
#define BLITSCRT_STAT_VBLANK     (1u << 3)
#define BLITSCRT_STAT_APPLYING   (1u << 4) /* a modeset is pending vblank */

/*
 * Heartbeat. The daemon bumps this register on a timer. The fabric watches it
 * in the video domain: if it stops changing for about a second, the HPS is
 * assumed down and the overlay falls back to the fabric's own baked banner.
 * This is what lets the screen tell "Linux not up" from "up, no USB host".
 */
#define BLITSCRT_REG_HEARTBEAT   0x0064u   /* WO, daemon writes an incrementing value */

/*
 * Host-status hint, written by the daemon so the fabric banner can reflect it
 * even though only the daemon knows the USB state.
 */
#define BLITSCRT_REG_HOSTSTATE   0x0068u   /* WO */
#define BLITSCRT_HOST_NONE       0u
#define BLITSCRT_HOST_ATTACHED   1u
#define BLITSCRT_HOST_STREAMING  2u

/* ---- timing, per field vertically ---- */
#define BLITSCRT_REG_H_SY        0x0010u
#define BLITSCRT_REG_H_BP        0x0014u
#define BLITSCRT_REG_H_ACT       0x0018u
#define BLITSCRT_REG_H_FP        0x001Cu
#define BLITSCRT_REG_V_SY        0x0020u
#define BLITSCRT_REG_V_BP        0x0024u
#define BLITSCRT_REG_V_ACT       0x0028u
#define BLITSCRT_REG_V_FP        0x002Cu

#define BLITSCRT_REG_MODE_FLAGS  0x0030u
#define BLITSCRT_MODE_INTERLACE  (1u << 0)
#define BLITSCRT_MODE_PHSYNC     (1u << 1) /* positive horizontal sync */
#define BLITSCRT_MODE_PVSYNC     (1u << 2)
#define BLITSCRT_MODE_DBLSCAN    (1u << 3)

/* ---- pixel clock ---- */
#define BLITSCRT_REG_PLL_M       0x0034u
#define BLITSCRT_REG_PLL_N       0x0038u
#define BLITSCRT_REG_PLL_C       0x003Cu
#define BLITSCRT_REG_PCLK_KHZ    0x0040u   /* informational, drives the overlay */
#define BLITSCRT_REG_APPLY       0x0044u   /* W1, latch timing+PLL on next vblank */

/* ---- framebuffer ---- */
#define BLITSCRT_REG_FB_BASE     0x0050u   /* byte address in SDRAM */
#define BLITSCRT_REG_FB_STRIDE   0x0054u   /* bytes per line */
#define BLITSCRT_REG_FB_FORMAT   0x0058u
#define BLITSCRT_FMT_RGB565      0u
#define BLITSCRT_FMT_RGB888      1u
#define BLITSCRT_FMT_XRGB8888    2u
#define BLITSCRT_FMT_RGB332      3u
#define BLITSCRT_REG_FB_FLIP     0x005Cu   /* W1, swap buffers on next vblank */
#define BLITSCRT_REG_FRAME_COUNT 0x0060u   /* RO, increments per field */

/* ---- PLL reconfiguration ---- */
/*
 * altera_pll_reconfig hangs off the same lightweight bridge. Writing the
 * counters here and then BLITSCRT_REG_APPLY reprograms the pixel clock, which
 * is what turns a validated arbitrary modeline into one the fabric can produce.
 */
#define BLITSCRT_PLLRECFG_OFFSET 0x1000u
#define BLITSCRT_PLLRECFG_SPAN   0x0040u

/* ---- overlay character buffer ---- */
/*
 * 128 cols x 64 rows of 8-bit codes, addressed {row[5:0], col[6:0]}.
 * One byte per 32-bit word, so the 8192 entries occupy 0x2000..0x3FFF.
 */
#define BLITSCRT_CHARRAM_OFFSET  0x2000u
#define BLITSCRT_CHARRAM_COLS    128u
#define BLITSCRT_CHARRAM_ROWS    64u
#define BLITSCRT_CHAR_BLANK      0x20u     /* transparent, video shows through */
#define BLITSCRT_CHAR_BACKED     0x01u     /* opaque black, no glyph */

#endif
