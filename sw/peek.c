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
#include "fabric.h"

static void usage(const char *p)
{
	fprintf(stderr,
		"usage: %s <off> [off ...]     read one or more registers\n"
		"       %s -w <off> <val>      write a register, then read it back\n"
		"       %s -b [off]            beat a register (default 0x64) for ~5s\n"
		"offsets and values are hex (0x64) or decimal. Kill blitscrtd first.\n",
		p, p, p);
}

static uint32_t parse(const char *s) { return (uint32_t)strtoul(s, NULL, 0); }

int main(int argc, char **argv)
{
	struct blitscrt_fabric *f;
	int i;

	if (argc < 2) { usage(argv[0]); return 2; }

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
	} else {
		for (i = 1; i < argc; i++) {
			uint32_t off = parse(argv[i]);
			printf("[0x%04x] = 0x%08x\n", off, blitscrt_fabric_read(f, off));
		}
	}

	blitscrt_fabric_close(f);
	return 0;
}
