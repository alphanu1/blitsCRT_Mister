set_global_assignment -entity "pll_pix" -library "lib_pll_pix" -name IP_TOOL_NAME "altera_pll"
set_global_assignment -entity "pll_pix" -library "lib_pll_pix" -name IP_TOOL_VERSION "24.1"
set_global_assignment -entity "pll_pix" -library "lib_pll_pix" -name IP_TOOL_ENV "mwpim"
set_global_assignment -library "lib_pll_pix" -name SPD_FILE [file join $::quartus(sip_path) "pll_pix.spd"]

set_global_assignment -library "lib_pll_pix" -name MISC_FILE [file join $::quartus(sip_path) "pll_pix_sim/pll_pix.vo"]
