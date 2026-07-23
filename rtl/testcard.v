// -----------------------------------------------------------------------------
// testcard.v -- CRT alignment pattern, RGB666
//
//   top 60%      eight full-amplitude colour bars
//   next 15%     the same bars at half amplitude (DAC linearity / grey tracking)
//   bottom 25%   sixteen-step greyscale ramp
//   overlaid     one-pixel white border and a centre crosshair for geometry
//
// Bar and ramp boundaries come from counters rather than division so the width
// need not be a power of two.
// -----------------------------------------------------------------------------

`timescale 1ns/1ps
`default_nettype none

module testcard (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [11:0] h_act,            // active width
    input  wire [11:0] v_act,            // frame lines, not field lines
    input  wire        de,
    input  wire [11:0] xpos,
    input  wire [11:0] ypos,
    output reg  [5:0]  r,
    output reg  [5:0]  g,
    output reg  [5:0]  b
);

    /* Geometry is now runtime, so every derived value has to be cheap. Eight
     * bars and sixteen ramp steps are shifts. The two band boundaries use
     * 5/8 and 3/4 rather than the 60% and 75% they approximate, which costs a
     * few scan lines and no multiplier. */
    wire [11:0] BARW     = {3'd0, h_act[11:3]};          // /8
    wire [11:0] STEPW    = {4'd0, h_act[11:4]};          // /16
    wire [11:0] BARS_END = {3'd0, v_act[11:3]} + {2'd0, v_act[11:2]};  // 5/8
    wire [11:0] HALF_END = {1'd0, v_act[11:1]} + {2'd0, v_act[11:2]};  // 3/4
    wire [11:0] CX       = {1'd0, h_act[11:1]};
    wire [11:0] CY       = {1'd0, v_act[11:1]};
    wire [11:0] X_LAST   = h_act - 12'd1;
    wire [11:0] Y_LAST   = v_act - 12'd1;

    // ---- horizontal position decode ----
    reg [11:0] bar_px, step_px;
    reg [2:0]  bar;
    reg [3:0]  step;

    wire line_start = de && (xpos == 12'd0);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bar_px <= 12'd0; bar  <= 3'd0;
            step_px<= 12'd0; step <= 4'd0;
        end else if (line_start) begin
            bar_px <= 12'd1; bar  <= 3'd0;
            step_px<= 12'd1; step <= 4'd0;
        end else if (de) begin
            if (bar_px == BARW - 12'd1) begin
                bar_px <= 12'd0;
                bar    <= bar + 3'd1;
            end else bar_px <= bar_px + 12'd1;

            if (step_px == STEPW - 12'd1) begin
                step_px <= 12'd0;
                step    <= step + 4'd1;
            end else step_px <= step_px + 12'd1;
        end
    end

    // ---- bar colours: white yellow cyan green magenta red blue black ----
    reg [2:0] bit_rgb;
    always @* begin
        case (bar)
            3'd0: bit_rgb = 3'b111;
            3'd1: bit_rgb = 3'b110;
            3'd2: bit_rgb = 3'b011;
            3'd3: bit_rgb = 3'b010;
            3'd4: bit_rgb = 3'b101;
            3'd5: bit_rgb = 3'b100;
            3'd6: bit_rgb = 3'b001;
            default: bit_rgb = 3'b000;
        endcase
    end

    // 63/31 full/half amplitude, and a 0..63 ramp from a 4-bit step
    wire [5:0] grey = {step, step[3:2]};

    wire border = (xpos == 12'd0) || (xpos == X_LAST) ||
                  (ypos == 12'd0) || (ypos == Y_LAST);

    wire crosshair = (xpos == CX) || (ypos == CY);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r <= 6'd0; g <= 6'd0; b <= 6'd0;
        end else if (!de) begin
            r <= 6'd0; g <= 6'd0; b <= 6'd0;
        end else if (border || crosshair) begin
            r <= 6'd63; g <= 6'd63; b <= 6'd63;
        end else if (ypos < BARS_END) begin
            r <= bit_rgb[2] ? 6'd63 : 6'd0;
            g <= bit_rgb[1] ? 6'd63 : 6'd0;
            b <= bit_rgb[0] ? 6'd63 : 6'd0;
        end else if (ypos < HALF_END) begin
            r <= bit_rgb[2] ? 6'd31 : 6'd0;
            g <= bit_rgb[1] ? 6'd31 : 6'd0;
            b <= bit_rgb[0] ? 6'd31 : 6'd0;
        end else begin
            r <= grey; g <= grey; b <= grey;
        end
    end

endmodule

`default_nettype wire
