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

/* Stands in for the generated Altera PLL. Two fixed outputs; reconfiguration
 * ports accepted and ignored, since functional sim does not retune. */
module pll_pix (
    input  wire        refclk,
    input  wire        rst,
    output wire        outclk_0,
    output wire        outclk_1,
    output wire        locked,
    input  wire [63:0] reconfig_to_pll,
    output wire [63:0] reconfig_from_pll
);
    reg c0 = 1'b0, c1 = 1'b0;
    always #39.68254 c0 = ~c0;          // 12.6 MHz
    always #79.36508 c1 = ~c1;          //  6.3 MHz
    assign outclk_0 = c0;
    assign outclk_1 = c1;
    assign locked   = 1'b1;
    assign reconfig_from_pll = 64'd0;
endmodule

/* Stands in for altera_pll_reconfig. Accepts the Avalon slave and never
 * stalls; functional sim does not model the reconfiguration shift. */
module pll_reconfig (
    input  wire        mgmt_clk,
    input  wire        mgmt_reset,
    input  wire [5:0]  mgmt_address,
    input  wire        mgmt_read,
    output wire [31:0] mgmt_readdata,
    input  wire        mgmt_write,
    input  wire [31:0] mgmt_writedata,
    output wire        mgmt_waitrequest,
    output wire [63:0] reconfig_to_pll,
    input  wire [63:0] reconfig_from_pll
);
    assign mgmt_readdata    = 32'd0;
    assign mgmt_waitrequest = 1'b0;
    assign reconfig_to_pll  = 64'd0;
endmodule

/* Stands in for the hardened HPS general-purpose interface. In sim gp_out is
 * held idle; a testbench that wants to inject ARM writes drives the DUT's
 * gp_out net directly rather than through this. */
module cyclonev_hps_interface_mpu_general_purpose (
    input  wire [31:0] gp_in,
    output wire [31:0] gp_out
);
    assign gp_out = 32'd0;
endmodule
