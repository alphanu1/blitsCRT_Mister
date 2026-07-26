# Lifted from MiSTer

These two files come from the MiSTer framework
(<https://github.com/MiSTer-devel/Template_MiSTer>, `sys/`) and are **GPL-2.0**,
not MIT. They are kept in their own directory, unmodified, so what is ours and
what is theirs is never in doubt.

| file | what it is |
|---|---|
| `sysmem.sv` | `sysmem_lite` -- a flattened, pre-generated Platform Designer system carrying the HPS component with three FPGA-to-SDRAM ports. It instantiates `cyclonev_hps_interface_fpga2sdram` directly, so no Qsys generation step is needed. |
| `f2sdram_safe_terminator.sv` | Copyright (c) 2021 bellwood420. Completes an in-flight burst when reset is asserted. `sysmem.sv` instantiates one per port, so it comes along. |

`sysmem.sv` is used rather than a system generated here for a reason beyond
convenience. The f2sdram port configuration is latched by writing `APPLYCFG` in
the SDRAM controller while the DDR interface is completely idle, which cannot be
done once Linux is running -- the preloader does it at boot. The A2 preloader on
a MiSTer card was built against *this* configuration. Generating a different one
would mean the latched configuration no longer matched, and fixing that means
rebuilding the preloader.

Interface notes, since they are not obvious from the port list:

- **Addresses are word addresses, not byte addresses.** `ram1_address[28:0]` is a
  64-bit word index; `ddr_svc.sv` feeds it `ch0_addr[31:3]`. The shift lives in
  `rtl/blitscrt_f2sdram.v`.
- `burstcount` is 8 bits, so a burst is at most 128 beats.
- Each port takes its own clock from the fabric. `clock` out of `sysmem_lite` is
  `h2f_user0_clk` and is what we feed back in.
- `reset_out` holds for two million cycles after configuration before releasing.
