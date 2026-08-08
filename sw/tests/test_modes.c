/* SPDX-License-Identifier: GPL-2.0-or-later */
/* Check that real modelines survive the round trip, and that dangerous ones
 * are rejected. */
#include <stdio.h>
#include <math.h>
#include <string.h>
#include "../modes.h"

struct tc {
	const char *name;
	struct blitscrt_mode m;
	enum blitscrt_mode_result expect;
};

#define M(c,hd,hss,hse,ht,vd,vss,vse,vt,f) \
	{ .clock_khz=c, .hdisplay=hd, .hsync_start=hss, .hsync_end=hse, .htotal=ht, \
	  .vdisplay=vd, .vsync_start=vss, .vsync_end=vse, .vtotal=vt, .flags=f }

static const struct tc cases[] = {
 /* the two modes M1 ships, expressed the way DRM would */
 { "320x240p60",   M(6400, 320,344,374,406, 240,243,246,262, BLITSCRT_MF_NHSYNC|BLITSCRT_MF_NVSYNC),
   BLITSCRT_MODE_OK },
 { "640x480i60",   M(12600, 640,664,724,800, 480,486,492,525,
                     BLITSCRT_MF_INTERLACE|BLITSCRT_MF_NHSYNC|BLITSCRT_MF_NVSYNC),
   BLITSCRT_MODE_OK },

 /* Switchres would generate these per game */
 { "256x224@59.18",M(5369, 256,276,306,341, 224,227,230,262, 0), BLITSCRT_MODE_OK },
 { "384x224@59.64",M(8000, 384,408,448,508, 224,227,230,262, 0), BLITSCRT_MODE_OK },
 { "320x224@59.92",M(6710, 320,344,376,426, 224,227,230,262, 0), BLITSCRT_MODE_OK },
 { "320x256@50 PAL",M(6400, 320,344,374,406, 256,259,262,312, 0), BLITSCRT_MODE_OK },

 /* 31 kHz progressive is no longer refused: it is halved into 15 kHz
  * interlaced, which is the whole point -- stock VGA 640x480p60 becomes
  * 640x480i60 on a 15 kHz set, and the host renders 60 frames a second
  * because nothing told it the mode was interlaced. 525 is odd, so the
  * interlace half line makes the two rates agree exactly. */
 { "640x480p60 31k",M(25175, 640,656,752,800, 480,490,492,525, 0), BLITSCRT_MODE_OK },

 /* things that must be refused */
 { "800x600p60",    M(40000, 800,840,968,1056, 600,601,605,628, 0), BLITSCRT_MODE_NO_PLL },
 /* 1024 and 1280 are inside the sink now -- super-resolution modes are 1280
  * wide at the same line rate. 1536 is over. */
 { "1024x240 wide",  M(18900, 1024,1048,1128,1200, 240,243,246,262, 0), BLITSCRT_MODE_OK },
 { "1280x240 supres",M(25200, 1280,1328,1448,1600, 240,243,246,262, 0), BLITSCRT_MODE_OK },
 { "1536x240 too wide",
                     M(30240, 1536,1584,1704,1920, 240,243,246,262, 0), BLITSCRT_MODE_TOO_BIG },
 { "160p @ 90Hz",   M(6400, 320,344,374,406, 160,163,166,175, 0), BLITSCRT_MODE_FIELD_RATE },
 { "sync out of order", M(6400, 320,300,374,406, 240,243,246,262, 0), BLITSCRT_MODE_BAD_GEOMETRY },
 { "clock too high",M(60000, 320,344,374,406, 240,243,246,262, 0), BLITSCRT_MODE_NO_PLL },
};

