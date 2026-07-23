// -----------------------------------------------------------------------------
// adv7513_init.v -- configure the HDMI transmitter for MiSTer Direct Video
//
// On MiSTer this job belongs to software: sys_top.v routes HDMI_I2C to the HPS
// and the MiSTer binary writes the registers from Linux. M1 has no software, so
// the same table lives here and a small sequencer walks it.
//
// Register values follow MiSTer's own init in Main_MiSTer/video.cpp, which is
// field-proven on this transmitter, minus the audio block. Two differ on
// purpose:
//
//   0x3B = 0x00  automatic pixel repetition. This is the whole trick behind
//                Direct Video -- the ADV7513 detects a pixel clock below its
//                minimum and repeats internally, so a 6.4 MHz 240p stream goes
//                out the connector without the fabric doing anything. MiSTer
//                sets exactly this when direct_video is on.
//   0xAF = 0x04  DVI mode rather than HDMI. Nothing downstream wants
//                infoframes; the far end is a dumb TMDS-to-analog converter.
//
// The table is replayed about twice a second. Rewriting identical values costs
// nothing and means a display plugged in later gets picked up without a
// hotplug interrupt to watch.
// -----------------------------------------------------------------------------

`timescale 1ns/1ps
`default_nettype none

module adv7513_init #(
    parameter integer CLK_HZ = 50_000_000,
    parameter [6:0]   DEV    = 7'h39,
    parameter [7:0]   REG_17 = 8'h00      // 4:3, sync polarity not inverted
) (
    input  wire  clk,
    input  wire  rst_n,

    output wire  scl,
    output wire  sda_out,
    input  wire  sda_in,

    output reg   configured,
    output reg   last_nack
);

    /* Quartus rounds the inferred ROM to 64 entries and then complains that
     * the init file is shorter. Padding with repeats of the last write costs
     * nothing and silences it. */
    localparam integer N = 47;
    localparam integer ROM_DEPTH = 64;

    integer pad;
    reg [15:0] rom [0:ROM_DEPTH-1];
    initial begin
        rom[ 0] = 16'h9803; rom[ 1] = 16'hD6C0; rom[ 2] = 16'h4110;
        rom[ 3] = 16'h9A70; rom[ 4] = 16'h9C30; rom[ 5] = 16'h9D61;
        rom[ 6] = 16'hA2A4; rom[ 7] = 16'hA3A4; rom[ 8] = 16'hE0D0;
        rom[ 9] = 16'h3540; rom[10] = 16'h36D9; rom[11] = 16'h370A;
        rom[12] = 16'h3800; rom[13] = 16'h392D; rom[14] = 16'h3A00;
        rom[15] = 16'h1638;                       // 444 out, 8-bit in, RGB
        rom[16] = {8'h17, REG_17};
        rom[17] = 16'h3B00;                       // automatic pixel repetition
        rom[18] = 16'h3C00;                       // VIC 0
        rom[19] = 16'h4808; rom[20] = 16'h49A8; rom[21] = 16'h4000;
        rom[22] = 16'h4A80; rom[23] = 16'h4C00; rom[24] = 16'h5510;
        rom[25] = 16'h5608; rom[26] = 16'h5708; rom[27] = 16'h5900;
        rom[28] = 16'h7301; rom[29] = 16'h96FF; rom[30] = 16'hC900;
        rom[31] = 16'h9902; rom[32] = 16'h9B18; rom[33] = 16'h9F00;
        rom[34] = 16'hA100; rom[35] = 16'hA408; rom[36] = 16'hA504;
        rom[37] = 16'hA600; rom[38] = 16'hA700; rom[39] = 16'hA800;
        rom[40] = 16'hA900; rom[41] = 16'hAA00; rom[42] = 16'hAB40;
        rom[43] = 16'hAF04;                       // DVI mode, HDCP off
        rom[44] = 16'hBA60; rom[45] = 16'hE201;   // CEC powered down
        rom[46] = 16'hFA7D;
        for (pad = N; pad < ROM_DEPTH; pad = pad + 1)
            rom[pad] = 16'hFA7D;      // harmless repeat, never indexed
    end

    localparam integer REPLAY = CLK_HZ / 2;       // about twice a second

    reg         i2c_start;
    reg  [7:0]  i2c_reg, i2c_dat;
    wire        i2c_busy, i2c_done, i2c_nack;

    i2c_master #(.CLK_HZ(CLK_HZ), .SCL_HZ(100_000)) u_i2c (
        .clk(clk), .rst_n(rst_n),
        .start(i2c_start), .dev_addr(DEV),
        .reg_addr(i2c_reg), .data(i2c_dat),
        .busy(i2c_busy), .done(i2c_done), .nack(i2c_nack),
        .scl(scl), .sda_out(sda_out), .sda_in(sda_in)
    );

    localparam [1:0] W_WAIT = 2'd0, W_ISSUE = 2'd1, W_BUSY = 2'd2;

    reg [1:0]  st;
    reg [6:0]  idx;
    reg [25:0] gap;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st         <= W_ISSUE;   // first pass immediately
            idx        <= 7'd0;
            gap        <= 26'd0;
            i2c_start  <= 1'b0;
            configured <= 1'b0;
            last_nack  <= 1'b0;
        end else begin
            i2c_start <= 1'b0;

            case (st)
                W_WAIT: begin
                    if (gap == REPLAY[25:0] - 26'd1) begin
                        gap <= 26'd0;
                        idx <= 7'd0;
                        st  <= W_ISSUE;
                    end else begin
                        gap <= gap + 26'd1;
                    end
                end

                W_ISSUE: begin
                    if (!i2c_busy) begin
                        i2c_reg   <= rom[idx][15:8];
                        i2c_dat   <= rom[idx][7:0];
                        i2c_start <= 1'b1;
                        st        <= W_BUSY;
                    end
                end

                W_BUSY: begin
                    if (i2c_done) begin
                        last_nack <= i2c_nack;
                        if (idx == N[6:0] - 7'd1) begin
                            configured <= ~i2c_nack;
                            st         <= W_WAIT;
                        end else begin
                            idx <= idx + 7'd1;
                            st  <= W_ISSUE;
                        end
                    end
                end

                default: st <= W_WAIT;
            endcase
        end
    end

endmodule

`default_nettype wire
