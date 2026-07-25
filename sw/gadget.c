/* SPDX-License-Identifier: MIT */
/*
 * gadget.c -- FunctionFS transport for the GUD device side.
 *
 * Moves bytes between ep0 and device.c and nothing more. Keeping the protocol
 * out of here is what lets the whole control surface be tested without USB.
 *
 * The Linux gadget cannot control the status stage of a control OUT that
 * carries a payload, which is why the descriptor sets STATUS_ON_SET and the
 * host follows every SET with a GET_STATUS.
 */

#define _GNU_SOURCE
#include "gadget.h"
#include "device.h"

#include <errno.h>
#include <poll.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/types.h>
#include <linux/usb/ch9.h>
#include <linux/usb/functionfs.h>

/*
 * htole32 is not constant-foldable in a static initialiser on glibc, so the
 * descriptors use the same conditional macros the kernel's own FunctionFS
 * examples do. ARM is little-endian and these reduce to identity.
 */
#include <endian.h>
#if __BYTE_ORDER == __LITTLE_ENDIAN
#define cpu_to_le32(x)  (x)
#define cpu_to_le16(x)  (x)
#else
#define cpu_to_le32(x)  __builtin_bswap32(x)
#define cpu_to_le16(x)  __builtin_bswap16(x)
#endif

#define EP0_BUF   4096
#define BULK_BUF  (1024 * 1024)

struct blitscrt_gadget {
	int ep0, ep_out;
	struct blitscrt_dev *dev;
	uint8_t *ep0buf;
	uint8_t *bulk;
	int running;
};

/* ---------------- descriptors ---------------- */

struct ffs_desc {
	struct usb_functionfs_descs_head_v2 header;
	__le32 fs_count, hs_count;
	struct {
		struct usb_interface_descriptor intf;
		struct usb_endpoint_descriptor_no_audio bulk_out;
	} __attribute__((packed)) fs, hs;
} __attribute__((packed));

#define STR_INTERFACE "blitsCRT_Mister"

struct ffs_strings {
	struct usb_functionfs_strings_head header;
	struct {
		__le16 code;
		char str[sizeof STR_INTERFACE];
	} __attribute__((packed)) lang0;
} __attribute__((packed));

static int write_descriptors(int ep0)
{
	static const struct ffs_desc desc = {
		.header = {
			.magic  = cpu_to_le32(FUNCTIONFS_DESCRIPTORS_MAGIC_V2),
			.length = cpu_to_le32(sizeof desc),
			.flags  = cpu_to_le32(FUNCTIONFS_HAS_FS_DESC |
					  FUNCTIONFS_HAS_HS_DESC),
		},
		.fs_count = cpu_to_le32(2),
		.hs_count = cpu_to_le32(2),
		.fs = {
			.intf = {
				.bLength = sizeof desc.fs.intf,
				.bDescriptorType = USB_DT_INTERFACE,
				.bNumEndpoints = 1,
				.bInterfaceClass = USB_CLASS_VENDOR_SPEC,
				.iInterface = 1,
			},
			.bulk_out = {
				.bLength = sizeof desc.fs.bulk_out,
				.bDescriptorType = USB_DT_ENDPOINT,
				.bEndpointAddress = 1 | USB_DIR_OUT,
				.bmAttributes = USB_ENDPOINT_XFER_BULK,
				.wMaxPacketSize = cpu_to_le16(64),
			},
		},
		.hs = {
			.intf = {
				.bLength = sizeof desc.hs.intf,
				.bDescriptorType = USB_DT_INTERFACE,
				.bNumEndpoints = 1,
				.bInterfaceClass = USB_CLASS_VENDOR_SPEC,
				.iInterface = 1,
			},
			.bulk_out = {
				.bLength = sizeof desc.hs.bulk_out,
				.bDescriptorType = USB_DT_ENDPOINT,
				.bEndpointAddress = 1 | USB_DIR_OUT,
				.bmAttributes = USB_ENDPOINT_XFER_BULK,
				.wMaxPacketSize = cpu_to_le16(512),
			},
		},
	};

	static const struct ffs_strings strings = {
		.header = {
			.magic  = cpu_to_le32(FUNCTIONFS_STRINGS_MAGIC),
			.length = cpu_to_le32(sizeof strings),
			.str_count = cpu_to_le32(1),
			.lang_count = cpu_to_le32(1),
		},
		.lang0 = { cpu_to_le16(0x0409), STR_INTERFACE },
	};

	if (write(ep0, &desc, sizeof desc) < 0) {
		perror("write descriptors");
		return -1;
	}
	if (write(ep0, &strings, sizeof strings) < 0) {
		perror("write strings");
		return -1;
	}
	return 0;
}

/* ---------------- control transfers ---------------- */

/* A zero-length transfer in the wrong direction is how FunctionFS is told to
 * stall the control endpoint. The return value carries nothing. */
static void ep0_stall(struct blitscrt_gadget *g, int dir_in)
{
	ssize_t r;
	if (dir_in) r = read(g->ep0, NULL, 0);
	else        r = write(g->ep0, NULL, 0);
	(void)r;
}

