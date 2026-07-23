// -----------------------------------------------------------------------------
// video_timing.v -- blitsCRT_Mister timing generator (15kHz, progressive or interlaced)
//
// Line layout starts at the leading edge of hsync so vsync transitions land on
// a hsync edge rather than mid-active-video:
//
//   hcnt:  0 .. H_SY-1             hsync active
//          H_SY .. +H_BP-1         back porch
//          .. +H_ACT-1             active video
//          .. H_TOT-1              front porch
//
// hcnt free-runs and is never reset by a field boundary, so the hsync train is
// perfectly periodic in both fields. Interlace comes from vsync alone: on the
// odd field vsync starts half a line late, which is what makes a CRT drop its
// raster half a line and interleave rather than overlay.
//
// All VERTICAL values are PER FIELD.
//   progressive frame = V_TOT lines
//   interlaced frame  = 2*V_TOT + 1 lines  (262 -> 525)
//
// Timing arrives as inputs rather than parameters so the mode can change at
// runtime. They are sampled continuously, and the caller must hold rst_n low
// while changing them. A mode change switches the pixel clock anyway, so the
// reset is needed regardless and nothing has to be latched here.
// -----------------------------------------------------------------------------

`timescale 1ns/1ps
`default_nettype none

module video_timing (
    input  wire        clk,
    input  wire        rst_n,

    // timing, stable while rst_n is low
    input  wire [11:0] h_sy,
    input  wire [11:0] h_bp,
    input  wire [11:0] h_act,
    input  wire [11:0] h_fp,
    input  wire [11:0] v_sy,
    input  wire [11:0] v_bp,
    input  wire [11:0] v_act,       // per field
    input  wire [11:0] v_fp,
    input  wire        interlace,

    output wire        hs,              // active high; invert at the pad
    output wire        vs,
    output wire        cs,              // composite sync for SCART
    output reg         de,

    output reg  [11:0] hcnt,            // 0..H_TOT-1
    output reg  [11:0] lcnt,            // 0..FRAME_LINES-1
    output wire [11:0] xpos,            // 0..H_ACT-1, valid while de
    output wire [11:0] ypos,            // frame line, field-interleaved
    output wire        field,           // 0 = even, always 0 when progressive
    output wire        vblank,
    output wire        field_start      // one clk pulse at the top of a field
);

    wire [11:0] H_TOT  = h_sy + h_bp + h_act + h_fp;
    wire [11:0] V_TOT  = v_sy + v_bp + v_act + v_fp;
    wire [11:0] H_HALF = {1'b0, H_TOT[11:1]};

    wire [11:0] FRAME_LINES = interlace ? ((V_TOT << 1) + 12'd1) : V_TOT;

    wire [11:0] H_ACT_S  = h_sy + h_bp;
    wire [11:0] V_ACT_S0 = v_sy + v_bp;                     // even field
    wire [11:0] V_ACT_S1 = V_TOT + v_sy + v_bp + 12'd1;     // odd field

    // ---------------- counters ----------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hcnt <= 12'd0;
            lcnt <= 12'd0;
        end else if (hcnt == H_TOT - 12'd1) begin
            hcnt <= 12'd0;
            lcnt <= (lcnt == FRAME_LINES - 12'd1) ? 12'd0 : lcnt + 12'd1;
        end else begin
            hcnt <= hcnt + 12'd1;
        end
    end

    assign field = interlace && (lcnt >= V_TOT);

    // ---------------- sync ----------------
    assign hs = (hcnt < h_sy);

    wire vs_even = (lcnt < v_sy);

    // odd field: starts half a line into line V_TOT, ends half a line into
    // line V_TOT+V_SY
    wire vs_odd = ((lcnt == V_TOT) && (hcnt >= H_HALF))                    ||
                  ((lcnt >  V_TOT) && (lcnt < V_TOT + v_sy))         ||
                  ((lcnt == V_TOT + v_sy) && (hcnt < H_HALF));

    assign vs = interlace ? (field ? vs_odd : vs_even) : vs_even;
    assign cs = hs ^ vs;

    // ---------------- active window ----------------
    wire h_active = (hcnt >= H_ACT_S) &&
                    (hcnt <  H_ACT_S + h_act);

    wire [11:0] v_start = (field) ? V_ACT_S1 : V_ACT_S0;
    wire v_active = (lcnt >= v_start) && (lcnt < v_start + v_act);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) de <= 1'b0;
        else        de <= h_active && v_active;
    end

    // xpos/ypos registered alongside de so they line up with the pixel the
    // downstream generators are producing.
    reg [11:0] xr, yr;
    reg        fr;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            xr <= 12'd0;
            yr <= 12'd0;
            fr <= 1'b0;
        end else begin
            xr <= hcnt - H_ACT_S;
            yr <= lcnt - v_start;
            fr <= field;
        end
    end

    assign xpos   = xr;
    assign ypos   = interlace ? {yr[10:0], fr} : yr;
    assign vblank = !v_active;

    assign field_start = (hcnt == 12'd0) &&
                         ((lcnt == 12'd0) ||
                          (interlace && (lcnt == V_TOT)));

endmodule

`default_nettype wire
