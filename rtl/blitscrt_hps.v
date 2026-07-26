// SPDX-License-Identifier: GPL-2.0-or-later
`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// blitscrt_hps.v -- the HPS interface primitive, isolated.
//
// This is the only module that instantiates hard-processor-system primitives.
// It brings out the 32-bit general-purpose ports MiSTer uses -- the one HPS
// interface proven on this board without a Platform Designer system -- and
// presents them to blitscrt_bridge as gp_out/gp_in.
//
// cyclonev_hps_interface_mpu_general_purpose is a hardened block: gp_out is
// driven by the ARM (h2f), gp_in is read by it (f2h). No pins, no board
// dependency; the ports exist inside the SoC.
//
// Keeping this separate is what lets the design build and simulate with no HPS
// at all. tb and the M1 bitstream leave it out; only the full M2 top pulls it
// in, guarded by the WITH_HPS parameter so a bare fabric build is unaffected.
// -----------------------------------------------------------------------------

`default_nettype none

module blitscrt_hps #(
    parameter WITH_HPS = 1              // 0 stubs the HPS out for simulation
) (
    output wire [31:0] gp_out,          // ARM -> fabric
    input  wire [31:0] gp_in            // fabric -> ARM
);

    generate
    if (WITH_HPS) begin : g_hps
        // The hardened general-purpose interface. gp_out carries the ARM's
        // writes to h2f_gp; gp_in is presented back on f2h_gp. Same primitive
        // and connection MiSTer uses in sys_top.v.
        cyclonev_hps_interface_mpu_general_purpose h2f_gp (
            .gp_in  (gp_in),
            .gp_out (gp_out)
        );
    end
    else begin : g_stub
        // No HPS in the build. gp_out idle; gp_in ignored.
        assign gp_out = 32'd0;
    end
    endgenerate

endmodule

`default_nettype wire
