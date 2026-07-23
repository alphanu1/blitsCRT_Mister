/* Walk the sequence a GUD host actually performs, then the dynamic-resolution
 * path that Switchres would drive. No USB, no hardware. */
#include <stdio.h>
#include <string.h>
#include "../device.h"

static struct blitscrt_dev dev;
static uint8_t buf[4096];
static int fails;

static int req(uint8_t r, uint16_t v, const void *d, uint16_t dl)
{
	return blitscrt_handle_ctrl(&dev, r, v, 0, d, dl, buf, sizeof buf);
}

static void check(const char *what, int cond)
{
	printf("  %-52s %s\n", what, cond ? "ok" : "FAIL");
	if (!cond) fails++;
}

int main(void)
{
	int n;

	blitscrt_dev_init(&dev, NULL);

	printf("host enumeration\n");

	n = req(GUD_REQ_GET_DESCRIPTOR, 0, NULL, 0);
	{
		struct gud_display_descriptor_req r;
		memcpy(&r, buf, sizeof r);
		check("GET_DESCRIPTOR returns the right size",
		      n == (int)sizeof r);
		check("magic is 0x1d50614d", r.magic == GUD_DISPLAY_MAGIC);
		check("STATUS_ON_SET set for the Linux gadget",
		      (r.flags & GUD_DISPLAY_FLAG_STATUS_ON_SET) != 0);
		check("compression declined", r.compression == 0);
		printf("        %ux%u .. %ux%u\n", r.min_width, r.min_height,
		       r.max_width, r.max_height);
	}

	n = req(GUD_REQ_GET_FORMATS, 0, NULL, 0);
	check("GET_FORMATS offers RGB888 first, matching the RGB666 ladder",
	      n == 3 && buf[0] == GUD_PIXEL_FORMAT_RGB888);
	check("RGB565 and RGB332 also offered",
	      buf[1] == GUD_PIXEL_FORMAT_RGB565 && buf[2] == GUD_PIXEL_FORMAT_RGB332);

	n = req(GUD_REQ_GET_CONNECTORS, 0, NULL, 0);
	{
		struct gud_connector_descriptor_req c;
		memcpy(&c, buf, sizeof c);
		check("connector reports as VGA",
		      c.connector_type == GUD_CONNECTOR_TYPE_VGA);
		check("INTERLACE flag set, or 480i is never offered",
		      (c.flags & GUD_CONNECTOR_FLAGS_INTERLACE) != 0);
	}

	n = req(GUD_REQ_GET_CONNECTOR_STATUS, 0, NULL, 0);
	check("connector reports connected",
	      n == 1 && (buf[0] & GUD_CONNECTOR_STATUS_CONNECTED_MASK)
			== GUD_CONNECTOR_STATUS_CONNECTED);

	n = req(GUD_REQ_GET_CONNECTOR_MODES, 0, NULL, 0);
	{
		unsigned count = n / sizeof(struct gud_display_mode_req);
		struct gud_display_mode_req m[BLITSCRT_MAX_MODES];
		unsigned i;
		memcpy(m, buf, n);
		check("mode list is non-empty", count > 0);
		printf("        %u modes advertised:\n", count);
		for (i = 0; i < count; i++)
			printf("          %4ux%-4u %6u kHz  htotal %4u vtotal %4u %s\n",
			       m[i].hdisplay, m[i].vdisplay, m[i].clock,
			       m[i].htotal, m[i].vtotal,
			       (m[i].flags & GUD_DISPLAY_MODE_FLAG_INTERLACE) ? "interlaced" : "");
	}

	printf("\nmodeset to an advertised mode\n");
	{
		struct gud_state_req s;
		memset(&s, 0, sizeof s);
		s.mode.clock = 6400;
		s.mode.hdisplay = 320; s.mode.hsync_start = 344;
		s.mode.hsync_end = 374; s.mode.htotal = 406;
		s.mode.vdisplay = 240; s.mode.vsync_start = 243;
		s.mode.vsync_end = 246; s.mode.vtotal = 262;
		s.format = GUD_PIXEL_FORMAT_RGB565;

		check("SET_STATE_CHECK accepts",
		      req(GUD_REQ_SET_STATE_CHECK, 0, &s, sizeof s) == 0);
		check("GET_STATUS reports OK",
		      req(GUD_REQ_GET_STATUS, 0, NULL, 0) == 1 &&
		      buf[0] == GUD_STATUS_OK);
		check("SET_STATE_COMMIT applies",
		      req(GUD_REQ_SET_STATE_COMMIT, 0, NULL, 0) == 0);
		printf("        PLL M=%u N=%u C=%u -> %llu Hz (%+lld ppm)\n",
		       dev.active_timing.pll.m, dev.active_timing.pll.n,
		       dev.active_timing.pll.c, dev.active_timing.pll.actual_hz,
		       dev.active_timing.pll.error_ppm);
		check("fabric timing matches the RTL parameters",
		      dev.active_timing.h_sy == 30 && dev.active_timing.h_bp == 32 &&
		      dev.active_timing.h_act == 320 && dev.active_timing.h_fp == 24 &&
		      dev.active_timing.v_sy == 3  && dev.active_timing.v_bp == 16 &&
		      dev.active_timing.v_act == 240 && dev.active_timing.v_fp == 3);
	}

	{
		uint8_t on = 1;
		check("SET_CONTROLLER_ENABLE",
		      req(GUD_REQ_SET_CONTROLLER_ENABLE, 0, &on, 1) == 0);
		check("SET_DISPLAY_ENABLE",
		      req(GUD_REQ_SET_DISPLAY_ENABLE, 0, &on, 1) == 0);
	}

	printf("\nframebuffer flush\n");
	{
		struct gud_set_buffer_req b;
		memset(&b, 0, sizeof b);
		b.x = 0; b.y = 0; b.width = 320; b.height = 240;
		b.length = 320 * 240 * 2;
		check("SET_BUFFER accepts a full-frame rect",
		      req(GUD_REQ_SET_BUFFER, 0, &b, sizeof b) == 0);

		b.x = 300; b.width = 64;                 /* runs off the right edge */
		check("SET_BUFFER rejects a rect outside the mode",
		      req(GUD_REQ_SET_BUFFER, 0, &b, sizeof b) < 0);
		check("and reports INVALID_PARAMETER",
		      req(GUD_REQ_GET_STATUS, 0, NULL, 0) == 1 &&
		      buf[0] == GUD_STATUS_INVALID_PARAMETER);
	}

	printf("\nrefusing what the CRT cannot take\n");
	{
		struct gud_state_req s;
		memset(&s, 0, sizeof s);
		s.mode.clock = 25175;                     /* 640x480p60, 31.5 kHz */
		s.mode.hdisplay = 640; s.mode.hsync_start = 656;
		s.mode.hsync_end = 752; s.mode.htotal = 800;
		s.mode.vdisplay = 480; s.mode.vsync_start = 490;
		s.mode.vsync_end = 492; s.mode.vtotal = 525;
		s.format = GUD_PIXEL_FORMAT_RGB565;

		check("SET_STATE_CHECK stalls on a 31kHz mode",
		      req(GUD_REQ_SET_STATE_CHECK, 0, &s, sizeof s) < 0);
		check("status is INVALID_PARAMETER",
		      req(GUD_REQ_GET_STATUS, 0, NULL, 0) == 1 &&
		      buf[0] == GUD_STATUS_INVALID_PARAMETER);
		check("COMMIT after a failed CHECK is refused",
		      req(GUD_REQ_SET_STATE_COMMIT, 0, NULL, 0) < 0);
		check("the previous mode is still live", dev.active_valid == 1);
	}

	printf("\ndynamic resolution, the Switchres path\n");
	{
		struct blitscrt_mode nm;
		struct gud_state_req s;
		unsigned before, after;

		n = req(GUD_REQ_GET_CONNECTOR_MODES, 0, NULL, 0);
		before = n / sizeof(struct gud_display_mode_req);

		/* a per-game modeline that was never in the list */
		blitscrt_mode_from_modeline(&nm, 6710, 320, 344, 376, 426,
					    224, 227, 230, 262, 0);
		check("a new 320x224 mode is accepted into the list",
		      blitscrt_modelist_add(&dev, &nm) == 0);

		n = req(GUD_REQ_GET_CONNECTOR_STATUS, 0, NULL, 0);
		check("status now carries CHANGED, forcing a re-probe",
		      (buf[0] & GUD_CONNECTOR_STATUS_CHANGED) != 0);
		n = req(GUD_REQ_GET_CONNECTOR_STATUS, 0, NULL, 0);
		check("CHANGED is one-shot",
		      (buf[0] & GUD_CONNECTOR_STATUS_CHANGED) == 0);

		n = req(GUD_REQ_GET_CONNECTOR_MODES, 0, NULL, 0);
		after = n / sizeof(struct gud_display_mode_req);
		check("the re-read list has grown", after == before + 1);

		/* and a host may set a mode that was never advertised at all */
		memset(&s, 0, sizeof s);
		s.mode.clock = 8000;
		s.mode.hdisplay = 384; s.mode.hsync_start = 408;
		s.mode.hsync_end = 448; s.mode.htotal = 508;
		s.mode.vdisplay = 224; s.mode.vsync_start = 227;
		s.mode.vsync_end = 230; s.mode.vtotal = 262;
		s.format = GUD_PIXEL_FORMAT_RGB565;
		check("an unadvertised 384x224 modeline is accepted",
		      req(GUD_REQ_SET_STATE_CHECK, 0, &s, sizeof s) == 0);
		check("and commits",
		      req(GUD_REQ_SET_STATE_COMMIT, 0, NULL, 0) == 0);
		printf("        now running %ux%u at %.3f kHz / %.2f Hz, PLL %u/%u/%u\n",
		       dev.active_mode.hdisplay, dev.active_mode.vdisplay,
		       dev.active_timing.line_hz / 1000.0,
		       dev.active_timing.field_hz,
		       dev.active_timing.pll.m, dev.active_timing.pll.n,
		       dev.active_timing.pll.c);
	}

	printf("\nunknown request\n");
	check("stalls", req(0x7F, 0, NULL, 0) < 0);
	check("status is REQUEST_NOT_SUPPORTED",
	      req(GUD_REQ_GET_STATUS, 0, NULL, 0) == 1 &&
	      buf[0] == GUD_STATUS_REQUEST_NOT_SUPPORTED);

	printf("\n%lu modesets, %lu rejected\n", dev.stat_modeset, dev.stat_rejected);
	printf("%s\n", fails ? "FAIL" : "PASS");
	return fails ? 1 : 0;
}
