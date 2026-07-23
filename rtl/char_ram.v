// -----------------------------------------------------------------------------
// char_ram.v -- overlay character buffer, 64 rows x 128 cols, 8 KB
//
// Sized for the largest grid we need (80x60 at 640x480 with an 8x8 cell) and
// addressed as {row[5:0], col[6:0]}. Port A is the write side, which the HPS
// bridge attaches to in M2; port B is the scanout read. Contents come up from
// banner.hex so a picture appears with no software running at all.
// -----------------------------------------------------------------------------

`timescale 1ns/1ps
`default_nettype none

module char_ram (
    input  wire        clk,

    input  wire        we,
    input  wire [12:0] waddr,
    input  wire [7:0]  wdata,

    input  wire [12:0] raddr,
    output reg  [7:0]  rdata
);
    reg [7:0] mem [0:8191];
    initial $readmemh("banner.hex", mem);

    always @(posedge clk) begin
        if (we) mem[waddr] <= wdata;
        rdata <= mem[raddr];
    end
endmodule

`default_nettype wire
