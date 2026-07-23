# blitsCRT_Mister timing constraints

create_clock -name FPGA_CLK1_50 -period 20.000 [get_ports {FPGA_CLK1_50}]

derive_pll_clocks
derive_clock_uncertainty

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
