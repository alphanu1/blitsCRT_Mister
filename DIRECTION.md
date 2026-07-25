# blitsCRT_Mister — project direction

## The decision (this is settled)

The stock MiSTer kernel cannot host GUD. Confirmed on hardware: `/sys/class/udc/`
does not exist, so there is no USB Device Controller — the board cannot be a USB
peripheral, and GUD requires the device side to be a USB peripheral. MiSTer runs
`dwc2` in host mode (for controllers/keyboards), not peripheral.

Therefore the project moves to its own **custom kernel** with:

1. `dwc2` in **peripheral** (or dual-role) mode, so a UDC exists.
2. **FunctionFS + configfs + libcomposite**, so the GUD gadget can be built from
   userspace.
3. A **transport layer** for control (register access) that actually works on
   this hardware — the stock gp path does not (see `GP_FINDINGS.md`).
4. Once the kernel owns the boot, the HPS↔FPGA bridges can be configured the way
   this design needs, rather than inheriting MiSTer's constraints.

GUD is the point of the whole project. Everything else serves getting a host PC
to see the board as a display and getting those pixels onto the analog CRT.

## Why the custom kernel unblocks more than USB

Two things were previously entangled and are now clarified:

- **USB peripheral** — only the custom kernel provides it. Non-negotiable for GUD.
- **The register transport** — on stock MiSTer we were forced onto MiSTer's gp
  protocol (io_clk/io_ss/io_din), which our bridge did not match, and the
  lightweight bridge is non-functional on MiSTer. Once we own u-boot and the HPS
  configuration under the custom kernel, we are no longer bound to MiSTer's gp
  protocol. We can bring up a clean HPS↔FPGA interface (AXI/Avalon via Platform
  Designer, or an f2sdram window) and define the register bus ourselves.

So the earlier "Option A: speak MiSTer's io protocol" is now correctly seen as
throwaway — we are not staying inside MiSTer's ecosystem for the datapath. We do
the transport once, cleanly, on our own boot chain.

## The three data paths (keep these separate)

GUD is not one pipe. It is three, with different requirements:

1. **USB gadget (host → HPS).** Present as a GUD device, receive framebuffer /
   damage data over USB. Needs: custom kernel (dwc2 peripheral, FunctionFS), the
   userspace daemon binding the gadget, an A-to-A cable with VBUS cut on the
   board side.
2. **Pixel datapath (HPS → fabric scanout).** The firehose. Received pixels must
   land in the fabric's scanout memory. This is wide and fast — f2sdram (HPS
   DDR3 shared window) or a large FIFO, NOT the gp port. This is essentially M3.
3. **Control (mode set, PLL, heartbeat, overlay).** Low bandwidth. Register
   reads/writes. This is the transport that is currently broken and must be
   redesigned on the custom boot chain.

Critically: paths 2 and 3 are independent of MiSTer's gp problem once we own the
HPS configuration. And path 1 (the actual GUD USB link) never touched gp at all.

## What already works and carries forward (do not rebuild)

- The whole fabric: video timing (15kHz confirmed on hardware), test card,
  overlay with the three-state boot banner, char_ram, PLL modes, register block.
- The daemon's structure: modes, PLL reconfig, heartbeat, overlay refresh,
  `--no-gadget` fabric-only mode, and the FULL gadget mode (gadget.c) already
  written for GUD over FunctionFS.
- The gadget kernel config fragment (`linux/blitscrt_gadget.config`): dwc2
  dual-role, FunctionFS, configfs, libcomposite — already written, already
  merged into the kernel build.
- The kernel BUILDS today: `make world` produces zImage + dtb with the MiSTer
  tree, cross-compiled, static daemon staged. What is missing is booting it.
- Build system: get-toolchain, kernel-clone, static ARM daemon, bitstream
  skip-when-current, all working.

## The next milestone: boot the custom kernel into GUD

Concrete work, roughly in order:

1. **Root filesystem.** The u-boot override sets a console but no `root=`, so a
   bare `bootz` panics. Choose one: point `root=` at MiSTer's existing rootfs on
   the card, or ship a small initramfs carrying just the daemon. Initramfs is
   cleaner for an appliance and avoids depending on MiSTer's userland.
2. **dr_mode = peripheral.** Set it explicitly in the device tree overlay so the
   UDC comes up as a device, not host. This is the thing whose absence we just
   confirmed (no /sys/class/udc).
3. **Init hook.** Something in the rootfs starts `gadget-setup.sh` then
   `blitscrtd` (full gadget mode, not --no-gadget) once Linux is up.
4. **/dev/mem open.** Keep CONFIG_STRICT_DEVMEM off (or add a UIO node) so the
   daemon can reach the fabric. MiSTer's kernel allowed it; a fresh config may
   not.
5. **The transport.** Bring up a working control path on the custom boot chain.
   Options: Platform Designer HPS component exposing a real lwh2f/h2f AXI master
   to an Avalon register slave (the clean way, now that we control the HPS), or
   an f2sdram mailbox. Decide alongside M3, since the pixel path wants f2sdram
   anyway — one DDR3 bring-up can serve both.
6. **The cable.** A-to-A with VBUS cut on the board side (MiSTer Pi has a Type-A
   host receptacle).

With those, the gadget config already in the kernel comes alive, the daemon binds
the UDC, and a host enumerates the board as a GUD display.

## What NOT to do (learned the hard way)

- Do not try to run GUD on the stock MiSTer kernel — no UDC, confirmed.
- Do not wire the lightweight bridge expecting MiSTer to route it — non-functional
  on MiSTer. (Under our own HPS config it may be fine; that is different.)
- Do not implement MiSTer's gp io_clk/io_ss protocol — throwaway once we leave
  MiSTer's boot chain.
- Do not drive gp_out[31:30] on MiSTer — those are core reset. The daemon's gp
  write path is disabled by default now (BLITSCRT_GP_UNSAFE to opt in).
- Do not build the kernel and the transport as two unproven things at once. Boot
  the kernel to a shell first (rootfs + console), THEN bring up the gadget, THEN
  the transport. One variable at a time.
