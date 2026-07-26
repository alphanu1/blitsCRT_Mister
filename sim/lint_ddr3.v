// SPDX-License-Identifier: GPL-2.0-or-later
module lint_ddr3;
    /* WITH_QSYS(0): Icarus has no cyclonev_hps_interface_* primitives, so the
     * real sysmem_lite cannot elaborate here. This checks everything around it. */
    blitscrt_top #(.SCANOUT_SRC("DDR3"), .F2SDRAM_DW(64), .WITH_QSYS(0)) u ();
endmodule
