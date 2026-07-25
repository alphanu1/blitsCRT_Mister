# HPS<->fabric transport: findings from hardware (CORRECTED)

Status: the daemon runs on stock MiSTer Linux, reaches /dev/mem, bridges are out
of reset. But every register read returns the identical 0x23a40000 -- the
addressed-register model is not working over the gp path as implemented.

## Correction to an earlier wrong conclusion

An earlier version of this doc recommended pivoting to the lightweight HPS->FPGA
bridge (LWH2F) at 0xFF200000. That is now believed to be WRONG for MiSTer:

- A 2026 MiSTer project reports the HPS2FPGA lightweight bridge is "non-functional
  on MiSTer" and had to be abandoned; they used the f2sdram Avalon port instead.
- MiSTer's own documented mechanism for ARM<->fabric is NOT an AXI bridge at all.

Do not spend time wiring LWH2F. It is a likely dead end on this platform.

## How MiSTer actually does ARM <-> fabric (the real reference)

Per MiSTer developer docs (hps_io, emu, porting):

- Communication is the "parallel bus" HPS_BUS, handled by the hps_io module.
  It is 16-bit I/O, and transactions are SPI/SCSI-like -- a defined command/
  response protocol, NOT a flat memory-mapped register window.
- gp_out (HPS->fabric) and gp_in (fabric->HPS) are the physical wires. In
  sys_top.v gp_in is a live status word and gp_out's top bits are reset control.
  The actual data protocol on top is implemented by hps_io.sv on the FPGA side
  and Main_MiSTer on the ARM side.

So the gp channel IS the right transport -- but it carries a specific protocol,
not raw addressed reads. Our blitscrt_bridge invented its own strobe/address/
readback scheme over gp_out/gp_in. On hardware that scheme does not line up with
what actually drives gp_in, so reads return a fixed value.

## Why every register read the same 0x23a40000

The daemon's addressed reads are not reaching an addressable slave. gp_in on
hardware is driven by something other than our bridge's readback (our RTL forces
gp_in[30:16]=0, but hardware shows those bits set). The read is landing on a
fixed source, so id/ver/status all return the same value.

## Options for the real fix (to be evaluated, not yet chosen)

1. Adopt MiSTer's hps_io protocol directly. Instantiate hps_io.sv (or a faithful
   subset) on the fabric side and speak its protocol from the daemon on the ARM
   side. Heaviest, but it is the proven path and aligns with how every MiSTer
   core talks to the ARM. Requires understanding Main_MiSTer's side of the
   protocol -- the daemon would implement that, since we are not running
   Main_MiSTer.

2. Define our OWN minimal protocol over gp_out/gp_in that matches on both sides,
   end to end, verified in sim against the actual gp_in wiring. This is close to
   what blitscrt_bridge attempts, but it must be validated against how gp_in is
   really sampled/driven on MiSTer -- the current mismatch says our model of that
   is wrong. Needs the actual gp timing from MiSTer's hps_io as reference.

3. Use the f2sdram Avalon port (what the A2065 project fell back to) -- share the
   HPS DDR3 as a flat window and put a mailbox/registers there. Heavier RTL, but
   reported working on MiSTer where LWH2F was not. This also lines up with M3
   (scanout memory) which will need f2sdram anyway.

## Recommended direction

Option 3 (f2sdram shared window) is worth serious consideration because it is
(a) reported working on MiSTer where the bridges are not, and (b) on the path to
M3 scanout memory regardless. A register mailbox in a known DDR3 region, polled
by the fabric, may be simpler and more robust than matching MiSTer's gp protocol
bit-for-bit.

Whichever path: this is a transport-DESIGN task, validated on the stock-kernel +
/dev/mem rig (fast iteration). It does NOT need the custom kernel, and the custom
kernel would not fix it.

## What NOT to do

- Do not wire LWH2F (non-functional on MiSTer).
- Do not build the custom kernel to "fix" this -- transport is independent of the
  kernel; the daemon reads the same way on either.
