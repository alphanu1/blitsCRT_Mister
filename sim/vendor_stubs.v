// Behavioural stand-ins for the Quartus primitives so the top level can be
// elaborated and linted under Icarus. Not used in synthesis.
`timescale 1ns/1ps

module altera_pll #(
    parameter fractional_vco_multiplier = "false",
    parameter reference_clock_frequency = "50.0 MHz",
    parameter operation_mode = "direct",
    parameter number_of_clocks = 1,
    parameter output_clock_frequency0 = "25.200000 MHz",
    parameter phase_shift0 = "0 ps",
    parameter duty_cycle0 = 50,
    parameter output_clock_frequency1 = "12.600000 MHz",
    parameter phase_shift1 = "0 ps",
    parameter duty_cycle1 = 50,
    parameter pll_type = "General",
    parameter pll_subtype = "General"
) (
    input  wire rst, refclk, fbclk,
    output wire [number_of_clocks-1:0] outclk,
    output wire locked, fboutclk
);
    reg c0 = 1'b0, c1 = 1'b0;
    always #19.84127 c0 = ~c0;          // 25.2 MHz
    always #39.68254 c1 = ~c1;          // 12.6 MHz
    assign outclk   = (number_of_clocks > 1) ? {c1, c0} : c0;
    assign locked   = 1'b1;
    assign fboutclk = 1'b0;
endmodule

module altddio_out #(
    parameter extend_oe_disable = "OFF",
    parameter intended_device_family = "Cyclone V",
    parameter invert_output = "OFF",
    parameter lpm_type = "altddio_out",
    parameter oe_reg = "UNREGISTERED",
    parameter power_up_high = "OFF",
    parameter width = 1
) (
    input  wire [width-1:0] datain_h, datain_l,
    input  wire outclock, outclocken, aclr, aset, sclr, sset, oe,
    output wire [width-1:0] dataout
);
    assign dataout = outclock ? datain_h : datain_l;
endmodule

/* Glitch-free clock mux. The real primitive switches on an inactive edge; the
 * stub just selects, which is enough for functional simulation. */
module altclkctrl #(
    parameter clock_type = "AUTO",
    parameter ena_register_mode = "none",
    parameter intended_device_family = "Cyclone V",
    parameter implement_in_les = "OFF",
    parameter number_of_clocks = 4,
    parameter use_glitch_free_switch_over_implementation = "ON",
    parameter width_clkselect = 2,
    parameter lpm_type = "altclkctrl"
) (
    input  wire [width_clkselect-1:0] clkselect,
    input  wire ena,
    input  wire [number_of_clocks-1:0] inclk,
    output wire outclk
);
    assign outclk = ena ? inclk[clkselect] : 1'b0;
endmodule
