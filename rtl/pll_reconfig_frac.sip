set_global_assignment -entity "pll_reconfig_frac" -library "lib_pll_reconfig_frac" -name IP_TOOL_NAME "altera_pll_reconfig"
set_global_assignment -entity "pll_reconfig_frac" -library "lib_pll_reconfig_frac" -name IP_TOOL_VERSION "24.1"
set_global_assignment -entity "pll_reconfig_frac" -library "lib_pll_reconfig_frac" -name IP_TOOL_ENV "mwpim"
set_global_assignment -library "lib_pll_reconfig_frac" -name SPD_FILE [file join $::quartus(sip_path) "pll_reconfig_frac.spd"]

set_global_assignment -library "lib_pll_reconfig_frac" -name MISC_FILE [file join $::quartus(sip_path) "pll_reconfig_frac_sim/pll_reconfig_frac.v"]
set_global_assignment -library "lib_pll_reconfig_frac" -name MISC_FILE [file join $::quartus(sip_path) "pll_reconfig_frac_sim/altera_pll_reconfig/altera_pll_reconfig_top.v"]
set_global_assignment -library "lib_pll_reconfig_frac" -name MISC_FILE [file join $::quartus(sip_path) "pll_reconfig_frac_sim/altera_pll_reconfig/altera_pll_reconfig_core.v"]
set_global_assignment -library "lib_pll_reconfig_frac" -name MISC_FILE [file join $::quartus(sip_path) "pll_reconfig_frac_sim/altera_pll_reconfig/altera_std_synchronizer.v"]
