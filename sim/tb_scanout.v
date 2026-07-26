// SPDX-License-Identifier: GPL-2.0-or-later
// Exercises the framebuffer reader three ways: the format unpack on its own, the
// full path from raster position through block RAM to RGB666, and the bounds
// clamp.
//
// The path test is also the latency assertion. scanout must cost exactly one
// clock from xpos to r/g/b, matching testcard.v, or the source mux in
// blitscrt_top is not transparent and the picture shifts within the active
// window. The probes here compare against a one-clock delay of de/xpos/ypos --
// the same delay blitscrt_top applies -- so a two-clock scanout puts the
// previous pixel under every probe and every check fails.
`timescale 1ns/1ps

module tb_scanout;

    reg clk = 0, rst_n = 0;
    always #20 clk = ~clk;                 // 25 MHz, arbitrary

    integer fails = 0;

    task ck(input [359:0] name, input [17:0] got, input [17:0] want);
    begin
        if (got === want) $display("  %-0s   ok", name);
        else begin
            $display("  %-0s   FAIL  got %06x want %06x", name, got, want);
            fails = fails + 1;
        end
    end endtask

    // -----------------------------------------------------------------------
    // 1. the unpack, driven directly
    // -----------------------------------------------------------------------
    reg [31:0] q_drv = 32'd0;
    reg [2:0]  fmt_drv = 3'd0;
    wire [5:0] ur, ug, ub;
    wire [19:0] dummy_addr;

    scanout u_unpack (
        .clk(clk), .rst_n(rst_n),
        .de(1'b1), .xpos(12'd0), .ypos(12'd0),
        .sc_w(12'd4095), .sc_h(12'd4095), .sc_pitch(12'd1),
        .sc_format(fmt_drv), .hdouble(1'b0), .vdouble(1'b0),
        .mem_addr(dummy_addr), .mem_q(q_drv),
        .r(ur), .g(ug), .b(ub)
    );

    task unpack_is(input [359:0] name, input [2:0] f, input [31:0] word,
                   input [5:0] er, input [5:0] eg, input [5:0] eb);
    begin
        fmt_drv = f; q_drv = word;
        @(posedge clk); @(posedge clk);      // let de_q settle
        #1;
        ck(name, {ur, ug, ub}, {er, eg, eb});
    end endtask

    // -----------------------------------------------------------------------
    // 2. the full path: 16x8 framebuffer doubled into a 32x16 raster
    // -----------------------------------------------------------------------
    localparam integer H_SY=4, H_BP=4, H_ACT=32, H_FP=4;
    localparam integer V_SY=2, V_BP=2, V_ACT=16, V_FP=2;

    wire hs, vs, cs, de;
    wire [11:0] hcnt, lcnt, xpos, ypos;
    wire field, vblank, field_start;

    video_timing u_timing (
        .clk(clk), .rst_n(rst_n),
        .h_sy(H_SY[11:0]), .h_bp(H_BP[11:0]), .h_act(H_ACT[11:0]), .h_fp(H_FP[11:0]),
        .v_sy(V_SY[11:0]), .v_bp(V_BP[11:0]), .v_act(V_ACT[11:0]), .v_fp(V_FP[11:0]),
        .interlace(1'b0),
        .hs(hs), .vs(vs), .cs(cs), .de(de),
        .hcnt(hcnt), .lcnt(lcnt), .xpos(xpos), .ypos(ypos),
        .field(field), .vblank(vblank), .field_start(field_start)
    );

    reg  [11:0] sc_w = 12'd16;
    reg         we = 0;
    reg  [16:0] waddr = 0;
    reg  [15:0] wdata = 0;
    wire [19:0] mem_addr;
    wire [15:0] mem_q;

    scanout_ram #(.DW(16), .AW(17), .WORDS(128), .INIT_FILE("")) u_fb (
        .wclk(clk), .we(we), .waddr(waddr), .wdata(wdata),
        .rclk(clk), .raddr(mem_addr[16:0]), .rdata(mem_q)
    );

    wire [5:0] sc_r, sc_g, sc_b;

    scanout u_path (
        .clk(clk), .rst_n(rst_n),
        .de(de), .xpos(xpos), .ypos(ypos),
        .sc_w(sc_w), .sc_h(12'd8), .sc_pitch(12'd16),
        .sc_format(3'd0),                  // RGB565
        .hdouble(1'b1), .vdouble(1'b1),
        .mem_addr(mem_addr), .mem_q({16'd0, mem_q}),
        .r(sc_r), .g(sc_g), .b(sc_b)
    );

    /* The same one-clock delay blitscrt_top applies to de/xpos/ypos so the
     * testcard's registered output lines up. scanout has to land here too. */
    reg de_d; reg [11:0] x_d, y_d;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin de_d <= 0; x_d <= 0; y_d <= 0; end
        else begin de_d <= de; x_d <= xpos; y_d <= ypos; end
    end

    task fbwr(input [11:0] sx, input [11:0] sy, input [15:0] v);
    begin
        @(posedge clk); we <= 1; waddr <= sy * 16 + sx; wdata <= v;
        @(posedge clk); we <= 0;
    end endtask

    /* Latch what the raster showed at a given frame coordinate. */
    reg [17:0] seen [0:31][0:15];
    reg        capture = 0;
    integer    cx, cy;
    always @(posedge clk) begin
        if (capture && de_d && x_d < 32 && y_d < 16)
            seen[x_d][y_d] <= {sc_r, sc_g, sc_b};
    end

    task grab_frame;
    begin
        for (cx = 0; cx < 32; cx = cx + 1)
            for (cy = 0; cy < 16; cy = cy + 1)
                seen[cx][cy] <= 18'h3FFFF;      // poison
        @(negedge vblank);                       // start of active video
        capture = 1;
        @(posedge vblank);                       // whole frame captured
        capture = 0;
    end endtask

    initial begin
        $dumpfile("sim/tb_scanout.vcd");
        $dumpvars(0, tb_scanout);

        repeat (4) @(posedge clk);
        rst_n = 1;
        repeat (4) @(posedge clk);

        $display("format unpack to RGB666");
        // RGB565: red and blue gain their own MSB as a low bit, green is 6 bits
        unpack_is("rgb565  full red      ", 3'd0, 32'h0000_F800, 6'd63, 6'd0,  6'd0);
        unpack_is("rgb565  full green    ", 3'd0, 32'h0000_07E0, 6'd0,  6'd63, 6'd0);
        unpack_is("rgb565  full blue     ", 3'd0, 32'h0000_001F, 6'd0,  6'd0,  6'd63);
        unpack_is("rgb565  white         ", 3'd0, 32'h0000_FFFF, 6'd63, 6'd63, 6'd63);
        unpack_is("rgb565  black         ", 3'd0, 32'h0000_0000, 6'd0,  6'd0,  6'd0);
        unpack_is("rgb565  one lsb each  ", 3'd0, 32'h0000_0821, 6'd2,  6'd1,  6'd2);

        // RGB888/XRGB8888: 0x00RRGGBB, eight bits truncated to the ladder's six
        unpack_is("rgb888  full scale    ", 3'd1, 32'h00FF_FFFF, 6'd63, 6'd63, 6'd63);
        unpack_is("rgb888  mid grey      ", 3'd1, 32'h0080_8080, 6'd32, 6'd32, 6'd32);
        unpack_is("rgb888  red only      ", 3'd1, 32'h00FF_0000, 6'd63, 6'd0,  6'd0);
        unpack_is("xrgb    ignores alpha ", 3'd2, 32'hFF00_FF00, 6'd0,  6'd63, 6'd0);

        // RGB332: each field repeated, so full scale in is full scale out
        unpack_is("rgb332  full scale    ", 3'd3, 32'h0000_00FF, 6'd63, 6'd63, 6'd63);
        unpack_is("rgb332  red only      ", 3'd3, 32'h0000_00E0, 6'd63, 6'd0,  6'd0);
        unpack_is("rgb332  blue only     ", 3'd3, 32'h0000_0003, 6'd0,  6'd0,  6'd63);
        unpack_is("rgb332  black         ", 3'd3, 32'h0000_0000, 6'd0,  6'd0,  6'd0);

        // -------------------------------------------------------------------
        $display("");
        $display("address generation, 16x8 buffer doubled into a 32x16 raster");

        fbwr(0,  0, 16'hF81F);      // magenta
        fbwr(1,  0, 16'h07E0);      // green
        fbwr(0,  1, 16'h001F);      // blue
        fbwr(8,  4, 16'h0821);      // one lsb per channel
        fbwr(15, 7, 16'hFFFF);      // white, last pixel of the buffer
        fbwr(7,  0, 16'hF800);      // last in bounds once sc_w drops to 8

        grab_frame;

        ck("pixel (0,0)  from fb(0,0)      ", seen[0][0],   {6'd63, 6'd0,  6'd63});
        ck("pixel (1,0)  same source pixel ", seen[1][0],   {6'd63, 6'd0,  6'd63});
        ck("pixel (0,1)  line doubled      ", seen[0][1],   {6'd63, 6'd0,  6'd63});
        ck("pixel (1,1)  both doubled      ", seen[1][1],   {6'd63, 6'd0,  6'd63});
        ck("pixel (2,0)  from fb(1,0)      ", seen[2][0],   {6'd0,  6'd63, 6'd0});
        ck("pixel (3,1)  from fb(1,0)      ", seen[3][1],   {6'd0,  6'd63, 6'd0});
        ck("pixel (0,2)  from fb(0,1)      ", seen[0][2],   {6'd0,  6'd0,  6'd63});
        ck("pixel (16,8) from fb(8,4)      ", seen[16][8],  {6'd2,  6'd1,  6'd2});
        ck("pixel (30,14) from fb(15,7)    ", seen[30][14], {6'd63, 6'd63, 6'd63});
        ck("pixel (31,15) last of the pair ", seen[31][15], {6'd63, 6'd63, 6'd63});

        // -------------------------------------------------------------------
        $display("");
        $display("bounds clamp");

        sc_w = 12'd8;              // right half of the raster now has no source
        grab_frame;

        ck("inside  (0,0) still shown      ", seen[0][0],   {6'd63, 6'd0,  6'd63});
        ck("inside  (15,0) last in bounds  ", seen[15][0],  {6'd63, 6'd0, 6'd0});
        ck("outside (16,0) reads black     ", seen[16][0],  18'd0);
        ck("outside (31,15) reads black    ", seen[31][15], 18'd0);

        $display("");
        if (fails == 0) $display("PASS");
        else            $display("FAIL  %0d checks", fails);
        $finish;
    end

    initial begin
        #4000000;
        $display("FAIL  timeout");
        $finish;
    end

endmodule
