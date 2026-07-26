# -----------------------------------------------------------------------------
# pins.tcl -- blitsCRT_Mister pin assignments for MiSTer Pi / DE10-Nano
#
# ---------------------------------------------------------------------------
# The assignments here are derived from the MiSTer framework:
#
#     sys/sys.tcl and sys/sys_analog.tcl in MiSTer-devel/Template_MiSTer
#     GPL-2.0
#
# They are facts about how the board is wired, reduced to the signals this
# design actually uses. `make check-pins MISTER=...` diffs ours against theirs.
# ---------------------------------------------------------------------------
#
# The SDRAM block is present but commented out.
#
# VGA on the analog A/V board is a six-bit resistor ladder per channel driven
# straight off FPGA pins. There is no DAC chip in the path, which is why the
# design outputs RGB666 natively.
# -----------------------------------------------------------------------------

set_global_assignment -name FAMILY "Cyclone V"
set_global_assignment -name DEVICE 5CSEBA6U23I7

#============================================================
# Clocks
#============================================================
set_location_assignment PIN_V11 -to FPGA_CLK1_50
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to FPGA_CLK1_50

#============================================================
# VGA -- analog A/V board, RGB666 + separate sync
#============================================================
set_location_assignment PIN_AE17 -to VGA_R[0]
set_location_assignment PIN_AE20 -to VGA_R[1]
set_location_assignment PIN_AF20 -to VGA_R[2]
set_location_assignment PIN_AH18 -to VGA_R[3]
set_location_assignment PIN_AH19 -to VGA_R[4]
set_location_assignment PIN_AF21 -to VGA_R[5]

set_location_assignment PIN_AE19 -to VGA_G[0]
set_location_assignment PIN_AG15 -to VGA_G[1]
set_location_assignment PIN_AF18 -to VGA_G[2]
set_location_assignment PIN_AG18 -to VGA_G[3]
set_location_assignment PIN_AG19 -to VGA_G[4]
set_location_assignment PIN_AG20 -to VGA_G[5]

set_location_assignment PIN_AG21 -to VGA_B[0]
set_location_assignment PIN_AA20 -to VGA_B[1]
set_location_assignment PIN_AE22 -to VGA_B[2]
set_location_assignment PIN_AF22 -to VGA_B[3]
set_location_assignment PIN_AH23 -to VGA_B[4]
set_location_assignment PIN_AH21 -to VGA_B[5]

set_location_assignment PIN_AH22 -to VGA_HS
set_location_assignment PIN_AG24 -to VGA_VS

# board-present detect: the A/V board pulls this low
set_location_assignment PIN_AH27 -to VGA_EN
set_instance_assignment -name WEAK_PULL_UP_RESISTOR ON -to VGA_EN

set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to VGA_*
set_instance_assignment -name CURRENT_STRENGTH_NEW 8MA -to VGA_*

#============================================================
# I/O board buttons and LEDs
#============================================================
set_location_assignment PIN_Y15  -to LED_USER
set_location_assignment PIN_AA15 -to LED_HDD
set_location_assignment PIN_AG28 -to LED_POWER

set_location_assignment PIN_AH24 -to BTN_USER
set_location_assignment PIN_AG25 -to BTN_OSD
set_location_assignment PIN_AG23 -to BTN_RESET

set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to LED_*
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to BTN_*
set_instance_assignment -name WEAK_PULL_UP_RESISTOR ON -to BTN_*


#============================================================
# HDMI -- ADV7513 transmitter (Direct Video)
#============================================================
set_location_assignment PIN_AG5  -to HDMI_TX_CLK
set_location_assignment PIN_AD19 -to HDMI_TX_DE
set_location_assignment PIN_T8   -to HDMI_TX_HS
set_location_assignment PIN_V13  -to HDMI_TX_VS
set_location_assignment PIN_AF11 -to HDMI_TX_INT
set_location_assignment PIN_U10  -to HDMI_I2C_SCL
set_location_assignment PIN_AA4  -to HDMI_I2C_SDA

