// -----------------------------------------------------------------------------
// overlay.v -- 8x8 text overlay composited over the incoming video
//
// Two clocks of lookup latency (char RAM, then font ROM), so the incoming RGB
// and de are delayed to match. The whole picture therefore sits two pixels
// later in the line; the front porch absorbs it.
//
// double_h renders each font row across two frame lines. Set it for interlaced
// modes or single-pixel horizontal strokes land in one field only and strobe
// at the frame rate.
// -----------------------------------------------------------------------------

`timescale 1ns/1ps
`default_nettype none

module overlay (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        double_h,    // render each font row across two lines
    input  wire [1:0]  bank,        // which mode's text block to show
    input  wire        hps_alive,   // daemon writing text? if not, show bank 3

    input  wire        de_in,
    input  wire [11:0] xpos,
    input  wire [11:0] ypos,
    input  wire [5:0]  r_in,
    input  wire [5:0]  g_in,
    input  wire [5:0]  b_in,

    input  wire        enable,

    // character buffer read port
    output wire [12:0] char_addr,
    input  wire [7:0]  char_data,

    // font ROM read port
    output wire [9:0]  font_addr,
    input  wire [7:0]  font_data,

    output reg         de_out,
    output reg  [5:0]  r_out,
    output reg  [5:0]  g_out,
    output reg  [5:0]  b_out
);

    // ---- stage 0: address the character cell ----
    wire [6:0] col  = xpos[9:3];
    wire [5:0] row  = double_h ? ypos[9:4] : ypos[8:3];
    wire [2:0] yoff = double_h ? ypos[3:1] : ypos[2:0];

    /* The character buffer holds one text block per mode, 16 rows each. The
     * fabric picks modes at runtime, so a single baked block would report
     * whichever mode it was generated for whatever is actually on screen. */
    /*
     * Banks 0..2 are the three modes' text, written by the daemon when it is
     * alive. Bank 3 is the fabric's own baked "no HPS" banner, shown when the
     * heartbeat is stale. So the screen distinguishes a running daemon from a
     * board that powered up the fabric but never brought Linux up.
     */
    wire        row_in_bank = (row[5:4] == 2'b00);
    wire [1:0]  active_bank = hps_alive ? bank : 2'd3;
    wire [5:0]  banked_row  = {active_bank, row[3:0]};

    assign char_addr = {banked_row, col};

    // ---- stage 1: character byte is out, address the glyph row ----
    reg [2:0] yoff_d1, xoff_d1;
    always @(posedge clk) begin
        yoff_d1 <= yoff;
        xoff_d1 <= xpos[2:0];
    end

    assign font_addr = {char_data[6:0], yoff_d1};

    // non-space cells get a black backing so text stays legible over the bars
    reg cell_used_d1;
    always @(posedge clk)
        cell_used_d1 <= row_in_bank &&
                        (char_data != 8'h20) && (char_data != 8'h00);

    // ---- stage 2: glyph row is out, pick the pixel ----
    // cell_used_d1 and font_data both become valid on the same clock, since
    // both are derived from char_data. Giving cell_used a second stage put the
    // backing box one pixel to the right of the glyph it belongs to.
    reg [2:0] xoff_d2;
    always @(posedge clk) xoff_d2 <= xoff_d1;

    wire fg = font_data[3'd7 - xoff_d2];

    // ---- match the two-clock latency on the video path ----
    reg        de_d1, de_d2;
    reg [5:0]  r_d1, g_d1, b_d1, r_d2, g_d2, b_d2;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            de_d1 <= 1'b0; de_d2 <= 1'b0;
            r_d1 <= 6'd0; g_d1 <= 6'd0; b_d1 <= 6'd0;
            r_d2 <= 6'd0; g_d2 <= 6'd0; b_d2 <= 6'd0;
        end else begin
            de_d1 <= de_in; de_d2 <= de_d1;
            r_d1 <= r_in;  g_d1 <= g_in;  b_d1 <= b_in;
            r_d2 <= r_d1;  g_d2 <= g_d1;  b_d2 <= b_d1;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            de_out <= 1'b0;
            r_out  <= 6'd0; g_out <= 6'd0; b_out <= 6'd0;
        end else begin
            de_out <= de_d2;
            if (!de_d2) begin
                r_out <= 6'd0; g_out <= 6'd0; b_out <= 6'd0;
            end else if (enable && cell_used_d1 && fg) begin
                r_out <= 6'd63; g_out <= 6'd63; b_out <= 6'd63;
            end else if (enable && cell_used_d1) begin
                r_out <= 6'd0;  g_out <= 6'd0;  b_out <= 6'd0;
            end else begin
                r_out <= r_d2;  g_out <= g_d2;  b_out <= b_d2;
            end
        end
    end

endmodule

`default_nettype wire
