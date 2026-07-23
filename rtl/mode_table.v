`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// mode_table.v -- the modes the fabric can produce, and which one is selected.
//
// Three entries. Two are 15kHz for a CRT; the third is standard VGA timing,
// which any monitor or HDMI sink will display without a DAC or a SCART lead in
// the path. That third mode exists to separate "the design works" from "the
// analog cable works", which are otherwise indistinguishable when the screen
// stays dark.
//
// Selection at reset comes from what is plugged in. BTN_OSD cycles manually
// from there, since detection cannot know whether the cable beyond the
// connector is any good.
// -----------------------------------------------------------------------------

`default_nettype none

module mode_table #(
    // Both default to 640x480i60. It is a standard SD format, so an HDMI sink
    // is far more likely to accept it than 320x240p, which nothing recognises,
    // and a 15kHz CRT takes it as readily as 240p. Mode 0 suits a CRT better
    // once the analog path is known good.
    parameter integer DEFAULT_VGA  = 1,   // analog board fitted
    parameter integer DEFAULT_HDMI = 1,   // HDMI only
    // Set to 2 to come up at 31kHz VGA timing, which needs no DAC at all.
    parameter integer FORCE_MODE   = -1   // >= 0 pins the mode, ignoring detect
) (
    input  wire        clk,               // 50 MHz, always running
    input  wire        rst_n,

    input  wire        av_present,        // VGA_EN low, analog board fitted
    input  wire        hdmi_hpd,          // sink asserting hot plug detect
    input  wire        btn_cycle,         // active low, debounced elsewhere

    output reg  [1:0]  mode,
    output wire [11:0] h_sy, h_bp, h_act, h_fp,
    output wire [11:0] v_sy, v_bp, v_act, v_fp,
    output wire        interlace,
    output wire [1:0]  clk_sel,
    output wire [31:0] pclk_khz
);

    localparam [1:0] MODE_640x240p = 2'd0;   // 12.600 MHz, 15.750 kHz, 60.11 Hz
    localparam [1:0] MODE_640x480i = 2'd1;   // 12.600 MHz, 15.750 kHz, 60.00 Hz
    localparam [1:0] MODE_640x480p = 2'd2;   // 25.200 MHz, 31.500 kHz, 60.00 Hz

    /* clkselect values, not clock indices: altclkctrl slots 0 and 1 are wired
     * to the reference pin to satisfy the placement rule, and only 2 and 3
     * carry PLL outputs. */
    localparam [1:0] CLK_12M6 = 2'd2;
    localparam [1:0] CLK_25M2 = 2'd3;

    // ---- selection ----
    reg btn_d;
    reg picked;

    wire [1:0] auto_mode = av_present ? DEFAULT_VGA[1:0]
                         : (hdmi_hpd  ? DEFAULT_HDMI[1:0]
                                      : DEFAULT_VGA[1:0]);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mode   <= (FORCE_MODE >= 0) ? FORCE_MODE[1:0] : 2'd0;
            picked <= 1'b0;
            btn_d  <= 1'b1;
        end else begin
            btn_d <= btn_cycle;

            // latch the detected default once, then leave it to the button
            if (!picked && (FORCE_MODE < 0)) begin
                mode   <= auto_mode;
                picked <= 1'b1;
            end

            if (btn_d && !btn_cycle && (FORCE_MODE < 0))
                mode <= (mode == MODE_640x480p) ? MODE_640x240p : mode + 2'd1;
        end
    end

    // ---- the table ----
    reg [11:0] r_hsy, r_hbp, r_hact, r_hfp;
    reg [11:0] r_vsy, r_vbp, r_vact, r_vfp;
    reg        r_ilace;
    reg [1:0]  r_clksel;
    reg [31:0] r_khz;

    always @* begin
        case (mode)
        MODE_640x480i: begin           // 800 x (2*262+1 = 525)
            r_hsy = 12'd60;  r_hbp = 12'd76;  r_hact = 12'd640; r_hfp = 12'd24;
            r_vsy = 12'd3;   r_vbp = 12'd16;  r_vact = 12'd240; r_vfp = 12'd3;
            r_ilace = 1'b1; r_clksel = CLK_12M6; r_khz = 32'd12600;
        end
        MODE_640x480p: begin           // 800 x 525, standard VGA
            r_hsy = 12'd96;  r_hbp = 12'd48;  r_hact = 12'd640; r_hfp = 12'd16;
            r_vsy = 12'd2;   r_vbp = 12'd33;  r_vact = 12'd480; r_vfp = 12'd10;
            r_ilace = 1'b0; r_clksel = CLK_25M2; r_khz = 32'd25200;
        end
        default: begin                 // 800 x 262, same raster as 480i
            r_hsy = 12'd60;  r_hbp = 12'd76;  r_hact = 12'd640; r_hfp = 12'd24;
            r_vsy = 12'd3;   r_vbp = 12'd16;  r_vact = 12'd240; r_vfp = 12'd3;
            r_ilace = 1'b0; r_clksel = CLK_12M6; r_khz = 32'd12600;
        end
        endcase
    end

    assign h_sy = r_hsy; assign h_bp = r_hbp;
    assign h_act = r_hact; assign h_fp = r_hfp;
    assign v_sy = r_vsy; assign v_bp = r_vbp;
    assign v_act = r_vact; assign v_fp = r_vfp;
    assign interlace = r_ilace;
    assign clk_sel   = r_clksel;
    assign pclk_khz  = r_khz;

endmodule

`default_nettype wire
