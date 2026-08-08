# Which paths miss timing, and between what.
#
# The .sta.rpt summary gives a number per clock and never names a node, so a
# design can carry -214 ns of total negative slack with nothing in the report
# saying where. This asks the analyser directly.
#
#   make failing-paths
#
# The operating condition is named in full, speed-grade prefix included:
# 7_slow_1100mv_100c, not slow_1100mv_100c and not -slow_model. Three earlier
# spellings were rejected; the error message from the second listed the legal
# ones, which is where this came from.
project_open [lindex $quartus(args) 0]
# Try the named condition first; fall back to a plain netlist if the name
# differs again in another Quartus. Guessing at this API has cost three runs.
if {[catch {create_timing_netlist -model slow -temperature 100 -voltage 1100}]} {
    puts "note: named operating condition rejected, using the default netlist"
    create_timing_netlist
}
read_sdc
update_timing_netlist

puts "\n================ worst setup paths, all endpoints ================"
report_timing -setup -npaths 25 -detail summary -stdout

puts "\n================ worst setup paths, registers only ================"
# The pad constraints cover 47 pins between them, so if those are what fail
# they fill the list above and hide anything else.
report_timing -setup -npaths 15 -detail summary -stdout -to [get_registers *]

project_close
