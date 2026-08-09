# pll_pix_frac_0002.v is hand-corrected

The parameter editor generated counters that cannot work. Corrected in place
rather than regenerated -- re-entering the same values in the editor produces
the same output, and the parameters are plain text in this file.

## What was wrong

| | as generated | corrected | integer `pll_pix` |
|---|---|---|---|
| `n_cnt_hi/lo_div` | 256 / 256 | 3 / 2 | 3 / 2 |
| `n_cnt_bypass_en` | true | false | false |
| `m_cnt_hi/lo_div` | 4 / 4 | 32 / 31 | 32 / 31 |
| `c_cnt_*_div0` | 16 | 25 | 25 |
| `c_cnt_*_div1` | 32 | 50 | 50 |
| `pll_vco_div` | 2 | 1 | 1 |
| `fractional_division` | 274877907 | 1 | 1 |
| **VCO** | **403.2 MHz** | **630.0 MHz** | 630.0 MHz |
| **outclk0** | **6.30 MHz** | **12.60 MHz** | 12.60 MHz |

Two faults. Cyclone V's VCO minimum is 600 MHz, so 403.2 could never lock; and
the outputs came out at exactly half the intended frequency, which says the
figures entered in the editor were not the ones wanted.

On hardware it showed as the PLL never locking at all --
`reconfig_from_pll[16] = 0` from power-on, before software wrote anything. The
core gates everything on that, so the raster never started, the daemon could not
finish, and the front panel showed power off with the orange LED for a gadget
that never bound. `peek -p` confirmed the reconfiguration path was healthy:
`accepts=255`, `stalled=0`, no counter writes attempted.

## What makes it fractional

One parameter:

    fractional_vco_multiplier("true")

Everything else now matches `pll_pix` exactly, apart from the loop bandwidth --
`pll_bwctrl(4000)` against 6000 -- which is narrower on purpose, since a tighter
loop filters the dither a fractional divider produces.

`fractional_division` is 1 at power-on, the same as the integer core. The
runtime numerator is written by the daemon through `PLL_RECONFIG_K` at 0x101c;
this parameter only sets where the core starts.

## Regenerating

If this IP is ever regenerated, check before building:

    n_cnt, m_cnt and the VCO -- 50 MHz * M / N must land in 600-1600 MHz
    c_cnt_div0 -> 12.600 MHz, c_cnt_div1 -> 6.300 MHz

Reading `fractional_cout(32)` and assuming the rest is right is what let a
non-locking core through the first time.
