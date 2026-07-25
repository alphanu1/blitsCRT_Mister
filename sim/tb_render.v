// Captures every active pixel the RTL drives for one frame and writes
// x,y,r,g,b so it can be rendered to PNG. Verifies the test card and the
// overlay against the real datapath rather than a mock-up.
`timescale 1ns/1ps

module tb_render;

`ifdef RENDER_INTERLACED
    localparam integer H_SY=60, H_BP=76, H_ACT=640, H_FP=24;
    localparam integer V_SY=3,  V_BP=16, V_ACT=240, V_FP=3;
    localparam integer ILACE=1;
    localparam integer BANK=1;
    localparam integer V_FRAME=480;
    localparam real    HALFP = 39.68254;      // 12.600 MHz
`else
    localparam integer H_SY=60, H_BP=76, H_ACT=640, H_FP=24;
    localparam integer V_SY=3,  V_BP=16, V_ACT=240, V_FP=3;
    localparam integer ILACE=0;
    localparam integer BANK=0;
    localparam integer V_FRAME=240;
    localparam real    HALFP = 39.68254;      // 12.600 MHz
`endif

    reg clk = 0, rst_n = 0;
    always #(HALFP) clk = ~clk;

    wire hs, vs, cs, de;
    wire [11:0] hcnt, lcnt, xpos, ypos;
    wire field, vblank, field_start;

    video_timing u_timing (
        .clk(clk), .rst_n(rst_n),
        .h_sy(H_SY[11:0]), .h_bp(H_BP[11:0]), .h_act(H_ACT[11:0]), .h_fp(H_FP[11:0]),
        .v_sy(V_SY[11:0]), .v_bp(V_BP[11:0]), .v_act(V_ACT[11:0]), .v_fp(V_FP[11:0]),
        .interlace(ILACE[0]), .hs(hs), .vs(vs), .cs(cs), .de(de),
        .hcnt(hcnt), .lcnt(lcnt), .xpos(xpos), .ypos(ypos),
        .field(field), .vblank(vblank), .field_start(field_start)
    );

    wire [5:0] tc_r, tc_g, tc_b;
    testcard u_card (
        .clk(clk), .rst_n(rst_n),
        .h_act(H_ACT[11:0]), .v_act(V_FRAME[11:0]),
        .de(de), .xpos(xpos), .ypos(ypos),
        .r(tc_r), .g(tc_g), .b(tc_b)
    );

    reg de_card; reg [11:0] x_card, y_card;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin de_card<=0; x_card<=0; y_card<=0; end
        else begin de_card<=de; x_card<=xpos; y_card<=ypos; end
    end

    wire [12:0] char_addr; wire [7:0] char_data;
    wire [9:0]  font_addr; wire [7:0] font_data;

    char_ram u_chars (.wclk(clk), .we(1'b0), .waddr(13'd0), .wdata(8'd0),
                      .rclk(clk), .raddr(char_addr), .rdata(char_data));
    font_rom u_font  (.clk(clk), .addr(font_addr), .data(font_data));

    wire de_px; wire [5:0] px_r, px_g, px_b;
    overlay u_overlay (
        .clk(clk), .rst_n(rst_n), .double_h(ILACE[0]), .bank(BANK[1:0]),
        .hps_alive(1'b1),
        .de_in(de_card), .xpos(x_card), .ypos(y_card),
        .r_in(tc_r), .g_in(tc_g), .b_in(tc_b), .enable(1'b1),
        .char_addr(char_addr), .char_data(char_data),
        .font_addr(font_addr), .font_data(font_data),
        .de_out(de_px), .r_out(px_r), .g_out(px_g), .b_out(px_b)
    );

    // xpos/ypos delayed to sit alongside the pixel that came out of the chain
    reg [11:0] x_d1, x_d2, x_d3, y_d1, y_d2, y_d3;
    always @(posedge clk) begin
        x_d1 <= x_card; x_d2 <= x_d1; x_d3 <= x_d2;
        y_d1 <= y_card; y_d2 <= y_d1; y_d3 <= y_d2;
    end

    integer fh, n, fields_seen;
    reg started;
    reg fld_d;

    initial begin
        fh = $fopen("render.txt", "w");
        n = 0; fields_seen = 0; started = 0;
        #1000 rst_n = 1;

        // start at the top of an even field
        @(posedge vs);
        while (field !== 1'b0) @(posedge vs);
        started = 1;
        fld_d = field;

        forever begin
            @(posedge clk);
            if (de_px) begin
                $fwrite(fh, "%0d %0d %0d %0d %0d\n", x_d3, y_d3, px_r, px_g, px_b);
                n = n + 1;
            end
            if (field !== fld_d) begin
                fields_seen = fields_seen + 1;
                fld_d = field;
                if (fields_seen == (ILACE ? 2 : 1)) begin
                    $fclose(fh);
                    $display("rendered %0d pixels (expect %0d)", n, H_ACT*V_FRAME);
                    $finish;
                end
            end
            if (!ILACE && vs && n > 1000 && x_d3 == 0 && y_d3 == 0) begin
                // progressive: one vsync is one frame
            end
        end
    end

    // progressive has no field toggle, so stop on the second vsync instead
    initial begin
        if (ILACE == 0) begin
            @(posedge rst_n);
            @(posedge vs);
            @(negedge vs);
            @(posedge vs);
            #1000;
            $fclose(fh);
            $display("rendered %0d pixels (expect %0d)", n, H_ACT*V_FRAME);
            $finish;
        end
    end

    initial begin
        #200_000_000; $display("TIMEOUT n=%0d", n); $finish;
    end

endmodule
