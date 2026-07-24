# Wiring altera_pll_reconfig

`sw/pll_reconfig.c` builds the register writes. This is the fabric side it
writes into, which has to be generated in the IP Catalog rather than written by
hand.

## The PLL

`rtl/pll_modes.v` currently instantiates `altera_pll` with no reconfiguration
ports. Regenerate it with **Enable reconfigurable PLL** ticked, which adds:

```
    .reconfig_to_pll   (reconfig_to_pll),    // [63:0]
    .reconfig_from_pll (reconfig_from_pll)   // [63:0]
```

## The reconfiguration block

Add `altera_pll_reconfig` from the IP Catalog and connect it to those two
buses. It presents an Avalon-MM slave, which goes on the lightweight bridge at
`BLITSCRT_PLLRECFG_OFFSET` (0x1000 from the design base).

```
    altera_pll_reconfig u_recfg (
        .mgmt_clk        (FPGA_CLK1_50),
        .mgmt_reset      (~rst50_n),
        .mgmt_address    (avs_address[2:0]),
        .mgmt_write      (avs_write),
        .mgmt_writedata  (avs_writedata),
        .mgmt_read       (avs_read),
        .mgmt_readdata   (avs_readdata),
        .mgmt_waitrequest(avs_waitrequest),
        .reconfig_to_pll  (reconfig_to_pll),
        .reconfig_from_pll(reconfig_from_pll)
    );
```

## Holding the pipeline

The pixel clock is unusable between the start write and lock returning. Extend
the existing `mode_hold` counter in `blitscrt_top.v` to cover it: assert on a
write to `BLITSCRT_REG_APPLY`, release when `locked` comes back. The mechanism
already exists for clock mux switches and wants the same treatment here.

## What to check first

Two things in `sw/pll_reconfig.h` are marked VERIFY and cannot be settled
without the generated IP:

- **The register addresses.** The map there is the standard one, but IP options
  move things. A wrong address mis-clocks the video rather than failing.
- **The counter field width.** The encoding assumes eight-bit half-periods,
  which caps any divide at 510. Some variants carry nine bits, lifting it to
  1022. `PLL_CNT_FIELD_BITS` is the single place to change it, and
  `pll_cyclonev` in `sw/pll.c` has matching limits.

`sw/tests/test_pll_reconfig.c` checks the encoding round-trips across every
divide, so a field-width change is one edit and one test run.
