/* SPDX-License-Identifier: GPL-2.0-or-later */
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
#include "fabric.h"
#include "lz4dec.h"

#include <dirent.h>
#include <errno.h>
#include <poll.h>
#include <pthread.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
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

/* High-speed bulk max packet, from the endpoint descriptor. Reads are rounded up
 * to this so a transfer padded past the declared length still arrives in one
 * piece, without the request being large enough to swallow the next one. */
#define BULK_MAXPACKET 512


struct blitscrt_gadget {
	int ep0, ep_out;
	struct blitscrt_dev *dev;
	uint8_t *ep0buf;
	uint8_t *bulk;                      /* the rect, decompressed */
	int running;

	/*
	 * The bulk endpoint gets its own thread.
	 *
	 * A read on a FunctionFS endpoint blocks until the transfer completes,
	 * and doing that on the ep0 thread means no control request can be
	 * answered while a frame is arriving. If the host issues any control
	 * transfer during its flush -- and it may -- both sides wait on each
	 * other: the host never returns from the control request so never
	 * finishes the bulk write, and the daemon never leaves the read. That is
	 * what an indefinite hang with no timeout on either side looks like, and
	 * it is why Linux's own ffs-test.c runs a thread per endpoint.
	 */
	pthread_t       bulk_thread;        /* reads the wire */
	pthread_t       blit_thread;        /* decompresses and blits */
	int             bulk_started;

	/*
	 * A slot pool between the two, so the read of frame N+1 overlaps the
	 * decompress and blit of frame N.
	 *
	 * Measured serially, a frame cost read 1.5 ms, lz4 2.6 ms and blit
	 * 5.6 ms -- 9.5 ms typical against the 16.7 a 60 Hz frame allows, but
	 * 14.7 at worst, which leaves too little for jitter and drops the odd
	 * frame. Overlapping makes it max(read, lz4 + blit) rather than the sum.
	 *
	 * The blit is the fixed part: 614400 bytes into the uncached DDR3 window
	 * at about 110 MB/s, whatever the content. Decompressing straight into
	 * that window instead would not help -- LZ4 emits short scattered
	 * writes, the worst case for write-combining, and that is the
	 * 69-against-110 MB/s gap measured on this board.
	 */
#define NSLOT 2
	struct {
		struct gud_set_buffer_req r;
		uint8_t *wire;              /* as it arrived, maybe compressed */
		size_t   got;               /* bytes actually read */
	} slot[NSLOT];
	unsigned sin, sout;                 /* sin - sout = slots filled */
	/* Reporting only, written by the reader and read by the processor
	 * without the lock. A torn double would misprint one line and nothing
	 * else depends on it; taking the lock on every frame to tidy a log
	 * message would be the worse trade. */
	double   ms_read, ms_wait, ms_xfer, mbs;
	pthread_cond_t slot_free, slot_full;

	/*
	 * The fabric is not thread-safe. The gp transport carries a strobe
	 * parity across calls, so two threads issuing commands would corrupt
	 * each other's transactions -- and on a DDR3 build the blit is a plain
	 * memcpy that never touches gp, which would make this a race that only
	 * appears on on-chip builds. Serialise it rather than leave that lying.
	 */
	pthread_mutex_t fablock;

	pthread_mutex_t lock;
	pthread_cond_t  work;               /* signalled when a rect is queued */

	/*
	 * A queue, not a single slot.
	 *
	 * GUD sends SET_BUFFER and then the pixels, but the control request
	 * completes on the ep0 thread the moment it is answered -- while this
	 * thread may still be reading the previous rect. So the host can get a
	 * frame ahead, and a single slot loses the older header while its data
	 * is still on the wire. Everything after that is decoded against the
	 * wrong length: blocks that fail outright, or worse, blocks that decode
	 * to a plausible but wrong size.
	 *
	 * The wire is FIFO, so the headers must be too. Overflow is not
	 * recoverable -- the stream would desynchronise exactly as before -- so
	 * it is reported rather than papered over.
	 */
#define RECTQ 16
	struct gud_set_buffer_req rectq[RECTQ];
	unsigned qhead, qtail;              /* qhead == qtail means empty */
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

/* Every control request, on one line each, when BLITSCRT_TRACE is set.
 *
 * The log used to stop at "host attached" with no indication of what came next
 * -- a modeset that worked logs nothing, and one that never arrived logs nothing
 * either. Telling those apart from the outside is impossible, and guessing at it
 * cost several rebuilds. */
static int trace_on(void)
{
	static int v = -1;
	if (v < 0) v = getenv("BLITSCRT_TRACE") ? 1 : 0;
	return v;
}

#define TRACE(...) do { if (trace_on()) { \
	fprintf(stderr, "  trace: " __VA_ARGS__); fflush(stderr); } } while (0)

