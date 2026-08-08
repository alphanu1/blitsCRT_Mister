// SPDX-License-Identifier: GPL-2.0-or-later
// Exercises the line fetcher against a behavioural memory: that it computes
// base + y*stride, bursts the right number of beats, splits a line that exceeds
// one burst, and that the read side pulls the right pixel back out at the right
// column for each format.
//
// The memory model deliberately answers with latency and a gap between the read
// being accepted and data arriving, because the whole reason for double
// buffering is that a late burst must not reach the raster. A model that
// answered combinationally would prove nothing about that.
`timescale 1ns/1ps

module tb_scanout_fetch;

    localparam integer DW    = 64;
    localparam integer BYTES = DW / 8;
    localparam integer AW    = 32;

    reg clk_mem = 0, rst_mem_n = 0;
    always #5 clk_mem = ~clk_mem;               // 100 MHz

    reg clk_pix = 0, rst_pix_n = 0;
    always #39.68254 clk_pix = ~clk_pix;        // 12.6 MHz

    integer fails = 0;

    task chk(input [359:0] name, input ok);
    begin
        if (ok) $display("  %-0s   ok", name);
        else begin $display("  %-0s   FAIL", name); fails = fails + 1; end
    end endtask

    // ---------------- behavioural memory ----------------
    localparam integer MEM_BYTES = 1 << 18;
    reg [7:0] mem [0:MEM_BYTES-1];

    wire [AW-1:0] avm_address;
    wire          avm_read;
    wire [9:0]    avm_burstcount;
    reg           avm_waitrequest = 0;
    reg  [DW-1:0] avm_readdata = 0;
    reg           avm_readdatavalid = 0;

    integer  q_len;
    integer  beats0, bursts0;
    reg [AW-1:0] q_addr;
    integer  lat;
    integer  beats_served;

    initial begin
        q_len = 0; beats_served = 0; lat = 0;
    end

    /* Accept a burst, wait a few cycles, then stream it out with the odd bubble.
     * Nothing downstream should care when the beats arrive. */
    always @(posedge clk_mem) begin
        if (!rst_mem_n) begin
            avm_readdatavalid <= 0; q_len <= 0; avm_waitrequest <= 0;
        end else begin
            avm_readdatavalid <= 0;
            if (avm_read && !avm_waitrequest && q_len == 0) begin
                q_addr <= avm_address;
                q_len  <= avm_burstcount;
                lat    <= 7;                       // read latency
            end else if (q_len > 0) begin
                if (lat > 0) begin
                    lat <= lat - 1;
                end else if ($random % 5 != 0) begin   // occasional bubble
                    avm_readdata <= {mem[q_addr+7], mem[q_addr+6],
                                     mem[q_addr+5], mem[q_addr+4],
                                     mem[q_addr+3], mem[q_addr+2],
                                     mem[q_addr+1], mem[q_addr+0]};
                    avm_readdatavalid <= 1;
                    q_addr <= q_addr + BYTES;
                    q_len  <= q_len - 1;
                    beats_served <= beats_served + 1;
                end
            end
        end
    end

    // ---------------- the fetcher ----------------
    reg  [AW-1:0] sc_base   = 32'h0000_1000;
    reg  [15:0]   sc_stride = 16'd1280;
    reg  [11:0]   sc_w      = 12'd640;
    reg  [2:0]    sc_format = 3'd0;              // RGB565

    reg           line_req = 0;
    reg  [11:0]   line_y = 0;
    reg           line_show = 0;
    wire          line_valid, line_done, busy, underrun_tog;
    wire [15:0]   beats_last;
    reg  [11:0]   rd_x = 0;
    wire [31:0]   rd_q;

    scanout_fetch #(.DW(DW), .AW(AW), .MAXW(1024), .MAX_BURST(128)) dut (
        .clk_mem(clk_mem), .rst_mem_n(rst_mem_n),
        .avm_address(avm_address), .avm_read(avm_read),
        .avm_burstcount(avm_burstcount), .avm_waitrequest(avm_waitrequest),
        .avm_readdata(avm_readdata), .avm_readdatavalid(avm_readdatavalid),
        .sc_base(sc_base), .sc_stride(sc_stride), .sc_w(sc_w),
        .sc_format(sc_format),
        .clk_pix(clk_pix), .rst_pix_n(rst_pix_n),
        .line_req(line_req), .line_y(line_y), .line_show(line_show),
        .line_valid(line_valid),
        .line_done(line_done), .busy(busy),
        .underrun_tog(underrun_tog), .beats_last(beats_last),
        .rd_x(rd_x), .rd_q(rd_q)
    );

    // watch the addresses the fetcher asks for
    reg [AW-1:0] first_addr; integer n_bursts;
    always @(posedge clk_mem) begin
        if (!rst_mem_n) begin n_bursts <= 0; end
        else if (avm_read && !avm_waitrequest) begin
            /* First burst of a line: the fetcher is holding the request and has
             * not yet subtracted this burst from the line's total. */
            if (dut.state == 2'd2 && dut.beats_left == dut.line_beats)
                first_addr <= avm_address;
            n_bursts <= n_bursts + 1;
        end
    end

    task fetch(input [11:0] y);
    begin
        @(posedge clk_pix); line_req <= 1; line_y <= y;
        @(posedge clk_pix); line_req <= 0;
        @(posedge line_done);
        @(posedge clk_pix); line_show <= 1;
        @(posedge clk_pix); line_show <= 0;
        repeat (4) @(posedge clk_pix);
    end endtask

    task px(input [11:0] x);
    begin
        @(posedge clk_pix); rd_x <= x;
        @(posedge clk_pix);
        @(posedge clk_pix);          /* registered read, then the lane mux */
        #1;
    end endtask

    integer i;
    reg [31:0] want;

    initial begin
        // Fill memory so every byte is a function of its address: any address
        // error shows up as the wrong value rather than plausible garbage.
        for (i = 0; i < MEM_BYTES; i = i + 1)
            mem[i] = i[7:0] ^ {i[15:12], 4'h0};

        /* Hold reset across pixel-clock edges, not just memory-clock ones. The
         * pixel clock is eight times slower here, so releasing after four
         * clk_mem edges lands before its first posedge and leaves the whole
         * clk_pix domain uninitialised. */
        repeat (4) @(posedge clk_pix);
        rst_mem_n = 1; rst_pix_n = 1;
        repeat (4) @(posedge clk_pix);

        $display("addressing");

        beats0 = beats_served; bursts0 = n_bursts;
        fetch(12'd0);
        chk("line 0 reads from sc_base            ", first_addr == 32'h0000_1000);
        chk("640 px RGB565 is 160 beats           ", beats_served - beats0 == 160);
        chk("160 beats splits at MAX_BURST=128    ", n_bursts - bursts0 == 2);

        beats0 = beats_served; bursts0 = n_bursts;
        fetch(12'd37);
        chk("line 37 is base + 37*stride          ",
            first_addr == 32'h0000_1000 + 37*1280);
        chk("still 160 beats                      ", beats_served - beats0 == 160);

        // -------------------------------------------------------------------
        $display("");
        $display("RGB565 read back at the right column");

        for (i = 0; i < 4; i = i + 1) begin
            px(i[11:0]);
            want = {16'd0,
                    mem[32'h1000 + 37*1280 + i*2 + 1],
                    mem[32'h1000 + 37*1280 + i*2 + 0]};
            chk(i == 0 ? "column 0                             " :
                i == 1 ? "column 1                             " :
                i == 2 ? "column 2                             " :
                         "column 3                             ", rd_q == want);
        end

        px(12'd639);
        want = {16'd0, mem[32'h1000 + 37*1280 + 639*2 + 1],
                       mem[32'h1000 + 37*1280 + 639*2 + 0]};
        chk("column 639, last of the line         ", rd_q == want);

        px(12'd8);      /* first pixel of beat 2 -- lane 0 after a beat step */
        want = {16'd0, mem[32'h1000 + 37*1280 + 17], mem[32'h1000 + 37*1280 + 16]};
        chk("column 8 crosses into the next beat  ", rd_q == want);

        // -------------------------------------------------------------------
        $display("");
        $display("XRGB8888, four bytes a pixel, splits into two bursts");

        sc_format = 3'd2; sc_stride = 16'd2560;
        @(posedge clk_mem);
        beats0 = beats_served; bursts0 = n_bursts;
        fetch(12'd2);
        chk("640 px at 4 bytes is 320 beats       ", beats_served - beats0 == 320);
        chk("320 beats needs three bursts         ", n_bursts - bursts0 == 3);
        chk("first burst still at base + 2*stride ",
            first_addr == 32'h0000_1000 + 2*2560);

        px(12'd100);
        want = {mem[32'h1000 + 2*2560 + 403], mem[32'h1000 + 2*2560 + 402],
                mem[32'h1000 + 2*2560 + 401], mem[32'h1000 + 2*2560 + 400]};
        chk("column 100 assembles four bytes      ", rd_q == want);

        // -------------------------------------------------------------------
        $display("");
        $display("RGB332, one byte a pixel");

        sc_format = 3'd3; sc_stride = 16'd640;
        @(posedge clk_mem);
        beats0 = beats_served; bursts0 = n_bursts;
        fetch(12'd5);
        chk("640 px at 1 byte is 80 beats         ", beats_served - beats0 == 80);

        px(12'd333);
        want = {24'd0, mem[32'h1000 + 5*640 + 333]};
        chk("column 333 selects the right byte    ", rd_q == want);

        chk("no underrun through all of that     ", underrun_tog == 1'b0);
        chk("beats_last agrees with the count     ", beats_last == 16'd80);

        $display("");
        check_cdc;

        $display("");
        if (fails == 0) $display("PASS");
        else            $display("FAIL  %0d checks", fails);
        $finish;
    end

    initial begin
        #50000000; $display("FAIL  timeout"); $finish;
    end


    // -------------------------------------------------------------------
    // the line number must be settled before the flag moves
    // -------------------------------------------------------------------
    /*
     * A simulation cannot show metastability, so this checks the property
     * that avoids it instead: when req_tog changes, req_y must already have
     * been stable for a cycle.
     *
     * It was not. req_tog and req_y were assigned on the same edge, so the
     * reader -- which synchronises the flag through two flops and then samples
     * the whole twelve-bit bus -- could catch that bus mid-transition and fetch
     * a line from base + wrong_y * stride. On hardware that is a block edge
     * stepping part-way along a scan, with underruns at zero throughout,
     * because the fetch completes perfectly and simply fetches the wrong line.
     *
     * Nothing else in this testbench notices: in simulation the wrong value is
     * never sampled, because there is no timing to get wrong.
     */
    /* Initialised to the DUT's reset values, so the first toggle is not
       compared against X. */
    reg [11:0] req_y_prev = 12'd0;
    reg        req_tog_prev = 1'b0;
    integer    cdc_fails = 0;
    integer    cdc_seen  = 0;

    /* Sampled a delta after the edge, with blocking assignments, so what is
       read is the settled post-edge value rather than whatever the scheduler
       happens to have updated first. Comparing across a clock edge is exactly
       the case where reading mid-update gives an answer that means nothing. */
    always @(posedge clk_pix) begin
        #1;
        if (dut.req_tog !== req_tog_prev) begin
            cdc_seen = cdc_seen + 1;
            if (dut.req_y !== req_y_prev) begin
                cdc_fails = cdc_fails + 1;
                $display("  req_y moved on the same edge as req_tog (y=%0d)",
                         dut.req_y);
            end
        end
        req_y_prev   = dut.req_y;
        req_tog_prev = dut.req_tog;
    end

    task check_cdc;
        begin
            $display("the request crossing");
            chk("req_tog moved at least once           ", cdc_seen > 0);
            chk("req_y settled before every toggle     ", cdc_fails == 0);
            $display("        %0d toggles, %0d with a moving line number",
                     cdc_seen, cdc_fails);
        end
    endtask

endmodule
