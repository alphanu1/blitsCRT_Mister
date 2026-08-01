// SPDX-License-Identifier: GPL-2.0-or-later
// -----------------------------------------------------------------------------
// scanout.v -- scanout memory reader: address generation and format unpack.
//
// Latency is exactly ONE clock from xpos/ypos to r/g/b, which is what testcard.v
// costs. That is deliberate: the source mux in blitscrt_top is then transparent
// and PIPE stays at 5. Getting it wrong does not fail loudly -- it shifts the
// picture within the active window and moves the porches the CRT centres on.
//
//   cycle N     xpos/ypos present. mem_addr is combinational, so the memory
//               latches the address on this edge.
//   cycle N+1   mem_q is valid. The unpack is combinational, so r/g/b are
//               valid in this cycle -- level with testcard's registered output.
//
// Memory is addressed in PIXELS, one pixel per word, not in bytes. The byte
// address the register contract describes (sc_base + y*sc_stride + x*bpp) is the
// memory adapter's business, not the unpacker's:
//
//   on-chip (M3a/M3b)  the pixel index *is* the word address
//   HPS DDR3 (M3c)     the line fetcher turns index into
//                      sc_base + (index << bpp_shift)
//
// Keeping the unpacker unaware of that is what lets it survive the move
// off-chip unchanged. sc_base is not an input here for the same reason.
//
// Everything unpacks to RGB666.
//
// That was right for the older A/V board, whose resistor ladder is six bits a
// channel. The newer board carries an ADV7125 that takes eight, so this now
// throws away two bits per channel that the DAC could have used -- see the note
// below, and the low-two-bits-on-SDIO entry in the roadmap.
//
// The original reasoning: RGB666 is what the A/V board's resistor
// ladder actually is. Short fields are widened by repeating the field rather
// than zero-padding, so full scale in maps to full scale out: a 3-bit 7 becomes
// 63, not 56.
// -----------------------------------------------------------------------------

`timescale 1ns/1ps
`default_nettype none

module scanout #(
    parameter integer AW = 20            // pixel-index width; 20 covers 640x480
) (
    input  wire          clk,
    input  wire          rst_n,

    // raster position, straight off video_timing
    input  wire          de,
    input  wire [11:0]   xpos,
    input  wire [11:0]   ypos,           // frame line, field-interleaved

    // scanout memory geometry, in pixels
    input  wire [11:0]   sc_w,
    input  wire [11:0]   sc_h,
    input  wire [11:0]   sc_pitch,       // pixels per line; == sc_w when packed
    input  wire [2:0]    sc_format,      // BLITSCRT_FMT_*
    input  wire          hdouble,        // replicate each source pixel across two
    input  wire          vdouble,        // ...and each source line down two

    // memory port: address out combinational, data back registered (latency 1)
    output wire [AW-1:0] mem_addr,
    input  wire [31:0]   mem_q,

    /* The same source coordinates the address is composed from, brought out so
     * a line-buffered memory can be addressed by column instead. M3a and M3b
     * use mem_addr against a whole-frame memory; M3c's line fetcher holds one
     * line at a time and wants x_src. Both are driven, the top picks. y_src is
     * out here so the fetcher can see which line is being displayed rather than
     * deriving it a second time and risking a different answer. */
    output wire [11:0]   x_src,
    output wire [11:0]   y_src_o,

    output wire [5:0]    r,
    output wire [5:0]    g,
    output wire [5:0]    b
);

    /* Format codes, mirroring sw/blitscrt_regs.h. Kept as localparams rather
     * than magic numbers in the case below so a change to the header is a
     * one-line change here. */
    localparam [2:0] FMT_RGB565   = 3'd0;
    localparam [2:0] FMT_RGB888   = 3'd1;
    localparam [2:0] FMT_XRGB8888 = 3'd2;
    localparam [2:0] FMT_RGB332   = 3'd3;

    // ---------------- address ----------------
    wire [11:0] x_src_w = hdouble ? {1'b0, xpos[11:1]} : xpos;
    wire [11:0] y_src   = vdouble ? {1'b0, ypos[11:1]} : ypos;

    /* Outside the scanout memory reads black rather than whatever the address
     * happens to wrap onto. A mode taller or wider than the buffer is a
     * legitimate transient -- the daemon applies timing and geometry on
     * different vblanks -- and garbage on screen during it looks like a fault. */
    wire in_bounds = (x_src_w < sc_w) && (y_src < sc_h);

    /* A 12x12 multiply on the pixel-clock path. At 12.6-25.2 MHz this has
     * enormous slack and Quartus infers a DSP block, so it is not worth an
     * accumulator and the interlace/vdouble special cases one would need. M3c
     * moves it off the pixel path anyway: the line fetcher computes a line base
     * once per line, not once per pixel. */
    wire [23:0] index = (y_src * sc_pitch) + {12'd0, x_src_w};

    assign mem_addr = index[AW-1:0];
    assign x_src     = x_src_w;
    assign y_src_o   = y_src;

    // de follows the address by one clock, so it lands with the data
    reg de_q;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) de_q <= 1'b0;
        else        de_q <= de && in_bounds;
    end

    // ---------------- unpack to RGB666 ----------------
    reg [5:0] ur, ug, ub;

    always @* begin
        case (sc_format)
            FMT_RGB565: begin
                /* 5/6/5. Green is already six bits. Red and blue gain their
                 * own MSB as a low bit. */
                ur = {mem_q[15:11], mem_q[15]};
                ug =  mem_q[10:5];
                ub = {mem_q[4:0],   mem_q[4]};
            end
            FMT_RGB888, FMT_XRGB8888: begin
                /* 0x00RRGGBB in the word. Byte order in memory is the
                 * fetcher's problem; by the time it reaches here it is a
                 * packed word.
                 *
                 * Eight bits truncate to six. On the older board that was the
                 * ladder's depth and nothing was lost. On the newer one the DAC
                 * takes eight, so this is where the two extra bits go -- driving
                 * the SDIO pins alone would not recover them. */
                ur = mem_q[23:18];
                ug = mem_q[15:10];
                ub = mem_q[7:2];
            end
            FMT_RGB332: begin
                /* 3/3/2 in the low byte, each field repeated to fill six bits. */
                ur = {mem_q[7:5], mem_q[7:5]};
                ug = {mem_q[4:2], mem_q[4:2]};
                ub = {mem_q[1:0], mem_q[1:0], mem_q[1:0]};
            end
            default: begin
                ur = 6'd0; ug = 6'd0; ub = 6'd0;
            end
        endcase
    end

    assign r = de_q ? ur : 6'd0;
    assign g = de_q ? ug : 6'd0;
    assign b = de_q ? ub : 6'd0;

endmodule

`default_nettype wire
