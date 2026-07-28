/* SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef BLITSCRT_LZ4DEC_H
#define BLITSCRT_LZ4DEC_H

#include <stddef.h>
#include <stdint.h>

/*
 * Decompress one LZ4 block. Returns the number of bytes written, or -1 if the
 * block is malformed or would not fit.
 *
 * Block format only -- no frame header, no checksum. That is what GUD sends:
 * gud_set_buffer_req carries compressed_length on the wire and length as the
 * decompressed size, so both ends already know the sizes and the frame wrapper
 * would be redundant.
 */
long blitscrt_lz4_decompress(const void *src, size_t src_len,
			     void *dst, size_t dst_cap);

#endif
