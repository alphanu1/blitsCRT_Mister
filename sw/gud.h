/* SPDX-License-Identifier: MIT */
/*
 * gud.h -- Generic USB Display protocol, device side.
 *
 * Mirrors include/drm/gud.h from the Linux kernel (Copyright 2020 Noralf
 * Trønnes, MIT). Only what the device needs to answer is reproduced here.
 * The host driver has been in-tree since v5.13.
 */
#ifndef BLITSCRT_GUD_H
#define BLITSCRT_GUD_H

#include <stdint.h>

#define GUD_DISPLAY_MAGIC               0x1d50614d

struct gud_display_descriptor_req {
	uint32_t magic;
	uint8_t  version;
	uint32_t flags;
	uint8_t  compression;
	uint32_t max_buffer_size;
	uint32_t min_width, max_width;
	uint32_t min_height, max_height;
} __attribute__((packed));

#define GUD_DISPLAY_FLAG_STATUS_ON_SET  (1u << 0)
#define GUD_DISPLAY_FLAG_FULL_UPDATE    (1u << 1)
#define GUD_COMPRESSION_LZ4             (1u << 0)

struct gud_property_req {
	uint16_t prop;
	uint64_t val;
} __attribute__((packed));

struct gud_display_mode_req {
	uint32_t clock;             /* kHz */
	uint16_t hdisplay, hsync_start, hsync_end, htotal;
	uint16_t vdisplay, vsync_start, vsync_end, vtotal;
	uint32_t flags;
} __attribute__((packed));

#define GUD_DISPLAY_MODE_FLAG_PHSYNC    (1u << 0)
#define GUD_DISPLAY_MODE_FLAG_NHSYNC    (1u << 1)
#define GUD_DISPLAY_MODE_FLAG_PVSYNC    (1u << 2)
#define GUD_DISPLAY_MODE_FLAG_NVSYNC    (1u << 3)
#define GUD_DISPLAY_MODE_FLAG_INTERLACE (1u << 4)
#define GUD_DISPLAY_MODE_FLAG_DBLSCAN   (1u << 5)
#define GUD_DISPLAY_MODE_FLAG_CSYNC     (1u << 6)
#define GUD_DISPLAY_MODE_FLAG_PREFERRED (1u << 10)

struct gud_connector_descriptor_req {
	uint8_t  connector_type;
	uint32_t flags;
} __attribute__((packed));

#define GUD_CONNECTOR_TYPE_PANEL        0
#define GUD_CONNECTOR_TYPE_VGA          1
#define GUD_CONNECTOR_TYPE_COMPOSITE    2
#define GUD_CONNECTOR_TYPE_SVIDEO       3
#define GUD_CONNECTOR_TYPE_COMPONENT    4
#define GUD_CONNECTOR_TYPE_DVI          5
#define GUD_CONNECTOR_TYPE_DISPLAYPORT  6
#define GUD_CONNECTOR_TYPE_HDMI         7

#define GUD_CONNECTOR_FLAGS_POLL_STATUS (1u << 0)
#define GUD_CONNECTOR_FLAGS_INTERLACE   (1u << 1)
#define GUD_CONNECTOR_FLAGS_DOUBLESCAN  (1u << 2)

struct gud_set_buffer_req {
	uint32_t x, y, width, height;
	uint32_t length;
	uint8_t  compression;
	uint32_t compressed_length;
} __attribute__((packed));

struct gud_state_req {
	struct gud_display_mode_req mode;
	uint8_t format;
	uint8_t connector;
	/* struct gud_property_req properties[]; */
} __attribute__((packed));

/* control requests */
#define GUD_REQ_GET_STATUS                      0x00
#define GUD_STATUS_OK                           0x00
#define GUD_STATUS_BUSY                         0x01
#define GUD_STATUS_REQUEST_NOT_SUPPORTED        0x02
#define GUD_STATUS_PROTOCOL_ERROR               0x03
#define GUD_STATUS_INVALID_PARAMETER            0x04
#define GUD_STATUS_ERROR                        0x05

#define GUD_REQ_GET_DESCRIPTOR                  0x01
#define GUD_REQ_GET_FORMATS                     0x40
#define GUD_FORMATS_MAX_NUM                     32
#define GUD_PIXEL_FORMAT_R1                     0x01
#define GUD_PIXEL_FORMAT_R8                     0x08
#define GUD_PIXEL_FORMAT_XRGB1111               0x20
#define GUD_PIXEL_FORMAT_RGB332                 0x30
#define GUD_PIXEL_FORMAT_RGB565                 0x40
#define GUD_PIXEL_FORMAT_RGB888                 0x50
#define GUD_PIXEL_FORMAT_XRGB8888               0x80
#define GUD_PIXEL_FORMAT_ARGB8888               0x81

#define GUD_REQ_GET_PROPERTIES                  0x41
#define GUD_REQ_GET_CONNECTORS                  0x50
#define GUD_REQ_GET_CONNECTOR_PROPERTIES        0x51
#define GUD_REQ_GET_CONNECTOR_TV_MODE_VALUES    0x52
#define GUD_REQ_SET_CONNECTOR_FORCE_DETECT      0x53

#define GUD_REQ_GET_CONNECTOR_STATUS            0x54
#define GUD_CONNECTOR_STATUS_DISCONNECTED       0x00
#define GUD_CONNECTOR_STATUS_CONNECTED          0x01
#define GUD_CONNECTOR_STATUS_UNKNOWN            0x02
#define GUD_CONNECTOR_STATUS_CONNECTED_MASK     0x03
#define GUD_CONNECTOR_STATUS_CHANGED            (1u << 7)

#define GUD_REQ_GET_CONNECTOR_MODES             0x55
#define GUD_CONNECTOR_MAX_NUM_MODES             128
#define GUD_REQ_GET_CONNECTOR_EDID              0x56
#define GUD_REQ_SET_BUFFER                      0x60
#define GUD_REQ_SET_STATE_CHECK                 0x61
#define GUD_REQ_SET_STATE_COMMIT                0x62
#define GUD_REQ_SET_CONTROLLER_ENABLE           0x63
#define GUD_REQ_SET_DISPLAY_ENABLE              0x64

#endif
