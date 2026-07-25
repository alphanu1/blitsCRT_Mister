`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// pll_modes.v -- pixel clock generation and selection.
//
// Wraps the generated pll_pix (Altera PLL with reconfiguration enabled) and an
// altclkctrl mux. The PLL comes up at 12.600 and 6.300 MHz; altera_pll_reconfig
// shifts new counters in at runtime for anything else.
//
// altclkctrl on Cyclone V takes PLL outputs on inclk[2] and inclk[3] only;
// inclk[0] and inclk[1] must be real clock pins. So the two PLL outputs go to
// slots 2 and 3 and the reference fills 0 and 1.
//
// Both advertised clock families reach every mode:
//   outclk_0  full rate   640-wide modes and the 31kHz diagnostic
//   outclk_1  half rate    320-wide modes
// Reconfiguration retunes both together, since they share the VCO.
// -----------------------------------------------------------------------------

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
