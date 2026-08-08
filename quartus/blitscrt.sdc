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
# 25 ns, not 12.
#
# The 12 ns figure was invented and could never be met: the pixel clock takes
# 8.9 ns to reach the output registers, so the constraint left 3.1 ns for 8.7 ns
# of routing and every one of these pins failed by about 5.6 ns. That put -214 ns
# of total negative slack in the report -- enough to bury anything real, and it
# very nearly did.
#
# What actually matters here is not absolute delay but skew between the bits:
# the DAC on the A/V board latches all six bits of each channel together, so
# they must arrive within a fraction of a pixel. 25 ns is comfortably longer
# than the worst path and still far inside the 79 ns pixel period at 12.6 MHz,
# or 40 ns at 25.2 MHz, so the bits stay bunched without demanding routing the
# fitter cannot deliver.
#
# The DAC has no clock pin of its own on this board -- see the note about
# VGA_TX_CLK in blitscrt_top.v -- so a source-synchronous constraint is not
# available for VGA the way it is for HDMI below.
set_max_delay -to [get_ports {VGA_R[*] VGA_G[*] VGA_B[*] VGA_HS VGA_VS}] 25.0
set_min_delay -to [get_ports {VGA_R[*] VGA_G[*] VGA_B[*] VGA_HS VGA_VS}] 0.0
set_min_delay -to [get_ports {VGA_R[*] VGA_G[*] VGA_B[*] VGA_HS VGA_VS}] -2.0

# HDMI. The transmitter latches on the clock we hand it, so the data bus wants
# the same skew bound as the analog side. I2C is a 100kHz open-drain bus and
# needs no constraining.
# 25 ns, the same reasoning as the VGA pins above.
#
# A source-synchronous constraint was tried here first: a generated clock on the
# forwarded HDMI_TX_CLK with +/-1.5 ns of output delay, which is the textbook
# shape and what the ADV7513 actually samples with. It made timing worse, not
# better -- -8.251 ns against the -5.641 it replaced -- because the forwarded
# clock leaves through a DDIO and its arrival at the pin bears no simple
# relation to the launch clock at the registers. Getting that right needs the
# DDIO path modelled properly, which is a job on its own.
#
# So: a plain bound, generous enough to be met, tight enough to keep the bits
# of a channel together. At 79 ns per pixel the outputs have never been close
# to marginal, and both HDMI and the CRT have worked throughout.
set_max_delay -to [get_ports {HDMI_TX_D[*] HDMI_TX_DE HDMI_TX_HS HDMI_TX_VS}] 25.0
set_min_delay -to [get_ports {HDMI_TX_D[*] HDMI_TX_DE HDMI_TX_HS HDMI_TX_VS}] 0.0
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
