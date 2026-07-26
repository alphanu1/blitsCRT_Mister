/* SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef BLITSCRT_MODES_H
#define BLITSCRT_MODES_H

#include <stdint.h>
#include "pll.h"

/* A DRM display mode, in the shape GUD carries it. */
struct blitscrt_mode {
	uint32_t clock_khz;
	uint16_t hdisplay, hsync_start, hsync_end, htotal;
	uint16_t vdisplay, vsync_start, vsync_end, vtotal;
	uint32_t flags;
};

/* subset of the DRM/GUD mode flags we act on */
#define BLITSCRT_MF_PHSYNC     (1u << 0)
#define BLITSCRT_MF_NHSYNC     (1u << 1)
#define BLITSCRT_MF_PVSYNC     (1u << 2)
#define BLITSCRT_MF_NVSYNC     (1u << 3)
#define BLITSCRT_MF_INTERLACE  (1u << 4)
#define BLITSCRT_MF_DBLSCAN    (1u << 5)
#define BLITSCRT_MF_PREFERRED  (1u << 10)

/* What the CRT will actually tolerate. A sink that lies about this gets a
 * rolling picture at best and a stressed flyback at worst. */
struct blitscrt_sink_limits {
	uint32_t line_hz_min, line_hz_max;   /* horizontal scan rate */
	uint32_t field_hz_min, field_hz_max;
	uint16_t h_max, v_max;
	uint32_t pclk_khz_min, pclk_khz_max;
};

extern const struct blitscrt_sink_limits blitscrt_limits_15khz;

enum blitscrt_mode_result {
	BLITSCRT_MODE_OK = 0,
	BLITSCRT_MODE_BAD_GEOMETRY,
	BLITSCRT_MODE_LINE_RATE,
	BLITSCRT_MODE_FIELD_RATE,
	BLITSCRT_MODE_TOO_BIG,
	BLITSCRT_MODE_NO_PLL,
};

const char *blitscrt_mode_result_str(enum blitscrt_mode_result r);

/* Derived numbers, all computed rather than declared. */
struct blitscrt_timing {
	uint16_t h_sy, h_bp, h_act, h_fp;
	uint16_t v_sy, v_bp, v_act, v_fp;    /* per field */
	uint32_t mode_flags;                  /* BLITSCRT_MODE_* for the fabric */
	uint32_t h_total, v_total_field, frame_lines;
	double   line_hz, field_hz, frame_hz;
	struct pll_config pll;
};

/* Validate a mode against the sink and solve its clock. */
enum blitscrt_mode_result
blitscrt_mode_check(const struct blitscrt_mode *m,
		    const struct blitscrt_sink_limits *lim,
		    struct blitscrt_timing *out);

/* Build a mode from a Switchres-style modeline description. */
void blitscrt_mode_from_modeline(struct blitscrt_mode *m,
				 uint32_t clock_khz,
				 uint16_t hd, uint16_t hss, uint16_t hse, uint16_t ht,
				 uint16_t vd, uint16_t vss, uint16_t vse, uint16_t vt,
				 uint32_t flags);

#endif
