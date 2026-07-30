/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * LZ4 block decompression, just enough for GUD.
 *
 * Carried here rather than linking liblz4: the daemon is a static ARM binary and
 * this is the only compression it will ever need. The block format is small
 * enough to hold in your head, and having it here means the bounds checking is
 * ours -- the input arrives over USB from whatever is at the other end, so every
 * read and every write is range-checked and a malformed block returns an error
 * rather than walking off a buffer.
 *
 * The format, in full:
 *
 *   token       one byte: high nibble literal length, low nibble match length
 *   [lit len]   if the nibble is 15, bytes follow; 255 means "and more"
 *   literals    copied straight out
 *   offset      two bytes little-endian, distance back into the output
 *   [match len] if the nibble is 15, bytes follow; 255 means "and more"
 *
 * Match length has 4 added to it -- the minimum match is 4 bytes, so the nibble
 * counts from there. The last sequence in a block is literals only and stops
 * before the offset, which is why the loop checks for input exhaustion after
 * copying literals rather than assuming an offset follows.
 *
 * Matches may overlap the current output position -- an offset of 1 with a
 * length of 20 is the run-length case, one byte repeated -- so the copy has to
 * be byte at a time rather than memcpy.
 */

#include <string.h>

#include "lz4dec.h"

long blitscrt_lz4_decompress(const void *src, size_t src_len,
			     void *dst, size_t dst_cap)
{
	const uint8_t *in = src, *in_end = in + src_len;
	uint8_t *out = dst, *out_end = out + dst_cap;
	uint8_t *out_start = out;

	if (!src || !dst)
		return -1;

	while (in < in_end) {
		unsigned token = *in++;
		size_t lit = token >> 4;
		size_t match, off;

		/* literal length */
		if (lit == 15) {
			unsigned b;
			do {
				if (in >= in_end) return -1;
				b = *in++;
				if (lit > (size_t)-1 - b) return -1;   /* overflow */
				lit += b;
			} while (b == 255);
		}

		if ((size_t)(in_end - in) < lit) return -1;
		if ((size_t)(out_end - out) < lit) return -1;
		memcpy(out, in, lit);
		out += lit;
		in  += lit;

		/* A block ends on a literal run. No offset follows. */
		if (in == in_end)
			break;

		/* offset, little-endian */
		if (in_end - in < 2) return -1;
		off = (size_t)in[0] | ((size_t)in[1] << 8);
		in += 2;
		if (off == 0) return -1;                       /* not legal */
		if ((size_t)(out - out_start) < off) return -1; /* before the start */

		/* match length, 4 implied */
		match = token & 0x0f;
		if (match == 15) {
			unsigned b;
			do {
				if (in >= in_end) return -1;
				b = *in++;
				if (match > (size_t)-1 - b) return -1;
				match += b;
			} while (b == 255);
		}
		match += 4;

		if ((size_t)(out_end - out) < match) return -1;

		/*
		 * A match may overlap the write position -- offset 1 with length
		 * 20 is one byte repeated twenty times, which is how LZ4 encodes
		 * runs -- so a plain memcpy of the whole thing is undefined.
		 *
		 * But a copy no longer than the gap cannot overlap, and every
		 * such copy doubles the gap. So the run is filled in
		 * exponentially larger memcpys: off, 2*off, 4*off, and so on.
		 * Twenty bytes at offset 1 becomes five memcpys rather than
		 * twenty byte stores, and offsets of 2 and 4 -- a repeated pixel
		 * or pixel pair, which is most of what sprite data is made of --
		 * reach wide copies almost immediately.
		 *
		 * memcpy is the right primitive here rather than a hand-rolled
		 * loop: the C library's is NEON-accelerated on this core, and
		 * nothing written by hand will beat it.
		 */
		{
			size_t gap = off;

			while (match) {
				size_t n = gap < match ? gap : match;

				/* n <= gap, so source and destination cannot
				 * overlap however small the offset is. */
				memcpy(out, out - gap, n);
				out   += n;
				match -= n;
				gap   += n;
			}
		}
	}

	return (long)(out - out_start);
}
