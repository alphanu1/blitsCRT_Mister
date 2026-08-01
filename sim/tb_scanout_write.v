// SPDX-License-Identifier: GPL-2.0-or-later
// Exercises the rect write port the way the daemon drives it: seek once, stream a
// run of pixels, and let the pointer follow.
//
// Two halves. The first watches the write port itself -- that the pointer lands
// where it was told, advances by exactly one per word, and reads back so software
// can count what landed. The second wires the whole path together, bus domain
// through memory into the pixel domain, writes a rect over a known background and
// confirms it scans out at the right raster coordinates and nowhere else.
//
// The second half is the one that matters: it is daemon to memory to raster, the
// same silicon a host's damage rectangle will travel through, with only the
// transport above it left to build.
`timescale 1ns/1ps

module tb_scanout_write;

    reg clk = 0, rst_n = 0;                 // 50 MHz bus
    always #10 clk = ~clk;

    reg clk_pix = 0, vid_rst_n = 0;         // 25 MHz pixel, arbitrary
    always #20 clk_pix = ~clk_pix;

    integer fails = 0;

    task chk(input [359:0] name, input ok);
    begin
        if (ok) $display("  %-0s   ok", name);
        else begin $display("  %-0s   FAIL", name); fails = fails + 1; end
    end endtask

    // ---------------- the register slave ----------------
    reg  [13:0] address = 0;
    reg         read = 0, write = 0;
    reg  [31:0] writedata = 0;
    wire [31:0] readdata;
    wire        waitrequest;

    // video-side inputs it needs
    wire        vblank, field;

    wire [11:0] q_hsy, q_hbp, q_hact, q_hfp, q_vsy, q_vbp, q_vact, q_vfp;
    wire        q_ilace;
    wire [31:0] q_khz, q_base, q_stride;
    wire [2:0]  sc_format;
    wire        scanout_en, testcard_en, ovl_en, csync_en, hdmi_en;
    wire [8:0]  q_m, q_n, q_c;
    wire        q_pll_apply, q_char_we;
    wire [12:0] q_char_addr;
    wire [7:0]  q_char_data;
    wire        q_alive;
    wire [1:0]  q_host;

    wire [11:0] lat_w, lat_h;
    wire        sc_we;
    wire [19:0] sc_waddr;
    wire [15:0] sc_wdata;

    localparam integer SC_W = 16, SC_H = 8;

    blitscrt_regs #(.SC_W(SC_W), .SC_H(SC_H), .CAPS(32'h0000_0001)) u_regs (
        .clk(clk), .rst_n(rst_n),
        .address(address), .read(read), .write(write),
        .writedata(writedata), .readdata(readdata), .waitrequest(waitrequest),
        .clk_pix(clk_pix), .vid_cfg_rst_n(vid_rst_n),
        .vblank(vblank), .field(field),
        .pll_locked(1'b1), .hdmi_configured(1'b1),
        .pll_locked_raw(1'b1), .pll_start_wr(1'b0), .pll_cnt_wr(1'b0),
        .pll_wait(1'b0), .pll_accept(1'b0), .bus_stalled(1'b0),
        .scanout_underrun_tog(1'b0), .scanout_beats(16'd0),
        .live_hsy(12'd60), .live_hbp(12'd76), .live_hact(12'd640), .live_hfp(12'd24),
        .live_vsy(12'd3),  .live_vbp(12'd16), .live_vact(12'd240), .live_vfp(12'd3),
        .live_ilace(1'b1), .live_clksel(2'd2),
        .h_sy(q_hsy), .h_bp(q_hbp), .h_act(q_hact), .h_fp(q_hfp),
        .v_sy(q_vsy), .v_bp(q_vbp), .v_act(q_vact), .v_fp(q_vfp),
        .interlace(q_ilace), .pclk_khz(q_khz),
        .scanout_en(scanout_en), .testcard_en(testcard_en),
        .overlay_en(ovl_en), .csync_en(csync_en), .hdmi_en(hdmi_en),
        .hps_timing(), .hps_timing_bus(),
        .sc_base(q_base), .sc_stride(q_stride), .sc_format(sc_format),
        .sc_w(lat_w), .sc_h(lat_h),
        .pll_m(q_m), .pll_n(q_n), .pll_c(q_c), .pll_apply(q_pll_apply),
        .char_we(q_char_we), .char_addr(q_char_addr), .char_data(q_char_data),
        .sc_we(sc_we), .sc_waddr(sc_waddr), .sc_wdata(sc_wdata),
        .hps_alive(q_alive), .host_state(q_host)
    );

    task wr(input [13:0] a, input [31:0] d);
    begin
        @(posedge clk); address <= a; writedata <= d; write <= 1;
        @(posedge clk); write <= 0;
    end endtask

    task rd(input [13:0] a);
    begin
        @(posedge clk); address <= a; read <= 1;
        @(posedge clk); read <= 0;
        @(posedge clk);                     /* registered readdata settles */
    end endtask

    /* Watch the write port so the stream can be checked without reaching into
     * the memory. */
    integer wr_count; reg [19:0] first_addr, last_addr;
    always @(posedge clk) begin
        if (sc_we) begin
            if (wr_count == 0) first_addr <= sc_waddr;
            last_addr <= sc_waddr;
            wr_count  <= wr_count + 1;
        end
    end

    // ---------------- the full path ----------------
    localparam integer H_SY=4, H_BP=4, H_ACT=32, H_FP=4;
    localparam integer V_SY=2, V_BP=2, V_ACT=16, V_FP=2;

    wire hs, vs, cs, de;
    wire [11:0] hcnt, lcnt, xpos, ypos;
    wire fs;

    video_timing u_timing (
        .clk(clk_pix), .rst_n(vid_rst_n),
        .h_sy(H_SY[11:0]), .h_bp(H_BP[11:0]), .h_act(H_ACT[11:0]), .h_fp(H_FP[11:0]),
        .v_sy(V_SY[11:0]), .v_bp(V_BP[11:0]), .v_act(V_ACT[11:0]), .v_fp(V_FP[11:0]),
        .interlace(1'b0),
        .hs(hs), .vs(vs), .cs(cs), .de(de),
        .hcnt(hcnt), .lcnt(lcnt), .xpos(xpos), .ypos(ypos),
        .field(field), .vblank(vblank), .field_start(fs)
    );

    wire [19:0] rd_addr;
    wire [15:0] sc_q;

    /* Written from the bus domain by the register slave, read in the pixel
     * domain by scanout -- exactly the wiring in blitscrt_top. */
    scanout_ram #(.DW(16), .AW(17), .WORDS(SC_W*SC_H), .INIT_FILE("")) u_ram (
        .wclk(clk),     .we(sc_we), .waddr(sc_waddr[16:0]), .wdata(sc_wdata),
        .rclk(clk_pix), .raddr(rd_addr[16:0]), .rdata(sc_q)
    );

    wire [5:0] px_r, px_g, px_b;

    scanout #(.AW(20)) u_scanout (
        .clk(clk_pix), .rst_n(vid_rst_n),
        .de(de), .xpos(xpos), .ypos(ypos),
        .sc_w(SC_W[11:0]), .sc_h(SC_H[11:0]), .sc_pitch(SC_W[11:0]),
        .sc_format(sc_format), .hdouble(1'b1), .vdouble(1'b1),
        .mem_addr(rd_addr), .mem_q({16'd0, sc_q}),
        .r(px_r), .g(px_g), .b(px_b)
    );

    reg de_d; reg [11:0] x_d, y_d;
    always @(posedge clk_pix or negedge vid_rst_n) begin
        if (!vid_rst_n) begin de_d <= 0; x_d <= 0; y_d <= 0; end
        else begin de_d <= de; x_d <= xpos; y_d <= ypos; end
    end

    reg [17:0] seen [0:31][0:15];
    reg capture = 0;
    integer cx, cy;
    always @(posedge clk_pix)
        if (capture && de_d && x_d < 32 && y_d < 16)
            seen[x_d][y_d] <= {px_r, px_g, px_b};

    task grab_frame;
    begin
        @(negedge vblank); capture = 1; @(posedge vblank); capture = 0;
    end endtask

    // ---------------- software-side helpers, mirroring fabric.c ----------------
    task vblank_pulse;
    begin
        @(posedge vblank); repeat (4) @(posedge clk_pix); repeat (4) @(posedge clk);
    end endtask

    task sc_seek(input [19:0] idx);
    begin wr(14'h070, {12'd0, idx}); end endtask

    task sc_word(input [15:0] v);
    begin wr(14'h074, {16'd0, v}); end endtask

    /* What blitscrt_scanout_fill() does: one seek per row, then the run. */
    task sc_fill(input [11:0] x, input [11:0] y,
                 input [11:0] w, input [11:0] h, input [15:0] v);
        integer row, col;
    begin
        for (row = 0; row < h; row = row + 1) begin
            sc_seek((y + row) * SC_W + x);
            for (col = 0; col < w; col = col + 1) sc_word(v);
        end
    end endtask

    integer i;

    initial begin
        wr_count = 0; first_addr = 0; last_addr = 0;
        for (cx = 0; cx < 32; cx = cx + 1)
            for (cy = 0; cy < 16; cy = cy + 1) seen[cx][cy] = 18'h3FFFF;

        repeat (4) @(posedge clk); rst_n = 1; vid_rst_n = 1;
        repeat (4) @(posedge clk);

        $display("geometry and the write pointer");

        rd(14'h078);
        chk("GEOM reports 16x8                 ", readdata == {16'd8, 16'd16});

        rd(14'h004);
        chk("VERSION reads 3.22                ", readdata == 32'h0003_0016);

        rd(14'h07C);
        chk("CAPS reports the build            ", readdata == 32'h0000_0001);

        /* Geometry is writable and staged: the video side must not see it until
         * an APPLY lands on a vblank, or a resize could tear. */
        wr(14'h078, {16'd600, 16'd800});
        rd(14'h078);
        chk("GEOM reads back what was written  ", readdata == {16'd600, 16'd800});
        chk("but the video side still has 16x8 ", lat_w == 12'd16 && lat_h == 12'd8);

        vblank_pulse;
        chk("...unchanged without APPLY        ", lat_w == 12'd16 && lat_h == 12'd8);

        wr(14'h044, 32'd1);                  /* APPLY */
        vblank_pulse;
        chk("APPLY on a vblank latches it      ", lat_w == 12'd800 && lat_h == 12'd600);

        wr(14'h078, {16'd8, 16'd16});        /* put it back for the rect test */
        wr(14'h044, 32'd1);
        vblank_pulse;
        chk("and back again                    ", lat_w == 12'd16 && lat_h == 12'd8);

        rd(14'h070);
        chk("pointer resets to zero            ", readdata == 32'd0);

        sc_seek(20'd100);
        rd(14'h070);
        chk("seek lands where it was told      ", readdata == 32'd100);

        wr_count = 0;
        for (i = 0; i < 8; i = i + 1) sc_word(16'h1000 + i[15:0]);
        rd(14'h070);
        chk("pointer advanced by exactly eight ", readdata == 32'd108);
        chk("eight writes reached the memory   ", wr_count == 8);
        chk("first landed at the seek address  ", first_addr == 20'd100);
        chk("last landed at seek + seven       ", last_addr  == 20'd107);

        // -------------------------------------------------------------------
        $display("");
        $display("rect written over a known background, read back off the raster");

        /* Background first: fill the whole 16x8 memory blue. */
        sc_fill(12'd0, 12'd0, SC_W[11:0], SC_H[11:0], 16'h001F);

        /* Then a 4x2 red rect at (2,1) -- not at the origin, so an address that
         * ignores the row offset cannot pass by accident. */
        sc_fill(12'd2, 12'd1, 12'd4, 12'd2, 16'hF800);

        grab_frame;

        /* hdouble and vdouble are on, so source (sx,sy) covers raster
         * (2sx..2sx+1, 2sy..2sy+1). The rect is source x 2..5, y 1..2, which is
         * raster x 4..11, y 2..5. */
        chk("rect top left    raster (4,2)     ", seen[4][2]   == {6'd63, 6'd0, 6'd0});
        chk("rect bottom right raster (11,5)   ", seen[11][5]  == {6'd63, 6'd0, 6'd0});
        chk("rect interior    raster (7,3)     ", seen[7][3]   == {6'd63, 6'd0, 6'd0});
        chk("just left of it  raster (3,2)     ", seen[3][2]   == {6'd0, 6'd0, 6'd63});
        chk("just right of it raster (12,2)    ", seen[12][2]  == {6'd0, 6'd0, 6'd63});
        chk("just above it    raster (4,1)     ", seen[4][1]   == {6'd0, 6'd0, 6'd63});
        chk("just below it    raster (4,6)     ", seen[4][6]   == {6'd0, 6'd0, 6'd63});
        chk("far corner untouched raster (30,14)", seen[30][14] == {6'd0, 6'd0, 6'd63});

        $display("");
        if (fails == 0) $display("PASS");
        else            $display("FAIL  %0d checks", fails);
        $finish;
    end

    initial begin
        #20000000; $display("FAIL  timeout"); $finish;
    end

endmodule
