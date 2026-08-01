# Generating the two megafunctions

`rtl/pll_modes.v` currently instantiates `altera_pll` inline with parameter
overrides, which works because nothing needs reconfiguring yet. Runtime
arbitrary pixel clocks need two IP blocks generated properly:

1. **Altera PLL**, regenerated with reconfiguration enabled
2. **Altera PLL Reconfig**, which drives it over Avalon-MM

GUI labels shift between Quartus releases. This gives the settings that
matter and then a check on the generated output. `make check-ip` verifies the
result rather than the steps.

---

## 1. Altera PLL

**IP Catalog → Library → Basic Functions → Clocks; PLLs and Resets → PLL →
Altera PLL.** In 24.1 it may be listed as *PLL Intel FPGA IP* or *Altera PLL
Intel FPGA IP*; it is the same core.

Name the output `pll_pix` so it lands in `rtl/pll_pix/`.

### General

| setting | value | why |
|---|---|---|
| Device family | Cyclone V | |
| PLL mode | **Integer-N** | see below |
| Reference clock frequency | **50.0 MHz** | `FPGA_CLK1_50`, pin V11 |
| Operation mode | **direct** | |
| Enable locked output port | **yes** | the video pipeline is held in reset until it asserts |
| Enable physical output clock parameters | no | frequencies are set below, counters come from software |

### Integer-N or Fractional-N

Fractional-N exists on this device and would be more accurate. It is not the
default here, and the reasoning is worth recording.

Sweeping every pixel clock the design can be asked for, in 1 kHz steps:

| band | mean error | worst | exact hits |
|---|---|---|---|
| 15kHz modes, 5–13 MHz | 9.22 ppm | 409 ppm at 12.494 MHz | 11.6% |
| 31kHz, 20–28 MHz | 25.94 ppm | 880 ppm at 24.978 MHz | 3.7% |

That worst case is a hardware limit, not a search failure. An exhaustive sweep
of all 566,100 M/N/C combinations finds the same answer `sw/pll.c` reaches in
814 operations. Integer ratios get coarse at high output frequencies: at 25 MHz
the C divider is only 24–64 and the achievable steps are wide. At 6 MHz it
is 94–250, and exact hits are common.

What the error costs, as a slipped frame against a 60 Hz source:

```
built-in modes           exact        never
typical modeline        9.22 ppm      one frame every 30 minutes
worst in 15kHz band   409.00 ppm      one frame every 41 seconds
worst overall         880.00 ppm      one frame every 19 seconds
```

So the case is split:

- **For the fabric's own modes and the advertised fallback, integer is exact.**
  They solve to 0 ppm, so fractional buys nothing.
- **For arbitrary Switchres modelines, integer is usually fine and occasionally
  poor.** A judder every 30 minutes is invisible; every 41 seconds is not, and
  exact refresh matching is the entire point of Switchres.

Against that, fractional-N dithers the M divider between two integers to make
the average fractional. The dithering is periodic, not random, and periodic
phase noise correlates with pixel position, which is the classic reason video
PLLs stay integer. At 12.6 MHz a pixel is 79 ns and the jitter is small in absolute terms. It is patterned rather than diffuse, which is what makes it
visible.

Integer is the starting point because every advertised mode is exact and
`sw/pll_reconfig.c` is written for integer counters. If a modeline lands badly
in practice, switching means regenerating this IP as Fractional-N and teaching
`pll_reconfig.c` to write the K register at `PLL_RECONFIG_K`. The RTL does not
change.

Worth checking when you generate it: fractional and integer PLLs are not
always interchangeable on a given device, and the count of each differs.

### Output clocks

Two, and the second is exactly half the first. Every advertised mode is a
640-wide timing and its 320-wide half:

| output | frequency | serves |
|---|---|---|
| `outclk0` | **12.600 MHz** | 640x480i60, 640x240p60 |
| `outclk1` | **6.300 MHz** | 320x240p60 |

Duty cycle 50%, phase shift 0 ps on both.

These are power-on values only. Reconfiguration reaches the PAL pair (12.500
and 6.250 MHz) and the 31kHz diagnostic (25.200 MHz) at runtime.

### The setting that matters

**Enable dynamic reconfiguration** — on the *Settings* or *Dynamic
Reconfiguration* tab depending on release. Sometimes worded *Create a
reconfiguration interface* or *Enable reconfigurable PLL*.

Ticking it adds two ports:

```
input  wire [63:0] reconfig_to_pll,
output wire [63:0] reconfig_from_pll
```

**If those two ports are not in the generated file, reconfiguration is off** and
nothing downstream will work. That is the one thing to verify before moving on.

Leave *Enable dynamic phase shift* off; nothing here shifts phase.

