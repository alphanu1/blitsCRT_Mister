/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * blitscrt-peek -- read and write fabric registers over the same gp transport
 * the daemon uses, for bring-up. The heartbeat register (0x64) is writable and
 * reads back, so `-w 0x64 <value>` verifies the write path end to end: if a
 * 32-bit value reads back intact, writes work (and any lingering "NO HPS YET" is
 * the watchdog RTL, not the write); if it reads back shifted or truncated, the
 * bridge's 16-bit-half write assembly is the culprit.
 *
 * Kill blitscrtd first -- two masters on gp_out race and corrupt each other.
 *
 * Useful offsets (see sw/blitscrt_regs.h):
 *   0x00 ID "BCRT"   0x04 VERSION   0x0C STATUS   0x64 HEARTBEAT   0x68 HOSTSTATE
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <time.h>
#include "blitscrt_regs.h"
#include "fabric.h"
#include "modes.h"

static void usage(const char *p)
{
	fprintf(stderr,
		"usage: %s <off> [off ...]     read one or more registers\n"
		"       %s -w <off> <val>      write a register, then read it back\n"
		"       %s -b [off]            beat a register (default 0x64) for ~5s\n"
		"       %s -g                   report scanout source, geometry, fetch state\n"
		"       %s -t                   report the timing the raster is really running\n"
		"       %s -i                   I/O board buttons and LEDs, live and sticky\n"
		"       %s -p                   dump the PLL reconfig window\n"
		"       %s -R [ms] [pre]        reconfig by hand; 'pre' first does the register\n"
		"                              writes set_mode makes before it\n"
		"       %s -m <clk_khz> <hd> <hss> <hse> <ht> <vd> <vss> <vse> <vt> [i]\n"
		"                              apply a modeline; PAL: -m 12500 640 668 732 800 576 580 586 625 i\n"
		"       %s -c <w> <h>           configure geometry (and map DDR3 window)\n"
		"       %s -f <x> <y> <w> <h> <rgb565>\n"
		"                              fill a rect in scanout memory, timed\n"
		"offsets and values are hex (0x64) or decimal. Kill blitscrtd first.\n",
		p, p, p, p, p, p, p, p, p, p, p);
}

static uint32_t parse(const char *s) { return (uint32_t)strtoul(s, NULL, 0); }

