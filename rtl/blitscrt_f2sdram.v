// SPDX-License-Identifier: GPL-2.0-or-later
// -----------------------------------------------------------------------------
// blitscrt_f2sdram.v -- the Platform Designer seam, isolated.
//
// Everything upstream (scanout_fetch) speaks plain Avalon-MM read. This is the
// one module that knows the system underneath is a generated one, and it exists
// so that generating it does not touch anything else -- the same reason
// blitscrt_hps.v is the only module holding an HPS primitive.
//
// Its ports are internal to blitscrt_top, so nothing here asks for a pin and
// check-pins stays clean. f2sdram is an on-die path to the HPS SDRAM
// controller; there is no board wiring involved.
//
// WITH_QSYS = 0 stubs it out: the master never gets data, which is honest
// behaviour for a build with no system generated yet, and it lets the DDR3
// configuration elaborate and lint before the Quartus work is done.
//
// WITH_QSYS = 1 fits MiSTer's sysmem_lite, lifted unmodified into rtl/mister/.
// It is not a Platform Designer project to generate -- it is a flattened system
// checked in as SystemVerilog, instantiating cyclonev_hps_interface_fpga2sdram
// directly, the same way blitscrt_hps.v holds the gp primitive. rtl/mister/
// carries the provenance and the licensing.
//
// Using theirs rather than generating our own is not only convenience. The
// f2sdram port configuration is latched by APPLYCFG while the SDRAM interface
// is idle, which the preloader does at boot and Linux cannot do at all. The A2
// preloader on a MiSTer card was built against that configuration; a different
// one would not match what is already latched.
//
// The two things the adapter below exists for:
//
//   addresses  the port is word-addressed, so a byte address is shifted right
//              by three for the 64-bit port
//   burstcount eight bits there, ten here, so a burst is at most 128 beats --
//              which is what scanout_fetch's MAX_BURST already assumes
// -----------------------------------------------------------------------------

`timescale 1ns/1ps
`default_nettype none

module blitscrt_f2sdram #(
    parameter integer DW        = 64,
    parameter integer WITH_QSYS = 1      // 0 only for lint; see blitscrt_top
) (
    input  wire            ref_clk,      // fallback clock for the stub
    input  wire            ref_rst_n,

    output wire            m_clk,
    output wire            m_rst_n,
    input  wire [31:0]     m_address,
    input  wire            m_read,
    input  wire [9:0]      m_burstcount,
    output wire            m_waitrequest,
    output wire [DW-1:0]   m_readdata,
    output wire            m_readdatavalid
);

    generate
    if (WITH_QSYS) begin : g_qsys

        /* sysmem_lite is MiSTer's, lifted unmodified -- see rtl/mister/README.md
         * for why a generated system would be worse than a borrowed one. Three
         * f2sdram ports; ram1 is the 64-bit one and the only one used here. */
        wire        sys_clock, sys_reset;

        /* Word addresses, not byte addresses. ram1 is 64 bits wide, so the port
         * indexes 8-byte words and the low three bits of a byte address are
         * implicit. ddr_svc.sv does the same thing by taking ch0_addr[31:3].
         * Getting this wrong does not fail loudly -- it reads the right bytes
         * from eight times the wrong place. */
        wire [28:0] ram1_address = m_address[31:3];

        assign m_clk   = sys_clock;
        assign m_rst_n = ~sys_reset;

        sysmem_lite u_sysmem (
            .clock              (sys_clock),
            .reset_out          (sys_reset),

            .reset_hps_cold_req (1'b0),
            .reset_hps_warm_req (1'b0),
            .reset_core_req     (1'b0),

            /* Read only: the fabric never writes scanout memory. The daemon
             * writes it from the ARM side with an ordinary memcpy, which is
             * the entire point of putting it in DDR3. */
            .ram1_clk           (sys_clock),
            .ram1_address       (ram1_address),
            .ram1_burstcount    (m_burstcount[7:0]),
            .ram1_waitrequest   (m_waitrequest),
            .ram1_readdata      (m_readdata),
            .ram1_readdatavalid (m_readdatavalid),
            .ram1_read          (m_read),
            .ram1_writedata     (64'd0),
            .ram1_byteenable    (8'd0),
            .ram1_write         (1'b0),

            /* Unused ports still need a clock: each has a safe terminator that
             * is clocked whether or not anything drives the port. */
            .ram2_clk           (sys_clock),
            .ram2_address       (29'd0),
            .ram2_burstcount    (8'd1),
            .ram2_waitrequest   (),
            .ram2_readdata      (),
            .ram2_readdatavalid (),
            .ram2_read          (1'b0),
            .ram2_writedata     (64'd0),
            .ram2_byteenable    (8'd0),
            .ram2_write         (1'b0),

            .vbuf_clk           (sys_clock),
            .vbuf_address       (28'd0),
            .vbuf_burstcount    (8'd1),
            .vbuf_waitrequest   (),
            .vbuf_readdata      (),
            .vbuf_readdatavalid (),
            .vbuf_read          (1'b0),
            .vbuf_writedata     (128'd0),
            .vbuf_byteenable    (16'd0),
            .vbuf_write         (1'b0)
        );

    end else begin : g_stub

        /* No system in the build. The master is accepted and never answered, so
         * a DDR3 configuration still elaborates and lints -- which is what keeps
         * this path from rotting while the Quartus side is unfinished. The
         * underrun bit is what says so out loud on hardware. */
        assign m_clk           = ref_clk;
        assign m_rst_n         = ref_rst_n;
        assign m_waitrequest   = 1'b0;
        assign m_readdata      = {DW{1'b0}};
        assign m_readdatavalid = 1'b0;

    end
    endgenerate

endmodule

`default_nettype wire
