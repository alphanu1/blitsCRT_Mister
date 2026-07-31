// SPDX-License-Identifier: GPL-2.0-or-later
// -----------------------------------------------------------------------------
// scanout_fetch.v -- one scanline at a time, out of DDR3 and into a line buffer.
//
// This is what replaces the whole-frame on-chip memory. Scanout memory moves to
// HPS DDR3 over f2sdram, which means the pixels are already where the USB gadget
// put them: the daemon writes rects into a reserved DDR3 window with an ordinary
// memcpy and the fabric comes to them, rather than software pushing every pixel
// across a bridge. Measured on hardware, that window takes 110 MB/s from the ARM
// against USB 2.0's ~35 MB/s ceiling, so the host side stops being a limit.
//
// Two buffers, ping-ponged. While the raster reads line N out of one, the other
// is filled with line N+1. A line is 1280 bytes at 640 RGB565 against a 63.5 us
// line time, so even a 64-bit port at 100 MHz finishes in about 1.6 us plus
// latency -- roughly forty times the margin. The double buffer is not there for
// throughput, it is there so a late burst cannot stall scanout mid-line, which
// would tear the picture rather than merely slow it.
//
// The buffers hold RAW BEATS, not unpacked pixels. Storing what the bus
// delivered and doing lane selection on the read side keeps the fetch path
// entirely format-agnostic: it moves bytes and never learns what a pixel is.
// The read side extracts bpp bytes at the right lane, which is a mux after a
// registered RAM read, so the one-clock latency scanout.v is built around is
// preserved and the source mux in the top stays transparent.
//
// Formats of 1, 2 and 4 bytes work directly, since they divide into the beat
// width and no pixel ever straddles two beats. RGB888 at 3 bytes does straddle,
// and needs a two-beat window on the read side; it is deliberately left out
// rather than half-done. XRGB8888 carries the same 8 bits per channel aligned,
// and the extra byte costs wire, not ladder depth.
// -----------------------------------------------------------------------------

`timescale 1ns/1ps
`default_nettype none

