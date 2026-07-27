# Vendor IP, for simulation only

`altera_pll_reconfig_*.v`, `altera_std_synchronizer.v` and `pll_reconfig.v` are
Intel/Altera IP, copied here unmodified from the Quartus IP catalog output so the
reconfiguration path can be simulated. They are **not** built into the bitstream:
the .qsf pulls the generated copies under `rtl/pll_reconfig/` via its .qip, and
these are compiled only by `sim/tb_pll_reconfig.v`.

`cyclonev_stub.v` is ours, GPL-2.0-or-later. `altera_pll_reconfig_core` uses one
Cyclone V primitive, `cyclonev_lcell_comb`, which Icarus has no model for; this is
a four-input LUT with the truth table in `lut_mask`, which is all the core needs
from it.

Copying them in was worth it. The reconfiguration window read and wrote zero on
hardware across four rebuilds while every health indicator said the block was
ready -- addressed, clocked, out of reset, accepting, waitrequest low. Simulating
the real IP reproduced it on the first run and found the cause in minutes: the
bug was in `blitscrt_pllbus.v`, which held `mgmt_read` asserted after acceptance.
The slave's read FSM re-runs for as long as read is asserted, and its readdata
alternates between the register value and zero as it cycles, so capturing "the
freshest value" took whichever phase it landed on.

If these are regenerated, replace them from
`rtl/pll_reconfig/pll_reconfig/` and re-run `make sim`.
