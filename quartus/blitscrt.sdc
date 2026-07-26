# blitsCRT_Mister timing constraints

create_clock -name FPGA_CLK1_50 -period 20.000 [get_ports {FPGA_CLK1_50}]

derive_pll_clocks
derive_clock_uncertainty

# The HPS user clock. sysmem_lite brings it out as h2f_user0_clk and the f2sdram
# port, the line fetcher and its buffers all run on it. It comes out of the hard
# processor system rather than a fabric PLL, so derive_pll_clocks does not find
# it and without this the whole domain is unconstrained -- which does not fail
# the build, it just stops the fitter having anything to close. Constrained the
# same way MiSTer's sys_top.sdc does.
#
# If the fitter reports h2f_user0_clk as an unconstrained clock, this wildcard
# did not match; check the instance path before trusting any timing result.
create_clock -period "100.0 MHz" [get_pins -compatibility_mode *|h2f_user0_clk]

# Three independent domains: the 50 MHz reference, the pixel clock out of the
# PLL, and the HPS clock. Everything crossing between them goes through the
# two-flop synchronisers in blitscrt_regs and scanout_fetch, or through a
# dual-clock M10K. Declaring them asynchronous is what stops the fitter trying
# to close timing on paths that are handled by the synchronisers instead.
#
# -asynchronous rather than -exclusive: these clocks genuinely run at the same
# time and are simply unrelated. -exclusive would claim they never coexist.
set_clock_groups -asynchronous \
   -group [get_clocks {FPGA_CLK1_50}] \
   -group [get_clocks {*|h2f_user0_clk}] \
   -group [get_clocks {*altera_pll_i|*divclk*}]

# MiSTer's sys_top.sdc false-paths the f2h reset request inputs. We tie all three
# off, so they optimise away and there is no object for the constraint to match
# -- Quartus reports it as an ignored filter. Left out deliberately; add it back
# if anything ever drives reset_hps_cold_req and friends.

# Buttons and the A/V board detect are asynchronous and already resynchronised
# or static.
set_false_path -from [get_ports {BTN_RESET BTN_OSD BTN_USER VGA_EN}]
set_false_path -to   [get_ports {LED_USER LED_HDD LED_POWER}]

# The analog board is a resistor ladder, so there is no capture clock to
# constrain against. What does matter is skew between the colour bits and
# sync -- a few nanoseconds of spread shows up as coloured fringing on a
# sharp edge. Bound it rather than false-pathing the whole bus.
set_max_delay -to [get_ports {VGA_R[*] VGA_G[*] VGA_B[*] VGA_HS VGA_VS}] 12.0
set_min_delay -to [get_ports {VGA_R[*] VGA_G[*] VGA_B[*] VGA_HS VGA_VS}] -2.0

# HDMI. The transmitter latches on the clock we hand it, so the data bus wants
# the same skew bound as the analog side. I2C is a 100kHz open-drain bus and
# needs no constraining.
set_max_delay -to [get_ports {HDMI_TX_D[*] HDMI_TX_DE HDMI_TX_HS HDMI_TX_VS}] 12.0
set_min_delay -to [get_ports {HDMI_TX_D[*] HDMI_TX_DE HDMI_TX_HS HDMI_TX_VS}] -2.0
set_false_path -to   [get_ports {HDMI_I2C_SCL HDMI_I2C_SDA}]
set_false_path -from [get_ports {HDMI_I2C_SDA HDMI_TX_INT}]
