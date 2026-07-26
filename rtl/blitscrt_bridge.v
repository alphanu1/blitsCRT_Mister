// SPDX-License-Identifier: GPL-2.0-or-later
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
    output wire        bus_stalled,      // sticky: a slave never accepted

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
        assign bus_stalled = 1'b0;
    end
    else begin : g_gp
        // Marshal one transaction per gp_out command. Layout:
        //
        //   gp_out[31]     strobe, toggles to start a transaction
        //   gp_out[30]     1 = write, 0 = read
        //   gp_out[29:16]  address[13:0]   (address[13] selects the char buffer)
        //   gp_out[15:0]   16 bits of data
        //
        // 16 bits move per command, so a 32-bit register transfer is two
        // commands: software addresses the low half at `off` and the high half
        // at `off|1`. In the register region (address[13]==0) bit 0 is therefore
        // a half-select, resolved here so the slave only ever sees aligned 32-bit
        // accesses. The character buffer (address[13]==1) is byte-addressed, so
        // bit 0 is a real address bit there and passes straight through.
        reg        strobe_ack;  // echoed back only once a command has completed
        reg [13:0] r_addr;
        reg        r_write;
        reg [31:0] r_wdata;
        reg [15:0] r_wlo;       // low half held between the two halves of a write
        reg        r_req;       // Avalon request active
        reg        r_rpend;     // read accepted; slave presents its data next cycle
        reg        r_rhold;     // read data captured; hold it stable one cycle before the echo
        reg [31:0] r_readback;

        // gp_out crosses from the HPS with no relation to this clock. Synchronise
        // the strobe through two flops before edge-detecting it; the rest of
        // gp_out was written in the same HPS store, so by the time the
        // synchronised edge fires it has long settled and can be latched directly.
        // Sampling gp_out[31] straight into an edge-detect flop instead let the
        // fabric catch a command mid-transition and drop a transfer -- the
        // intermittently-zero read half seen on hardware.
        reg [1:0]  strobe_meta;
        reg        strobe_d;
        always @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin strobe_meta <= 2'b00; strobe_d <= 1'b0; end
            else begin
                strobe_meta <= {strobe_meta[0], gp_out[31]};
                strobe_d    <= strobe_meta[1];
            end
        end
        wire strobe_now = strobe_meta[1];   // strobe, synchronised to this clock

        wire n_write = gp_out[30];
        wire n_char  = gp_out[29];      // address[13]
        wire n_hi    = gp_out[16];      // address[0]

        // The register slave registers its readdata with waitrequest tied low, so
        // a read is *accepted* the cycle avm_read is high and the data is valid
        // the NEXT cycle (fixed read latency 1). The echo must wait for that extra
        // cycle, or the HPS latches the previous register's value.
        wire read_done  = avm_read  && !avm_waitrequest;   // accepted; data next cycle
        wire write_done = avm_write && !avm_waitrequest;

        /* A slave that never drops waitrequest used to wedge this: r_req stayed
         * set, strobe_ack never moved, and the HPS spun until its own timeout --
         * every access to that address appearing to return zero while the rest of
         * the map worked. Give up after 255 cycles instead, echo anyway so the
         * host is not left waiting, and latch the fact. 255 cycles at 50 MHz is
         * 5 us, far longer than any slave here legitimately needs. */
        reg [7:0] stall;
        reg       stalled;                  // sticky: some access timed out
        wire      give_up = (stall == 8'hFF);
        always @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin
                stall <= 8'd0; stalled <= 1'b0;
            end else if (r_req && !read_done && !write_done) begin
                if (!give_up) stall <= stall + 8'd1;
                else          stalled <= 1'b1;
            end else begin
                stall <= 8'd0;
            end
        end

        always @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin
                strobe_ack <= 1'b0;
                r_addr <= 14'd0; r_write <= 1'b0; r_wdata <= 32'd0;
                r_wlo <= 16'd0; r_req <= 1'b0; r_rpend <= 1'b0; r_rhold <= 1'b0;
                r_readback <= 32'd0;
            end else begin
                r_rpend <= 1'b0;               // one-shot
                r_rhold <= 1'b0;               // one-shot
                if (strobe_now != strobe_d) begin
                    // New command: latch address and direction, assemble data.
                    r_addr  <= gp_out[29:16];
                    r_write <= n_write;
                    r_req   <= 1'b1;
                    if (n_write && !n_char && n_hi)
                        r_wdata <= {gp_out[15:0], r_wlo};  // high half of a reg write
                    else begin
                        r_wdata <= {16'd0, gp_out[15:0]};  // low half / byte / char
                        r_wlo   <= gp_out[15:0];
                    end
                end else if (give_up) begin
                    /* Abandon it. r_readback keeps its previous value, which is
                     * wrong -- but a wrong value with bus_stalled set is far
                     * easier to diagnose than a transport that looks dead. */
                    r_req      <= 1'b0;
                    strobe_ack <= strobe_d;
                end else if (write_done) begin
                    r_req      <= 1'b0;
                    strobe_ack <= strobe_d;      // writes complete on acceptance
                end else if (read_done) begin
                    r_req   <= 1'b0;             // ...data lands next cycle
                    r_rpend <= 1'b1;
                end else if (r_rpend) begin
                    r_readback <= avm_readdata;  // now valid (read latency 1)
                    r_rhold    <= 1'b1;          // ...let it settle before the echo
                end else if (r_rhold) begin
                    strobe_ack <= strobe_d;      // data has led the echo by a cycle
                end
            end
        end

        assign bus_stalled = stalled;

        wire is_char = r_addr[13];

        // Register accesses are forced 32-bit aligned (bit 0 is the half-select);
        // char-buffer accesses keep their byte address.
        assign avm_address   = is_char ? r_addr : {r_addr[13:1], 1'b0};
        assign avm_write     = r_req &  r_write;
        assign avm_read      = r_req & ~r_write;
        assign avm_writedata = r_wdata;

        // Response: 16 bits per command, completion echo in the top bit. For a
        // register high-half read (bit 0 set) return the upper half, else the
        // lower half; char reads always take the low half.
        assign gp_in = {strobe_ack, 15'd0,
                        (!is_char && r_addr[0]) ? r_readback[31:16]
                                                : r_readback[15:0]};

        assign lw_readdata    = 32'd0;
        assign lw_waitrequest = 1'b0;
    end
    endgenerate

endmodule

`default_nettype wire
