/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * modes.c -- turn a DRM mode into fabric timing, or reject it.
 *
 * GUD hands the device a full DRM mode on every modeset: pixel clock in kHz
 * plus the eight timing values and a flag word. Nothing constrains the host to
 * modes the device advertised, and Switchres exists precisely to synthesise
 * new ones per game. So the device is the arbiter, and this is where it says
 * yes or no.
 *
 * The checks are about what the CRT can survive, not what the fabric can
 * count to. A 31kHz line rate on a 15kHz set is a repair bill.
 */

#include "modes.h"

#include <string.h>

const struct blitscrt_sink_limits blitscrt_limits_15khz = {
	/* 15.734kHz NTSC and 15.625kHz PAL sit inside this, with margin for
	 * the arcade monitors that run a little fast or slow. */
	.line_hz_min  = 15000,
	.line_hz_max  = 16500,
	.field_hz_min = 47,
	.field_hz_max = 63,
	/*
	 * 1280 for super-resolution modes: Switchres generates 1280- and
	 * 2560-wide timings so the host GPU does the horizontal scaling, which
	 * is invisible on a CRT and cheap on the host. The line rate is what a
	 * CRT actually cares about, and that is unchanged -- a 1280-wide line at
	 * 15.75 kHz is the same deflection work as a 640-wide one, just a faster
	 * pixel clock.
	 */
	.h_max = 1280,
	.v_max = 640,
	.pclk_khz_min = 2000,
	.pclk_khz_max = 32000,
};

const char *blitscrt_mode_result_str(enum blitscrt_mode_result r)
{
	switch (r) {
	case BLITSCRT_MODE_OK:           return "ok";
	case BLITSCRT_MODE_BAD_GEOMETRY: return "timing values out of order";
	case BLITSCRT_MODE_LINE_RATE:    return "line rate outside the sink range";
	case BLITSCRT_MODE_FIELD_RATE:   return "field rate outside the sink range";
	case BLITSCRT_MODE_TOO_BIG:      return "geometry larger than the sink";
	case BLITSCRT_MODE_NO_PLL:       return "pixel clock unreachable";
	}
	return "?";
}

void blitscrt_mode_from_modeline(struct blitscrt_mode *m,
				 uint32_t clock_khz,
				 uint16_t hd, uint16_t hss, uint16_t hse, uint16_t ht,
				 uint16_t vd, uint16_t vss, uint16_t vse, uint16_t vt,
				 uint32_t flags)
{
	memset(m, 0, sizeof *m);
	m->clock_khz   = clock_khz;
	m->hdisplay    = hd; m->hsync_start = hss;
	m->hsync_end   = hse; m->htotal     = ht;
	m->vdisplay    = vd; m->vsync_start = vss;
	m->vsync_end   = vse; m->vtotal     = vt;
	m->flags       = flags;
}

enum blitscrt_mode_result
blitscrt_mode_check(const struct blitscrt_mode *m,
		    const struct blitscrt_sink_limits *lim,
		    struct blitscrt_timing *out)
{
	int interlaced;
	/* A 31 kHz progressive mode is rewritten into a 15 kHz interlaced one
	 * here; conv holds the rewrite and m is repointed at it. */
	struct blitscrt_mode conv;
	int converted = 0;
	/* The pixel clock in Hz. Normally clock_khz*1000, but a converted mode
	 * needs finer resolution than a whole kHz -- see the conversion. */
	double clk_hz = 0.0;
	uint32_t v_total_field, v_act_field;
	double line_hz, field_hz;

	if (!m || !lim || !out)
		return BLITSCRT_MODE_BAD_GEOMETRY;

	memset(out, 0, sizeof *out);

	/* DRM guarantees display <= sync_start <= sync_end <= total. A host
	 * that breaks it has a bug, and acting on it would produce sync the
	 * CRT cannot follow. */
	if (!(m->hdisplay && m->vdisplay && m->clock_khz))
		return BLITSCRT_MODE_BAD_GEOMETRY;
	if (m->hdisplay > m->hsync_start || m->hsync_start > m->hsync_end ||
	    m->hsync_end > m->htotal)
		return BLITSCRT_MODE_BAD_GEOMETRY;
	if (m->vdisplay > m->vsync_start || m->vsync_start > m->vsync_end ||
	    m->vsync_end > m->vtotal)
		return BLITSCRT_MODE_BAD_GEOMETRY;