---

## 2. Altera PLL Reconfig

**IP Catalog → Library → Basic Functions → Clocks; PLLs and Resets → PLL →
Altera PLL Reconfig.**

Name it `pll_reconfig` so it lands in `rtl/pll_reconfig/`.

| setting | value | why |
|---|---|---|
| Device family | Cyclone V | |
| Enable MIF streaming | **no** | counters are written directly, not streamed from a file |
| MIF file | leave blank | |
| Enable Avalon interface | **yes** | `sw/pll_reconfig.c` writes `mgmt_*` |

Generated ports:

```
mgmt_clk, mgmt_reset
mgmt_address[5:0], mgmt_write, mgmt_writedata[31:0]
mgmt_read, mgmt_readdata[31:0], mgmt_waitrequest
reconfig_to_pll[63:0], reconfig_from_pll[63:0]
```

---

## 3. Add both to the project

Each generates a `.qip`. Add them to `quartus/blitscrt.qsf`:

```
set_global_assignment -name QIP_FILE ../rtl/pll_pix/pll_pix.qip
set_global_assignment -name QIP_FILE ../rtl/pll_reconfig/pll_reconfig.qip
```

Then drop the inline `altera_pll` instantiation from `rtl/pll_modes.v` and
instantiate the generated `pll_pix` instead.

---

## 4. Wire them together

The two 64-bit buses connect directly, and the Avalon slave goes on the bridge
at `BLITSCRT_PLLRECFG_OFFSET`, which is 0x1000 from the design base.

```verilog
    wire [63:0] reconfig_to_pll, reconfig_from_pll;

    pll_pix u_pll (
        .refclk            (FPGA_CLK1_50),
        .rst               (~rst50_n),
        .outclk_0          (clk_full),          // 12.600 MHz at power-on
        .outclk_1          (clk_half),          //  6.300 MHz at power-on
        .locked            (pll_locked),
        .reconfig_to_pll   (reconfig_to_pll),
        .reconfig_from_pll (reconfig_from_pll)
    );

    pll_reconfig u_recfg (
        .mgmt_clk          (FPGA_CLK1_50),
        .mgmt_reset        (~rst50_n),
        .mgmt_address      (avs_address[5:0]),
        .mgmt_write        (avs_write  && avs_sel_pll),
        .mgmt_writedata    (avs_writedata),
        .mgmt_read         (avs_read   && avs_sel_pll),
        .mgmt_readdata     (avs_pll_readdata),
        .mgmt_waitrequest  (avs_pll_waitrequest),
        .reconfig_to_pll   (reconfig_to_pll),
        .reconfig_from_pll (reconfig_from_pll)
    );
```

`avs_sel_pll` is `address[13:12] == 2'b01`, the 0x1000 window.
`rtl/blitscrt_regs.v` already decodes 0x0000 and 0x2000 and leaves 0x1000 alone.

### Holding the pipeline

The pixel clock is unusable between the start write and lock returning. Extend
the `mode_hold` counter in `blitscrt_top.v` to cover it: assert on a write to
`BLITSCRT_REG_APPLY`, release when `locked` comes back. The mechanism is
already there for clock mux switches and wants the same treatment.

---

## 5. Verify

```
make check-ip
```

It reads the generated files and reports what it found: reconfiguration ports
present, output frequencies, integer mode, and the counter field width the
software encoding assumes.

Two things in `sw/pll_reconfig.h` are marked VERIFY and can only be settled
once the IP exists:

- **Register addresses.** The map there is the standard one, but IP options
  move things. A wrong address mis-clocks the video rather than failing.
- **Counter field width.** The encoding assumes eight-bit half-periods, capping
  any divide at 510. Some variants carry nine bits, lifting it to 1022.
  `PLL_CNT_FIELD_BITS` is the single place to change it, and `pll_cyclonev` in
  `sw/pll.c` has matching limits. `make test` re-checks the encoding across
  every divide afterwards.

---

## Frequency reference

The advertised modes and the counters `sw/pll.c` solves for them:

```
640x480i60   12.600 MHz   M=63  N=2   C=125     VCO 1575   NTSC pair
320x240p60    6.300 MHz   M=63  N=2   C=250     VCO 1575
640x576i50   12.500 MHz   M=16  N=1   C=64      VCO  800   PAL pair
320x288p50    6.250 MHz   M=16  N=1   C=128     VCO  800
640x480p60   25.200 MHz   M=126 N=5   C=50      VCO 1260   31kHz diagnostic
```

Within a VCO the 640-wide and 320-wide modes are one counter apart, so
switching between them is a C write. Switching between NTSC and PAL moves M and
N as well.
