`timescale 1ns/1ps
`default_nettype none
//
// tb_csync.v -- composite sync has the broadcast shape, not hs ^ vs.
//
// A monitor's sync separator takes the XOR form. A television's does not: it
// integrates the sync line and needs serration at half-line rate through
// vertical sync, with equalising pulses either side. Given the XOR form a TV
// locks horizontally and rolls vertically -- observed on a Nokia set through
// SCART, which is why this exists.
//
// cs is active high here and inverted at the pad, so a pulse below is sync
// asserted.

module tb_csync;

    reg clk = 0, rst_n = 0;
    always #1 clk = ~clk;

    wire hs, vs, cs, de, field, vblank, field_start;
    wire [11:0] hcnt, lcnt, xpos, ypos;

    /* 320x240p60: 320 332 362 400 / 240 243 246 262 */
    video_timing dut (
        .clk(clk), .rst_n(rst_n),
        .h_sy(12'd30), .h_bp(12'd38), .h_act(12'd320), .h_fp(12'd12),
        .v_sy(12'd3),  .v_bp(12'd16), .v_act(12'd240), .v_fp(12'd3),
        .interlace(1'b0),
        .hs(hs), .vs(vs), .cs(cs), .de(de),
        .hcnt(hcnt), .lcnt(lcnt), .xpos(xpos), .ypos(ypos),
        .field(field), .vblank(vblank), .field_start(field_start)
    );

    integer fails = 0;
    task chk(input [255:0] name, input ok);
        begin
            $write("  %-52s %s\n", name, ok ? "ok" : "FAIL");
            if (!ok) fails = fails + 1;
        end
    endtask

    integer pulses, asserted, total;
    reg d;

    /* Count sync pulses and how long sync is asserted, over one whole line. */
    task scan_line(input [11:0] line);
        begin
            while (!(lcnt == line && hcnt == 0)) @(posedge clk);
            pulses = 0; asserted = 0; total = 0; d = cs;
            while (lcnt == line) begin
                @(posedge clk);
                if (!d && cs) pulses = pulses + 1;
                if (cs) asserted = asserted + 1;
                total = total + 1;
                d = cs;
            end
        end
    endtask

    initial begin
        $display("composite sync");
        #10 rst_n = 1;
        @(posedge field_start);

        /* Vertical sync: broad pulses, serrated at half-line rate. Two per line,
         * and sync asserted for most of it. */
        scan_line(12'd0);
        chk("vsync line has two serrations", pulses == 2);
        chk("vsync line is mostly asserted", asserted > (total * 3) / 4);

        scan_line(12'd2);
        chk("last vsync line the same", pulses == 2 &&
                                        asserted > (total * 3) / 4);

        /* Equalising: two narrow pulses per line, each half an hsync. */
        scan_line(12'd4);
        chk("equalising line has two pulses", pulses == 2);
        chk("equalising pulses are narrow", asserted < total / 8);

        /* Ordinary lines: one pulse, full hsync width. */
        scan_line(12'd8);
        chk("ordinary line has one pulse", pulses == 1);
        chk("and it is a full hsync", asserted == 30);

        scan_line(12'd100);
        chk("active line has one pulse", pulses == 1 && asserted == 30);

        if (fails) $display("\nFAIL  %0d checks", fails);
        else       $display("\nPASS");
        $finish;
    end

    initial begin
        #400_000_000;
        $display("\nFAIL  timed out");
        $finish;
    end

endmodule

`default_nettype wire