module scanout_fetch #(
    parameter integer DW        = 64,     // f2sdram data width, bits
    parameter integer AW        = 32,     // byte address width
    /*
     * Widest line the buffer holds. Raised from 1024 for super-resolution modes:
     * Switchres generates 1280-wide timings at 15 kHz so the host does the
     * horizontal scaling, and the line buffer has to hold one. Two buffers of
     * 1280 x 16 bits is 5 KB of M10K, which this part has in abundance.
     */
    parameter integer MAXW      = 1280,
    parameter integer MAX_BURST = 128     // beats per burst; longer lines split
) (
    // ---- memory side ----
    input  wire            clk_mem,
    input  wire            rst_mem_n,

    output reg  [AW-1:0]   avm_address,        // byte address, beat aligned
    output reg             avm_read,
    output reg  [9:0]      avm_burstcount,
    input  wire            avm_waitrequest,
    input  wire [DW-1:0]   avm_readdata,
    input  wire            avm_readdatavalid,

    /* Geometry, clk_mem domain. Held stable while running: these come off the
     * register block, which already latches the whole timing set as a block on
     * a vblank, so they cannot change under a line in flight. */
    input  wire [AW-1:0]   sc_base,            // byte address of line 0
    input  wire [15:0]     sc_stride,          // bytes per line
    input  wire [11:0]     sc_w,               // pixels per line
    input  wire [2:0]      sc_format,

    // ---- video side ----
    input  wire            clk_pix,
    input  wire            rst_pix_n,

    /* Pulse to start filling the spare buffer with line_y, then swap. Raised
     * once per line during blanking, so the fetch has a whole line time. */
    input  wire            line_req,
    input  wire [11:0]     line_y,
    /* Present the filled buffer to the raster. Separate from completion on
     * purpose: a fetch finishing mid-line would otherwise swap the buffer under
     * the raster and tear it. The top pulses this in blanking, a few clocks
     * before active video, so the swap is always between lines. */
    input  wire            line_show,
    output wire            line_valid,         // the displayed buffer holds a line
    output reg             line_done,          // one clk_pix pulse as a line lands
    output wire            busy,               // a fetch is in flight

    /* Diagnostics, clk_mem domain.
     *
     * underrun_tog flips once per event -- a line asked for while the previous
     * was still in flight, so the raster is about to show a stale buffer. A
     * toggle rather than a sticky level so the bus side can count events and
     * tell "it happened once at startup" from "it is happening every frame".
     *
     * beats_last is how many beats the last completed line actually moved.
     * Zero after a fetch means the port never answered, which separates a dead
     * f2sdram interface from wrong address arithmetic -- the two look identical
     * on screen. */
    output reg             underrun_tog,
    output reg  [15:0]     beats_last,

    // read port, feeding scanout.mem_q
    input  wire [11:0]     rd_x,
    output wire [31:0]     rd_q
);

    localparam integer BYTES  = DW / 8;                 // bytes per beat
    localparam integer LANEB  = $clog2(BYTES);          // lane select bits
    localparam integer DEPTH  = (MAXW * 4) / BYTES;     // beats for the widest line
    localparam integer DAW    = $clog2(DEPTH);

    localparam [2:0] FMT_RGB565   = 3'd0;
    localparam [2:0] FMT_RGB888   = 3'd1;
    localparam [2:0] FMT_XRGB8888 = 3'd2;
    localparam [2:0] FMT_RGB332   = 3'd3;

    // bytes per pixel; RGB888 is not supported here and reads as 4 so the
    // address arithmetic stays sane rather than collapsing to zero
    wire [2:0] bpp = (sc_format == FMT_RGB332)   ? 3'd1 :
                     (sc_format == FMT_RGB565)   ? 3'd2 : 3'd4;

    // -------------------------------------------------------------------
    // two line buffers, written on clk_mem and read on clk_pix
    // -------------------------------------------------------------------
    /* ONE array, with the buffer select as the top address bit -- not two arrays
     * muxed on the way out. Reading both and selecting before the output
     * register puts logic between the memory and its register, and Quartus then
     * declines to infer RAM at all: 2 x 512 x 64 bits becomes 65,536 registers
     * plus the muxes to read them, which is a design that does not fit. The
     * shape below is char_ram.v's, which infers cleanly on this device. */
    (* ramstyle = "M10K" *) reg [DW-1:0] linebuf [0:2*DEPTH-1];

    reg             fill_sel;               // buffer being filled, clk_mem
    reg             fill_sel_q;             // ...which buffer fill_data belongs to
    reg  [DAW-1:0]  fill_addr;              // where the NEXT beat goes
    reg  [DAW-1:0]  fill_wa;                // where the beat in fill_data goes
    reg             fill_we;
    reg  [DW-1:0]   fill_data;

    /* fill_wa is separate from fill_addr on purpose. Both are registered, so
     * incrementing fill_addr in the same cycle fill_we is raised would present
     * the *next* slot's address alongside this beat's data and write every beat
     * one place too far along -- which reads back as a picture shifted by one
     * beat, not as an obvious failure. */
    /* fill_sel_q for the same reason as fill_wa. fill_sel flips on the cycle the
     * last beat of a line is captured, so a write qualified by fill_sel would
     * put that final beat in the buffer that is about to be displayed -- losing
     * the last pixels of every line into the wrong half of the ping-pong. */
    always @(posedge clk_mem)
        if (fill_we) linebuf[{fill_sel_q, fill_wa}] <= fill_data;

    // -------------------------------------------------------------------
    // request handshake across the clock boundary
    // -------------------------------------------------------------------
    /* Toggles rather than pulses, so neither side has to catch a single cycle
     * of the other's clock. The same shape blitscrt_regs uses for APPLY. */
    reg        req_tog;                     // clk_pix
    reg [11:0] req_y;
    reg [1:0]  req_meta;                    // clk_mem
    reg        req_seen;
    reg        ack_tog;                     // clk_mem
    reg [1:0]  ack_meta;                    // clk_pix
    reg        ack_seen;

    always @(posedge clk_pix or negedge rst_pix_n) begin
        if (!rst_pix_n) begin
            req_tog <= 1'b0; req_y <= 12'd0;
        end else if (line_req) begin
            req_tog <= ~req_tog;
            req_y   <= line_y;
        end
    end

    // -------------------------------------------------------------------
    // fetch state machine, clk_mem
    // -------------------------------------------------------------------
    /* ISSUE raises the request, WAIT holds it until the slave accepts. They
     * have to be separate cycles: asserting avm_read and testing waitrequest in
     * one always block means the accept branch overwrites the assert, and the
     * request never appears on the bus at all. */
    localparam [1:0] S_IDLE = 2'd0, S_ISSUE = 2'd1, S_WAIT = 2'd2, S_DATA = 2'd3;

    reg [1:0]      state;
    reg [9:0]      cur_burst;               // beats in the burst being issued
    reg [15:0]     beats_seen;              // beats moved for the line in flight
    reg [AW-1:0]   line_addr;               // byte address of the line
    reg [15:0]     beats_left;              // beats still to fetch for this line
    reg [9:0]      burst_left;              // beats outstanding in this burst

    /* Total beats for one line, rounded up. The multiply runs once per line,
     * not once per pixel -- which is the point of moving it off the pixel clock
     * that scanout.v's comment flags. */
    wire [23:0] line_bytes = sc_w * {21'd0, bpp};
    wire [23-LANEB:0] beats_whole = line_bytes[23:LANEB];
    wire [15:0] line_beats = beats_whole[15:0] +
                             ((line_bytes[LANEB-1:0] != 0) ? 16'd1 : 16'd0);

    wire [9:0] this_burst = (beats_left > MAX_BURST[15:0]) ? MAX_BURST[9:0]
                                                           : beats_left[9:0];

    always @(posedge clk_mem or negedge rst_mem_n) begin
        if (!rst_mem_n) begin
            state      <= S_IDLE;
            avm_read   <= 1'b0;
            avm_address<= {AW{1'b0}};
            avm_burstcount <= 10'd1;
            fill_we    <= 1'b0;
            fill_addr  <= {DAW{1'b0}};
            fill_wa    <= {DAW{1'b0}};
            fill_sel   <= 1'b0;
            fill_sel_q <= 1'b0;
            req_meta   <= 2'b00;
            req_seen   <= 1'b0;
            ack_tog    <= 1'b0;
            beats_left <= 16'd0;
            burst_left <= 10'd0;
            cur_burst  <= 10'd0;
            underrun_tog <= 1'b0;
            beats_last <= 16'd0;
            beats_seen <= 16'd0;
            line_addr  <= {AW{1'b0}};
        end else begin
            req_meta <= {req_meta[0], req_tog};
            fill_we  <= 1'b0;

            /* A fresh request arriving while a line is still being fetched. */
            if ((req_meta[1] != req_seen) && (state != S_IDLE))
                underrun_tog <= ~underrun_tog;

            case (state)
            S_IDLE: begin
                if (req_meta[1] != req_seen) begin
                    req_seen   <= req_meta[1];
                    /* base + y*stride. Both come from the register block and
                     * are stable for the whole field. */
                    line_addr  <= sc_base + (req_y * sc_stride);
                    beats_left <= line_beats;
                    fill_addr  <= {DAW{1'b0}};
                    beats_seen <= 16'd0;
                    state      <= (line_beats == 0) ? S_IDLE : S_ISSUE;
                end
            end

            S_ISSUE: begin
                avm_address    <= line_addr;
                avm_burstcount <= this_burst;
                cur_burst      <= this_burst;
                avm_read       <= 1'b1;
                state          <= S_WAIT;
            end

            S_WAIT: begin
                if (!avm_waitrequest) begin
                    avm_read   <= 1'b0;
                    burst_left <= cur_burst;
                    beats_left <= beats_left - {6'd0, cur_burst};
                    line_addr  <= line_addr + {{(AW-13){1'b0}}, cur_burst, {LANEB{1'b0}}};
                    state      <= S_DATA;
                end
            end

            S_DATA: begin
                if (avm_readdatavalid) begin
                    fill_we    <= 1'b1;
                    fill_data  <= avm_readdata;
                    fill_wa    <= fill_addr;
                    fill_sel_q <= fill_sel;
                    fill_addr  <= fill_addr + {{(DAW-1){1'b0}}, 1'b1};
                    burst_left <= burst_left - 10'd1;
                    beats_seen <= beats_seen + 16'd1;
                    if (burst_left == 10'd1) begin
                        if (beats_left == 16'd0) begin
                            /* Line complete: hand it to the video side and
                             * take the other buffer for the next one. */
                            fill_sel   <= ~fill_sel;
                            ack_tog    <= ~ack_tog;
                            beats_last <= beats_seen + 16'd1;
                            state      <= S_IDLE;
                        end else begin
                            state <= S_ISSUE;
                        end
                    end
                end
            end

            default: state <= S_IDLE;
            endcase
        end
    end

    /* fill_addr is post-incremented above, so it must not be reset between the
     * bursts of one line -- only at S_IDLE, where it is. */

    // -------------------------------------------------------------------
    // read side, clk_pix
    // -------------------------------------------------------------------
    always @(posedge clk_pix or negedge rst_pix_n) begin
        if (!rst_pix_n) begin
            ack_meta <= 2'b00; ack_seen <= 1'b0;
        end else begin
            ack_meta <= {ack_meta[0], ack_tog};
            if (ack_meta[1] != ack_seen) ack_seen <= ack_meta[1];
        end
    end

    /* The buffer being displayed is whichever one is not being filled. fill_sel
     * crosses back through the same acknowledge, so the read side flips exactly
     * when a line completes and never mid-line. */
    reg show_sel;
    reg has_line;
    reg pending;                 // a line has landed and is waiting to be shown
    always @(posedge clk_pix or negedge rst_pix_n) begin
        if (!rst_pix_n) begin
            show_sel <= 1'b1; has_line <= 1'b0; line_done <= 1'b0;
            pending  <= 1'b0;
        end else begin
            line_done <= 1'b0;
            if (ack_meta[1] != ack_seen) begin
                pending   <= 1'b1;
                line_done <= 1'b1;
            end
            if (line_show && pending) begin
                show_sel <= ~show_sel;
                has_line <= 1'b1;
                pending  <= 1'b0;
            end
        end
    end

    assign line_valid = has_line;
    assign busy       = (state != S_IDLE);

    // byte offset of this pixel within the line, then beat and lane
    wire [15:0] byte_off = {4'd0, rd_x} * {13'd0, bpp};
    wire [DAW-1:0]  rd_beat = byte_off[DAW+LANEB-1:LANEB];
    wire [LANEB-1:0] rd_lane = byte_off[LANEB-1:0];

    reg [DW-1:0]     rd_beat_q;
    reg [LANEB-1:0]  rd_lane_q;
    reg [2:0]        bpp_q;

    /* Address in, data out next cycle, nothing in between. show_sel selects the
     * half and is stable across a line, so it joins the address rather than
     * gating the output. */
    always @(posedge clk_pix) begin
        rd_beat_q <= linebuf[{show_sel, rd_beat}];
        rd_lane_q <= rd_lane;
        bpp_q     <= bpp;
    end

    /* Lane select: shift the beat down so the pixel's first byte is at bit 0.
     * A variable shift of DW bits at the pixel clock, which is a mux of byte
     * slices and comfortable at 12.6-25.2 MHz. */
    wire [DW-1:0] shifted = rd_beat_q >> ({3'd0, rd_lane_q} << 3);

    assign rd_q = (bpp_q == 3'd1) ? {24'd0, shifted[7:0]}   :
                  (bpp_q == 3'd2) ? {16'd0, shifted[15:0]}  :
                                    shifted[31:0];

endmodule

`default_nettype wire