	if (m->hdisplay > lim->h_max || m->vdisplay > lim->v_max)
		return BLITSCRT_MODE_TOO_BIG;

	/*
	 * A 31 kHz progressive mode becomes a 15 kHz interlaced one.
	 *
	 * This exists because of how the display stack rates interlaced modes.
	 * RandR reports an interlaced mode at its *frame* rate, so a host told
	 * "480i60" renders 30 frames a second and the CRT gets 60 fields drawn
	 * from 30 renders -- correct 480i, but half the motion an interlaced
	 * console produces. Measured: 320x448i asks for 59.92 Hz and the host
	 * delivers 33, with the device idle two thirds of the time.
	 *
	 * Nothing on this side can change what X tells an application. What it
	 * can change is what the application is asked for. A 448-line
	 * *progressive* mode at 31 kHz has no interlace flag, so nothing halves
	 * it: the host allocates 448 lines and renders 60 frames a second into
	 * them. The fabric then emits a 15 kHz interlaced raster reading
	 * alternate rows, so each field comes from a different render -- 448
	 * distinct lines at 60 Hz motion, which is what the console does.
	 *
	 * The conversion is exact and refresh-preserving by construction:
	 * halving the clock and the vertical total divides both sides of
	 * clock/(htotal*vtotal), so the field rate equals the progressive rate
	 * the host was given, whatever Switchres computed and however the PLL
	 * later rounds it.
	 *
	 *   in   13.036 MHz / 416 / 522     31.337 kHz, 60.03 Hz progressive
	 *   out   6.518 MHz / 416 / 261 i   15.668 kHz, 60.03 Hz field
	 *
	 * Only modes out of the sink's band whose half is inside it convert, so
	 * a 224p mode at 15 kHz is left exactly as it arrives. Requires a
	 * dual-range monitor profile on the host: 15 kHz for the short modes,
	 * 31 kHz for the tall ones. See docs/INTERLACE.md.
	 */
	{
		double lr = (double)m->clock_khz * 1000.0 / (double)m->htotal;

		if (lr > lim->line_hz_max && !(m->flags & BLITSCRT_MF_INTERLACE) &&
		    lr / 2.0 >= lim->line_hz_min && lr / 2.0 <= lim->line_hz_max) {
			conv = *m;

			/*
			 * The clock comes from the rate, not from halving.
			 *
			 * An interlaced frame is 2*field+1 lines. The half line
			 * is what offsets one field against the other; without
			 * it both fields land on the same scanlines and the
			 * picture is 224 lines drawn twice rather than 448. So
			 * it cannot be dropped to make the arithmetic tidy.
			 *
			 * Which means an even host total does not simply halve.
			 * 522 progressive lines become 261 field lines plus the
			 * half line -- 261.5 -- and a clock of exactly half runs
			 * the field rate 1912 ppm slow. That is 0.11 frames a
			 * second, a slip every nine seconds, plainly visible.
			 *
			 * But the fabric's clock is ours to choose. What has to
			 * match is the field rate, not the ratio to the host's
			 * clock. So solve for it:
			 *
			 *   fabric = host * (field + 0.5) / vtotal
			 *
			 * which is exactly half when the total is odd, and a
			 * little over half when it is even. Both land on 0 ppm.
			 *
			 *   522 even   half 6.518000 MHz  -1912 ppm
			 *              solved 6.530487 MHz     0 ppm
			 *
			 * The deviation from "half" is invisible: 0.19% on a
			 * pixel clock changes nothing a CRT can see, while
			 * 0.19% on the frame rate is a dropped field every nine
			 * seconds.
			 */
			{
				unsigned field = m->vtotal / 2u;

				/* Exact, in Hz. clock_khz is an integer, and
				 * rounding 6530.487 kHz to 6530 costs 75 ppm --
				 * small, but there is no reason to spend it
				 * when the PLL solver takes Hz anyway. */
				clk_hz = (double)m->clock_khz * 1000.0 *
					 ((double)field + 0.5) /
					 (double)m->vtotal;

				conv.clock_khz = (uint32_t)(clk_hz / 1000.0 + 0.5);
				conv.vtotal    = 2u * field + 1u;
			}
			conv.flags |= BLITSCRT_MF_INTERLACE;

			m = &conv;
			converted = 1;
		}
	}

