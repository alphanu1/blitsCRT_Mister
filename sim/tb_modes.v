// Measures the 31kHz VGA mode, and checks that mode_table selects the right
// default for what is plugged in and cycles correctly on the button.
`timescale 1ns/1ps

module tb_modes;

    // ---------------- 640x480p60 at 25.200 MHz ----------------
    reg clk = 0, rst_n = 0;
    always #19.84127 clk = ~clk;          // 25.200 MHz

    wire hs, vs, cs, de, vb, fs, fld;
    wire [11:0] hc, lc, x, y;

    video_timing u_t (
        .clk(clk), .rst_n(rst_n),
        .h_sy(12'd96), .h_bp(12'd48), .h_act(12'd640), .h_fp(12'd16),
        .v_sy(12'd2),  .v_bp(12'd33), .v_act(12'd480), .v_fp(12'd10),
        .interlace(1'b0),
        .hs(hs), .vs(vs), .cs(cs), .de(de),
        .hcnt(hc), .lcnt(lc), .xpos(x), .ypos(y),
        .field(fld), .vblank(vb), .field_start(fs)
    );

    real th0, th1, tv0, tv1;
    integer nlines, npix, xmax, ymax;
    reg hs_d;
    integer fails = 0;
    integer done_vga = 0, done_sel = 0;

    initial begin : vga_measure
        #500 rst_n = 1;
        @(negedge vs);
        @(posedge hs); th0 = $realtime;
        @(posedge hs); th1 = $realtime;
        @(posedge vs); tv0 = $realtime;
        nlines = 0; npix = 0; xmax = 0; ymax = 0; hs_d = 1'b1;

        forever begin
            @(posedge clk);
            if (hs && !hs_d) nlines = nlines + 1;
            hs_d = hs;
            if (de) begin
                npix = npix + 1;
                if (x > xmax) xmax = x;
                if (y > ymax) ymax = y;
            end
            if (nlines == 525 && hc == 12'd1) begin
                tv1 = $realtime;
                $display("=== 640x480p60, pclk 25.200 MHz, H_TOT=800 V_TOT=525 ===");
                $display("  line period    %0.4f us    -> %0.4f kHz",
                         (th1-th0)/1000.0, 1e6/(th1-th0));
                $display("  frame period   %0.4f ms    -> %0.4f Hz",
                         (tv1-tv0)/1e6, 1e9/(tv1-tv0));
                $display("  hsync/frame    %0d  (expect 525)", nlines);
                $display("  active pixels  %0d  (expect %0d)", npix, 640*480);
                $display("  xpos 0..%0d   ypos 0..%0d", xmax, ymax);
                if (nlines != 525)      begin $display("  FAIL lines"); fails=fails+1; end
                if (npix != 640*480)    begin $display("  FAIL pixels"); fails=fails+1; end
                if (1e6/(th1-th0) < 31.3 || 1e6/(th1-th0) > 31.7)
                                        begin $display("  FAIL line rate"); fails=fails+1; end
                done_vga = 1;
                disable vga_measure;
            end
        end
    end

    // ---------------- mode_table selection ----------------
    reg  mclk = 0, mrst = 0;
    reg  av, hpd, btn;
    wire [1:0] mode, clk_sel;
    wire [11:0] mh_sy, mh_bp, mh_act, mh_fp, mv_sy, mv_bp, mv_act, mv_fp;
    wire mil;
    wire [31:0] mkhz;
    always #10 mclk = ~mclk;

    mode_table #(.DEFAULT_VGA(1), .DEFAULT_HDMI(1), .FORCE_MODE(-1)) u_m (
        .clk(mclk), .rst_n(mrst),
        .av_present(av), .hdmi_hpd(hpd), .btn_cycle(btn),
        .mode(mode),
        .h_sy(mh_sy), .h_bp(mh_bp), .h_act(mh_act), .h_fp(mh_fp),
        .v_sy(mv_sy), .v_bp(mv_bp), .v_act(mv_act), .v_fp(mv_fp),
        .interlace(mil), .clk_sel(clk_sel), .pclk_khz(mkhz)
    );

    task press; begin
        btn = 0; repeat (4) @(posedge mclk);
        btn = 1; repeat (4) @(posedge mclk);
    end endtask

    task expect_mode(input [1:0] want, input [500:0] why);
    begin
        if (mode !== want) begin
            $display("  FAIL %0s: mode %0d, expected %0d", why, mode, want);
            fails = fails + 1;
        end else begin
            $display("  ok   %0s -> mode %0d, %0d kHz, %0dx%0d%s",
                     why, mode, mkhz, mh_act, mil ? mv_act*2 : mv_act,
                     mil ? "i" : "p");
        end
    end
    endtask

    initial begin
        av = 1; hpd = 0; btn = 1; mrst = 0;
        repeat (4) @(posedge mclk);
        mrst = 1;
        repeat (8) @(posedge mclk);

        $display("");
        $display("=== mode_table selection ===");
        expect_mode(2'd1, "analog board fitted, default");

        press; expect_mode(2'd2, "BTN_OSD once");
        press; expect_mode(2'd0, "BTN_OSD twice");
        press; expect_mode(2'd1, "BTN_OSD wraps");

        // no analog board, HDMI sink present
        mrst = 0; av = 0; hpd = 1;
        repeat (4) @(posedge mclk);
        mrst = 1; repeat (8) @(posedge mclk);
        expect_mode(2'd1, "HDMI only, no analog board");

        done_sel = 1;
    end

    /* whichever finishes last reports */
    initial begin
        wait (done_vga && done_sel);
        #1;
        $display("");
        if (fails) $display("FAIL"); else $display("PASS");
        $finish;
    end

    initial begin #50_000_000; $display("TIMEOUT"); $finish; end

endmodule
