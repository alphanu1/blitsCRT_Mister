/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * The LZ4 block decompressor, including malformed input.
 *
 * The blocks arrive over USB from whatever is at the other end, so the refusals
 * matter as much as the successes: a bad offset, or a length that runs past the
 * buffer, must return an error rather than walk off the end.
 */

#include <stdio.h>
#include <string.h>

#include "../lz4dec.h"

static int fails;

static void chk(const char *name, int ok)
{
	printf("  %-52s %s\n", name, ok ? "ok" : "FAIL");
	if (!ok)
		fails++;
}

int main(void)
{
	uint8_t out[256];
	long n;

	printf("LZ4 block decompression\n");

	/* token 0x50: five literals, no match */
	{
		const uint8_t b[] = { 0x50, 'H', 'e', 'l', 'l', 'o' };
		n = blitscrt_lz4_decompress(b, sizeof b, out, sizeof out);
		chk("literals only", n == 5 && !memcmp(out, "Hello", 5));
	}

	/* one literal 'A', then offset 1 and match 0+4: the run-length case,
	 * which is why the copy has to be byte at a time */
	{
		const uint8_t b[] = { 0x10, 'A', 0x01, 0x00 };
		n = blitscrt_lz4_decompress(b, sizeof b, out, sizeof out);
		chk("overlapping match encodes a run",
		    n == 5 && !memcmp(out, "AAAAA", 5));
	}

	/* literal length 15 plus an extension byte */
	{
		uint8_t b[22];
		int i;
		b[0] = 0xF0;
		b[1] = 5;                       /* 15 + 5 = 20 */
		for (i = 0; i < 20; i++)
			b[2 + i] = (uint8_t)('a' + i);
		n = blitscrt_lz4_decompress(b, sizeof b, out, sizeof out);
		chk("extended literal length", n == 20 && out[19] == 'a' + 19);
	}

	{
		const uint8_t b[] = { 0x10, 'A', 0x10, 0x00 };
		chk("offset before the buffer start is refused",
		    blitscrt_lz4_decompress(b, sizeof b, out, sizeof out) == -1);
	}

	{
		const uint8_t b[] = { 0xA0, 'x' };
		chk("literals past the input end are refused",
		    blitscrt_lz4_decompress(b, sizeof b, out, sizeof out) == -1);
	}

	{
		const uint8_t b[] = { 0x10, 'A', 0x00, 0x00 };
		chk("zero offset is refused",
		    blitscrt_lz4_decompress(b, sizeof b, out, sizeof out) == -1);
	}

	{
		const uint8_t b[] = { 0x50, 'H', 'e', 'l', 'l', 'o' };
		chk("output overrun is refused",
		    blitscrt_lz4_decompress(b, sizeof b, out, 3) == -1);
	}

	/*
	 * Small offsets, which the doubling copy handles differently from large
	 * ones. Offsets of 2 and 4 are a repeated pixel or pixel pair and are
	 * most of what sprite data is made of, so they are worth checking
	 * explicitly rather than trusting the general case.
	 */
	{
		/* two literals, then offset 2 with match 15+3+4 = 22:
		 * "ab" repeated to 24 bytes total */
		uint8_t b[6];
		b[0] = 0x2F;            /* 2 literals, match nibble 15 */
		b[1] = 'a'; b[2] = 'b';
		b[3] = 0x02; b[4] = 0x00;   /* offset 2 */
		b[5] = 3;                   /* match 15 + 3 + 4 = 22 */
		n = blitscrt_lz4_decompress(b, sizeof b, out, sizeof out);
		chk("offset 2 repeats a pixel pair", n == 24);
		{
			int i, ok = 1;
			for (i = 0; i < 24; i++)
				if (out[i] != (i & 1 ? 'b' : 'a')) ok = 0;
			chk("  and every byte is right", ok);
		}
	}

	{
		/* four literals, offset 4, match 15+1+4 = 20 -> 24 bytes */
		uint8_t b[8];
		b[0] = 0x4F;
		b[1] = 'w'; b[2] = 'x'; b[3] = 'y'; b[4] = 'z';
		b[5] = 0x04; b[6] = 0x00;
		b[7] = 1;
		n = blitscrt_lz4_decompress(b, sizeof b, out, sizeof out);
		chk("offset 4 repeats a 32-bit group", n == 24);
		{
			int i, ok = 1;
			const char *pat = "wxyz";
			for (i = 0; i < 24; i++)
				if (out[i] != pat[i & 3]) ok = 0;
			chk("  and every byte is right", ok);
		}
	}

	if (fails)
		printf("\nFAIL  %d checks\n", fails);
	else
		printf("\nPASS\n");
	return fails != 0;
}