set_location_assignment PIN_AD12 -to HDMI_TX_D[0]
set_location_assignment PIN_AE12 -to HDMI_TX_D[1]
set_location_assignment PIN_W8   -to HDMI_TX_D[2]
set_location_assignment PIN_Y8   -to HDMI_TX_D[3]
set_location_assignment PIN_AD11 -to HDMI_TX_D[4]
set_location_assignment PIN_AD10 -to HDMI_TX_D[5]
set_location_assignment PIN_AE11 -to HDMI_TX_D[6]
set_location_assignment PIN_Y5   -to HDMI_TX_D[7]
set_location_assignment PIN_AF10 -to HDMI_TX_D[8]
set_location_assignment PIN_Y4   -to HDMI_TX_D[9]
set_location_assignment PIN_AE9  -to HDMI_TX_D[10]
set_location_assignment PIN_AB4  -to HDMI_TX_D[11]
set_location_assignment PIN_AE7  -to HDMI_TX_D[12]
set_location_assignment PIN_AF6  -to HDMI_TX_D[13]
set_location_assignment PIN_AF8  -to HDMI_TX_D[14]
set_location_assignment PIN_AF5  -to HDMI_TX_D[15]
set_location_assignment PIN_AE4  -to HDMI_TX_D[16]
set_location_assignment PIN_AH2  -to HDMI_TX_D[17]
set_location_assignment PIN_AH4  -to HDMI_TX_D[18]
set_location_assignment PIN_AH5  -to HDMI_TX_D[19]
set_location_assignment PIN_AH6  -to HDMI_TX_D[20]
set_location_assignment PIN_AG6  -to HDMI_TX_D[21]
set_location_assignment PIN_AF9  -to HDMI_TX_D[22]
set_location_assignment PIN_AE8  -to HDMI_TX_D[23]

set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to HDMI_*
set_instance_assignment -name CURRENT_STRENGTH_NEW 8MA  -to HDMI_TX_*
set_instance_assignment -name WEAK_PULL_UP_RESISTOR ON  -to HDMI_I2C_*
set_instance_assignment -name WEAK_PULL_UP_RESISTOR ON  -to HDMI_TX_INT

#============================================================
# SDRAM module -- M3, not wired in yet
#============================================================
# set_location_assignment PIN_Y11  -to SDRAM_A[0]
# set_location_assignment PIN_AA26 -to SDRAM_A[1]
# set_location_assignment PIN_AA13 -to SDRAM_A[2]
# set_location_assignment PIN_AA11 -to SDRAM_A[3]
# set_location_assignment PIN_W11  -to SDRAM_A[4]
# set_location_assignment PIN_Y19  -to SDRAM_A[5]
# set_location_assignment PIN_AB23 -to SDRAM_A[6]
# set_location_assignment PIN_AC23 -to SDRAM_A[7]
# set_location_assignment PIN_AC22 -to SDRAM_A[8]
# set_location_assignment PIN_C12  -to SDRAM_A[9]
# set_location_assignment PIN_AB26 -to SDRAM_A[10]
# set_location_assignment PIN_AD17 -to SDRAM_A[11]
# set_location_assignment PIN_D12  -to SDRAM_A[12]
# set_location_assignment PIN_Y17  -to SDRAM_BA[0]
# set_location_assignment PIN_AB25 -to SDRAM_BA[1]
# set_location_assignment PIN_V12  -to SDRAM_DQ[0]
# set_location_assignment PIN_E8   -to SDRAM_DQ[1]
# set_location_assignment PIN_D11  -to SDRAM_DQ[2]
# set_location_assignment PIN_W12  -to SDRAM_DQ[3]
# set_location_assignment PIN_AH13 -to SDRAM_DQ[4]
# set_location_assignment PIN_D8   -to SDRAM_DQ[5]
# set_location_assignment PIN_AH14 -to SDRAM_DQ[6]
# set_location_assignment PIN_AF7  -to SDRAM_DQ[7]
# set_location_assignment PIN_AE24 -to SDRAM_DQ[8]
# set_location_assignment PIN_AD23 -to SDRAM_DQ[9]
# set_location_assignment PIN_AE6  -to SDRAM_DQ[10]
# set_location_assignment PIN_AE23 -to SDRAM_DQ[11]
# set_location_assignment PIN_AG14 -to SDRAM_DQ[12]
# set_location_assignment PIN_AD5  -to SDRAM_DQ[13]
# set_location_assignment PIN_AF4  -to SDRAM_DQ[14]
# set_location_assignment PIN_AH3  -to SDRAM_DQ[15]
# set_location_assignment PIN_AG13 -to SDRAM_DQML
# set_location_assignment PIN_AF13 -to SDRAM_DQMH
# set_location_assignment PIN_AD20 -to SDRAM_CLK
# set_location_assignment PIN_AG10 -to SDRAM_CKE
# set_location_assignment PIN_AA19 -to SDRAM_nWE
# set_location_assignment PIN_AA18 -to SDRAM_nCAS
# set_location_assignment PIN_Y18  -to SDRAM_nCS
# set_location_assignment PIN_W14  -to SDRAM_nRAS