int main(int argc, char **argv)
{
	struct blitscrt_fabric *f;
	int i;

	if (argc < 2) { usage(argv[0]); return 2; }

	/*
	 * Check the option before opening the fabric.
	 *
	 * strtoul("-i") is 0 with no error, so an unrecognised option used to
	 * fall through to the register read and print the magic at 0x0000 -- a
	 * plausible-looking answer to a question nobody asked, and how a stale
	 * binary on the card passed for a working one. Doing it here rather than
	 * at the end of the chain also means the message is about the option
	 * rather than about there being no fabric.
	 */
	if (argv[1][0] == '-' && !strchr("wbgtipRmcf", argv[1][1])) {
		fprintf(stderr, "%s: unknown option '%s'\n\n", argv[0], argv[1]);
		usage(argv[0]);
		return 2;
	}

	/* We own gp_out on this board, so gp access is safe; the transport gates it
	 * behind this, so set it here rather than making the caller prefix it. */
	setenv("BLITSCRT_GP_UNSAFE", "1", 1);

	f = blitscrt_fabric_open();
	if (!f) {
		fprintf(stderr, "blitscrt-peek: no fabric -- BCRT id did not read "
				"(is the blitsCRT core loaded?)\n");
		return 1;
	}

	if (!strcmp(argv[1], "-w")) {
		uint32_t off, val, back;
		if (argc != 4) { usage(argv[0]); blitscrt_fabric_close(f); return 2; }
		off = parse(argv[2]);
		val = parse(argv[3]);
		blitscrt_fabric_write(f, off, val);
		back = blitscrt_fabric_read(f, off);
		printf("[0x%04x] wrote 0x%08x, read back 0x%08x  %s\n",
		       off, val, back,
		       back == val ? "OK" : "MISMATCH");
	} else if (!strcmp(argv[1], "-b")) {
		/* Beat a register (default 0x64, the heartbeat) with an incrementing
		 * value for ~5 s. If the fabric watchdog works, hps_alive goes high
		 * partway in and the overlay leaves the bank-3 "NO HPS" banner --
		 * proving the watchdog independently of the daemon. */
		uint32_t off = (argc >= 3) ? parse(argv[2]) : 0x64u;
		int i;
		printf("beating [0x%04x] 1..25 over ~5s -- watch the screen leave "
		       "the NO HPS banner\n", off);
		for (i = 1; i <= 25; i++) {
			blitscrt_fabric_write(f, off, (uint32_t)i);
			usleep(200000);
		}
		printf("done; hps_alive goes stale ~1.5s after the beats stop\n");
	} else if (!strcmp(argv[1], "-g")) {
		unsigned w, h;
		uint32_t caps = blitscrt_fabric_caps(f);
		uint32_t diag = blitscrt_fabric_read(f, BLITSCRT_REG_SCANOUT_DIAG);

		if (caps & BLITSCRT_CAP_SCANOUT_DDR3)
			printf("scanout source  HPS DDR3 over f2sdram, window 0x%08x\n",
			       BLITSCRT_SCANOUT_DDR_BASE);
		else if (caps & BLITSCRT_CAP_RECT_PORT)
			printf("scanout source  on-chip M10K, rect port over gp\n");
		else
			printf("scanout source  not reported -- bitstream older than 3.1\n");

		if (blitscrt_scanout_geom(f, &w, &h) < 0)
			printf("geometry        unavailable\n");
		else
			printf("geometry        %ux%u, %u pixels\n", w, h, w * h);

		if (caps & BLITSCRT_CAP_SCANOUT_DDR3) {
			printf("last line       %u beats\n", BLITSCRT_DIAG_BEATS(diag));
			printf("underruns       %u%s\n",
			       BLITSCRT_DIAG_UNDERRUNS(diag),
			       BLITSCRT_DIAG_UNDERRUNS(diag) == 255 ? " (saturated)" : "");
			if (BLITSCRT_DIAG_BEATS(diag) == 0)
				printf("  zero beats: the f2sdram port is not answering.\n"
				       "  Check FPGAPORTRST (devmem 0xFFC25080) before\n"
				       "  suspecting the address arithmetic.\n");
		}
	} else if (!strcmp(argv[1], "-t")) {
		/*
		 * What video_timing is actually being fed. The staged registers can
		 * read back perfectly while the raster runs on something else --
		 * which is exactly how a clock select pointing at the 50 MHz
		 * reference pin went unnoticed until a monitor refused to sync.
		 */
		struct blitscrt_live lv;
		if (blitscrt_fabric_live(f, &lv) < 0) {
			printf("live timing unavailable -- fabric older than 3.4\n");
		} else {
			printf("owner      %s\n", lv.hps_timing
			       ? "host (CTRL bit 5)" : "front-panel mode table");
			printf("H          %u / %u / %u / %u   total %u\n",
			       lv.h_sy, lv.h_bp, lv.h_act, lv.h_fp, lv.h_total);
			printf("V          %u / %u / %u / %u   total %u%s\n",
			       lv.v_sy, lv.v_bp, lv.v_act, lv.v_fp, lv.v_total,
			       lv.interlace ? " per field" : "");
			printf("clk_sel    %u -> %.4f MHz%s\n", lv.clk_sel,
			       lv.pclk_hz / 1e6,
			       lv.clk_sel < 2
			         ? "  *** reference pin, not a pixel clock ***" : "");
			printf("derived    %.3f kHz line, %.2f Hz %s\n",
			       lv.line_hz / 1e3, lv.field_hz,
			       lv.interlace ? "field" : "frame");
			{
				unsigned w = 0, h = 0;
				blitscrt_scanout_geom(f, &w, &h);
				printf("scanout    %ux%u%s\n", w, h,
				       (h && lv.v_act &&
				        h != lv.v_act * (lv.interlace ? 2u : 1u))
				         ? "   *** does not match the raster ***" : "");
			}
		}
	} else if (!strcmp(argv[1], "-i")) {
		/*
		 * The I/O board pins. Everything is active low, so a pressed
		 * button and a lit LED both read as 0 at the pin -- printed here
		 * as "pressed" and "lit" so the inversion does not have to be
		 * held in the head.
		 */
		uint32_t v = blitscrt_fabric_read(f, BLITSCRT_REG_IO_DIAG);
		unsigned btn  =  v        & 7;
		unsigned seen = (v >> BLITSCRT_IO_SEEN_SHIFT) & 7;
		unsigned led  = (v >> BLITSCRT_IO_LED_SHIFT)  & 7;
		static const char *bn[3] = { "USER", "OSD ", "RESET" };
		static const char *ln[3] = { "USER", "HDD ", "POWER" };
		int i;

		printf("IO_DIAG = 0x%08x\n", v);
		printf("  buttons   now        since last read\n");
		for (i = 0; i < 3; i++)
			printf("    %-6s  %-9s  %s\n", bn[i],
			       (btn  >> i) & 1 ? "-" : "pressed",
			       (seen >> i) & 1 ? "pressed" : "-");
		printf("  LEDs being driven\n");
		for (i = 0; i < 3; i++)
			printf("    %-6s  %s\n", ln[i],
			       (led >> i) & 1 ? "off" : "lit");
		printf("\n  All active low. A button reads 0 while held; an LED\n"
		       "  lights when the fabric pulls its pin to ground.\n");

	} else if (!strcmp(argv[1], "-p")) {
		/* The reconfig block's own registers, read through the 0x1000
		 * aperture. All zeroes means the aperture is not reaching the
		 * block at all, which is a decode question rather than a PLL
		 * one -- and the two look identical from set_mode. */
		static const char *nm[8] = { "MODE", "STATUS", "START", "N",
					     "M", "C", "PHASE", "K" };
		int k;
		uint32_t bd = blitscrt_fabric_read(f, BLITSCRT_REG_BUS_DIAG);
		printf("pll lock   reconfig_from_pll[16] = %d%s\n",
		       (bd & BLITSCRT_BUS_PLL_LOCKED) ? 1 : 0,
		       (bd & BLITSCRT_BUS_PLL_LOCKED) ? ""
		         : "   *** the core gates everything on this ***");
		printf("writes     START=%u  N/M/C=%u%s\n",
		       BLITSCRT_BUS_PLL_STARTS(bd), BLITSCRT_BUS_PLL_CNTS(bd),
		       (BLITSCRT_BUS_PLL_STARTS(bd) &&
		        BLITSCRT_BUS_PLL_CNTS(bd) < 3)
		         ? "   *** START with fewer than three counter writes:"
		           " usr_valid_changes would be false ***" : "");
		printf("bus        waitrequest now=%d ever=%d  stalled=%d  "
		       "aperture accepts=%u\n",
		       (bd & BLITSCRT_BUS_PLL_WAIT) ? 1 : 0,
		       (bd & BLITSCRT_BUS_PLL_WAIT_SEEN) ? 1 : 0,
		       (bd & BLITSCRT_BUS_STALLED) ? 1 : 0,
		       BLITSCRT_BUS_PLL_ACCEPTS(bd));
		if (bd & BLITSCRT_BUS_PLL_WAIT)
			printf("  the reconfig slave is holding waitrequest: it never\n"
			       "  accepts, so reads return stale data and writes are\n"
			       "  dropped. Not a decode fault -- the slave is stalled.\n");
		else if (BLITSCRT_BUS_PLL_ACCEPTS(bd) == 0)
			printf("  no aperture access has ever been accepted: the decode\n"
			       "  is not reaching the slave at all.\n");
		printf("PLL reconfig window at 0x%04x\n", BLITSCRT_PLLRECFG_OFFSET);
		for (k = 0; k < 8; k++) {
			uint32_t v = blitscrt_fabric_read(f,
					BLITSCRT_PLLRECFG_OFFSET + k * 4);
			printf("  [0x%04x] %-6s = 0x%08x%s\n",
			       BLITSCRT_PLLRECFG_OFFSET + k * 4, nm[k], v,
			       k == 1 ? ((v & 1) ? "   busy" :
					 (v & 2) ? "   locked" : "   idle, not locked")
				      : "");
		}
	} else if (!strcmp(argv[1], "-R")) {
		/*
		 * The reconfiguration sequence by hand, in one process, with a
		 * chosen wait before a single STATUS read.
		 *
		 * Driven as separate peek invocations -- seconds apart, one read
		 * each -- this sequence completes every time. Driven from
		 * set_mode, which polls hard starting microseconds after START,
		 * it never does. The writes are identical, so the difference is
		 * either how soon the first read happens or how many reads there
		 * are. This isolates that: -R 500 waits half a second and reads
		 * once, which is what the working case does.
		 */
		unsigned wait_ms = (argc > 2) ? parse(argv[2]) : 500;
		int pre = (argc > 3);        /* any third argument: do the
					      * register writes set_mode makes
					      * before the reconfiguration */
		uint32_t st;

		if (pre) {
			/* Exactly what blitscrt_fabric_set_mode() writes before
			 * calling the reconfiguration. All register-file, none
			 * of it near the 0x1000 aperture -- but it is the only
			 * thing that path does and this one does not. */
			blitscrt_fabric_write(f, BLITSCRT_REG_H_SY,  64);
			blitscrt_fabric_write(f, BLITSCRT_REG_H_BP,  68);
			blitscrt_fabric_write(f, BLITSCRT_REG_H_ACT, 640);
			blitscrt_fabric_write(f, BLITSCRT_REG_H_FP,  28);
			blitscrt_fabric_write(f, BLITSCRT_REG_V_SY,  3);
			blitscrt_fabric_write(f, BLITSCRT_REG_V_BP,  19);
			blitscrt_fabric_write(f, BLITSCRT_REG_V_ACT, 288);
			blitscrt_fabric_write(f, BLITSCRT_REG_V_FP,  2);
			blitscrt_fabric_write(f, BLITSCRT_REG_MODE_FLAGS, 1);
			blitscrt_fabric_write(f, BLITSCRT_REG_PLL_M, 16);
			blitscrt_fabric_write(f, BLITSCRT_REG_PLL_N, 1);
			blitscrt_fabric_write(f, BLITSCRT_REG_PLL_C, 64);
			printf("(did the 12 register writes set_mode makes first)\n");
		}

		printf("MODE=1, N, M, C, START, wait %u ms, one STATUS read\n",
		       wait_ms);
		blitscrt_fabric_write(f, 0x1000, 1);          /* polling mode  */
		blitscrt_fabric_write(f, 0x100C, 0x00010101); /* N = 1, bypass */
		blitscrt_fabric_write(f, 0x1010, 0x00000808); /* M = 16        */
		blitscrt_fabric_write(f, 0x1014, 0x00002020); /* C = 64, idx 0 */
		blitscrt_fabric_write(f, 0x1008, 1);          /* START         */

		usleep(wait_ms * 1000u);

		st = blitscrt_fabric_read(f, 0x1004);
		printf("STATUS = 0x%08x  %s\n", st,
		       (st & 1) ? "READY -- the sequence works; polling is what breaks it"
			        : "still not ready");
	} else if (!strcmp(argv[1], "-m")) {
		/*
		 * Apply a Switchres/DRM-style modeline through the same path a
		 * host modeset takes: solve the PLL, reconfigure it, latch the
		 * timing, claim ownership. That makes this the only way to
		 * exercise the reconfig block without a USB host attached --
		 * and reconfig is the one part of the chain nothing has run.
		 *
		 * vtotal is in FRAME lines. The fabric counts per field, and an
		 * interlaced frame is 2*V_TOT+1, so 625 becomes 312 per field.
		 *
		 * PAL 640x576i50:
		 *   -m 12500 640 668 732 800 576 580 586 625 i
		 * NTSC 640x480i60, what the mode table already gives:
		 *   -m 12600 640 664 724 800 480 486 492 525 i
		 */
		struct blitscrt_mode m;
		struct blitscrt_timing t;
		enum blitscrt_mode_result r;

		if (argc != 11 && argc != 12) {
			usage(argv[0]); blitscrt_fabric_close(f); return 2;
		}
		blitscrt_mode_from_modeline(&m, parse(argv[2]),
			(uint16_t)parse(argv[3]), (uint16_t)parse(argv[4]),
			(uint16_t)parse(argv[5]), (uint16_t)parse(argv[6]),
			(uint16_t)parse(argv[7]), (uint16_t)parse(argv[8]),
			(uint16_t)parse(argv[9]), (uint16_t)parse(argv[10]),
			(argc == 12 && argv[11][0] == 'i') ? BLITSCRT_MF_INTERLACE : 0);

		r = blitscrt_mode_check(&m, &blitscrt_limits_15khz, &t);
		if (r != BLITSCRT_MODE_OK) {
			printf("rejected: %s\n", blitscrt_mode_result_str(r));
			blitscrt_fabric_close(f);
			return 1;
		}
		printf("solved     %.3f kHz line, %.2f Hz field, %u frame lines\n",
		       t.line_hz / 1e3, t.field_hz, t.frame_lines);
		printf("PLL        M=%u N=%u C=%u -> %.4f MHz (asked %u kHz)\n",
		       t.pll.m, t.pll.n, t.pll.c, t.pll.actual_hz / 1e6,
		       m.clock_khz);

		if (blitscrt_fabric_set_mode(f, &t, BLITSCRT_FMT_RGB565) < 0) {
			printf("set_mode failed -- the PLL reconfig or the apply\n"
			       "did not complete. Recover with: %s -w 0x08 0x11\n",
			       argv[0]);
			blitscrt_fabric_close(f);
			return 1;
		}
		printf("applied. recover with: %s -w 0x08 0x11\n", argv[0]);
	} else if (!strcmp(argv[1], "-c")) {
		unsigned w, h;
		if (argc != 4) { usage(argv[0]); blitscrt_fabric_close(f); return 2; }
		w = parse(argv[2]); h = parse(argv[3]);
		if (blitscrt_scanout_configure(f, w, h, BLITSCRT_FMT_RGB565) < 0) {
			printf("configure failed\n");
		} else {
			uint32_t caps = blitscrt_fabric_caps(f);
			uint32_t g = blitscrt_fabric_read(f, BLITSCRT_REG_SCANOUT_GEOM);
			printf("geometry reads back %ux%u, stride %u bytes\n",
			       g & 0xffffu, (g >> 16) & 0xffffu, w * 2);
			printf("writes will go via %s\n",
			       (caps & BLITSCRT_CAP_SCANOUT_DDR3)
				 ? "memcpy into the DDR3 window"
				 : "the gp rect port, one command per pixel");
			if (!(caps & BLITSCRT_CAP_SCANOUT_DDR3))
				printf("  CAPS = 0x%08x -- not a DDR3 build, or the read\n"
				       "  failed at open. Check with: %s 0x7c\n",
				       caps, argv[0]);
		}
	} else if (!strcmp(argv[1], "-f")) {
		/*
		 * Fill a rect and time it. This is the only place the real gp
		 * throughput gets measured: one command per pixel is the floor
		 * the transport allows, so pixels/second here is the transport's
		 * ceiling, and it is the number that decides whether M3c is
		 * optional or mandatory.
		 */
		unsigned x, y, w, h;
		uint16_t col;
		long n;
		struct timespec t0, t1;
		double secs;

		if (argc != 7) { usage(argv[0]); blitscrt_fabric_close(f); return 2; }
		x = parse(argv[2]); y = parse(argv[3]);
		w = parse(argv[4]); h = parse(argv[5]);
		col = (uint16_t)parse(argv[6]);

		clock_gettime(CLOCK_MONOTONIC, &t0);
		n = blitscrt_scanout_fill(f, x, y, w, h, col);
		clock_gettime(CLOCK_MONOTONIC, &t1);

		if (n < 0) {
			printf("fill failed -- see the message above\n");
		} else {
			secs = (double)(t1.tv_sec - t0.tv_sec) +
			       (double)(t1.tv_nsec - t0.tv_nsec) / 1e9;
			printf("%ld pixels in %.3f s -- %.0f px/s, %.2f MB/s (%s)\n",
			       n, secs,
			       secs > 0 ? n / secs : 0.0,
			       secs > 0 ? (n * 2.0) / secs / 1e6 : 0.0,
			       (blitscrt_fabric_caps(f) & BLITSCRT_CAP_SCANOUT_DDR3)
				 ? "memcpy into DDR3" : "gp, one command per pixel");
			printf("pointer now 0x%08x\n",
			       blitscrt_fabric_read(f, BLITSCRT_REG_SCANOUT_WADDR));
			printf("set CTRL for scanout to see it:  %s -w 0x08 0x11\n",
			       argv[0]);
		}
	} else {
		for (i = 1; i < argc; i++) {
			uint32_t off = parse(argv[i]);
			printf("[0x%04x] = 0x%08x\n", off, blitscrt_fabric_read(f, off));
		}
	}

	blitscrt_fabric_close(f);
	return 0;
}
