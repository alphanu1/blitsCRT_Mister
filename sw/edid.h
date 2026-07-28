/* SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef BLITSCRT_EDID_H
#define BLITSCRT_EDID_H

#include <stddef.h>
#include <stdint.h>

#define BLITSCRT_EDID_LEN 128

/*
 * Build a minimal EDID: a monitor name and a sync range, and no timings at all.
 * Returns the length written, or 0 if the buffer is too small.
 *
 * The mode list is authoritative on this device, so the block deliberately
 * carries nothing a host could turn into a mode.
 */
/*
 * with_range = 0 omits the range-limits descriptor and sends only the name.
 *
 * Worth having separately: sent with range limits, a host picks a mode wider
 * than the raster and drops frames, even though the block contains no timings.
 * The limits are the half a host can compute from, so a name-only block is the
 * conservative version and the one to try first.
 */
size_t blitscrt_edid_build(uint8_t *buf, size_t cap,
			   const char *name, int with_range,
			   unsigned hfreq_min_khz, unsigned hfreq_max_khz,
			   unsigned vfreq_min_hz, unsigned vfreq_max_hz,
			   unsigned max_clock_khz);

#endif