static void handle_setup(struct blitscrt_gadget *g,
			 const struct usb_ctrlrequest *ctrl)
{
	uint16_t len = le16toh(ctrl->wLength);
	uint16_t value = le16toh(ctrl->wValue);
	uint16_t index = le16toh(ctrl->wIndex);
	int n;

	TRACE("ctrl %s req=0x%02x val=0x%04x idx=0x%04x len=%u\n",
	      (ctrl->bRequestType & USB_DIR_IN) ? "IN " : "OUT",
	      ctrl->bRequest, value, index, len);

	if ((ctrl->bRequestType & USB_TYPE_MASK) != USB_TYPE_VENDOR) {
		/* not ours; stall and let the host move on */
		ep0_stall(g, ctrl->bRequestType & USB_DIR_IN);
		return;
	}

	if (ctrl->bRequestType & USB_DIR_IN) {
		/* Control handling reaches the fabric -- a modeset writes
		 * registers and reconfigures the PLL -- and the bulk worker
		 * reaches it too. Same lock, or the gp strobe parity gets
		 * corrupted by whichever interleaves. */
		pthread_mutex_lock(&g->fablock);
		n = blitscrt_handle_ctrl(g->dev, ctrl->bRequest, value, index,
					 NULL, 0, g->ep0buf, EP0_BUF);
		pthread_mutex_unlock(&g->fablock);
		if (n < 0) {
			ep0_stall(g, 1);
			return;
		}
		if (n > len)
			n = len;
		TRACE("  -> %d bytes\n", n);
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
		pthread_mutex_lock(&g->fablock);
		n = blitscrt_handle_ctrl(g->dev, ctrl->bRequest, value, index,
					 g->ep0buf, (uint16_t)got, NULL, 0);
		pthread_mutex_unlock(&g->fablock);
		TRACE("  -> %s (status 0x%02x)\n", n < 0 ? "STALL" : "ok",
		      g->dev->last_status);
		if (n < 0)
			ep0_stall(g, 0);
	}
}

/* ---------------- bulk pixel data ---------------- */

/*
 * Drain one rect and put it on screen.
 *
 * Two things this must not do. It must not block for the whole transfer: the
 * fabric watchdog needs a heartbeat every few hundred milliseconds, and a
 * blocking read of a 600 KB frame silently stops it -- the overlay reverts to
 * NO HPS HEARTBEAT while the daemon is alive and simply waiting. And it must not
 * return without draining, or the host's URB never completes and it gives up
 * with ETIMEDOUT, taking the compositor with it.
 *
 * So it polls, takes what has arrived, and ticks the heartbeat between reads.
 * The blit happens once the whole rect is in, because scanout is live: a
 * partial copy would be visible as a torn band.
 */
/*
 * The bulk thread. Waits for a rect, reads it whole, blits it, repeats.
 *
 * Blocking reads are correct here -- a read is what queues the USB request, and
 * without one queued the controller NAKs the host. What was wrong before was
 * doing it on the ep0 thread. In chunks because one read is one USB request and
 * dwc2 cannot carry a 600 KB frame in a single one.
 */
/* Monotonic microseconds, for the frame timing below. */
static uint64_t now_us(void)
{
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	return (uint64_t)t.tv_sec * 1000000u + (uint64_t)t.tv_nsec / 1000u;
}

/*
 * Reader: header from the queue, pixels off the wire, into a free slot.
 *
 * Only this thread touches the endpoint. It never decompresses and never blits,
 * so the read of frame N+1 proceeds while the other thread is still working on
 * frame N.
 */
