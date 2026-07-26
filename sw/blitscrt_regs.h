/* SPDX-License-Identifier: GPL-2.0-or-later */
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
/*
 * Whose timing the raster obeys. Clear at reset: the front-panel mode table
 * owns it, so a picture exists before any software runs. The daemon sets this
 * when a modeset lands and clears it when the host goes away, which makes the
 * mode table the way back from a mode the display cannot show.
 */
#define BLITSCRT_CTRL_HPS_TIMING (1u << 5)
#define BLITSCRT_CTRL_HDMI_EN    (1u << 4)

/* ---- status ---- */
#define BLITSCRT_REG_STATUS      0x000Cu   /* RO */
#define BLITSCRT_STAT_PLL_LOCKED (1u << 0)
#define BLITSCRT_STAT_HDMI_CFG   (1u << 1) /* ADV7513 acked its register table */
#define BLITSCRT_STAT_FIELD      (1u << 2)
#define BLITSCRT_STAT_VBLANK     (1u << 3)
#define BLITSCRT_STAT_APPLYING   (1u << 4) /* a modeset is pending vblank */
#define BLITSCRT_STAT_UNDERRUN   (1u << 5) /* the line fetcher has fallen behind */

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

/* ---- scanout memory ----
 *
 * Not a framebuffer. Damage rectangles are written straight into the region the
 * raster is already reading; nothing is presented and nothing is flipped, so
 * there is no swap register here. Double buffering would mean copying the
 * untouched remainder of the picture forward on every rect, which is the
 * full-frame cost the streamer model exists to avoid.
 */
#define BLITSCRT_REG_SCANOUT_BASE     0x0050u   /* byte address in DDR3 */
#define BLITSCRT_REG_SCANOUT_STRIDE   0x0054u   /* bytes per line */
#define BLITSCRT_REG_SCANOUT_FORMAT   0x0058u
#define BLITSCRT_FMT_RGB565      0u
#define BLITSCRT_FMT_RGB888      1u
#define BLITSCRT_FMT_XRGB8888    2u
#define BLITSCRT_FMT_RGB332      3u
#define BLITSCRT_REG_FRAME_COUNT 0x0060u   /* RO, increments per field */

/* ---- the rect write port ----
 *
 * Scanout memory is 76800 pixels and the bridge carries a 14-bit address, so it
 * cannot be mapped into the register window the way the character buffer is. It
 * is reached through an auto-incrementing pointer instead, which is the shape a
 * damage rectangle actually wants: seek to the start of a row, stream the run of
 * pixels in it, seek to the next row. Runs of consecutive pixels is all a rect
 * ever is.
 *
 * WDATA is deliberately 16 bits wide. The gp bridge issues a complete bus write
 * off a single low-half command, so a 16-bit register costs one command per
 * pixel where a 32-bit one costs two. On this transport that is the difference
 * between a full 320x240 repaint taking 77 ms and taking 150 ms.
 *
 * One pixel per word, whatever the format: the memory is 16 bits wide by
 * construction and scanout takes the format from SCANOUT_FORMAT. RGB332 sits in
 * the low byte and wastes half the wire, which is not worth a packing mode.
 *
 * WADDR reads back, so how many words actually landed is one register read away:
 * seek, stream n, and the pointer should have advanced by exactly n.
 */
#define BLITSCRT_REG_SCANOUT_WADDR  0x0070u  /* RW, pixel index of the next write */
#define BLITSCRT_REG_SCANOUT_WDATA  0x0074u  /* WO, one pixel word; pointer += 1 */

/*
 * (height << 16) | width -- the geometry of whatever memory is fitted. Resets to
 * the build's own parameters, so an on-chip build reports its M10K size and
 * needs no write. Writable because a DDR3 build has no compile-time size: the
 * host names a mode and software tells the fabric how big the picture is.
 *
 * Staged and latched on APPLY with the timing set, for the same reason -- a
 * geometry change landing mid-frame would tear.
 */
#define BLITSCRT_REG_SCANOUT_GEOM   0x0078u   /* RW; (height << 16) | width */

/*
 * RO. What this bitstream can actually do. Read it before anything else: a
 * build reports its own capabilities rather than the caller inferring them from
 * a version number, because the two scanout sources need entirely different
 * write paths and picking the wrong one fails silently -- rect writes to a DDR3
 * build go into a register that nothing is listening to.
 */
#define BLITSCRT_REG_CAPS           0x007Cu
#define BLITSCRT_CAP_SCANOUT_DDR3   (1u << 0) /* fabric reads HPS DDR3 over f2sdram */
#define BLITSCRT_CAP_RECT_PORT      (1u << 1) /* WADDR/WDATA reach on-chip memory */

