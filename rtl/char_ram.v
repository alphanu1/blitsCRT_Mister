`timescale 1ns/1ps
// char_ram.v -- overlay character buffer, 64 rows x 128 cols, 8 KB.
//
// True dual-clock: written from the bus domain by the register slave, read in
// the pixel domain by the overlay. Cyclone V M10K supports this directly.
//
// The banked layout: rows 0..15 are the fabric's baked banner (three mode
// blocks live in the low rows via the bank select in overlay.v). The daemon
// writes its live text into the same space. When the daemon is quiet the baked
// contents remain, which is what the overlay uses to show a distinct
// "fabric only" screen.

`default_nettype none

module char_ram (
    // write port, bus clock
    input  wire        wclk,
    input  wire        we,
    input  wire [12:0] waddr,
    input  wire [7:0]  wdata,

    // read port, pixel clock
    input  wire        rclk,
    input  wire [12:0] raddr,
    output reg  [7:0]  rdata
);
    (* ramstyle = "M10K" *) reg [7:0] mem [0:8191];
    initial $readmemh("banner.hex", mem);

    always @(posedge wclk)
        if (we) mem[waddr] <= wdata;

    always @(posedge rclk)
        rdata <= mem[raddr];

endmodule

`default_nettype wire