static void *bulk_worker(void *arg)
{
	struct blitscrt_gadget *g = arg;
	uint64_t t_read = 0, t_wait = 0, t_xfer = 0, t_bytes = 0, t_first;
	unsigned frames = 0;

	for (;;) {
		struct gud_set_buffer_req r;
		size_t want, done = 0;
		unsigned idx;
		uint64_t t0;
		int compressed;

		pthread_mutex_lock(&g->lock);
		while (g->qhead == g->qtail && g->running)
			pthread_cond_wait(&g->work, &g->lock);
		if (!g->running) { pthread_mutex_unlock(&g->lock); break; }
		r = g->rectq[g->qtail % RECTQ];
		g->qtail++;

		/* Wait for somewhere to put it. */
		while (g->sin - g->sout >= NSLOT && g->running)
			pthread_cond_wait(&g->slot_free, &g->lock);
		if (!g->running) { pthread_mutex_unlock(&g->lock); break; }
		idx = g->sin % NSLOT;
		pthread_mutex_unlock(&g->lock);

		compressed = (r.compression & GUD_COMPRESSION_LZ4) != 0;
		want = compressed ? r.compressed_length : r.length;

		if (want > BULK_BUF || r.length > BULK_BUF) {
			/* Dropping the header leaves its pixels on the wire and
			 * desynchronises everything after it, so this is not a
			 * recoverable case -- but BULK_BUF is a megabyte and the
			 * largest advertised mode is 720 KB uncompressed, so it
			 * should not arise. Say so if it ever does. */
			fprintf(stderr, "blitscrtd: rect of %u bytes (%zu on the "
					"wire) exceeds the %d-byte buffer -- the "
					"stream will not recover\n",
				r.length, want, BULK_BUF);
			continue;
		}

		TRACE("bulk %ux%u at %u,%u, %zu bytes on the wire, "
		      "%u decompressed, compression=%u\n",
		      r.width, r.height, r.x, r.y, want, r.length, r.compression);

		t0 = now_us();
		t_first = 0;

		/*
		 * The request size has to be judged, not guessed, and both
		 * obvious answers are wrong.
		 *
		 * Ask for exactly compressed_length and the kernel splits when
		 * the transfer is a little larger:
		 *
		 *   functionfs read size 9725 > requested size 9645,
		 *   splitting request into multiple reads.
		 *
		 * The remainder stays queued and every later read is offset.
		 *
		 * Ask for the whole buffer and the opposite happens -- one read
		 * returns everything queued, spanning many rects:
		 *
		 *   read 1048576, header said 4741
		 *
		 * so a dozen frames of pixels are consumed as if they belonged
		 * to this one. Both end the same way: the header and the data
		 * stop lining up, and nothing after that decodes.
		 *
		 * Round up to a packet boundary instead. Large enough to absorb
		 * a transfer padded past the declared length, small enough that
		 * it cannot reach into the frame behind it.
		 */
		while (done < want) {
			size_t ask = want - done;
			ssize_t got;

			ask = (ask + BULK_MAXPACKET - 1) &
			      ~(size_t)(BULK_MAXPACKET - 1);
			if (ask > BULK_BUF - done)
				ask = BULK_BUF - done;

			got = read(g->ep_out, g->slot[idx].wire + done, ask);
			if (got < 0) {
				if (errno == EINTR)
					continue;
				if (errno != ESHUTDOWN)
					fprintf(stderr, "blitscrtd: bulk read "
							"failed at %zu of %zu: "
							"%s\n", done, want,
						strerror(errno));
				done = 0;
				break;
			}
			if (got == 0)
				break;          /* host gave up mid-rect */
			/*
			 * When the first bytes land, split the wait from the
			 * transfer. A slow link and a host that is slow to start
			 * look identical in the total, and they are entirely
			 * different problems.
			 */
			if (!t_first)
				t_first = now_us();
			done += (size_t)got;
		}

		{
			uint64_t now = now_us();
			t_wait  += (t_first ? t_first : now) - t0;
			t_xfer  += t_first ? (now - t_first) : 0;
			t_bytes += done;
			t_read  += now - t0;
		}

		if (done != want)
			TRACE("  read %zu, header said %zu\n", done, want);

		if (done < want)
			continue;               /* nothing worth handing on */

		g->slot[idx].r   = r;
		g->slot[idx].got = done;

		pthread_mutex_lock(&g->lock);
		g->sin++;
		pthread_cond_signal(&g->slot_full);
		pthread_mutex_unlock(&g->lock);

		if (++frames >= 60) {
			g->ms_read = t_read / 60000.0;
			g->ms_wait = t_wait / 60000.0;
			g->ms_xfer = t_xfer / 60000.0;
			/* MB/s while bytes were actually moving. */
			g->mbs     = t_xfer ? (double)t_bytes / (double)t_xfer
					    : 0.0;
			t_read = t_wait = t_xfer = t_bytes = 0;
			frames = 0;
		}
	}
	return NULL;
}