static void handle_setup(struct blitscrt_gadget *g,
			 const struct usb_ctrlrequest *ctrl)
{
	uint16_t len = le16toh(ctrl->wLength);
	uint16_t value = le16toh(ctrl->wValue);
	uint16_t index = le16toh(ctrl->wIndex);
	int n;

	if ((ctrl->bRequestType & USB_TYPE_MASK) != USB_TYPE_VENDOR) {
		/* not ours; stall and let the host move on */
		ep0_stall(g, ctrl->bRequestType & USB_DIR_IN);
		return;
	}

	if (ctrl->bRequestType & USB_DIR_IN) {
		n = blitscrt_handle_ctrl(g->dev, ctrl->bRequest, value, index,
					 NULL, 0, g->ep0buf, EP0_BUF);
		if (n < 0) {
			ep0_stall(g, 1);
			return;
		}
		if (n > len)
			n = len;
		if (write(g->ep0, g->ep0buf, n) < 0)
			perror("ep0 write");
	} else {
		ssize_t got = 0;
		if (len) {
			if (len > EP0_BUF)
				len = EP0_BUF;
			got = read(g->ep0, g->ep0buf, len);
			if (got < 0) {
				perror("ep0 read");
				return;
			}
		}
		n = blitscrt_handle_ctrl(g->dev, ctrl->bRequest, value, index,
					 g->ep0buf, (uint16_t)got, NULL, 0);
		if (n < 0)
			ep0_stall(g, 0);
	}
}

/* ---------------- bulk pixel data ---------------- */

static void handle_bulk(struct blitscrt_gadget *g)
{
	struct blitscrt_dev *d = g->dev;
	ssize_t got;
	size_t want;

	if (!d->buffer_valid)
		return;

	want = d->buffer.length;
	if (want > BULK_BUF)
		want = BULK_BUF;

	got = read(g->ep_out, g->bulk, want);
	if (got < 0) {
		if (errno != EAGAIN && errno != EINTR && errno != ESHUTDOWN)
			perror("bulk read");
		return;
	}

	/*
	 * The rect lands at buffer.x/y in the framebuffer. Once the SDRAM
	 * path exists this becomes a strided copy into scanout memory; for
	 * now the transfer is drained and counted so the host stays happy.
	 */
	d->stat_flush++;
	d->buffer_valid = 0;
}

/* ---------------- event loop ---------------- */

struct blitscrt_gadget *blitscrt_gadget_open(const char *ffs_path,
					     struct blitscrt_dev *dev)
{
	struct blitscrt_gadget *g;
	char path[512];

	g = calloc(1, sizeof *g);
	if (!g) return NULL;
	g->dev = dev;
	g->ep0 = g->ep_out = -1;

	g->ep0buf = malloc(EP0_BUF);
	g->bulk   = malloc(BULK_BUF);
	if (!g->ep0buf || !g->bulk) goto fail;

	snprintf(path, sizeof path, "%s/ep0", ffs_path);
	g->ep0 = open(path, O_RDWR);
	if (g->ep0 < 0) { perror(path); goto fail; }

	if (write_descriptors(g->ep0) < 0) goto fail;

	snprintf(path, sizeof path, "%s/ep1", ffs_path);
	g->ep_out = open(path, O_RDONLY);
	if (g->ep_out < 0) { perror(path); goto fail; }

	g->running = 1;
	return g;

fail:
	blitscrt_gadget_close(g);
	return NULL;
}

void blitscrt_gadget_close(struct blitscrt_gadget *g)
{
	if (!g) return;
	if (g->ep_out >= 0) close(g->ep_out);
	if (g->ep0 >= 0) close(g->ep0);
	free(g->ep0buf);
	free(g->bulk);
	free(g);
}

int blitscrt_gadget_run(struct blitscrt_gadget *g)
{
	struct usb_functionfs_event ev[8];
	struct pollfd pfd = { .fd = g->ep0, .events = POLLIN };
	ssize_t n;
	int i;

	while (g->running) {
		/*
		 * Wake at least a few times a second even with no USB activity,
		 * so the fabric heartbeat keeps ticking while idle. Without the
		 * timeout the read blocks until a host does something, and the
		 * fabric would decide the daemon had died.
		 */
		int pr = poll(&pfd, 1, 250);
		if (pr == 0) {
			blitscrt_dev_heartbeat(g->dev);
			continue;
		}
		if (pr < 0) {
			if (errno == EINTR) continue;
			perror("ep0 poll");
			return -1;
		}

		n = read(g->ep0, ev, sizeof ev);
		if (n < 0) {
			if (errno == EINTR) continue;
			perror("ep0 event read");
			return -1;
		}

		for (i = 0; i < (int)(n / sizeof ev[0]); i++) {
			switch (ev[i].type) {
			case FUNCTIONFS_SETUP:
				handle_setup(g, &ev[i].u.setup);
				break;
			case FUNCTIONFS_ENABLE:
				fprintf(stderr, "blitscrt: host attached\n");
				blitscrt_dev_on_host(g->dev, 1);
				break;
			case FUNCTIONFS_DISABLE:
				fprintf(stderr, "blitscrt: host detached\n");
				blitscrt_dev_on_host(g->dev, 0);
				break;
			case FUNCTIONFS_SUSPEND:
			case FUNCTIONFS_RESUME:
			case FUNCTIONFS_BIND:
			case FUNCTIONFS_UNBIND:
				break;
			}
		}

		if (g->dev->buffer_valid)
			handle_bulk(g);

		blitscrt_dev_heartbeat(g->dev);
	}
	return 0;
}

void blitscrt_gadget_stop(struct blitscrt_gadget *g)
{
	if (g) g->running = 0;
}
