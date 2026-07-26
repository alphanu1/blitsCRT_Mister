// -----------------------------------------------------------------------------
// fb_ram.v -- on-chip framebuffer, one pixel per word.
//
// True dual-clock M10K, the same shape as char_ram.v: written from the bus
// domain, read in the pixel domain. Cyclone V supports that directly, so the
// only clock crossing is the one the block RAM itself handles.
//
// M10K budget on the 5CSEBA6U23I7 is 5,570 Kbit. One pixel per word:
//
//   320x240 x 16   1.2 Mbit    22%   RGB565 or RGB332, hdouble to 640 wide
//   640x240 x 16   2.4 Mbit    44%   RGB565 or RGB332, native 640
//   640x240 x 24   3.7 Mbit    66%   RGB888, tight but it fits
//   640x480 x 16   4.9 Mbit    88%   will not fit alongside the overlay
//
// The default is the first: it is the cheapest thing that proves the pipeline,
// and it is the case that gets a *true* 320-wide active area back, which the
// 640-wide mode 0 gave up when the design dropped to two pixel clocks.
//
// DW is 16, so RGB888 and XRGB8888 read back with their top bytes zero. That is
// deliberate rather than an oversight: 640x240 in RGB888 needs 3.7 Mbit here
// against 900 KB in DDR3, and RGB888 is what M3c is for. scanout.v unpacks all
// four formats regardless, so nothing changes in it when the memory widens.
//
// The write port is unused in M3a -- the buffer comes up holding INIT_FILE --
// and is what M3b drives from the daemon.
// -----------------------------------------------------------------------------

`timescale 1ns/1ps
`default_nettype none

module fb_ram #(
    parameter integer DW        = 16,
    parameter integer AW        = 17,
    parameter integer WORDS     = 76800,          // 320 x 240
    parameter         INIT_FILE = "fb_init.hex"   // "" leaves it uninitialised
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