int main(void)
{
	size_t i; int fails = 0;
#define check(name, cond) do { \
		printf("  %-52s %s\n", (name), (cond) ? "ok" : "FAIL"); \
		if (!(cond)) fails++; \
	} while (0)

	printf("%-18s %-9s  %-26s %s\n", "mode", "verdict", "fabric timing", "measured");
	printf("---------------------------------------------------------------------------------------------\n");

	for (i = 0; i < sizeof(cases)/sizeof(cases[0]); i++) {
		struct blitscrt_timing t;
		enum blitscrt_mode_result r =
			blitscrt_mode_check(&cases[i].m, &blitscrt_limits_15khz, &t);

		if (r != cases[i].expect) {
			printf("%-18s FAIL got '%s', expected '%s'\n", cases[i].name,
			       blitscrt_mode_result_str(r),
			       blitscrt_mode_result_str(cases[i].expect));
			fails++;
			continue;
		}

		if (r != BLITSCRT_MODE_OK) {
			printf("%-18s %-9s  rejected: %s\n", cases[i].name,
			       "REJECT", blitscrt_mode_result_str(r));
			continue;
		}

		printf("%-18s %-9s  H %3u/%3u/%3u/%-3u V %u/%u/%u/%-2u  %.3fkHz %.2fHz %s\n",
		       cases[i].name, "accept",
		       t.h_sy, t.h_bp, t.h_act, t.h_fp,
		       t.v_sy, t.v_bp, t.v_act, t.v_fp,
		       t.line_hz/1000.0, t.field_hz,
		       (t.mode_flags & 1) ? "interlaced" : "");

		/* the decomposition must reproduce the original totals */
		if (t.h_sy + t.h_bp + t.h_act + t.h_fp != cases[i].m.htotal) {
			printf("    FAIL htotal %u != %u\n",
			       t.h_sy+t.h_bp+t.h_act+t.h_fp, cases[i].m.htotal);
			fails++;
		}
		{
			uint32_t expect_frame = cases[i].m.vtotal;
			if (t.frame_lines != expect_frame) {
				printf("    FAIL frame lines %u != vtotal %u\n",
				       t.frame_lines, expect_frame);
				fails++;
			}
		}
		if (t.pll.error_ppm > 200 || t.pll.error_ppm < -200) {
			printf("    FAIL pll error %lld ppm\n", t.pll.error_ppm);
			fails++;
		}
	}

	printf("\n%s\n", fails ? "FAIL" : "PASS");
		/*
	 * A 31 kHz progressive mode becomes a 15 kHz interlaced one, at the
	 * same refresh.
	 *
	 * This is what lets an interlaced picture run at 60 Hz motion: the host
	 * is told 448p60, which nothing halves, and the fabric emits 15 kHz
	 * interlaced so each field comes from a different render.
	 */
	printf("\n31 kHz progressive rewritten as 15 kHz interlaced\n");
	{
		struct blitscrt_mode m;
		struct blitscrt_timing t;

		/* 13.036 MHz, 416 total, 523 lines: 31.337 kHz, 59.92 Hz.
		 * Odd, so the interlaced half line makes the rates match. */
		blitscrt_mode_from_modeline(&m, 13036, 320, 351, 383, 416,
					    448, 454, 460, 523,
					    BLITSCRT_MF_NHSYNC | BLITSCRT_MF_NVSYNC);

		check("a 31 kHz progressive mode is accepted",
		      blitscrt_mode_check(&m, &blitscrt_limits_15khz, &t)
		      == BLITSCRT_MODE_OK);
		check("and marked as rewritten", t.from_progressive == 1);
		check("it is now interlaced",
		      (t.mode_flags & 1u) != 0);
		check("at half the line rate, inside the band",
		      t.line_hz > 15000.0 && t.line_hz < 16500.0);
		check("with the refresh preserved exactly",
		      fabs(t.field_hz - 13036000.0 / (416.0 * 523.0)) < 0.001);
		check("448 lines a frame, 224 per field",
		      t.v_act == 224);
		check("the PLL solves the halved clock",
		      t.pll.actual_hz > 6.4e6 && t.pll.actual_hz < 6.6e6);
		printf("        %.3f kHz line, %.2f Hz field, %u lines a frame,"
		       " PLL %+lld ppm\n",
		       t.line_hz / 1000.0, t.field_hz, t.frame_lines,
		       t.pll.error_ppm);
	}
	{
		struct blitscrt_mode m;
		struct blitscrt_timing t;

		/* A 15 kHz mode must pass through untouched -- 224p content is
		 * already right and rewriting it would be wrong. */
		blitscrt_mode_from_modeline(&m, 6518, 320, 351, 383, 416,
					    224, 227, 230, 261,
					    BLITSCRT_MF_NHSYNC | BLITSCRT_MF_NVSYNC);
		check("a 15 kHz progressive mode is left alone",
		      blitscrt_mode_check(&m, &blitscrt_limits_15khz, &t)
		      == BLITSCRT_MODE_OK && t.from_progressive == 0);
		check("and stays progressive", (t.mode_flags & 1u) == 0);
	}
	{
		struct blitscrt_mode m;
		struct blitscrt_timing t;
		double host;

		/* An even total gains the interlace half line, so halving the
		 * clock would run 1912 ppm slow -- a dropped field every nine
		 * seconds. The clock is solved from the wanted rate instead. */
		blitscrt_mode_from_modeline(&m, 13036, 320, 351, 383, 416,
					    448, 454, 460, 522,
					    BLITSCRT_MF_NHSYNC | BLITSCRT_MF_NVSYNC);
		host = 13036000.0 / (416.0 * 522.0);

		check("an even vertical total is accepted",
		      blitscrt_mode_check(&m, &blitscrt_limits_15khz, &t)
		      == BLITSCRT_MODE_OK);
		check("the frame gains the half line", t.frame_lines == 523);
		check("and the rate still matches the host",
		      fabs(t.field_hz - host) / host < 50e-6);
		printf("        host %.4f Hz, fabric %.4f Hz, %+.0f ppm\n",
		       host, t.field_hz, (t.field_hz / host - 1.0) * 1e6);
	}
	{
		struct blitscrt_mode m;
		struct blitscrt_timing t;

		/* An interlaced mode is never rewritten, whatever its rate. */
		blitscrt_mode_from_modeline(&m, 12600, 648, 670, 730, 800,
					    480, 486, 492, 525,
					    BLITSCRT_MF_INTERLACE);
		check("an already-interlaced mode is not rewritten",
		      blitscrt_mode_check(&m, &blitscrt_limits_15khz, &t)
		      == BLITSCRT_MODE_OK && t.from_progressive == 0);
	}

return fails ? 1 : 0;
}