/*
 * RO diagnostics for the line fetcher, so a wrong picture is one register read
 * rather than an inference from what is on screen.
 *
 *   [15:0]   beats moved for the last completed line. Zero means the fetcher
 *            never got data -- the f2sdram port, not the address arithmetic.
 *   [23:16]  underruns since reset, saturating. Non-zero means a line was
 *            asked for while the previous one was still in flight, so the
 *            raster showed a stale buffer.
 */
#define BLITSCRT_REG_SCANOUT_DIAG   0x0080u

/*
 * RO. The timing video_timing is actually being fed, after the ownership mux --
 * not what was staged, and not what the mode table would give. Those three can
 * disagree, and until now nothing could tell them apart: the staged registers
 * read back correctly while the raster ran on something else entirely.
 *
 * LIVE_MISC also carries the effective clock select, which is the one that
 * matters and the one with no other symptom. On Cyclone V, altclkctrl takes PLL
 * outputs only on slots 2 and 3; slots 0 and 1 are the 50 MHz reference pin, so
 * a select below 2 means the raster is not on a pixel clock at all.
 */
#define BLITSCRT_REG_LIVE_H1        0x0084u  /* (h_bp << 16) | h_sy  */
#define BLITSCRT_REG_LIVE_H2        0x0088u  /* (h_fp << 16) | h_act */
#define BLITSCRT_REG_LIVE_V1        0x008Cu  /* (v_bp << 16) | v_sy  */
#define BLITSCRT_REG_LIVE_V2        0x0090u  /* (v_fp << 16) | v_act */
#define BLITSCRT_REG_LIVE_MISC      0x0094u

/*
 * RO. What the register bus itself is doing, which nothing else could see.
 *
 *   [0]      the PLL reconfig slave is asserting waitrequest right now
 *   [1]      it has asserted it long enough for the bridge to give up, ever
 *   [2]      the bridge abandoned some access as stalled, ever (sticky)
 *   [15:8]   accesses into the 0x1000 aperture the slave has accepted
 *
 * A slave that never drops waitrequest wedges a transaction, and from the HPS
 * side that is indistinguishable from a slave answering zero: the same symptom
 * as a decode that does not reach it. Bit 0 tells the two apart in one read.
 */
#define BLITSCRT_REG_BUS_DIAG       0x0098u
#define BLITSCRT_BUS_PLL_WAIT       (1u << 0)
#define BLITSCRT_BUS_PLL_WAIT_SEEN  (1u << 1)
#define BLITSCRT_BUS_STALLED        (1u << 2)
#define BLITSCRT_BUS_PLL_ACCEPTS(v) (((v) >> 8) & 0xffu)
#define BLITSCRT_LIVE_INTERLACE     (1u << 0)
#define BLITSCRT_LIVE_HPS_TIMING    (1u << 1) /* the mux is on host timing */
#define BLITSCRT_LIVE_CLKSEL(v)     (((v) >> 2) & 3u)
#define BLITSCRT_DIAG_BEATS(v)      ((v) & 0xffffu)
#define BLITSCRT_DIAG_UNDERRUNS(v)  (((v) >> 16) & 0xffu)

/* Physical base of the DDR3 window the fabric scans out of. Reserved from Linux
 * by mem= in the boot arguments; see tools/blitsenv.txt. */
#define BLITSCRT_SCANOUT_DDR_BASE   0x3E000000u
#define BLITSCRT_SCANOUT_DDR_SIZE   0x02000000u   /* 32 MB */


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
 * 128 cols x 64 rows of 8-bit codes, addressed {row[5:0], col[6:0]}. The buffer
 * is byte-addressed and contiguous: char (row,col) lives at
 * BLITSCRT_CHARRAM_OFFSET + row*COLS + col, so the 8192 entries fill
 * 0x2000..0x3FFF exactly (one byte per address, NOT one byte per 32-bit word).
 * The overlay shows 16 rows at a time -- one bank per mode -- and the daemon
 * writes its live text into bank 0 (rows 0..15).
 */
#define BLITSCRT_CHARRAM_OFFSET    0x2000u
#define BLITSCRT_CHARRAM_COLS      128u
#define BLITSCRT_CHARRAM_ROWS      64u
#define BLITSCRT_CHARRAM_BANK_ROWS 16u      /* rows the overlay shows per mode bank */
#define BLITSCRT_CHAR_BLANK        0x20u    /* transparent, video shows through */
#define BLITSCRT_CHAR_BACKED       0x01u    /* opaque black, no glyph */

#endif
