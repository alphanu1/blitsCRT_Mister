// SPDX-License-Identifier: GPL-2.0-or-later
// Exercises the register slave the way the daemon drives it: identify, stage a
// mode, apply it, and confirm the video side only sees the new timing at a
// vblank and only as a complete set.
`timescale 1ns/1ps

module tb_regs;

    reg clk = 0, rst_n = 0;             // 50 MHz bus
    always #10 clk = ~clk;

    reg clk_pix = 0, vid_rst_n = 0;     // 12.6 MHz video
    always #39.68254 clk_pix = ~clk_pix;

    reg [13:0] address = 0;
    reg        read = 0, write = 0;
    reg [31:0] writedata = 0;
    wire [31:0] readdata;
    wire waitrequest;

    reg vblank = 0, field = 0, pll_locked = 1, hdmi_configured = 1;

    wire [11:0] h_sy,h_bp,h_act,h_fp,v_sy,v_bp,v_act,v_fp;
    wire interlace, scanout_en, testcard_en, overlay_en, csync_en, hdmi_en;
    wire [31:0] pclk_khz, sc_base, sc_stride;
    wire [2:0] sc_format;
    wire [8:0] pll_m, pll_n, pll_c;
    wire pll_apply, char_we;
    wire [12:0] char_addr;
    wire [7:0] char_data;
    wire       hps_alive;
    wire [1:0] host_state;

    blitscrt_regs dut (
        .clk(clk), .rst_n(rst_n), .address(address), .read(read),
        .write(write), .writedata(writedata), .readdata(readdata),
        .waitrequest(waitrequest),
        .clk_pix(clk_pix), .vid_cfg_rst_n(vid_rst_n), .vblank(vblank),
        .field(field), .pll_locked(pll_locked),
        .hdmi_configured(hdmi_configured),
        .pll_locked_raw(1'b1), .pll_start_wr(1'b0), .pll_cnt_wr(1'b0),
        .pll_wait(1'b0), .pll_accept(1'b0), .bus_stalled(1'b0),
        .scanout_underrun_tog(1'b0), .scanout_beats(16'd0),
        .live_hsy(12'd60), .live_hbp(12'd76), .live_hact(12'd640), .live_hfp(12'd24),
        .live_vsy(12'd3),  .live_vbp(12'd16), .live_vact(12'd240), .live_vfp(12'd3),
        .live_ilace(1'b1), .live_clksel(2'd2),
        .h_sy(h_sy),.h_bp(h_bp),.h_act(h_act),.h_fp(h_fp),
        .v_sy(v_sy),.v_bp(v_bp),.v_act(v_act),.v_fp(v_fp),
        .interlace(interlace), .pclk_khz(pclk_khz),
        .scanout_en(scanout_en), .testcard_en(testcard_en),
        .overlay_en(overlay_en), .csync_en(csync_en), .hdmi_en(hdmi_en),
        .hps_timing(), .hps_timing_bus(),
        .sc_base(sc_base), .sc_stride(sc_stride), .sc_format(sc_format),
        .sc_w(), .sc_h(),
        .pll_m(pll_m), .pll_n(pll_n), .pll_c(pll_c), .pll_apply(pll_apply),
        .char_we(char_we), .char_addr(char_addr), .char_data(char_data),
        .hps_alive(hps_alive), .host_state(host_state)
    );

    integer fails = 0;

    task wr(input [13:0] a, input [31:0] d);
    begin
        @(posedge clk); address <= a; writedata <= d; write <= 1;
        @(posedge clk); write <= 0;
        @(posedge clk);            /* registered outputs settle */
    end endtask

    task rd(input [13:0] a);
    begin
        @(posedge clk); address <= a; read <= 1;
        @(posedge clk); read <= 0;
        @(posedge clk);
    end endtask

    task chk(input [55*8:1] what, input cond);
    begin
        $display("  %-0s %s", what, cond ? "ok" : "FAIL");
        if (!cond) fails = fails + 1;
    end endtask

    integer i;
    /* Blocking assignments: this is a monitor, and the checks read it in the
     * same delta the write completes. */
    reg cap_we; reg [12:0] cap_addr; reg [7:0] cap_data;
    always @(posedge clk) if (char_we) begin
        cap_we = 1'b1; cap_addr = char_addr; cap_data = char_data;
    end

    initial begin
        #100 rst_n = 1; vid_rst_n = 1;
        repeat (4) @(posedge clk);

        $display("identify");
        rd(14'h000); chk("ID reads BCRT", readdata == 32'h42435254);
        rd(14'h004); chk("VERSION reads 3.9", readdata == 32'h0003_0009);

        /* The PLL reconfig aperture at 0x1000 used to decode as register 0x00,
         * so a modeset wrote the M counter into H_SY, the C counter into H_BP
         * and the START word into CTRL -- then read STATUS from VERSION and
         * took it for success. Nothing in that window may reach these. */
        wr(14'h008, 32'h0000_0016);              /* known CTRL */
        wr(14'h010, 32'd60);                     /* known H_SY */
        wr(14'h014, 32'd76);                     /* known H_BP */
        wr(14'h1008, 32'h0000_0001);             /* PLL START */
        wr(14'h1010, 32'd999);                   /* PLL M */
        wr(14'h1014, 32'd888);                   /* PLL C */
        rd(14'h008); chk("PLL window leaves CTRL alone", readdata == 32'h16);
        rd(14'h010); chk("PLL window leaves H_SY alone", readdata == 32'd60);
        rd(14'h014); chk("PLL window leaves H_BP alone", readdata == 32'd76);

        wr(14'h008, 32'h0000_0036);              /* CTRL_HPS_TIMING | defaults */
        rd(14'h008); chk("CTRL carries the ownership bit", readdata == 32'h36);
        wr(14'h008, 32'h0000_0016);
        rd(14'h00C); chk("STATUS shows PLL locked and HDMI configured",
                         readdata[0] == 1'b1 && readdata[1] == 1'b1);

        $display("");
        $display("staging a mode does not disturb the video side");
        wr(14'h010, 32'd96);  wr(14'h014, 32'd48);
        wr(14'h018, 32'd640); wr(14'h01C, 32'd16);
        wr(14'h020, 32'd2);   wr(14'h024, 32'd33);
        wr(14'h028, 32'd480); wr(14'h02C, 32'd10);
        wr(14'h030, 32'd0);                    // progressive
        wr(14'h040, 32'd25200);
        repeat (20) @(posedge clk_pix);
        chk("video still on the reset timing",
            h_sy == 12'd60 && h_act == 12'd640 && v_act == 12'd240 &&
            interlace == 1'b1 && pclk_khz == 32'd12600);

        $display("");
        $display("apply, then a vblank");
        wr(14'h044, 32'd1);
        rd(14'h00C); chk("STATUS reports a modeset pending", readdata[4] == 1'b1);
        repeat (20) @(posedge clk_pix);
        chk("still not latched without a vblank",
            h_sy == 12'd60 && interlace == 1'b1);

        @(posedge clk_pix); vblank = 1;
        repeat (4) @(posedge clk_pix);
        vblank = 0;
        repeat (4) @(posedge clk_pix);

        chk("whole set latched at the vblank",
            h_sy == 12'd96 && h_bp == 12'd48 && h_act == 12'd640 &&
            h_fp == 12'd16 && v_sy == 12'd2 && v_bp == 12'd33 &&
            v_act == 12'd480 && v_fp == 12'd10 &&
            interlace == 1'b0 && pclk_khz == 32'd25200);
        repeat (10) @(posedge clk);
        rd(14'h00C); chk("pending clears once acknowledged", readdata[4] == 1'b0);

        $display("");
        $display("PLL counters and the apply pulse");
        wr(14'h034, 32'd126); wr(14'h038, 32'd5); wr(14'h03C, 32'd50);
        @(posedge clk);
        chk("counters staged", pll_m == 9'd126 && pll_n == 9'd5 && pll_c == 9'd50);
        rd(14'h034); chk("M reads back", readdata == 32'd126);

        $display("");
        $display("control bits reach the video side");
        wr(14'h008, 32'h1F);
        repeat (6) @(posedge clk_pix);
        chk("all five control bits set",
            scanout_en && testcard_en && overlay_en && csync_en && hdmi_en);
        wr(14'h008, 32'h00);
        repeat (6) @(posedge clk_pix);
        chk("and clear", !scanout_en && !testcard_en && !overlay_en);

        $display("");
        $display("character buffer window");
        cap_we = 0;
        wr(14'h2000 + 14'd5, 32'h41);
        @(posedge clk);
        chk("write lands at the right offset with the right byte",
            cap_we && cap_addr == 13'd5 && cap_data == 8'h41);
        cap_we = 0;
        wr(14'h2000 + 14'd8191, 32'h5A);
        @(posedge clk);
        chk("top of the buffer reachable",
            cap_we && cap_addr == 13'd8191 && cap_data == 8'h5A);
        cap_we = 0;
        wr(14'h010, 32'd96);
        @(posedge clk);
        chk("a register write does not touch the character buffer", !cap_we);

        $display("");
        $display("scanout memory registers");
        wr(14'h050, 32'h0200_0000);
        wr(14'h054, 32'd1920);
        wr(14'h058, 32'd1);
        wr(14'h044, 32'd1);
        @(posedge clk_pix); vblank = 1;
        repeat (4) @(posedge clk_pix); vblank = 0;
        repeat (4) @(posedge clk_pix);
        chk("base, stride and format latched",
            sc_base == 32'h0200_0000 && sc_stride == 32'd1920 &&
            sc_format == 3'd1);

        $display("");
        $display("heartbeat watchdog");
        // the watchdog samples once per field, so toggle field to advance it
        for (i = 0; i < 120; i = i + 1) begin
            repeat (4) @(posedge clk_pix); field = ~field;
        end
        chk("hps_alive low when no heartbeat", hps_alive == 1'b0);
        // beat it across several fields: alive should assert
        for (i = 0; i < 8; i = i + 1) begin
            wr(14'h064, i + 1);
            repeat (4) @(posedge clk_pix); field = ~field;
            repeat (4) @(posedge clk_pix); field = ~field;
        end
        chk("hps_alive high once heartbeat moves", hps_alive == 1'b1);
        @(posedge clk_pix); field = 1'b0;
        wr(14'h068, 32'd2);
        repeat (40) begin @(posedge clk_pix); field = ~field; end
        chk("host_state reflects the written value", host_state == 2'd2);
        // stop beating: alive should drop after the timeout
        for (i = 0; i < 120; i = i + 1) begin
            repeat (4) @(posedge clk_pix); field = ~field;
        end
        chk("hps_alive drops when heartbeat stops", hps_alive == 1'b0);

        $display("");
        if (fails) $display("FAIL"); else $display("PASS");
        $finish;
    end

    initial begin #500000; $display("TIMEOUT"); $finish; end

endmodule
