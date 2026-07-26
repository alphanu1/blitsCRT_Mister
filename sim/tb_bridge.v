// The bridge presents an identical Avalon master whichever way the HPS reaches
// it, and moves full 32-bit registers over two 16-bit gp halves. The gp slave
// here is REGISTERED (read latency 1), matching rtl/blitscrt_regs.v -- the old
// testbench drove readdata combinationally, which hid the latency bug.
`timescale 1ns/1ps

module tb_bridge;

    reg clk = 0, rst_n = 0;
    always #10 clk = ~clk;

    // ---- LWH2F variant: straight pass-through, combinational slave ----
    reg [13:0] lw_addr = 0; reg lw_rd = 0, lw_wr = 0; reg [31:0] lw_wdata = 0;
    wire [31:0] lw_rdata; wire lw_wait;
    wire [13:0] a_addr; wire a_rd, a_wr; wire [31:0] a_wdata;
    reg  [31:0] a_rdata = 32'hCAFEBABE; reg a_wait = 0;

    blitscrt_bridge #(.BRIDGE("LWH2F")) u_lw (
        .clk(clk), .rst_n(rst_n),
        .lw_address(lw_addr), .lw_read(lw_rd), .lw_write(lw_wr),
        .lw_writedata(lw_wdata), .lw_readdata(lw_rdata), .lw_waitrequest(lw_wait),
        .gp_out(32'd0), .gp_in(),
        .avm_address(a_addr), .avm_read(a_rd), .avm_write(a_wr),
        .avm_writedata(a_wdata), .avm_readdata(a_rdata), .avm_waitrequest(a_wait)
    );

    // ---- GP variant, with a registered (latency-1) slave like blitscrt_regs ----
    reg [31:0] gp_out = 0; wire [31:0] gp_in;
    wire [13:0] g_addr; wire g_rd, g_wr; wire [31:0] g_wdata;
    reg  [31:0] g_rdata = 0; reg g_wait = 0;

    blitscrt_bridge #(.BRIDGE("GP")) u_gp (
        .clk(clk), .rst_n(rst_n),
        .lw_address(14'd0), .lw_read(1'b0), .lw_write(1'b0),
        .lw_writedata(32'd0), .lw_readdata(), .lw_waitrequest(),
        .gp_out(gp_out), .gp_in(gp_in),
        .avm_address(g_addr), .avm_read(g_rd), .avm_write(g_wr),
        .avm_writedata(g_wdata), .avm_readdata(g_rdata), .avm_waitrequest(g_wait)
    );

    // Registered read decode: data valid the cycle AFTER avm_read, exactly like
    // blitscrt_regs. The bridge aligns register addresses, so 0x000 and 0x001
    // both land here as 0x000.
    always @(posedge clk) begin
        if (g_rd) case (g_addr)
            14'h000: g_rdata <= 32'h42435254;   // ID "BCRT"
            14'h004: g_rdata <= 32'h00020001;   // VERSION 2.1
            default: g_rdata <= 32'd0;
        endcase
    end

    reg g_wr_seen; reg [13:0] g_waddr; reg [31:0] g_wseen;
    always @(posedge clk) if (g_wr) begin g_wr_seen=1; g_waddr=g_addr; g_wseen=g_wdata; end

    integer fails = 0;
    task chk(input [400:0] w, input c);
        begin $display("  %-54s %s", w, c ? "ok" : "FAIL"); if(!c) fails=fails+1; end
    endtask

    // gp command: toggle the strobe, wait for the echo, return the 16-bit half.
    reg tb_strobe = 0;
    task gp_cmd(input wr, input [13:0] addr, input [15:0] data, output [15:0] res);
        integer spin; reg done;
        begin
            tb_strobe = ~tb_strobe;
            gp_out = {tb_strobe, wr, addr, data};
            done = 0; res = 16'h0;
            for (spin = 0; spin < 2000 && !done; spin = spin + 1) begin
                @(posedge clk); #1;
                if (gp_in[31] == tb_strobe) begin res = gp_in[15:0]; done = 1; end
            end
        end
    endtask

    task gp_read32(input [13:0] addr, output [31:0] val);
        reg [15:0] lo, hi;
        begin
            gp_cmd(1'b0, addr,            16'd0, lo);
            gp_cmd(1'b0, addr | 14'h0001, 16'd0, hi);
            val = {hi, lo};
        end
    endtask

    reg [31:0] rid, rver; reg [15:0] dummy;
    initial begin
        #40 rst_n = 1;
        @(posedge clk);

        $display("lightweight bridge passes Avalon straight through");
        lw_addr = 14'h044; lw_wdata = 32'd1; lw_wr = 1;
        @(posedge clk); #1;
        chk("write address and data reach the bus",
            a_addr == 14'h044 && a_wdata == 32'd1 && a_wr == 1'b1);
        lw_wr = 0; lw_addr = 14'h000; lw_rd = 1;
        @(posedge clk); #1;
        chk("read strobe reaches the bus", a_rd == 1'b1 && a_addr == 14'h000);
        chk("readdata returns to the HPS", lw_rdata == 32'hCAFEBABE);
        lw_rd = 0;

        $display("");
        $display("gp bridge moves full 32-bit registers over two 16-bit halves");
        gp_read32(14'h000, rid);
        chk("32-bit read assembles the ID (BCRT)", rid  == 32'h42435254);
        gp_read32(14'h004, rver);
        chk("32-bit read assembles VERSION (2.1)", rver == 32'h00020001);

        g_wr_seen = 0;
        gp_cmd(1'b1, 14'h044, 16'd1, dummy);
        chk("register write reaches the bus as Avalon",
            g_wr_seen && g_waddr == 14'h044 && g_wseen[15:0] == 16'd1);

        // char buffer (address[13]=1) is byte-addressed: an odd address must NOT
        // be aligned away.
        g_wr_seen = 0;
        gp_cmd(1'b1, 14'h2001, 16'h0041, dummy);
        chk("char byte write keeps its odd address",
            g_wr_seen && g_waddr == 14'h2001 && g_wseen[7:0] == 8'h41);

        $display("");
        if (fails) $display("FAIL"); else $display("PASS");
        $finish;
    end

    initial begin #200000; $display("TIMEOUT"); $finish; end

endmodule
