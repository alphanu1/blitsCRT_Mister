`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// pll_modes.v -- pixel clock generation and selection.
//
// One PLL, two output counters, one clock mux.
//
// altclkctrl on Cyclone V will only take PLL outputs on inclk[2] and inclk[3];
// inclk[0] and inclk[1] must come from real clock pins. So exactly two PLL
// clocks can be muxed, and the three modes are arranged to need only two:
//
//   12.600 MHz   640x240p60 and 640x480i60, both 15.750 kHz
//   25.200 MHz   640x480p60, 31.500 kHz
//
// Switching between the two 15kHz modes therefore does not touch the clock at
// all. Both counters hang off one VCO at 1260 MHz, C=100 and C=50.
//
// Arbitrary Switchres clocks need altera_pll_reconfig, which shifts new
// counters in over a scan chain. That arrives with M2.
// -----------------------------------------------------------------------------

`default_nettype none

module pll_modes (
    input  wire       refclk,        // 50 MHz, and a genuine clock pin
    input  wire       rst,
    input  wire [1:0] sel,           // 2 = 12.6 MHz, 3 = 25.2 MHz
    output wire       clk_pix,
    output wire       locked
);

    wire [1:0] outclk;               // [0] = 25.2 MHz, [1] = 12.6 MHz

    altera_pll #(
        .fractional_vco_multiplier("false"),
        .reference_clock_frequency("50.0 MHz"),
        .operation_mode("direct"),
        .number_of_clocks(2),
        .output_clock_frequency0("25.200000 MHz"),
        .phase_shift0("0 ps"),
        .duty_cycle0(50),
        .output_clock_frequency1("12.600000 MHz"),
        .phase_shift1("0 ps"),
        .duty_cycle1(50),
        .pll_type("General"),
        .pll_subtype("General")
    ) u_pll (
        .rst      (rst),
        .outclk   (outclk),
        .locked   (locked),
        .fboutclk (),
        .fbclk    (1'b0),
        .refclk   (refclk)
    );

    // inclk[0] and inclk[1] are tied to the reference, which is a clock pin and
    // satisfies the placement rule. Only slots 2 and 3 are ever selected.
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
        .inclk({outclk[0], outclk[1], refclk, refclk}),
        .outclk(clk_pix)
    );

endmodule

`default_nettype wire
