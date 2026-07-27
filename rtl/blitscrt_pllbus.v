// SPDX-License-Identifier: GPL-2.0-or-later
// -----------------------------------------------------------------------------
// blitscrt_pllbus.v -- adapter between blitscrt_bridge and the PLL reconfig
// slave, for the one thing they disagree about: when read data is valid.
//
// blitscrt_bridge deasserts avm_read the moment a read is accepted, then samples
// readdata on the following cycle:
//
//     end else if (read_done) begin
//         r_req   <= 1'b0;              // avm_read drops here
//         r_rpend <= 1'b1;
//     end else if (r_rpend) begin
//         r_readback <= avm_readdata;   // sampled here, read already low
//
// blitscrt_regs survives that because its readdata is registered and holds. A
// slave that drives readdata combinationally while read is asserted does not: it
// returns to zero as soon as read drops, and the bridge captures the zero. Every
// register in the reconfig window read back 0x00000000 for exactly that reason,
// which is indistinguishable from a decode that never arrives -- and cost most of
// a session to tell apart.
//
// So this stalls the bridge for the whole exchange and speaks plain Avalon to the
// slave: assert the request, hold it while waitrequest is high, capture readdata
// on the cycle waitrequest drops, then release. One accepted cycle, then done.
//
// It must NOT hold the request past acceptance. altera_pll_reconfig's read FSM
// re-runs for as long as mgmt_read is asserted, and mgmt_readdata alternates
// between the register value and zero as it cycles -- so "hold it a few cycles
// and keep the freshest value" takes whichever phase it lands on. That was worth
// a day: an earlier version of this module did exactly that, captured the right
// value, then overwrote it with zero one cycle later.
// -----------------------------------------------------------------------------

`timescale 1ns/1ps
`default_nettype none

module blitscrt_pllbus (
    input  wire        clk,
    input  wire        rst_n,

    // bridge side
    input  wire        sel,           // this access is in the reconfig window
    input  wire        read,
    input  wire        write,
    input  wire [5:0]  address,
    input  wire [31:0] writedata,
    output wire [31:0] readdata,
    output wire        waitrequest,

    // reconfig slave side
    output reg         m_read,
    output reg         m_write,
    output reg  [5:0]  m_address,
    output reg  [31:0] m_writedata,
    input  wire [31:0] m_readdata,
    input  wire        m_waitrequest
);

    localparam [1:0] S_IDLE = 2'd0, S_ACCEPT = 2'd1, S_DONE = 2'd2;

    reg [1:0]  state;
    reg [31:0] cap;

    /* Stall the bridge for the whole exchange, then release for one cycle. The
     * bridge samples readdata the cycle after it sees waitrequest low, and cap
     * is held from S_DONE onward, so what it takes is what was captured. */
    assign waitrequest = sel && (state != S_DONE);
    assign readdata    = cap;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            m_read <= 1'b0; m_write <= 1'b0;
            m_address <= 6'd0; m_writedata <= 32'd0; cap <= 32'd0;
        end else begin
            case (state)
            S_IDLE: begin
                m_read  <= 1'b0;
                m_write <= 1'b0;
                if (sel && (read || write)) begin
                    m_address   <= address;
                    m_writedata <= writedata;
                    m_read      <= read;
                    m_write     <= write;
                    state       <= S_ACCEPT;
                end
            end

            S_ACCEPT: begin
                /* Plain Avalon: the slave holds waitrequest while busy and drops
                 * it with valid data. Take it on that cycle and stop asking --
                 * asking again restarts the slave's read FSM. */
                if (!m_waitrequest) begin
                    cap     <= m_readdata;
                    m_read  <= 1'b0;
                    m_write <= 1'b0;
                    state   <= S_DONE;
                end
            end

            S_DONE: begin
                /* waitrequest is low this cycle, so the bridge accepts and reads
                 * cap on the next. cap is no longer being written. */
                state <= S_IDLE;
            end

            default: state <= S_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