/*
 * Processor: decompress a filled slot and put it on screen.
 *
 * Runs behind the reader, so its cost overlaps the next frame arriving instead
 * of adding to it.
 */
static void *blit_worker(void *arg)
{
	struct blitscrt_gadget *g = arg;
	struct blitscrt_dev *d = g->dev;
	uint64_t t_lz4 = 0, t_blit = 0, t_wall = 0;
	unsigned frames = 0;

	for (;;) {
		struct gud_set_buffer_req r;
		const uint8_t *px;
		size_t got;
		unsigned idx;
		uint64_t t0, t1;

		pthread_mutex_lock(&g->lock);
		while (g->sin == g->sout && g->running)
			pthread_cond_wait(&g->slot_full, &g->lock);
		if (!g->running) { pthread_mutex_unlock(&g->lock); break; }
		idx = g->sout % NSLOT;
		pthread_mutex_unlock(&g->lock);

		if (t_wall == 0)
			t_wall = now_us();

		r   = g->slot[idx].r;
		got = g->slot[idx].got;
		px  = g->slot[idx].wire;

		t0 = now_us();
		if (r.compression & GUD_COMPRESSION_LZ4) {
			/* Exactly compressed_length, not whatever arrived: a
			 * transfer can carry padding past the block, and the
			 * decompressor would read that as another sequence. */
			long n = blitscrt_lz4_decompress(px, got,
							 g->bulk, BULK_BUF);
			if (n < 0 || (uint32_t)n != r.length) {
				fprintf(stderr, "blitscrtd: LZ4 block bad -- "
						"%zu bytes in, expected %u out, "
						"got %ld\n", got, r.length, n);
				goto release;
			}
			TRACE("  lz4 %zu -> %ld (%.2fx)\n", got, n,
			      (double)n / (double)got);
			px = g->bulk;
		}
		t1 = now_us();
		t_lz4 += t1 - t0;
		t0 = t1;

		/* Into scanout memory. blit routes on CAPS, so on a DDR3 build
		 * this is a row-granular memcpy into the window the fetcher is
		 * already reading -- nothing has to tell the fabric. */
		if (d->fabric) {
			pthread_mutex_lock(&g->fablock);
			blitscrt_scanout_blit(d->fabric, r.x, r.y,
					      r.width, r.height,
					      (const uint16_t *)px);
			pthread_mutex_unlock(&g->fablock);
		}
		t_blit += now_us() - t0;
		d->stat_flush++;

		if (++frames >= 60) {
			/*
			 * Achieved rate as well as cost. The costs say what the
			 * daemon spends; the wall time says what actually
			 * arrived. Once the critical path sits well inside the
			 * frame budget, a gap between the two is the host not
			 * producing frames rather than this end failing to keep
			 * up -- and no amount of work here would close it.
			 */
			double wall = (now_us() - t_wall) / 1e6;

			/*
			 * The mode, on every line. blitscrt-peek cannot be used
			 * while the daemon runs, and stopping it clears
			 * HPS_TIMING -- so a peek always reports the front-panel
			 * table whatever was actually on screen. The overlay
			 * would say, but it hides itself when a host attaches.
			 * This is the only place the running mode is visible.
			 */
			fprintf(stderr, "blitscrtd: %ux%u%s %s -- ",
				d->active_valid ? d->active_mode.hdisplay : 0,
				d->active_valid ? d->active_mode.vdisplay : 0,
				(d->active_valid &&
				 (d->active_mode.flags & BLITSCRT_MF_INTERLACE))
					? "i" : "p",
				d->active_valid ? "host timing" : "NO MODE SET");

			fprintf(stderr, "%.1f fps -- wait %.1f ms, "
					"xfer %.1f ms at %.1f MB/s, lz4 %.1f ms, "
					"blit %.1f ms, critical path %.1f of "
					"%.1f available\n",
				wall > 0 ? 60.0 / wall : 0.0,
				g->ms_wait, g->ms_xfer, g->mbs,
				t_lz4 / 60000.0, t_blit / 60000.0,
				(t_lz4 + t_blit) / 60000.0,
				wall > 0 ? wall * 1000.0 / 60.0 : 0.0);
			fflush(stderr);
			t_lz4 = t_blit = 0;
			t_wall = 0;
			frames = 0;
		}

release:
		pthread_mutex_lock(&g->lock);
		g->sout++;
		pthread_cond_signal(&g->slot_free);
		pthread_mutex_unlock(&g->lock);
	}
	return NULL;
}