- Do not keep tweaking the gp strobe handshake blindly; the mismatch is in how
  gp_in is driven vs. how the daemon expects it, which needs the real MiSTer
  hps_io timing as reference, not another guess.

## THE ACTUAL gp PROTOCOL (decoded from MiSTer sys_top.v + hps_io.sv)

This is the real bit layout of gp_out, straight from MiSTer's sys_top.v. It
explains why every read returned the same value: our bridge's bit assignments
collide with MiSTer's clock and chip-select bits.

gp_out (HPS -> fabric), as MiSTer's HPS firmware drives it:

    gp_out[15:0]   io_din   -- 16-bit data word from the ARM
    gp_out[17]     io_clk   -- the transfer clock; io_strobe = rising edge
    gp_out[18]     io_ss0   -- chip select 0
    gp_out[19]     io_ss1   -- chip select 1
    gp_out[20]     io_ss2   -- chip select 2
    gp_out[31:30]  reset control (resetd)

    Chip-select decode:
      io_fpga = ~io_ss1 &  io_ss0   -- normal core I/O
      io_uio  = ~io_ss1 &  io_ss2   -- user I/O (hps_ext / EXT_BUS)
      osd     =  io_ss1 & ~io_ss0   -- OSD

    gp_out is double-registered through clk_sys before use:
      gp_outd <= gp_out; gp_outr <= gp_outd;

gp_in (fabric -> HPS), as MiSTer assembles it:

    gp_in = {1'b0, btn_user|btn[1], btn_osd|btn[0], io_dig, 7'd0,
             ~HDMI_TX_INT, io_ver, io_ack, io_wide, io_dout[15:0]}

    gp_in[15:0]  io_dout -- 16-bit data word back to the ARM
    gp_in[16]    io_wide
    gp_in[17]    io_ack  -- transaction acknowledge
    gp_in[18]    io_ver
    ... status bits above ...

The transaction is byte/word-counted and SPI-like (hps_io.sv):
  on each io_strobe, byte_cnt increments; byte_cnt==0 latches the command word
  (cmd <= io_din), following strobes carry data. io_dout is driven per command.

## Why our bridge failed, precisely

blitscrt_bridge put strobe in gp_out[31], write in [30], address in [29:16].
But MiSTer's HPS firmware drives gp_out[17]=clk, [18:20]=chip-selects,
[31:30]=reset. So:
  - Our "address" bits (29:16) overlap MiSTer's ss/clk region -> garbage.
  - Our bit-31 "strobe" is MiSTer's reset control -> toggling it is dangerous.
  - The ARM never runs our protocol at all; gp_in is MiSTer's status word,
    which is why gp_in[30:16] was nonzero and every read was a fixed value.

## The correct fix, now concrete

To speak to the fabric over gp on MiSTer, the ARM side must drive gp_out using
MiSTer's io_clk/io_ss/io_din protocol, and the fabric must decode it the same
way hps_io.sv does. BUT: that protocol is normally driven by Main_MiSTer, which
we are NOT running (we run our own daemon). Two realistic paths:

  A. Have the daemon emulate MiSTer's HPS-side io protocol: bit-bang io_clk,
     io_ss, io_din through fpgamgr gpo, read io_dout/io_ack from gpi, and put a
     hps_io-compatible decoder (or the real hps_io.sv, uio branch) in the fabric.
     This is the "be a MiSTer core" approach. Heavy but proven.

  B. Abandon gp for data and use f2sdram (HPS DDR3 shared window) for the
     register mailbox and later scanout. gp is left alone (or only its reset
     bits respected). This sidesteps the whole io protocol and is on the M3 path.

Recommendation stands: evaluate B (f2sdram) first. It avoids reimplementing
MiSTer's HPS firmware protocol and aligns with scanout memory. The A2065 project
chose exactly this after the bridges failed.

## Immediate caution

Our current bridge TOGGLES gp_out[31], which on MiSTer is reset control
(resetd <= gp_out[31:30]). Writing it may be poking the core reset logic. The
daemon should NOT drive gp_out bits 30/31 on MiSTer until the protocol is
correct. This is a safety note for the next iteration.
