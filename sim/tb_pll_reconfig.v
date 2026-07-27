// SPDX-License-Identifier: GPL-2.0-or-later
//
// The real altera_pll_reconfig, driven through the real blitscrt_bridge and
// blitscrt_pllbus, doing exactly what blitscrt-peek does on hardware: write MODE,
// read it back, read STATUS.
//
// On hardware all three return zero while every health indicator says the block
// is ready -- addressed, clocked, out of reset, accepting, waitrequest low. Four
// rebuilds and a lot of source reading did not settle why. The IP is simulatable
// once one Cyclone V primitive is stubbed, so this stops the guessing.
//
// reconfig_from_pll[16] is lock, driven high here because the hardware evidence
// says the PLL genuinely reports lock: slave_waitrequest sits low, and in mode_WR
// it can only do that when `locked === 1'b1`.
`timescale 1ns/1ps

module tb_pll_reconfig;

    reg clk = 0, rst_n = 0;
    always #10 clk = ~clk;              // 50 MHz, as on the board

    integer fails = 0;

    /* Clocks between register writes. 0 is back-to-back, as an earlier version
     * of this testbench ran. 100 is roughly the 2 us a gp command costs on the
     * board. */
`ifndef GAP
 `define GAP 100
`endif
    localparam integer GAP = `GAP;

    task chk(input [359:0] name, input ok);
    begin
        if (ok) $display("  %-0s   ok", name);
        else begin $display("  %-0s   FAIL", name); fails = fails + 1; end
    end endtask

    // ---- the gp side, driven the way fabric.c drives it ----
    reg  [31:0] gp_out = 32'd0;
    wire [31:0] gp_in;
    wire        bus_stalled;
    reg         strobe = 1'b0;

    wire [13:0] reg_address;
    wire        reg_read, reg_write;
    wire [31:0] reg_writedata, reg_readdata;
    wire        reg_waitrequest;

    blitscrt_bridge #(.BRIDGE("GP")) u_bridge (
        .clk(clk), .rst_n(rst_n),
        .gp_out(gp_out), .gp_in(gp_in), .bus_stalled(bus_stalled),
        .avm_address(reg_address), .avm_read(reg_read),
        .avm_write(reg_write), .avm_writedata(reg_writedata),
        .avm_readdata(reg_readdata), .avm_waitrequest(reg_waitrequest)
    );

    // ---- the adapter and the real IP ----
    wire        is_pll = (reg_address[13:12] == 2'b01);
    wire [31:0] pll_rdata;
    wire        pll_stall;
    wire [5:0]  m_address;
    wire        m_read, m_write;
    wire [31:0] m_writedata, m_readdata;
    wire        m_waitrequest;

    blitscrt_pllbus u_pllbus (
        .clk(clk), .rst_n(rst_n),
        .sel(is_pll), .read(reg_read), .write(reg_write),
        .address(reg_address[7:2]), .writedata(reg_writedata),
        .readdata(pll_rdata), .waitrequest(pll_stall),
        .m_read(m_read), .m_write(m_write),
        .m_address(m_address), .m_writedata(m_writedata),
        .m_readdata(m_readdata), .m_waitrequest(m_waitrequest)
    );

    /* No register slave here; anything outside the aperture reads zero, which is
     * enough since every access this drives is inside it. */
    assign reg_readdata    = is_pll ? pll_rdata : 32'd0;
    assign reg_waitrequest = is_pll ? pll_stall : 1'b0;

    wire [63:0] reconfig_to_pll;
    reg  [63:0] reconfig_from_pll = 64'd0;

    pll_reconfig u_pll (
        .mgmt_clk(clk), .mgmt_reset(~rst_n),
        .mgmt_waitrequest(m_waitrequest),
        .mgmt_read(m_read), .mgmt_write(m_write),
        .mgmt_readdata(m_readdata), .mgmt_address(m_address),
        .mgmt_writedata(m_writedata),
        .reconfig_to_pll(reconfig_to_pll),
        .reconfig_from_pll(reconfig_from_pll)
    );

    // ---- gp command, mirroring gp_command() in fabric.c ----
    reg [31:0] last_read;

    task gp_cmd(input wr, input [13:0] addr, input [15:0] data);
        integer spin;
    begin
        strobe = ~strobe;
        gp_out = {strobe, wr, addr, data};
        spin = 0;
        while (((gp_in[31]) !== strobe) && spin < 20000) begin
            @(posedge clk); spin = spin + 1;
        end
        if (spin >= 20000) $display("    (gp timeout at addr 0x%04x)", addr);
        repeat (2) @(posedge clk);
        last_read = {16'd0, gp_in[15:0]};
    end endtask

    task rd32(input [13:0] addr);
        reg [15:0] lo;
    begin
        gp_cmd(1'b0, addr, 16'd0);        lo = last_read[15:0];
        gp_cmd(1'b0, addr | 14'd1, 16'd0);
        last_read = {last_read[15:0], lo};
    end endtask

    task wr32(input [13:0] addr, input [31:0] v);
    begin
        gp_cmd(1'b1, addr, v[15:0]);
        if (v[31:16] != 16'd0) gp_cmd(1'b1, addr | 14'd1, v[31:16]);
    end endtask

    initial begin
        $dumpfile("sim/tb_pll_reconfig.vcd");
        $dumpvars(0, tb_pll_reconfig);

        /* Lock, as the hardware reports it. */
        reconfig_from_pll[16] = 1'b1;

        repeat (8) @(posedge clk);
        rst_n = 1;

        /* self_reset counts 340 clocks after mgmt_reset drops before releasing
         * the core's internal reset, and the DPRIO init runs after that. */
        repeat (2000) @(posedge clk);

        $display("the real IP through the real bridge");
        $display("  waitrequest=%b  dprio_init_done=%b  locked=%b",
                 m_waitrequest,
                 u_pll.pll_reconfig_inst.NM28_reconfig.reconfig_core.altera_pll_reconfig_core_inst0.dprio_init_done,
                 u_pll.pll_reconfig_inst.NM28_reconfig.reconfig_core.altera_pll_reconfig_core_inst0.locked);

        rd32(14'h1000);
        $display("  MODE   reads 0x%08x  (expect 0, mode_WR)", last_read);
        chk("MODE reads back as write-wait mode ", last_read == 32'd0);

        wr32(14'h1000, 32'd1);
        rd32(14'h1000);
        $display("  MODE   reads 0x%08x  after writing 1", last_read);
        chk("MODE write sticks                  ", last_read == 32'd1);

        rd32(14'h1004);
        $display("  STATUS reads 0x%08x  (0 in waitrequest mode, always)", last_read);

        /* -------------------------------------------------------------------
         * The full sequence pll_reconfig_build() emits, in polling mode.
         *
         * `status` is literally (current_state == LOCKED), and in waitrequest
         * mode the machine returns from WAIT_ON_LOCK straight to IDLE and never
         * enters LOCKED. So MODE=0 plus polling STATUS can never succeed --
         * which is indistinguishable, from the HPS side, from a dead block.
         * ------------------------------------------------------------------- */
        $display("");
        $display("full reconfiguration in polling mode: M=16 N=1 C=64");

        wr32(14'h1000, 32'd1);            // MODE = polling
        rd32(14'h1000);
        chk("MODE selects polling               ", last_read == 32'd1);

        /* Exactly what pll_reconfig_build() emits for M=16 N=1 C=64. N carries
         * the bypass-enable bit for divide-by-1, so it does not fit in 16 bits
         * and the bridge sends it as two commands -- which means two bus writes,
         * the first with the bypass bit still missing. */
        /* Hardware spacing. Each gp command is about 620 ns, so on the board the
         * counter writes and START are microseconds apart, not a few clocks.
         * If anything clears the *_changed flags in between, usr_valid_changes
         * is false when START lands and it is silently ignored. */
        wr32(14'h100C, 32'h0001_0101);    // N: bypass, lo=1 hi=1
        repeat (GAP) @(posedge clk);
        wr32(14'h1010, 32'h0000_0808);    // M: lo=8, hi=8  -> 16
        repeat (GAP) @(posedge clk);
        wr32(14'h1014, 32'h0000_2020);    // C: lo=32,hi=32 -> 64, index 0
        repeat (GAP) @(posedge clk);
        wr32(14'h1008, 32'd1);            // START

        begin : poll
            integer i;
            for (i = 0; i < 200; i = i + 1) begin
                rd32(14'h1004);
                if (last_read[0]) disable poll;
            end
        end
        /* Bit 0 is the whole of STATUS: the IP drives one bit from
         * (current_state == LOCKED). This testbench checked bit 0 and passed
         * while the daemon tested for "not busy and locked" against a second bit
         * that does not exist -- so every reconfiguration completed and every one
         * was reported as a failure. */
        $display("  STATUS reads 0x%08x after START", last_read);
        chk("STATUS bit 0 is ready, and is all   ", last_read == 32'd1);

        wr32(14'h1000, 32'd0);

        $display("");
        if (fails == 0) $display("PASS");
        else            $display("FAIL  %0d checks", fails);
        $finish;
    end

    initial begin
        #20000000; $display("FAIL  timeout"); $finish;
    end

endmodule
