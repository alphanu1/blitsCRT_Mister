set_global_assignment -entity "pll_pix_frac" -library "lib_pll_pix_frac" -name IP_TOOL_NAME "altera_pll"
set_global_assignment -entity "pll_pix_frac" -library "lib_pll_pix_frac" -name IP_TOOL_VERSION "24.1"
set_global_assignment -entity "pll_pix_frac" -library "lib_pll_pix_frac" -name IP_TOOL_ENV "mwpim"
set_global_assignment -library "lib_pll_pix_frac" -name SPD_FILE [file join $::quartus(sip_path) "pll_pix_frac.spd"]

set_global_assignment -library "lib_pll_pix_frac" -name MISC_FILE [file join $::quartus(sip_path) "pll_pix_frac_sim/pll_pix_frac.vo"]
