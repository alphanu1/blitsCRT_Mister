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
# 12 ns, and it does not meet -- deliberately.
#
# This was relaxed to 25 ns because 12 could never be met: the pixel clock takes
# 8.9 ns to reach the output registers, leaving 3.1 ns for 8.7 ns of routing, so
# every one of these pins failed by about 5.6 ns and put -214 ns of TNS in the
# report. That looked like a constraint written badly.
#
# Relaxing it changed the colour on a CRT, and the reason is instructive. What
# matters on these pins is not absolute delay but SKEW: the DAC latches all six
# bits of a channel on one edge, so they must arrive together. An unachievable
# max-delay makes the fitter minimise every one of these paths as hard as it
# can, which bunches them. An achievable one makes it stop as soon as each is
# under the number -- so paths that all sat near 8.7 ns were free to spread
# anywhere up to 25, and low bits carrying the previous pixel's value while high
# bits carry this one is exactly a wrong-looking gamma curve.
#
# So the failing constraint was doing useful work. It is left failing, and
# check-fit is told to expect it rather than the constraint being loosened to
# make the report quiet.
#
# The right fix is a proper source-synchronous constraint against a forwarded
# DAC clock. This board does not bring one out -- see the VGA_TX_CLK note in
# blitscrt_top.v -- so that needs hardware, not SDC.
set_max_delay -to [get_ports {VGA_R[*] VGA_G[*] VGA_B[*] VGA_HS VGA_VS}] 12.0
set_min_delay -to [get_ports {VGA_R[*] VGA_G[*] VGA_B[*] VGA_HS VGA_VS}] -2.0

# HDMI. The transmitter latches on the clock we hand it, so the data bus wants
# the same skew bound as the analog side. I2C is a 100kHz open-drain bus and
# needs no constraining.
# 12 ns, failing, for the same reason as the VGA pins above: it keeps the bits
# of the bus arriving together, which is what the ADV7513 needs.
set_max_delay -to [get_ports {HDMI_TX_D[*] HDMI_TX_DE HDMI_TX_HS HDMI_TX_VS}] 12.0
set_min_delay -to [get_ports {HDMI_TX_D[*] HDMI_TX_DE HDMI_TX_HS HDMI_TX_VS}] -2.0
set_false_path -to   [get_ports {HDMI_I2C_SCL HDMI_I2C_SDA}]
set_false_path -from [get_ports {HDMI_I2C_SDA HDMI_TX_INT}]

# ---------------------------------------------------------------------------
# The line-fetch request crossing
# ---------------------------------------------------------------------------
#
# scanout_fetch hands a line number from clk_pix to clk_mem with a toggle and a
# two-flop synchroniser. The flag is safe by construction; the twelve-bit line
# number beside it is not, unless its bits arrive together.
#
# They must, because the reader samples the whole bus the moment the flag
# lands. If one bit is a destination clock period later than the others, the
# fetch reads a line number part-way through a transition and pulls that line
# from the wrong address -- a block edge stepping part-way along a scan, with
# no underrun to show for it, since the fetch completes perfectly and simply
# fetches the wrong line.
#
# The RTL now registers the line number a full clk_pix cycle before raising the
# flag, which is the real fix. These constraints stop the fitter undoing it by
# routing the bus badly, and stop the timing report treating an unconstrained
# asynchronous path as met.
#
# 10 ns is the clk_mem period. Skew within the bus is what matters, so the
# minimum is bounded as well as the maximum.

set_max_delay -from [get_registers {*scanout_fetch*|req_y[*]}] \
              -to   [get_registers {*scanout_fetch*|line_addr[*]}] 10.0
set_min_delay -from [get_registers {*scanout_fetch*|req_y[*]}] \
              -to   [get_registers {*scanout_fetch*|line_addr[*]}] 0.0

# The toggles are the whole point of the handshake: a single bit, sampled twice,
# safe whenever it lands. Nothing to constrain.
set_false_path -from [get_registers {*scanout_fetch*|req_tog}] \
               -to   [get_registers {*scanout_fetch*|req_meta[0]}]
set_false_path -from [get_registers {*scanout_fetch*|ack_tog}] \
               -to   [get_registers {*scanout_fetch*|ack_meta[0]}]
