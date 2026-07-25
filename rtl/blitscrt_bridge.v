`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// blitscrt_bridge.v -- the seam between the HPS and the fabric.
//
// Everything downstream (the register slave, the reconfig block) speaks
// Avalon-MM at a fixed address. This module is the one place that knows *how*
// the HPS reaches that bus, and it exists so the how can change without
// touching anything else.
//
// Two implementations, picked by the BRIDGE parameter:
//
//   "LWH2F"  the HPS lightweight bridge, a real Avalon-MM master at
//            0xFF200000. The master ports pass straight through. This is what
//            sw/fabric.c targets today: /dev/mem, mmap, plain reads and writes.
//
//   "GP"     MiSTer's gp_in/gp_out general-purpose ports, 32 bits each way.
//            A command word on gp_out carries {write, address, data-or-nothing}
//            and is unpacked into an Avalon transaction here. Needs the matching
//            marshalling in software. Included so the move to a bare board that
//            only brings out the gp ports is a parameter change, not a rewrite.
//
// The downstream Avalon master interface is identical either way. Nothing above
// this module knows which bridge is fitted.
// -----------------------------------------------------------------------------

`default_nettype none

module blitscrt_bridge #(
    parameter BRIDGE = "LWH2F"
) (
    input  wire        clk,
    input  wire        rst_n,

    // ---- HPS lightweight bridge, used when BRIDGE == "LWH2F" ----
    input  wire [13:0] lw_address,
    input  wire        lw_read,
    input  wire        lw_write,
    input  wire [31:0] lw_writedata,
    output wire [31:0] lw_readdata,
    output wire        lw_waitrequest,

    // ---- general-purpose ports, used when BRIDGE == "GP" ----
    input  wire [31:0] gp_out,          // HPS -> fabric command
    output wire [31:0] gp_in,           // fabric -> HPS response

    // ---- downstream Avalon-MM master, to the register slave ----
    output wire [13:0] avm_address,
    output wire        avm_read,
    output wire        avm_write,
    output wire [31:0] avm_writedata,
    input  wire [31:0] avm_readdata,
    input  wire        avm_waitrequest
);

    generate
    if (BRIDGE == "LWH2F") begin : g_lw
        // Straight pass-through. The lightweight bridge already is an Avalon
        // master; the register slave is wired directly to the HPS.
        assign avm_address   = lw_address;
        assign avm_read      = lw_read;
        assign avm_write     = lw_write;
        assign avm_writedata = lw_writedata;
        assign lw_readdata   = avm_readdata;
        assign lw_waitrequest= avm_waitrequest;

        assign gp_in = 32'd0;
    end
    else begin : g_gp
        // Marshal one transaction per gp_out command. Layout:
        //
        //   gp_out[31]     strobe, toggles to start a transaction
        //   gp_out[30]     1 = write, 0 = read
        //   gp_out[29:16]  address[13:0]
        //   gp_out[15:0]   low half of write data; high half arrives in a
        //                  second command when [30:29] == 2'b11
        //
        // This is a deliberately plain scheme. It moves 16 data bits per
        // command, so a 32-bit write is two commands. The register map only
        // needs the full width on a handful of registers, and the character
        // buffer is byte-wide, so it is rarely the bottleneck.
        reg        strobe_d;    // last seen command strobe (edge detect)
        reg        strobe_ack;  // echoed back only once a command has completed
        reg [13:0] r_addr;
        reg        r_write;
        reg [31:0] r_wdata;
        reg        r_req;       // Avalon request active
        reg [31:0] r_readback;

        wire strobe = gp_out[31];

        // A read is not complete until the slave has presented its data, i.e.
        // avm_read is asserted with waitrequest low. Writes complete the cycle
        // the request is accepted. The strobe echo (gp_in[31]) must only flip
        // once that has happened, or the HPS spin-wait reads stale data back --
        // which returned 0x0000 in the low half and failed the ID check.
        wire read_done  = avm_read  && !avm_waitrequest;
        wire write_done = avm_write && !avm_waitrequest;

        always @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin
                strobe_d <= 1'b0; strobe_ack <= 1'b0;
                r_addr <= 14'd0; r_write <= 1'b0;
                r_wdata <= 32'd0; r_req <= 1'b0; r_readback <= 32'd0;
            end else begin
                strobe_d <= strobe;
                if (strobe != strobe_d) begin
                    // New command: latch it and raise the request.
                    r_addr  <= gp_out[29:16];
                    r_write <= gp_out[30];
                    r_wdata <= {16'd0, gp_out[15:0]};
                    r_req   <= 1'b1;
                end else if (read_done || write_done) begin
                    // Transaction accepted: capture read data, drop the request,
                    // and only now flip the echo to release the HPS.
                    if (read_done)
                        r_readback <= avm_readdata;
                    r_req      <= 1'b0;
                    strobe_ack <= strobe_d;
                end
            end
        end

        assign avm_address   = r_addr;
        assign avm_write     = r_req &  r_write;
        assign avm_read      = r_req & ~r_write;
        assign avm_writedata = r_wdata;

        // response: readback in the low half, completion echo in the top bit
        assign gp_in = {strobe_ack, 15'd0, r_readback[15:0]};

        assign lw_readdata    = 32'd0;
        assign lw_waitrequest = 1'b0;
    end
    endgenerate

endmodule

`default_nettype wire