	if (m->clock_khz < lim->pclk_khz_min || m->clock_khz > lim->pclk_khz_max)
		return BLITSCRT_MODE_NO_PLL;

	interlaced = (m->flags & BLITSCRT_MF_INTERLACE) ? 1 : 0;

	if (clk_hz == 0.0)
		clk_hz = (double)m->clock_khz * 1000.0;

	line_hz = clk_hz / (double)m->htotal;
	if (line_hz < lim->line_hz_min || line_hz > lim->line_hz_max)
		return BLITSCRT_MODE_LINE_RATE;

	/*
	 * DRM counts vtotal in frame lines. The fabric counts per field, and
	 * an interlaced frame is 2*V_TOT+1 lines, so the odd line is the half
	 * line that carries the interlace offset.
	 */
	if (interlaced) {
		v_total_field = (m->vtotal - 1) / 2;
		v_act_field   = m->vdisplay / 2;
		field_hz      = line_hz / ((double)m->vtotal / 2.0);
	} else {
		v_total_field = m->vtotal;
		v_act_field   = m->vdisplay;
		field_hz      = line_hz / (double)m->vtotal;
	}

	if (field_hz < lim->field_hz_min || field_hz > lim->field_hz_max)
		return BLITSCRT_MODE_FIELD_RATE;

	/* horizontal: the fabric's line starts at the sync edge */
	out->h_sy  = m->hsync_end   - m->hsync_start;
	out->h_bp  = m->htotal      - m->hsync_end;
	out->h_act = m->hdisplay;
	out->h_fp  = m->hsync_start - m->hdisplay;

	/* vertical, per field */
	if (interlaced) {
		out->v_sy = (m->vsync_end   - m->vsync_start) / 2;
		out->v_bp = (m->vtotal      - m->vsync_end)   / 2;
		out->v_fp = (m->vsync_start - m->vdisplay)    / 2;
		if (!out->v_sy) out->v_sy = 1;
	} else {
		out->v_sy = m->vsync_end   - m->vsync_start;
		out->v_bp = m->vtotal      - m->vsync_end;
		out->v_fp = m->vsync_start - m->vdisplay;
	}
	out->v_act = v_act_field;

	/* absorb rounding into the back porch so the totals still close */
	{
		int32_t sum = out->v_sy + out->v_bp + out->v_act + out->v_fp;
		int32_t diff = (int32_t)v_total_field - sum;
		if (diff > 0 || (diff < 0 && out->v_bp + diff > 0))
			out->v_bp = (uint16_t)(out->v_bp + diff);
	}

	out->mode_flags = 0;
	if (interlaced)                    out->mode_flags |= 1u << 0;
	if (m->flags & BLITSCRT_MF_PHSYNC) out->mode_flags |= 1u << 1;
	if (m->flags & BLITSCRT_MF_PVSYNC) out->mode_flags |= 1u << 2;
	if (m->flags & BLITSCRT_MF_DBLSCAN)out->mode_flags |= 1u << 3;

	out->h_total       = m->htotal;
	out->v_total_field = out->v_sy + out->v_bp + out->v_act + out->v_fp;
	out->frame_lines   = interlaced ? 2 * out->v_total_field + 1
					: out->v_total_field;
	out->line_hz  = line_hz;
	out->field_hz = field_hz;
	out->frame_hz = interlaced ? field_hz / 2.0 : field_hz;

	if (pll_solve((unsigned long long)(clk_hz + 0.5),
		      &pll_cyclonev, &out->pll) < 0)
		return BLITSCRT_MODE_NO_PLL;

	out->from_progressive = converted;

	return BLITSCRT_MODE_OK;
}