/* Hand the rect to the bulk thread and return at once, so ep0 keeps being
 * serviced while the frame arrives. */
static void handle_bulk(struct blitscrt_gadget *g)
{
	struct blitscrt_dev *d = g->dev;

	if (!d->buffer_valid)
		return;

	pthread_mutex_lock(&g->lock);
	if (g->qhead - g->qtail >= RECTQ) {
		/* Nothing sensible to do: dropping the header leaves its pixels
		 * on the wire and desynchronises everything after it. Say so
		 * loudly rather than produce quiet corruption. */
		fprintf(stderr, "blitscrtd: rect queue full (%u deep); the host "
				"is more than %d frames ahead\n",
			g->qhead - g->qtail, RECTQ);
	} else {
		g->rectq[g->qhead % RECTQ] = d->buffer;
		g->qhead++;
		pthread_cond_signal(&g->work);
	}
	pthread_mutex_unlock(&g->lock);

	d->buffer_valid = 0;
}

/* ---------------- event loop ---------------- */

/*
 * The configfs gadget directory, which gadget-setup.sh creates. Writing a UDC
 * name into its UDC file attaches the gadget to the controller; writing an empty
 * string detaches it.
 */
#define GADGET_DIR "/sys/kernel/config/usb_gadget/blitscrt"

static int udc_name(char *out, size_t n)
{
	DIR *d = opendir("/sys/class/udc");
	struct dirent *e;
	int found = 0;

	if (!d) {
		fprintf(stderr, "blitscrtd: /sys/class/udc missing -- no gadget "
				"controller. dwc2 is probably still in host mode; "
				"dr_mode must be peripheral.\n");
		return -1;
	}
	while ((e = readdir(d))) {
		if (e->d_name[0] == '.') continue;
		snprintf(out, n, "%s", e->d_name);
		found = 1;
		break;
	}
	closedir(d);
	if (!found)
		fprintf(stderr, "blitscrtd: /sys/class/udc is empty -- no gadget "
				"controller registered\n");
	return found ? 0 : -1;
}

static int udc_write(const char *val)
{
	int fd = open(GADGET_DIR "/UDC", O_WRONLY);
	ssize_t w;

	if (fd < 0) return -1;
	w = write(fd, val, strlen(val));
	close(fd);
	return w < 0 ? -1 : 0;
}

static void udc_bind(struct blitscrt_gadget *g)
{
	char name[NAME_MAX + 1];

	(void)g;
	if (udc_name(name, sizeof name) < 0)
		return;
	if (udc_write(name) < 0) {
		fprintf(stderr, "blitscrtd: cannot bind %s (%s) -- is the gadget "
				"staged? run gadget-setup.sh\n",
			name, strerror(errno));
		return;
	}
	fprintf(stderr, "blitscrtd: gadget bound to %s; a host should now "
			"enumerate it\n", name);
}

