// SPDX-License-Identifier: GPL-2.0-or-later
// -----------------------------------------------------------------------------
// scanout_ram.v -- on-chip scanout memory, one pixel per word.
//
// True dual-clock M10K, the same shape as char_ram.v: written from the bus
// domain, read in the pixel domain. Cyclone V supports that directly, so the
// only clock crossing is the one the block RAM itself handles.
//
// M10K budget on the 5CSEBA6U23I7 is 5,570 Kbit. One pixel per word:
//
//   320x240 x 16   1.23 Mbit   22%   240p only; 480i would have to line-double
//   320x480 x 16   2.46 Mbit   43%   <-- fitted. genuine 480i, hdouble to 640
//   640x240 x 16   2.46 Mbit   43%   native 640, but 240 lines
//   640x240 x 24   3.69 Mbit   65%   RGB888 at 240 lines
//   640x480 x 16   4.92 Mbit   86%   will not fit alongside the overlay
//
// 320x480 is fitted because 480i has to be genuinely interlaced. With 480
// distinct lines the raster reads 0,2,4.. on one field and 1,3,5.. on the other
// and both fields carry different content; 240 lines doubled would show the same
// content twice, which is 240p in a 480i timing. Full horizontal resolution as
// well needs 640x480, which does not fit here at any useful depth -- that is the
// case M3c exists for.
//
// DW is 16, so RGB888 and XRGB8888 read back with their top bytes zero. That is
// deliberate rather than an oversight: 640x240 in RGB888 needs 3.7 Mbit here
// against 900 KB in DDR3, and RGB888 is what M3c is for. scanout.v unpacks all
// four formats regardless, so nothing changes in it when the memory widens.
//
// The write port is what the daemon streams damage rectangles into. It comes up
// holding INIT_FILE, so there is a picture in memory before anything writes one.
// -----------------------------------------------------------------------------

`timescale 1ns/1ps
`default_nettype none

module scanout_ram #(
    parameter integer DW        = 16,
    parameter integer AW        = 18,
    parameter integer WORDS     = 153600,        // 320 x 480
    parameter         INIT_FILE = "scanout_init.hex"   // "" leaves it uninitialised
) (
    // write port, bus clock
    input  wire          wclk,
    input  wire          we,
    input  wire [AW-1:0] waddr,
    input  wire [DW-1:0] wdata,

    // read port, pixel clock
    input  wire          rclk,
    input  wire [AW-1:0] raddr,
    output reg  [DW-1:0] rdata
);

    (* ramstyle = "M10K" *) reg [DW-1:0] mem [0:WORDS-1];

    /* Guarded so a testbench can instantiate with INIT_FILE="" and load the
     * buffer itself instead of depending on a generated asset. The synthesised
     * instance always passes a real filename, so what Quartus elaborates is a
     * plain unconditional $readmemh -- the form it infers RAM initialisation
     * from, and the same one char_ram.v uses. */
    generate
    if (INIT_FILE != "") begin : g_init
        initial $readmemh(INIT_FILE, mem);
    end
    endgenerate

    always @(posedge wclk)
        if (we) mem[waddr] <= wdata;

    /* Address in, data out next cycle. scanout.v is built around this being
     * exactly one clock. */
    always @(posedge rclk)
        rdata <= mem[raddr];

endmodule

`default_nettype wire
