// Measures line rate, field/frame rate, active pixel counts and total line
// count straight out of the RTL, for both target modes.
`timescale 1ns/1ps

module tb_timing;

    integer done_p = 0, done_i = 0;

    // ---------------- 320x240p60 @ 6.400 MHz ----------------
    reg clk_p = 0, rst_p = 0;
    always #78.125 clk_p = ~clk_p;      // 6.400 MHz

    wire hs_p, vs_p, cs_p, de_p, vb_p, fs_p, fld_p;
    wire [11:0] hc_p, vc_p, x_p, y_p;

    video_timing dut_p (
        .clk(clk_p), .rst_n(rst_p),
        .h_sy(12'd30), .h_bp(12'd32), .h_act(12'd320), .h_fp(12'd24),
        .v_sy(12'd3),  .v_bp(12'd16), .v_act(12'd240), .v_fp(12'd3),
        .interlace(1'b0),
        .hs(hs_p), .vs(vs_p), .cs(cs_p), .de(de_p),
        .hcnt(hc_p), .lcnt(vc_p), .xpos(x_p), .ypos(y_p),
        .field(fld_p), .vblank(vb_p), .field_start(fs_p)
    );

    // ---------------- 640x480i60 @ 12.600 MHz ----------------
    reg clk_i = 0, rst_i = 0;
    always #39.68254 clk_i = ~clk_i;    // 12.600 MHz

    wire hs_i, vs_i, cs_i, de_i, vb_i, fs_i, fld_i;
    wire [11:0] hc_i, vc_i, x_i, y_i;

    video_timing dut_i (
        .clk(clk_i), .rst_n(rst_i),
        .h_sy(12'd60), .h_bp(12'd76), .h_act(12'd640), .h_fp(12'd24),
        .v_sy(12'd3),  .v_bp(12'd16), .v_act(12'd240), .v_fp(12'd3),
        .interlace(1'b1),
        .hs(hs_i), .vs(vs_i), .cs(cs_i), .de(de_i),
        .hcnt(hc_i), .lcnt(vc_i), .xpos(x_i), .ypos(y_i),
        .field(fld_i), .vblank(vb_i), .field_start(fs_i)
    );

    // ================= progressive measurement =================
    real th0, th1, tv0, tv1;
    integer nlines, npix, ymin, ymax, xmax;
    reg hs_d;

    initial begin : prog_measure
        #500 rst_p = 1;
        @(negedge vs_p);
        @(posedge hs_p); th0 = $realtime;
        @(posedge hs_p); th1 = $realtime;

        @(posedge vs_p);
        tv0 = $realtime;
        nlines = 0; npix = 0; ymin = 4095; ymax = 0; xmax = 0; hs_d = 1'b1;

        forever begin
            @(posedge clk_p);
            if (hs_p && !hs_d) nlines = nlines + 1;
            hs_d = hs_p;
            if (de_p) begin
                npix = npix + 1;
                if (y_p > ymax) ymax = y_p;
                if (y_p < ymin) ymin = y_p;
                if (x_p > xmax) xmax = x_p;
            end
            if (nlines == 262 && hc_p == 12'd1) begin
                tv1 = $realtime;
                $display("=== 320x240p60, pclk 6.400 MHz, H_TOT=406 V_TOT=262 ===");
                $display("  line period    %0.4f us    -> %0.4f kHz",
                         (th1-th0)/1000.0, 1e6/(th1-th0));
                $display("  frame period   %0.4f ms    -> %0.4f Hz",
                         (tv1-tv0)/1e6, 1e9/(tv1-tv0));
                $display("  hsync/frame    %0d  (expect 262)", nlines);
                $display("  active pixels  %0d  (expect %0d)", npix, 320*240);
                $display("  xpos range     0..%0d   ypos range %0d..%0d",
                         xmax, ymin, ymax);
                $display("");
                done_p = 1;
                if (done_i) $finish;
                disable prog_measure;
            end
        end
    end

    // ================= interlaced measurement =================
    real ith0, ith1, itf0, itf1, itfr;
    integer ilines, ipix, iymin, iymax, ixmax, fields;
    reg ihs_d, ifld_d;

    initial begin : ilace_measure
        #500 rst_i = 1;
        @(negedge vs_i);
        @(posedge hs_i); ith0 = $realtime;
        @(posedge hs_i); ith1 = $realtime;

        @(posedge vs_i);
        while (fld_i !== 1'b0) @(posedge vs_i);
        itf0 = $realtime;

        ilines = 0; ipix = 0; iymin = 4095; iymax = 0; ixmax = 0;
        fields = 0; ihs_d = 1'b1; ifld_d = fld_i;

        forever begin
            @(posedge clk_i);
            if (hs_i && !ihs_d) ilines = ilines + 1;
            ihs_d = hs_i;
            if (de_i) begin
                ipix = ipix + 1;
                if (y_i > iymax) iymax = y_i;
                if (y_i < iymin) iymin = y_i;
                if (x_i > ixmax) ixmax = x_i;
            end
            if (fld_i !== ifld_d) begin
                fields = fields + 1;
                if (fields == 1) begin
                    itf1 = $realtime;
                    $display("=== 640x480i60, pclk 12.600 MHz, H_TOT=800 V_TOT=262/field ===");
                    $display("  line period    %0.4f us    -> %0.4f kHz",
                             (ith1-ith0)/1000.0, 1e6/(ith1-ith0));
                    $display("  field period   %0.4f ms    -> %0.4f Hz field rate",
                             (itf1-itf0)/1e6, 1e9/(itf1-itf0));
                end
                if (fields == 2) begin
                    itfr = $realtime;
                    $display("  frame period   %0.4f ms    -> %0.4f Hz frame rate",
                             (itfr-itf0)/1e6, 1e9/(itfr-itf0));
                    $display("  hsync/frame    %0d  (expect 525)", ilines);
                    $display("  active pixels  %0d  (expect %0d)", ipix, 640*480);
                    $display("  xpos range     0..%0d   ypos range %0d..%0d",
                             ixmax, iymin, iymax);
                    $display("");
                    done_i = 1;
                    if (done_p) $finish;
                    disable ilace_measure;
                end
            end
            ifld_d = fld_i;
        end
    end

    // ---- half-line check: vsync-to-hsync gap must differ between fields ----
    real vse, hse, off_e, off_o;
    initial begin
        off_e = 0.0; off_o = 0.0;
        @(posedge rst_i);
        repeat (2) @(posedge vs_i);
        forever begin
            @(posedge vs_i);
            vse = $realtime;
            @(posedge hs_i);
            hse = $realtime;
            if (fld_i == 1'b0) off_e = hse - vse;
            else               off_o = hse - vse;
            if (off_e > 0.0 && off_o > 0.0) begin
                $display("  half-line check: vsync->hsync gap  even %0.4f us / odd %0.4f us",
                         off_e/1000.0, off_o/1000.0);
                $display("                   difference %0.4f us (expect ~%0.4f us)",
                         ((off_o > off_e) ? off_o-off_e : off_e-off_o)/1000.0,
                         (800.0/12.600e6)*1e6/2.0);
                off_e = 0.0; off_o = 0.0;
            end
        end
    end

    initial begin
        #200_000_000;
        $display("TIMEOUT  done_p=%0d done_i=%0d", done_p, done_i);
        $finish;
    end

endmodule
