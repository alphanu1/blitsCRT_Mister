// SPDX-License-Identifier: GPL-2.0-or-later
// Elaborates the on-chip configuration. The default is now DDR3, so without
// this the M3a/M3b path would stop being checked at all.
module lint_onchip;
    blitscrt_top #(.SCANOUT_SRC("ONCHIP")) u ();
endmodule
