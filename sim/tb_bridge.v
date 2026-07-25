// The bridge presents an identical Avalon master whichever way the HPS reaches
// it. This drives both variants through the same transactions and checks the
// downstream bus is the same.
`timescale 1ns/1ps

module tb_bridge;

    reg clk = 0, rst_n = 0;
    always #10 clk = ~clk;

    // LWH2F variant
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

    // GP variant
    reg [31:0] gp_out = 0; wire [31:0] gp_in;
    wire [13:0] g_addr; wire g_rd, g_wr; wire [31:0] g_wdata;
    reg  [31:0] g_rdata = 32'h0000BEEF; reg g_wait = 0;

    blitscrt_bridge #(.BRIDGE("GP")) u_gp (
        .clk(clk), .rst_n(rst_n),
        .lw_address(14'd0), .lw_read(1'b0), .lw_write(1'b0),
        .lw_writedata(32'd0), .lw_readdata(), .lw_waitrequest(),
        .gp_out(gp_out), .gp_in(gp_in),
        .avm_address(g_addr), .avm_read(g_rd), .avm_write(g_wr),
        .avm_writedata(g_wdata), .avm_readdata(g_rdata), .avm_waitrequest(g_wait)
    );

    reg g_wr_seen, g_rd_seen; reg [13:0] g_addr_seen; reg [31:0] g_wdata_seen;
    always @(posedge clk) begin
        if (g_wr) begin g_wr_seen=1; g_addr_seen=g_addr; g_wdata_seen=g_wdata; end
        if (g_rd) begin g_rd_seen=1; g_addr_seen=g_addr; end
    end

    integer fails = 0;
    task chk(input [300:0] w, input c);
        begin $display("  %-50s %s", w, c ? "ok" : "FAIL"); if(!c) fails=fails+1; end
    endtask

    initial begin
        #40 rst_n = 1;
        @(posedge clk);

        $display("lightweight bridge passes Avalon straight through");
        lw_addr = 14'h044; lw_wdata = 32'd1; lw_wr = 1;
        @(posedge clk); #1;
        chk("write address and data reach the bus",
            a_addr == 14'h044 && a_wdata == 32'd1 && a_wr == 1'b1);
        lw_wr = 0;
        lw_addr = 14'h000; lw_rd = 1;
        @(posedge clk); #1;
        chk("read strobe reaches the bus", a_rd == 1'b1 && a_addr == 14'h000);
        chk("readdata returns to the HPS", lw_rdata == 32'hCAFEBABE);
        lw_rd = 0;

        $display("");
        $display("gp bridge marshals a command into a transaction");
        // write to 0x044, data 1: strobe^ write=1 addr=0x044 data=1
        g_wr_seen = 0;
        gp_out = {1'b1, 1'b1, 14'h044, 16'd1};
        @(posedge clk); @(posedge clk); @(posedge clk); #1;
        chk("gp write reaches the bus as Avalon",
            g_wr_seen && g_addr_seen == 14'h044 && g_wdata_seen[15:0] == 16'd1);
        // read from 0x000: toggle strobe, write=0
        g_rd_seen = 0;
        gp_out = {1'b0, 1'b0, 14'h000, 16'd0};
        @(posedge clk); @(posedge clk); @(posedge clk); #1;
        chk("gp read reaches the bus as Avalon",
            g_rd_seen && g_addr_seen == 14'h000);
        chk("gp readback appears in gp_in low half", gp_in[15:0] == 16'hBEEF);
        // The completion echo (gp_in[31]) must equal the strobe just sent (0),
        // and must only assert once the readback is valid -- this is the
        // handshake that had the HPS reading stale zeros before the data landed.
        chk("gp strobe echo signals completion", gp_in[31] == 1'b0);

        $display("");
        if (fails) $display("FAIL"); else $display("PASS");
        $finish;
    end

    initial begin #100000; $display("TIMEOUT"); $finish; end

endmodule