static void udc_unbind(void)
{
	/* Detach cleanly so the next run can bind again. Leaving it attached
	 * with no daemon behind it gives a host a device that never answers. */
	(void)udc_write("\n");
}

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
	{
		int i;
		for (i = 0; i < NSLOT; i++) {
			g->slot[i].wire = malloc(BULK_BUF);
			if (!g->slot[i].wire) goto fail;
		}
	}

	snprintf(path, sizeof path, "%s/ep0", ffs_path);
	g->ep0 = open(path, O_RDWR);
	if (g->ep0 < 0) { perror(path); goto fail; }

	if (write_descriptors(g->ep0) < 0) goto fail;

	/*
	 * Blocking, and read from its own thread.
	 *
	 * A read is what queues a USB request for the endpoint; until one is
	 * queued the controller NAKs the host, so O_NONBLOCK is worse than
	 * useless here -- EAGAIN means nothing was ever offered. What must not
	 * happen is blocking the ep0 thread while it waits, which is why
	 * bulk_worker exists.
	 */
	snprintf(path, sizeof path, "%s/ep1", ffs_path);
	g->ep_out = open(path, O_RDONLY);
	if (g->ep_out < 0) { perror(path); goto fail; }

	/*
	 * Bind to the UDC now, not before.
	 *
	 * FunctionFS only produces the endpoint files once ep0 has taken the
	 * descriptors, and binding is what makes the gadget visible to a host --
	 * so binding earlier offers a host something with no endpoints behind
	 * it. The daemon is the only thing that knows the descriptors are in,
	 * which is why this lives here rather than in gadget-setup.sh.
	 */
	udc_bind(g);

	g->running = 1;

	pthread_mutex_init(&g->fablock, NULL);
	pthread_mutex_init(&g->lock, NULL);
	pthread_cond_init(&g->work, NULL);
	pthread_cond_init(&g->slot_free, NULL);
	pthread_cond_init(&g->slot_full, NULL);

	if (pthread_create(&g->bulk_thread, NULL, bulk_worker, g) != 0) {
		perror("bulk thread");
		goto fail;
	}
	if (pthread_create(&g->blit_thread, NULL, blit_worker, g) != 0) {
		perror("blit thread");
		g->running = 0;
		pthread_cond_broadcast(&g->work);
		pthread_join(g->bulk_thread, NULL);
		goto fail;
	}
	g->bulk_started = 1;
	return g;

fail:
	blitscrt_gadget_close(g);
	return NULL;
}

void blitscrt_gadget_close(struct blitscrt_gadget *g)
{
	if (!g) return;

	if (g->bulk_started) {
		/* Wake both so they see running == 0 and return. Closing the
		 * endpoint under the reader would leave it in a read that never
		 * completes. broadcast, not signal: either thread may be waiting
		 * on any of the three conditions. */
		pthread_mutex_lock(&g->lock);
		g->running = 0;
		pthread_cond_broadcast(&g->work);
		pthread_cond_broadcast(&g->slot_free);
		pthread_cond_broadcast(&g->slot_full);
		pthread_mutex_unlock(&g->lock);
		pthread_join(g->bulk_thread, NULL);
		pthread_join(g->blit_thread, NULL);
		pthread_mutex_destroy(&g->lock);
		pthread_mutex_destroy(&g->fablock);
		pthread_cond_destroy(&g->work);
		pthread_cond_destroy(&g->slot_free);
		pthread_cond_destroy(&g->slot_full);
	}

	udc_unbind();
	if (g->ep_out >= 0) close(g->ep_out);
	if (g->ep0 >= 0) close(g->ep0);
	free(g->ep0buf);
	free(g->bulk);
	{
		int i;
		for (i = 0; i < NSLOT; i++)
			free(g->slot[i].wire);
	}
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
				/* Drop anything queued; the next host starts
				 * from nothing and stale headers would be
				 * matched against its first frames. */
				/*
				 * Drop the pending headers only. The slot
				 * indices are deliberately left alone: the
				 * processor may be between taking a slot and
				 * releasing it, and resetting them under it
				 * makes its sout++ overshoot sin. Both are
				 * unsigned, so sin - sout wraps to a huge
				 * number, the reader sees a pool that is
				 * permanently full, and the daemon hangs on
				 * host detach.
				 *
				 * Whatever is already in the pool just gets
				 * blitted -- a frame or two of stale pixels
				 * behind a host that has gone away, which
				 * nobody will see.
				 */
				pthread_mutex_lock(&g->lock);
				g->qhead = g->qtail = 0;
				pthread_mutex_unlock(&g->lock);
				g->dev->buffer_valid = 0;
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

		pthread_mutex_lock(&g->fablock);
		blitscrt_dev_heartbeat(g->dev);
		pthread_mutex_unlock(&g->fablock);
	}
	return 0;
}

void blitscrt_gadget_stop(struct blitscrt_gadget *g)
{
	if (g) g->running = 0;
}
