/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * A minimal EDID, so a host has something to call this display.
 *
 * Without one a connector shows as "VGA-1-unknown": the first part is DRM naming
 * the connector, the second is the absence of a monitor name. Answering
 * GUD_REQ_GET_CONNECTOR_EDID with a block containing a name descriptor fixes the
 * second half.
 *
 * Deliberately carries no timings. No established timings, no standard timings,
 * and no detailed timing descriptor -- because the GUD mode list is authoritative
 * here and modes arriving from two directions could disagree.
 *
 * That turned out to be wrong, and this block is not sent by default because of
 * it. Tested on hardware, a host offered it picks a mode wider than the raster
 * and loses frames -- with the range limits and equally with a bare name, so it
 * is not the limits. What both share is having no timing at all, which is legal
 * but very unusual: a host expecting a preferred timing and finding none may fall
 * back to a default rather than deferring to the mode list.
 *
 * The variant with a reason to work is therefore the opposite of this one: a
 * single detailed timing descriptor matching the preferred mode. Interlaced DTDs
 * are awkward, which is why it was not tried first.
 *
 * The sync range is worth sending on its own account: it tells the host what the
 * deflection circuit will take, which is exactly the thing that matters on a
 * fixed-frequency CRT and exactly what a PC display normally has no reason to
 * publish.
 */

#include <string.h>

#include "edid.h"

/*
 * Three letters, five bits each, packed big-endian. A=1 through Z=26.
 *
 * BCT is not a VESA-registered PNP ID and is not claimed to be one. It exists so
 * the block is well-formed; nothing looks it up except a vendor database, which
 * will simply not find it. Registering an ID would mean joining UEFI's registry
 * for the sake of a string.
 */
static void pnp_id(uint8_t *out, const char *three)
{
	unsigned v = ((three[0] - 'A' + 1) << 10) |
		     ((three[1] - 'A' + 1) <<  5) |
		      (three[2] - 'A' + 1);
	out[0] = (uint8_t)(v >> 8);
	out[1] = (uint8_t)(v & 0xff);
}

/* A descriptor block: 00 00 00 <tag> 00 then thirteen bytes of payload. */
static void descriptor(uint8_t *d, uint8_t tag, const uint8_t *payload)
{
	d[0] = d[1] = d[2] = 0x00;
	d[3] = tag;
	d[4] = 0x00;
	memcpy(d + 5, payload, 13);
}

/* Thirteen bytes: the text, then 0x0A to end it, then spaces. */
static void text_payload(uint8_t *p, const char *s)
{
	size_t n = strlen(s);
	if (n > 13) n = 13;
	memset(p, 0x20, 13);
	memcpy(p, s, n);
	if (n < 13)
		p[n] = 0x0A;
}

size_t blitscrt_edid_build(uint8_t *buf, size_t cap,
			   const char *name, int with_range,
			   unsigned hfreq_min_khz, unsigned hfreq_max_khz,
			   unsigned vfreq_min_hz, unsigned vfreq_max_hz,
			   unsigned max_clock_khz)
{
	uint8_t payload[13];
	unsigned sum = 0;
	int i;

	if (!buf || cap < BLITSCRT_EDID_LEN)
		return 0;

	memset(buf, 0, BLITSCRT_EDID_LEN);

	/* Header. The one part of an EDID that is always the same. */
	buf[0] = 0x00;
	memset(buf + 1, 0xff, 6);
	buf[7] = 0x00;

	pnp_id(buf + 8, "BCT");
	buf[10] = 0x01;                 /* product code, little-endian */
	buf[11] = 0x00;
	buf[12] = 0x01;                 /* serial */
	buf[16] = 1;                    /* week */
	buf[17] = 2026 - 1990;          /* year */
	buf[18] = 1;                    /* EDID 1.4 */
	buf[19] = 4;

	buf[20] = 0x00;                 /* analog input, 0.700 Vpp */
	buf[21] = 0;                    /* image size unknown -- it is whatever */
	buf[22] = 0;                    /* CRT is on the end of the cable */
	buf[23] = 120;                  /* gamma 2.20 */
	buf[24] = 0x0c;                 /* RGB colour, sRGB not claimed */

	/*
	 * Chromaticity. Nothing here knows the phosphors of whatever CRT is
	 * attached, so these are sRGB's, which is a reasonable lie and better
	 * formed than zeroes.
	 */
	buf[25] = 0xee; buf[26] = 0x91; buf[27] = 0xa3; buf[28] = 0x54;
	buf[29] = 0x4c; buf[30] = 0x99; buf[31] = 0x26; buf[32] = 0x0f;
	buf[33] = 0x50; buf[34] = 0x54;

	/* Established and standard timings: none. See the note above. */
	buf[35] = buf[36] = buf[37] = 0x00;
	for (i = 38; i < 54; i += 2) {
		buf[i]     = 0x01;      /* 0x0101 is "unused" */
		buf[i + 1] = 0x01;
	}

	/* Descriptor 1: the name, which is the point of all this. */
	text_payload(payload, name && *name ? name : "blitsCRT");
	descriptor(buf + 54, 0xfc, payload);

	/*
	 * Descriptor 2: what the deflection circuit will take -- but only if
	 * asked for. This is the half a host can compute from, and with it
	 * present one picks a mode wider than the raster. A name-only block
	 * gives it nothing but a string.
	 */
	if (with_range) {
		payload[0] = (uint8_t)vfreq_min_hz;
		payload[1] = (uint8_t)vfreq_max_hz;
		payload[2] = (uint8_t)hfreq_min_khz;
		payload[3] = (uint8_t)hfreq_max_khz;
		payload[4] = (uint8_t)((max_clock_khz + 9999) / 10000);
		payload[5] = 0x0a;      /* no secondary timing formula */
		memset(payload + 6, 0x20, 7);
		descriptor(buf + 72, 0xfd, payload);
	} else {
		memset(payload, 0x00, 13);
		descriptor(buf + 72, 0x10, payload);
	}

	/* Descriptors 3 and 4: unused. */
	memset(payload, 0x00, 13);
	descriptor(buf + 90, 0x10, payload);
	descriptor(buf + 108, 0x10, payload);

	buf[126] = 0;                   /* no extension blocks */

	/* The whole block sums to zero mod 256. */
	for (i = 0; i < BLITSCRT_EDID_LEN - 1; i++)
		sum += buf[i];
	buf[127] = (uint8_t)(256 - (sum & 0xff)) & 0xff;

	return BLITSCRT_EDID_LEN;
}
