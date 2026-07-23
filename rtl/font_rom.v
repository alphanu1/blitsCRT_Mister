// 8x8 font ROM, 128 glyphs. Registered read, inferred M10K.
`timescale 1ns/1ps
`default_nettype none

module font_rom (
    input  wire        clk,
    input  wire [9:0]  addr,      // {char[6:0], row[2:0]}
    output reg  [7:0]  data
);
    reg [7:0] mem [0:1023];
    initial $readmemh("font8x8.hex", mem);

    always @(posedge clk) data <= mem[addr];
endmodule

`default_nettype wire
