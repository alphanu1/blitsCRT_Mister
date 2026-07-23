/* SPDX-License-Identifier: MIT */
/*
 * main.c -- blitscrtd, the GUD device daemon.
 *
 * Brings up the fabric, hands the mode list to the GUD layer, and runs the
 * FunctionFS event loop. Without a fabric it still answers the protocol, which
 * makes it possible to test enumeration against a real host before the SDRAM
 * path exists.
 */

#define _GNU_SOURCE
#include "device.h"
#include "fabric.h"
#include "gadget.h"
#include "blitscrt_regs.h"

#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static struct blitscrt_gadget *g_gadget;

static void on_signal(int sig)
{
	(void)sig;
	blitscrt_gadget_stop(g_gadget);
}

int main(int argc, char **argv)
{
	const char *ffs = (argc > 1) ? argv[1] : "/dev/ffs-blitscrt";
	struct blitscrt_dev dev;
	struct blitscrt_fabric *fab;

	fab = blitscrt_fabric_open();
	if (!fab)
		fprintf(stderr, "blitscrtd: no fabric, running protocol only\n");
	else
		fprintf(stderr, "blitscrtd: fabric v%u.%u\n",
			blitscrt_fabric_read(fab, BLITSCRT_REG_VERSION) >> 16,
			blitscrt_fabric_read(fab, BLITSCRT_REG_VERSION) & 0xffff);

	blitscrt_dev_init(&dev, fab);
	blitscrt_dev_on_host(&dev, 0);   /* test card until a host turns up */

	fprintf(stderr, "blitscrtd: advertising %u modes\n", dev.n_modes);

	g_gadget = blitscrt_gadget_open(ffs, &dev);
	if (!g_gadget) {
		fprintf(stderr, "blitscrtd: cannot open %s\n", ffs);
		fprintf(stderr, "           is the gadget mounted? see tools/gadget-setup.sh\n");
		blitscrt_fabric_close(fab);
		return 1;
	}

	signal(SIGINT,  on_signal);
	signal(SIGTERM, on_signal);

	blitscrt_gadget_run(g_gadget);

	fprintf(stderr, "blitscrtd: %lu modesets, %lu rejected, %lu flushes\n",
		dev.stat_modeset, dev.stat_rejected, dev.stat_flush);

	blitscrt_gadget_close(g_gadget);
	blitscrt_fabric_close(fab);
	return 0;
}
