// SPDX-License-Identifier: GPL-2.0-or-later
// Behavioural stand-in for the one Cyclone V primitive altera_pll_reconfig_core
// instantiates, so the real IP can be simulated. It is a 4-LUT: dataa..datad in,
// combout out, with the truth table in lut_mask.
`timescale 1ps/1ps
module cyclonev_lcell_comb #(
    parameter lut_mask = 64'h0000000000000000,
    parameter shared_arith = "off",
    parameter extended_lut = "off",
    parameter dont_touch = "off"
) (
    input  dataa, datab, datac, datad, datae, dataf, datag, cin, sharein,
    output combout, sumout, cout, shareout
);
    wire [3:0] idx = {datad, datac, datab, dataa};
    assign combout  = lut_mask[idx];
    assign sumout   = 1'b0;
    assign cout     = 1'b0;
    assign shareout = 1'b0;
endmodule
