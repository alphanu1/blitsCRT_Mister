// SPDX-License-Identifier: GPL-2.0-or-later
`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// pll_modes.v -- pixel clock generation and selection.
//
// Wraps the generated pll_pix (Altera PLL with reconfiguration enabled) and an
// altclkctrl mux.
//
//   outclk_0   12.600 MHz   15.750 kHz at htotal 800 -- 640x480i60, 640x240p60
//   outclk_1    6.300 MHz   15.750 kHz at htotal 400 -- 320x240p60
//
// Both are 15 kHz, which is the whole point of the project. Everything else in
// the advertised list is reached by altera_pll_reconfig retuning outclk_0 at
// runtime, which is what makes that block load-bearing rather than a nicety: the
// mode list is larger than two clocks and altclkctrl offers only two PLL slots.
// On Cyclone V it takes PLL outputs on inclk[2] and inclk[3] only; inclk[0] and
// inclk[1] must be real clock pins, so the reference fills those.
//
// Slot 3, outclk_1, is no longer selected by mode_table: the 31 kHz mode that
// used it has been removed. Historically it expected
// 25.200 MHz, so it runs at 6.3 and produces a 7.875 kHz line rate instead of
// 31.5. That mode is the HDMI diagnostic and not a 15 kHz target, so it is left
// alone: putting 25.2 on outclk_1 would cost 320x240p60, which is a real mode.
// Reaching 31 kHz properly means reconfiguration, like every other mode beyond
// these two.

`default_nettype none

module pll_modes (
    input  wire        refclk,          // 50 MHz, a real clock pin
    input  wire        rst,
    input  wire [1:0]  sel,             // 2 = outclk_0, 3 = outclk_1

    // reconfiguration, from the Avalon slave in blitscrt_top
    input  wire [63:0] reconfig_to_pll,
    output wire [63:0] reconfig_from_pll,

    output wire        clk_pix,
    output wire        locked
);

    wire c_full, c_half;

    pll_pix u_pll (
        .refclk            (refclk),
        .rst               (rst),
        .outclk_0          (c_full),        // 12.600 MHz at power-on
        .outclk_1          (c_half),        //  6.300 MHz at power-on
        .locked            (locked),
        .reconfig_to_pll   (reconfig_to_pll),
        .reconfig_from_pll (reconfig_from_pll)
    );

    // Slots 0 and 1 tie to the reference pin to satisfy the placement rule;
    // only 2 and 3 are ever selected.
    altclkctrl #(
        .clock_type("AUTO"),
        .ena_register_mode("none"),
        .intended_device_family("Cyclone V"),
        .implement_in_les("OFF"),
        .number_of_clocks(4),
        .use_glitch_free_switch_over_implementation("ON"),
        .width_clkselect(2),
        .lpm_type("altclkctrl")
    ) u_mux (
        .clkselect(sel),
        .ena(1'b1),
        .inclk({c_half, c_full, refclk, refclk}),
        .outclk(clk_pix)
    );

endmodule

`default_nettype wire
