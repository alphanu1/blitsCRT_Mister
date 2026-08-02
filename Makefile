# Simulation and asset generation. Quartus is driven from quartus/blitscrt.qsf.

IV      := iverilog -g2012
# Framebuffer preload geometry. Must match SCANOUT_W/SCANOUT_H on blitscrt_top.
SCANOUT_GEOM ?= 320x480
SCANOUT_FMT  ?= rgb565

RTL     := rtl/video_timing.v rtl/testcard.v rtl/overlay.v \
           rtl/char_ram.v rtl/font_rom.v \
           rtl/scanout.v rtl/scanout_ram.v

.PHONY: dr-mode all world manifest assets sim render render-i render-scanout render-scanout-i clean distclean tools setup setup-dry get-toolchain kernel-clone daemon bitstream bitstream-force ddrbench quartus-path lint check-pins check-decl check-ip uboot-txt preview linux build kernel-check kernel-config initramfs

# iverilog and Pillow are for verification only. Neither is needed to build the
# bitstream -- Quartus consumes rtl/ and the generated .hex files, nothing else.
HAVE_IVERILOG := $(shell command -v iverilog 2>/dev/null)

# Vendor stubs and the generated IP, for lint.
#
# Quartus generates the PLL megafunctions and they are committed, because a
# bitstream build needs them. Lint must not try to elaborate them:
#
#   rtl/pll_pix.v is only a wrapper. Its guts are named by pll_pix.qip and are
#   not in rtl/*.v, so iverilog sees a module instantiating something that does
#   not exist:
#
#     rtl/pll_pix.v:18: error: Unknown module type: pll_pix_0002
#
#   rtl/pll_reconfig is a directory of IP reached through its own .qip, so
#   rtl/*.v never picks it up at all.
#
# So lint always excludes the generated wrappers and always uses the stubs.
# That is the right shape anyway: lint checks that *this project's* RTL
# elaborates, and the vendor IP is Quartus's business.
#
# Conditioning on whether the files exist was tried and is wrong -- the wrapper
# being present says nothing about whether the rest of the IP is reachable.
RTL_GENERATED := rtl/pll_pix.v rtl/pll_reconfig.v
LINT_RTL      := $(filter-out $(RTL_GENERATED),$(wildcard rtl/*.v))
VENDOR_STUBS  := sim/vendor_stubs.v sim/vendor_pll_stubs.v
HAVE_PILLOW   := $(shell python3 -c "import PIL" 2>/dev/null && echo yes)

define need_iverilog
	@if [ -z "$(HAVE_IVERILOG)" ]; then \
	  echo ""; \
	  echo "iverilog not found."; \
	  echo "  Arch     sudo pacman -S iverilog"; \
	  echo "  Debian   sudo apt install iverilog"; \
	  echo "  Fedora   sudo dnf install iverilog"; \
	  echo ""; \
	  exit 1; \
	fi
endef

all: assets
	@$(MAKE) --no-print-directory check-decl
	@if [ -n "$(HAVE_IVERILOG)" ]; then \
	  $(MAKE) --no-print-directory sim; \
	else \
	  echo ""; \
	  echo "Assets built. Skipping testbenches, iverilog not installed."; \
	  echo "Quartus needs nothing further -- go to docs/BRINGUP.md step 2."; \
	  echo ""; \
	  echo "To run the testbenches:  sudo pacman -S iverilog"; \
	fi

# ---------------------------------------------------------------------------
# Everything in one pass. Steps whose tool is missing are skipped rather than
# fatal, and the manifest at the end shows what actually got built.
# ---------------------------------------------------------------------------
world: assets
	@$(MAKE) --no-print-directory check-decl
	@$(MAKE) --no-print-directory check-pins
	@if [ -n "$(HAVE_IVERILOG)" ]; then $(MAKE) --no-print-directory sim; \
	  else echo "-- skipping testbenches, no iverilog"; fi
	@if [ -n "$(HAVE_IVERILOG)" ] && [ -n "$(HAVE_PILLOW)" ]; then \
	  $(MAKE) --no-print-directory render render-i; \
	  else echo "-- skipping renders, needs iverilog and Pillow"; fi
	@$(MAKE) --no-print-directory check-ip
	@if [ -n "$(QUARTUS_SH)" ]; then \
	  $(MAKE) --no-print-directory bitstream; \
	else \
	  echo "-- skipping bitstream, quartus_sh not found (try: make quartus-path)"; \
	fi
	@if [ -z "$(KERNEL_SRC)" ]; then \
	  echo "-- no kernel tree found, skipping the kernel image."; \
	  echo "   looked in: ~/source/linux-socfpga, ~/source/Linux-Kernel_MiSTer,"; \
	  echo "              ~/linux-socfpga, ~/Linux-Kernel_MiSTer, ../linux-socfpga"; \
	  echo "   point at yours with:  make world KERNEL_SRC=/path/to/kernel"; \
	  echo "   you also need an ARM cross-compiler; see 'The kernel' in the README."; \
	elif [ ! -d "$(KERNEL_SRC)" ]; then \
	  echo "-- skipping kernel, KERNEL_SRC=$(KERNEL_SRC) is not a directory"; \
	else \
	  echo "-- building kernel from $(KERNEL_SRC)"; \
	  $(MAKE) --no-print-directory linux KERNEL_SRC="$(KERNEL_SRC)" || { \
	    echo ""; \
	    echo "=============================================================="; \
	    echo "-- KERNEL BUILD FAILED"; \
	    echo "   Staging the rest anyway, but there will be no card image:"; \
	    echo "   an image needs the bitstream, the kernel and a bootloader."; \
	    echo "=============================================================="; \
	    echo ""; }; \
	fi
	@$(MAKE) --no-print-directory daemon CROSS_COMPILE="$(CROSS_COMPILE)" STATIC="$(STATIC)" || echo "-- daemon build skipped"
	@$(MAKE) --no-print-directory peek CROSS_COMPILE="$(CROSS_COMPILE)" STATIC="$(STATIC)" || echo "-- peek build skipped"
	@$(MAKE) --no-print-directory ddrbench CROSS_COMPILE="$(CROSS_COMPILE)" STATIC="$(STATIC)" || echo "-- ddrbench build skipped"
	@# The bootloader, and then a writable card image.
	@#
	@# Both are skipped rather than fatal: a partial toolchain should still
	@# give a partial build, which is what world is for. The image needs the
	@# bitstream and the kernel, so it only appears once those exist.
	@if [ -f "$(UBOOT_SFP)" ]; then \
	  echo "-- bootloader already built: $(UBOOT_SFP)"; \
	elif [ -n "$(UBOOT_TC_GCC)" ]; then \
	  echo "-- building the bootloader"; \
	  $(MAKE) --no-print-directory uboot || { \
	    echo ""; \
	    echo "=============================================================="; \
	    echo "-- BOOTLOADER BUILD FAILED -- see $(UBOOT_LOG)"; \
	    echo "   There will be no card image without it."; \
	    echo "=============================================================="; \
	    echo ""; }; \
	else \
	  echo "-- skipping the bootloader, no gcc 4/5/6 ARM toolchain"; \
	  echo "   (make uboot-toolchain installs one; without it there is no"; \
	  echo "    card image, though build/ is still usable by hand)"; \
	fi
	@$(MAKE) --no-print-directory build   # build is idempotent (cp -f); safe
	@$(MAKE) --no-print-directory stage-uboot
	@echo ""
	@./tools/check_card.sh $(BUILD_DIR) || \
	  echo "-- build/ is incomplete; no card image this time"
	@if [ -f "$(BUILD_DIR)/u-boot-with-spl.sfp" ] || [ -n "$(BOOT_A2)" ]; then \
	  if ./tools/check_card.sh $(BUILD_DIR) >/dev/null 2>&1; then \
	    echo ""; \
	    echo "-- writing the card image to $(IMAGE)"; \
	    $(MAKE) --no-print-directory image || \
	      echo "-- image build failed"; \
	  fi; \
	fi
	@$(MAKE) --no-print-directory manifest

# Every output this project can produce, and whether it is there.
MANIFEST := \
  rtl/font8x8.hex \
  rtl/banner.hex \
  rtl/banner_i.hex \
  rtl/scanout_init.hex \
  sim/tb_timing.vvp \
  sim/tb_i2c.vvp \
  sim/tb_render.vvp \
  sim/testcard_640x240p60.png \
  sim/testcard_640x240p60_x2.png \
  sim/testcard_640x480i60.png \
  sim/testcard_640x480i60_x2.png \
  sim/scanout_640x240p60.png \
  sim/scanout_640x480i60.png \
  quartus/output_files/blitscrt.rbf \
  quartus/output_files/blitscrt.txt \
  quartus/output_files/blitscrt.sof \
  quartus/output_files/blitscrt.fit.rpt \
  quartus/output_files/blitscrt.map.rpt \
  quartus/output_files/blitscrt.sta.rpt \
  build/blitscrt.rbf \
  build/blitscrt.txt \
  build/blitscrt/zImage \
  build/blitscrt/blitscrt.dtb \
  build/blitscrt/blitscrtd \
  build/blitscrt/blitscrt-peek \
  build/blitscrt/blitscrt-ddrbench \
  build/blitscrt/gadget-setup.sh

manifest:
	@echo ""
	@echo "OUTPUTS"
	@for f in $(MANIFEST); do \
	  if [ -f "$$f" ]; then \
	    printf "  %-44s %8s\n" "$$f" "$$(du -h "$$f" | cut -f1)"; \
	  else \
	    printf "  %-44s %8s\n" "$$f" "-"; \
	  fi; \
	done
	@echo ""
	@if [ -f quartus/output_files/blitscrt.rbf ]; then \
	  echo "  Bitstream ready. Next: make sd DEST=/path/to/mounted/card"; \
	else \
	  echo "  No bitstream yet. Run 'make bitstream', or 'make quartus-path' first."; \
	fi
	@if [ -f build/blitscrt/zImage ]; then \
	  echo "  Kernel image staged at build/blitscrt/zImage."; \
	else \
	  echo "  No kernel image. Needs a kernel tree AND an ARM cross-compiler:"; \
	  echo "    cross-compiler: $(if $(CROSS_COMPILE),found ($(CROSS_COMPILE)gcc),MISSING -- prebuilt toolchain, see 'The kernel' in the README)"; \
	  echo "    kernel tree:    $(if $(KERNEL_SRC),$(KERNEL_SRC),MISSING -- run 'make setup' to clone one, or set KERNEL_SRC=)"; \
	fi
	@echo ""

# Self-contained HTML preview of the README, with the photo, the runtime clip
# and the video inlined as data URIs. Opens anywhere, no server needed.
preview:
	@python3 -c "import markdown" 2>/dev/null || \
	  { echo "python-markdown not found:  sudo pacman -S python-markdown"; exit 1; }
	@python3 tools/preview_readme.py README_preview.html

# Verify every top-level port has a location assignment, and optionally
# cross-check the assignments against a MiSTer checkout:
#   make check-pins MISTER=/path/to/Template_MiSTer
check-pins:
	@python3 tools/check_pins.py $(MISTER)

# Report what is and is not available.
# Install the build dependencies (testbench and render toolchain, ARM
# cross-compiler, dtc, git) via the system package manager, and optionally clone
# a kernel tree. Does not install Quartus, which needs a manual licensed setup.
setup:
	./tools/setup-deps.sh

# Same, but only print what it would install.
setup-dry:
	./tools/setup-deps.sh --dry-run

# Download and extract a prebuilt ARM cross-compiler (Bootlin). Opt-in and
# separate from setup because it pulls a large binary from a third party.
# Both cross-compilers: a current one for the kernel and daemon, and an old one
# for MiSTer's u-boot, which does not survive a modern gcc.
get-toolchain:
	./tools/get-toolchain.sh
	@echo ""
	@$(MAKE) --no-print-directory uboot-toolchain

# Clone the MiSTer kernel tree, non-interactively, where the build auto-detects
# it. Use this instead of the setup prompt if you skipped it. The tree is large;
# --depth 1 keeps it to one revision. Override the destination with
# KERNEL_CLONE_DIR=.
KERNEL_CLONE_DIR ?= $(HOME)/source/Linux-Kernel_MiSTer
# ---------------------------------------------------------------------------
# u-boot, built from source rather than lifted off a MiSTer card.
#
# Mainline has socfpga_de10_nano_defconfig, and the MiSTer Pi clones the
# DE10-Nano's HPS wiring, so the same bootloader applies. The build produces
# u-boot-with-spl.sfp: the preloader and u-boot in one file, which is exactly
# what the A2 partition holds.
#
# Building it rather than copying one settles three things at once. There is no
# redistributing somebody else's binary. `make image` needs no manual extraction
# step. And the default environment is ours, compiled in from
# tools/uboot_env.txt -- so a freshly written card boots BlitsCRT with no serial
# console and no import, whether u-boot keeps its environment in flash or on the
# card.
#
# The risk worth knowing: the preloader carries DDR3 timings. Mainline's are the
# DE10-Nano's, and a clone board need not populate the same memory parts. If a
# card built this way does not boot, that is the first thing to suspect -- and
# the way back is a MiSTer card, since there is no JTAG on a MiSTer Pi.
# ---------------------------------------------------------------------------
# MiSTer's u-boot, built with the toolchain it needs.
#
# It carries the Platform Designer handoff rtl/mister/sysmem.sv expects, which
# mainline does not: mainline's FPGAPORTRST enables nine f2sdram ports where
# fourteen are needed, and a board built that way boots, shows its test card,
# takes whole frames into DDR3 and displays nothing, because the fabric's reads
# come back empty.
#
# It also needs gcc 4 or 5. See UBOOT_CROSS below -- built with a current
# compiler its SPL hangs at its own banner, which looks like a broken tree and
# is not.
#
# For mainline instead, which needs no old toolchain but does need the handoff
# headers copied in from uboot/de10-nano-qts:
#
#   make uboot UBOOT_REPO=https://github.com/u-boot/u-boot.git \
#              UBOOT_REF=v2024.01 UBOOT_CFG=socfpga_de10_nano_defconfig \
#              UBOOT_DIR=$(HOME)/src/u-boot-mainline
UBOOT_REPO  ?= https://github.com/MiSTer-devel/u-boot_MiSTer.git
# Empty means whatever the repository's default branch is called. MiSTer's is
# not `master`, and guessing the name is how a clone fails on someone else's
# machine for no useful reason. Set it to pin a tag or branch.
UBOOT_REF   ?=
UBOOT_CFG   ?= MiSTer_defconfig
UBOOT_DIR   ?= $(HOME)/src/u-boot_MiSTer
UBOOT_SFP   := $(UBOOT_DIR)/u-boot-with-spl.sfp
UBOOT_LOG   := build-tmp/uboot-build.log

# u-boot gets its own cross-compiler, separate from the kernel's.
#
# MiSTer's tree is u-boot 2017.03 and does not survive a modern gcc. Their wiki
# is explicit about it:
#
#   "Building a working u-boot image seems to requires an ARM cross-compilation
#    toolchain with GCC version 4 or 5. Warning: In my experience, using a later
#    version of GCC produces a u-boot image that is unable to reboot without a
#    power cycle."
#
#   -- Compiling-the-boot-loader-for-MiSTer
#
# The stock image ships built with gcc 4.8. Built here with a 2024 buildroot
# toolchain -- gcc 13 -- the SPL hangs at its own banner, before it even reaches
# "Trying to boot from MMC1". Nothing else in this project cares: the kernel and
# the daemon both build fine with a current compiler.
#
# `make uboot-toolchain` fetches Linaro 5.5-2017.10, which is what the wiki
# recommends. Set UBOOT_CROSS to something else to override.
# Bootlin's oldest armv7-eabihf build, which is gcc 5.4.0 -- inside the "gcc 4
# or 5" the wiki asks for, and from the same source as the toolchain the rest of
# this project uses.
#
# Not Linaro's, which the wiki names: releases.linaro.org now 301s every
# toolchain URL to a contact page, so those archives are simply gone.
UBOOT_TC_NAME ?= armv7-eabihf--glibc--stable-2017.05-toolchains-1-1
UBOOT_TC_URL  ?= https://toolchains.bootlin.com/downloads/releases/toolchains/armv7-eabihf/tarballs/$(UBOOT_TC_NAME).tar.bz2
UBOOT_TC_DIR  ?= $(HOME)/toolchains/$(UBOOT_TC_NAME)

# An ARM gcc old enough for this u-boot, if one is installed. See the script --
# neither the directory nor the binary prefix is predictable, so it asks each
# compiler its version rather than guessing.
UBOOT_TC_GCC := $(shell ./tools/find_uboot_gcc.sh)
UBOOT_CROSS   ?= $(if $(UBOOT_TC_GCC),$(UBOOT_TC_GCC:gcc=),$(CROSS_COMPILE))

.PHONY: uboot-clone uboot
uboot-clone:
	@if [ -f "$(UBOOT_DIR)/Makefile" ]; then \
	  echo "u-boot tree already at $(UBOOT_DIR)"; \
	else \
	  echo "cloning $(UBOOT_REPO)$(if $(UBOOT_REF), ($(UBOOT_REF)),) into $(UBOOT_DIR)..."; \
	  mkdir -p "$$(dirname $(UBOOT_DIR))"; \
	  git clone --quiet --depth 1 $(if $(UBOOT_REF),--branch $(UBOOT_REF),) \
	    $(UBOOT_REPO) "$(UBOOT_DIR)" && \
	  echo "done ($$(git -C "$(UBOOT_DIR)" rev-parse --abbrev-ref HEAD), \
	    $$(git -C "$(UBOOT_DIR)" rev-parse --short HEAD))."; \
	fi

.PHONY: uboot-toolchain
uboot-toolchain:
	@if [ -n "$(UBOOT_TC_GCC)" ]; then \
	  echo "u-boot toolchain already present:"; \
	  echo "  $(UBOOT_TC_GCC)"; \
	  "$(UBOOT_TC_GCC)" --version | head -1 | sed 's/^/  /'; \
	else \
	  mkdir -p "$(HOME)/toolchains" build-tmp; \
	  tb=build-tmp/$(UBOOT_TC_NAME).tar.bz2; \
	  for d in "$(HOME)/Downloads" "$(HOME)" .; do \
	    if [ -f "$$d/$(UBOOT_TC_NAME).tar.bz2" ]; then \
	      echo "using $$d/$(UBOOT_TC_NAME).tar.bz2"; \
	      cp "$$d/$(UBOOT_TC_NAME).tar.bz2" "$$tb"; break; \
	    fi; \
	  done; \
	  if [ ! -f "$$tb" ]; then \
	    echo "fetching $(UBOOT_TC_NAME) (gcc 5.4, ~100 MB)..."; \
	    echo "  $(UBOOT_TC_URL)"; \
	    curl -fL --progress-bar -o "$$tb" "$(UBOOT_TC_URL)" || { \
	      echo "download failed -- fetch it in a browser instead:"; \
	      echo "  $(UBOOT_TC_URL)"; \
	      echo "then drop it in ~/Downloads and run this again."; \
	      exit 1; }; \
	  fi; \
	  case "$$(file -b "$$tb" 2>/dev/null)" in \
	  bzip2*|XZ*) ;; \
	  *) echo ""; \
	     echo "Not an archive -- $$(head -c 60 "$$tb" | tr -d '\0' | tr '\n' ' ')"; \
	     echo ""; \
	     echo "The download came back as something else. Fetch it by hand:"; \
	     echo ""; \
	     echo "  $(UBOOT_TC_URL)"; \
	     echo ""; \
	     echo "then unpack it and point make at it:"; \
	     echo ""; \
	     echo "  tar xf $(UBOOT_TC_NAME).tar.bz2 -C $(HOME)/toolchains"; \
	     echo "  make uboot"; \
	     echo ""; \
	     echo "Any gcc 4 or 5 ARM toolchain will do -- override with"; \
	     echo "UBOOT_CROSS=/path/to/bin/arm-linux-gnueabihf- if you have one."; \
	     rm -f "$$tb"; exit 1 ;; \
	  esac; \
	  top=$$(tar tf "$$tb" | head -1 | cut -d/ -f1); \
	  tar xf "$$tb" -C "$(HOME)/toolchains" && rm -f "$$tb" && \
	  echo "installed to $(HOME)/toolchains/$$top" && \
	  "$(HOME)/toolchains/$$top"/bin/*-gcc --version 2>/dev/null | head -1; \
	fi

# Copy the bootloader into build/, which is committed.
#
# Separate from `uboot` on purpose. That target does nothing when the tree is
# already built, so a bootloader built before this staging existed never reached
# build/ -- and CI failed on a missing .sfp that was sitting on the machine that
# made it. This runs from `world` regardless of whether u-boot was rebuilt.
# Is build/ a complete card? The same list the release workflow checks.
.PHONY: check-card
check-card:
	@./tools/check_card.sh $(BUILD_DIR)

.PHONY: stage-uboot
stage-uboot:
	@sfp="$(if $(wildcard $(UBOOT_SFP)),$(UBOOT_SFP),$(firstword $(wildcard $(HOME)/src/u-boot*/u-boot-with-spl.sfp)))"; \
	if [ -n "$$sfp" ] && [ -f "$$sfp" ]; then \
	  mkdir -p $(BUILD_DIR); \
	  cp -f "$$sfp" $(BUILD_DIR)/u-boot-with-spl.sfp; \
	  echo "staged $(BUILD_DIR)/u-boot-with-spl.sfp ($$(du -h "$$sfp" | cut -f1))"; \
	elif [ -f $(BUILD_DIR)/u-boot-with-spl.sfp ]; then \
	  echo "using the committed $(BUILD_DIR)/u-boot-with-spl.sfp"; \
	else \
	  echo "-- no bootloader to stage; 'make uboot' builds one"; \
	fi

uboot: uboot-clone
	@mkdir -p build-tmp
	@# CROSS_COMPILE is empty when no ARM toolchain was found, and an empty
	@# prefix makes this test find the host gcc and pass. u-boot then builds
	@# x86 objects with ARM flags and fails a long way in, complaining about
	@# -mtune rather than about a missing compiler.
	@test -n "$(CROSS_COMPILE)" || { \
	  echo "no ARM cross-compiler found."; \
	  echo "  make get-toolchain    downloads one"; \
	  exit 1; }
	@# Through KPATH, the same as the kernel build: a toolchain fetched by
	@# `make get-toolchain` lives in $(HOME)/toolchains and is not on PATH,
	@# so a bare command -v would report it missing when the build below can
	@# use it perfectly well.
	@$(KPATH) command -v $(CROSS_COMPILE)gcc >/dev/null 2>&1 || { \
	  echo "$(CROSS_COMPILE)gcc is named but not runnable."; \
	  echo "if you used 'make get-toolchain', its bin/ should be auto-added;"; \
	  echo "otherwise add the toolchain's bin/ to PATH."; exit 1; }
	@echo "cross-compiler: $(UBOOT_CROSS)gcc"
	@$(KPATH) $(UBOOT_CROSS)gcc --version 2>/dev/null | head -1 | sed "s/^/                /"
	@# u-boot's Kconfig is generated, so it needs bison, flex and the ncurses
	@# headers on the build host -- none of which the rest of this project
	@# uses, and all of which fail deep inside a sub-make with no hint that a
	@# package is missing.
	@missing=""; \
	 for t in bison flex bc; do \
	   command -v $$t >/dev/null || missing="$$missing $$t"; \
	 done; \
	 if [ -n "$$missing" ]; then \
	   echo "u-boot needs these on the build host:$$missing"; \
	   echo "  arch:   sudo pacman -S --needed bison flex bc openssl"; \
	   echo "  debian: sudo apt install bison flex bc libssl-dev"; \
	   echo "  fedora: sudo dnf install bison flex bc openssl-devel"; \
	   exit 1; \
	 fi
	@# MiSTer's tree needs gcc 4 or 5. Refuse rather than build an SPL that
	@# hangs at its own banner, which is what a modern gcc produces and which
	@# looks like a broken source tree rather than a toolchain problem.
	@if [ "$(UBOOT_CFG)" = "MiSTer_defconfig" ]; then \
	  v=$$($(KPATH) $(UBOOT_CROSS)gcc -dumpversion 2>/dev/null | cut -d. -f1); \
	  case "$$v" in \
	  4|5|6) ;; \
	  "") echo "cannot run $(UBOOT_CROSS)gcc"; exit 1 ;; \
	  *) echo ""; \
	     echo "gcc $$v is too new for MiSTer's u-boot."; \
	     echo ""; \
	     echo "Their wiki asks for gcc 4 or 5. Built with anything much"; \
	     echo "newer the SPL hangs at its own banner, before it even prints"; \
	     echo "'Trying to boot from MMC1'."; \
	     echo ""; \
	     echo "    make uboot-toolchain"; \
	     echo ""; \
	     echo "installs gcc 5.4 to $(UBOOT_TC_DIR)"; \
	     echo "and make uboot picks it up automatically."; \
	     echo ""; \
	     echo "To build anyway:  make uboot UBOOT_CROSS=$(UBOOT_CROSS)"; \
	     echo "                              UBOOT_FORCE_GCC=1"; \
	     echo ""; \
	     test -n "$(UBOOT_FORCE_GCC)" || exit 1 ;; \
	  esac; \
	fi
	@# mrproper first, every time.
	@#
	@# Objects do not rebuild when the compiler changes -- make only sees
	@# timestamps -- so switching from a modern gcc to the old one this tree
	@# needs leaves the previous build in place and produces the same broken
	@# SPL. That looked like the toolchain having no effect, and cost a round
	@# of debugging.
	@#
	@# Cheap enough: the whole build is a couple of minutes.
	@echo "cleaning $(UBOOT_DIR)..."
	@$(KPATH) $(MAKE) -C $(UBOOT_DIR) mrproper >/dev/null 2>&1 || true
	@echo "configuring u-boot ($(UBOOT_CFG))..."
	@$(KPATH) $(MAKE) -C $(UBOOT_DIR) ARCH=arm CROSS_COMPILE=$(UBOOT_CROSS) \
	  $(UBOOT_CFG) >/dev/null 2>&1
	@echo "baking in the boot command from tools/uboot_env.txt..."
	@./tools/uboot_config.sh "$(UBOOT_DIR)" tools/uboot_env.txt
	@# A 2018 tree meeting a 2024 dtc: its version check cannot parse a
	@# leading "v" and stops the build at checkdtc.
	@./tools/uboot_fix_dtc.sh "$(UBOOT_DIR)" >/dev/null
	@# The host tools search u-boot's own headers *after* the system ones, on
	@# the 2018 assumption that a build host has no libfdt of its own.
	@python3 ./tools/uboot_fix_libfdt.py "$(UBOOT_DIR)" >/dev/null
	@# The preloader's hardware handoff. Mainline ships the stock DE10-Nano's,
	@# which enables nine f2sdram ports where sysmem_lite needs fourteen --
	@# a board that boots and shows its test card and never displays a host's
	@# frames, because the fabric's reads come back empty.
	@if [ -d "$(UBOOT_DIR)/board/terasic/de10-nano/qts" ]; then \
	  python3 ./tools/uboot_fix_handoff.py "$(UBOOT_DIR)"; \
	fi
	@# To a log, not the console.
	@#
	@# A 2018 tree on a modern host produces thousands of lines of warnings
	@# and, when it fails, thousands more of errors -- and the one line that
	@# says what actually went wrong is somewhere in the middle. The log keeps
	@# everything; the console gets the tail and a pointer.
	@echo "building u-boot (log: $(UBOOT_LOG))..."
	@$(KPATH) $(MAKE) -C $(UBOOT_DIR) ARCH=arm CROSS_COMPILE=$(UBOOT_CROSS) \
	  $(if $(UBOOT_HOSTCFLAGS),HOSTCFLAGS="$(UBOOT_HOSTCFLAGS)",) \
	  -j$$(nproc) > $(UBOOT_LOG) 2>&1 || { \
	    echo ""; \
	    echo "u-boot build failed. Last errors:"; \
	    echo ""; \
	    grep -E '^[^ ]+:[0-9]+:[0-9]+: error:|Error [0-9]+' $(UBOOT_LOG) \
	      | head -8 | sed 's/^/  /'; \
	    echo ""; \
	    echo "  full log: $(UBOOT_LOG) ($$(wc -l < $(UBOOT_LOG)) lines)"; \
	    echo ""; \
	    if grep -q 'redefinition of .fdt_' $(UBOOT_LOG); then \
	      echo "  This one is the host's libfdt headers colliding with"; \
	      echo "  u-boot's own -- see 'System libfdt' in docs/UBOOT.md."; \
	      echo ""; \
	    fi; \
	    exit 1; }
	@test -f $(UBOOT_SFP) || { echo "u-boot did not produce $(UBOOT_SFP)"; exit 1; }
	@# Into build/ as well, which is committed.
	@#
	@# build/ is the whole card: bitstream, kernel, device tree, daemon,
	@# tools -- and now the bootloader. Committing it means a release needs
	@# nothing but `make image`, and CI needs no toolchain, no kernel tree and
	@# no u-boot build. It also means a tagged release can be turned back into
	@# the exact card it shipped.
	@mkdir -p $(BUILD_DIR)
	@cp -f $(UBOOT_SFP) $(BUILD_DIR)/u-boot-with-spl.sfp
	@echo "built $(UBOOT_SFP) ($$(du -h $(UBOOT_SFP) | cut -f1))"
	@echo "'make image' will use it; no MiSTer card needed."

kernel-clone:
	@if [ -f "$(KERNEL_CLONE_DIR)/Makefile" ]; then \
	  echo "kernel tree already at $(KERNEL_CLONE_DIR)"; \
	else \
	  echo "cloning MiSTer kernel into $(KERNEL_CLONE_DIR) (large, one revision)..."; \
	  mkdir -p "$$(dirname $(KERNEL_CLONE_DIR))"; \
	  git clone --depth 1 \
	    https://github.com/MiSTer-devel/Linux-Kernel_MiSTer.git \
	    "$(KERNEL_CLONE_DIR)" && \
	  echo "done. 'make world' will auto-detect it."; \
	fi

tools:
	@echo "python3    $$(python3 --version 2>&1)"
	@echo "iverilog   $${IV:-$(if $(HAVE_IVERILOG),$(HAVE_IVERILOG),NOT FOUND -- testbenches unavailable)}"
	@echo "Pillow     $(if $(HAVE_PILLOW),present,NOT FOUND -- make render unavailable)"
	@echo "quartus_sh $$(command -v quartus_sh || echo 'NOT FOUND -- cannot build the bitstream')"
	@echo "cross-gcc  $(if $(CROSS_COMPILE),$(CROSS_COMPILE)gcc,NOT FOUND -- cannot build the kernel)"
	@echo "dtc        $$(command -v dtc || echo 'NOT FOUND -- kernel device tree')"
	@echo "kerneltree $(if $(KERNEL_SRC),$(KERNEL_SRC),NOT FOUND -- set KERNEL_SRC or run make setup)"
	@echo "bison      $$(command -v bison || echo 'NOT FOUND -- make uboot')"
	@echo "flex       $$(command -v flex  || echo 'NOT FOUND -- make uboot')"
	@echo "bc         $$(command -v bc    || echo 'NOT FOUND -- make uboot')"
	@echo "mtools     $$(command -v mcopy || echo 'NOT FOUND -- make image')"
	@echo "mkfs.vfat  $$(command -v mkfs.vfat || echo 'NOT FOUND -- make image')"
	@echo "sfdisk     $$(command -v sfdisk || echo 'NOT FOUND -- make image')"
	@echo "u-boot gcc $(if $(UBOOT_TC_GCC),$(UBOOT_TC_GCC),NOT FOUND -- make uboot-toolchain)"
	@echo "u-boot     $(if $(wildcard $(UBOOT_SFP)),$(UBOOT_SFP),not built -- run make uboot)"

# Proper dependencies so 'make all' does not regenerate these for every
# downstream target.
assets: rtl/font8x8.hex rtl/banner.hex rtl/scanout_init.hex

rtl/font8x8.hex: tools/gen_font.py
	python3 tools/gen_font.py $@

# One image, three banks. The overlay indexes the bank with the live mode.
# The framebuffer preload. M3a has no write path, so the buffer comes up holding
# this; it exists to be told apart from the test card at a glance. Geometry must
# match SCANOUT_W/SCANOUT_H on blitscrt_top.
rtl/scanout_init.hex: tools/gen_scanout_test.py
	python3 tools/gen_scanout_test.py $@ $(SCANOUT_GEOM) $(SCANOUT_FMT)

rtl/banner.hex: tools/gen_banner.py
	python3 tools/gen_banner.py $@

sim: assets
	$(need_iverilog)
	$(IV) -o sim/tb_timing.vvp sim/tb_timing.v rtl/video_timing.v
	cd rtl && vvp ../sim/tb_timing.vvp
	$(IV) -o sim/tb_i2c.vvp sim/tb_i2c.v rtl/adv7513_init.v rtl/i2c_master.v
	vvp sim/tb_i2c.vvp
	$(IV) -o sim/tb_mcp23009.vvp sim/tb_mcp23009.v rtl/mcp23009.v rtl/i2c_master.v
	vvp sim/tb_mcp23009.vvp
	$(IV) -o sim/tb_modes.vvp sim/tb_modes.v rtl/video_timing.v rtl/mode_table.v
	vvp sim/tb_modes.vvp
	$(IV) -o sim/tb_csync.vvp sim/tb_csync.v rtl/video_timing.v
	vvp sim/tb_csync.vvp
	$(IV) -o sim/tb_regs.vvp sim/tb_regs.v rtl/blitscrt_regs.v
	vvp sim/tb_regs.vvp
	$(IV) -o sim/tb_bridge.vvp sim/tb_bridge.v rtl/blitscrt_bridge.v
	vvp sim/tb_bridge.vvp
	$(IV) -o sim/tb_scanout.vvp sim/tb_scanout.v rtl/scanout.v rtl/scanout_ram.v rtl/video_timing.v
	vvp sim/tb_scanout.vvp
	$(IV) -o sim/tb_scanout_write.vvp sim/tb_scanout_write.v rtl/blitscrt_regs.v \
	      rtl/scanout_ram.v rtl/scanout.v rtl/video_timing.v
	vvp sim/tb_scanout_write.vvp
	$(IV) -o sim/tb_scanout_fetch.vvp sim/tb_scanout_fetch.v rtl/scanout_fetch.v
	vvp sim/tb_scanout_fetch.vvp
	$(IV) -o sim/tb_pll_reconfig.vvp sim/tb_pll_reconfig.v rtl/blitscrt_bridge.v \
	      rtl/blitscrt_pllbus.v sim/ip/*.v 2>/dev/null
	vvp sim/tb_pll_reconfig.vvp

# Elaborate the real top level with stand-ins for the Quartus primitives.
.PHONY: lint
# Verify the generated PLL megafunctions carry the settings the design needs.
# Reads what came out rather than trusting what was ticked, since GUI labels
# move between Quartus releases. See docs/MEGAFUNCTIONS.md.
# Reads the Quartus reports for things it says but does not fail on.
check-fit:
	@python3 tools/check_fit.py quartus/output_files

check-ip:
	@python3 tools/check_ip.py

# Icarus builds disagree about use before declaration; mine accepts it and
# others reject it outright. Quartus never complains, so this only surfaces on
# somebody else's machine. Checked here instead.
check-decl:
	@python3 tools/check_decl_order.py rtl/*.v sim/*.v

# Both memory sources elaborate. The DDR3 configuration has no Platform Designer
# system behind it yet, so this is what catches a break in it before the Quartus
# work lands rather than after.
# The two altclkctrl slot constants must agree. A divergence here has no
# simulation symptom at all -- it shows up as a monitor refusing to sync.
check-clk:
	@python3 tools/check_clk_sel.py

lint: check-decl check-clk
	$(need_iverilog)
	$(IV) -o /dev/null -s lint_onchip $(LINT_RTL) $(VENDOR_STUBS) sim/lint_onchip.v && echo "top elaborates clean (ONCHIP)"
	$(IV) -o /dev/null -s lint_ddr3 $(LINT_RTL) $(VENDOR_STUBS) sim/lint_ddr3.v && echo "top elaborates clean (DDR3, stubbed f2sdram)"

render: assets
	$(need_iverilog)
	@python3 -c "import PIL" 2>/dev/null || \
	  { echo "Pillow not found:  sudo pacman -S python-pillow"; exit 1; }
	$(IV) -DRENDER_TXT='"render_p60.txt"' -o sim/tb_render.vvp sim/tb_render.v $(RTL)
	cd rtl && vvp ../sim/tb_render.vvp
	python3 tools/render_png.py 640x240p60 testcard rtl/render_p60.txt

render-i: assets
	$(need_iverilog)
	@python3 -c "import PIL" 2>/dev/null || \
	  { echo "Pillow not found:  sudo pacman -S python-pillow"; exit 1; }
	$(IV) -DRENDER_INTERLACED -DRENDER_TXT='"render_i60.txt"' -o sim/tb_render_i.vvp sim/tb_render.v $(RTL)
	cd rtl && vvp ../sim/tb_render_i.vvp
	python3 tools/render_png.py 640x480i60 testcard rtl/render_i60.txt

# Same pipeline, framebuffer instead of the test card. Proves the scanout path
# through the real overlay rather than a mock-up.
render-scanout: assets
	$(need_iverilog)
	@python3 -c "import PIL" 2>/dev/null || \
	  { echo "Pillow not found:  sudo pacman -S python-pillow"; exit 1; }
	$(IV) -DRENDER_SCANOUT -DRENDER_TXT='"render_sc.txt"' -o sim/tb_render_scanout.vvp sim/tb_render.v $(RTL)
	cd rtl && vvp ../sim/tb_render_scanout.vvp
	python3 tools/render_png.py 640x240p60 scanout rtl/render_sc.txt

# 480i out of scanout memory. This is the one that shows whether the interlace is
# real: both fields are captured and woven, so the single-row comb resolves as
# fine lines. Line-doubled memory would show it as two-line bars.
render-scanout-i: assets
	$(need_iverilog)
	@python3 -c "import PIL" 2>/dev/null || \
	  { echo "Pillow not found:  sudo pacman -S python-pillow"; exit 1; }
	$(IV) -DRENDER_SCANOUT -DRENDER_INTERLACED -DRENDER_TXT='"render_sc_i.txt"' -o sim/tb_render_scanout_i.vvp sim/tb_render.v $(RTL)
	cd rtl && vvp ../sim/tb_render_scanout_i.vvp
	python3 tools/render_png.py 640x480i60 scanout rtl/render_sc_i.txt

# Remove transient build products. Every rm uses -f / -rf, so a missing file is
# never an error -- clean works whether or not a full build ran. The tracked
# sim/*.png renders are left alone; the README embeds them.
#
# $(BUILD_DIR) goes, even though it is committed. `make world` restages every
# file in it unconditionally, so clean-then-world is the way to be certain the
# committed card matches what was just built rather than carrying something
# stale from an earlier one.
clean:
	rm -f  sim/*.vvp sim/*.vcd sim/*.fst sim/*.lxt
	rm -f  rtl/render_*.txt $(UBOOT_TXT) README_preview.html
	rm -f  sw/*.o sw/blitscrtd sw/test_pll sw/test_pll_reconfig sw/test_modes sw/test_device
	rm -rf $(BUILD_DIR) $(WORK_DIR)
	rm -rf __pycache__ tools/__pycache__ sw/__pycache__
	find . -name '*.pyc' -delete 2>/dev/null || true

# Also remove generated assets and the Quartus output. Leaves only tracked
# sources.
distclean: clean
	rm -f  rtl/font8x8.hex rtl/banner.hex rtl/banner_i.hex rtl/scanout_init.hex
	rm -rf quartus/output_files quartus/db quartus/incremental_db
	rm -rf quartus/greybox_tmp quartus/.qsys_edit quartus/hps_isw_handoff

# ---------------------------------------------------------------------------
# Bitstream. Quartus rarely ends up on PATH after an install, so look in the
# usual places before giving up.
# ---------------------------------------------------------------------------
# No version is pinned. Any Quartus that carries Cyclone V device support will
# build this; nothing here depends on a particular release. With several
# installed, take the newest -- sort -V so 24.1std beats 17.0, which a plain
# alphabetic sort gets backwards.
#
# Override with:  make bitstream QUARTUS_SH=/path/to/quartus_sh
QUARTUS_SH ?= $(shell command -v quartus_sh 2>/dev/null || \
  ls -1 /opt/intelFPGA_lite/*/quartus/bin/quartus_sh \
        /opt/intelFPGA/*/quartus/bin/quartus_sh \
        /opt/altera/*/quartus/bin/quartus_sh \
        $(HOME)/intelFPGA_lite/*/quartus/bin/quartus_sh \
        $(HOME)/intelFPGA/*/quartus/bin/quartus_sh \
        $(HOME)/altera/*/quartus/bin/quartus_sh 2>/dev/null | sort -V -r | head -1)

# ---------------------------------------------------------------------------
# Version, for a release workflow to read.
#
#   make version       0.8.10          the project version, same as cat VERSION
#   make fullversion   0.8.10-d42      with the daemon build appended
#   make versions      every number, one per line, name=value
#
# -s suppresses make's own output, so these are safe to capture:
#
#   VER=$(make -s fullversion)
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# A complete SD card image, ready for dd or Etcher.
#
#   make image BOOT_A2=boot.a2
#
# BOOT_A2 is the card's A2 partition -- the preloader and u-boot -- which cannot
# be generated here. Cyclone V's BootROM looks for a raw partition of that type,
# and the preloader carries DDR3 timings from a Platform Designer handoff that
# MiSTer's is known to get right on this hardware. Extract it once from any
# MiSTer card or image and keep the blob:
#
#   tools/make_image.sh --extract-boot /dev/sdX boot.a2
#
# Everything else is built fresh. No root: the FAT filesystem is written with
# mtools rather than by loop-mounting, so this runs in CI unchanged.
# ---------------------------------------------------------------------------
IMAGE     ?= blitscrt-$(BLITSCRT_FULLVER).img
IMAGE_MB  ?= 256
IMAGE_STAGE := build-tmp/image

.PHONY: image
# No `build` prerequisite, deliberately.
#
# build/ is committed and is the card. Rebuilding it here re-runs the daemon
# compile, and on a machine with no cross-compiler that quietly produces an
# x86-64 binary and stages it over the committed ARM one -- which is exactly
# what happened in CI. `make world` is what fills build/; this only wraps it.
image:
	@# Which bootloader, said loudly.
	@#
	@# UBOOT_DIR is only in effect for the command it is given to, so
	@# `make uboot UBOOT_DIR=...` followed by a bare `make image` silently
	@# picks up whatever is in the default directory instead. That has
	@# happened, and produced a card with a bootloader nobody meant to use.
	@if [ -n "$(BOOT_A2)" ]; then \
	  echo "bootloader: $(BOOT_A2)  (BOOT_A2)"; \
	elif [ ! -f "$(UBOOT_SFP)" ] && [ -f "$(BUILD_DIR)/u-boot-with-spl.sfp" ]; then \
	  echo "bootloader: $(BUILD_DIR)/u-boot-with-spl.sfp  (committed)"; \
	elif [ -f "$(UBOOT_SFP)" ]; then \
	  echo "bootloader: $(UBOOT_SFP)"; \
	  echo "            (from UBOOT_DIR=$(UBOOT_DIR) -- pass UBOOT_DIR or"; \
	  echo "             BOOT_A2 if that is not the one you just built)"; \
	fi
	@test -n "$(BOOT_A2)" -o -f "$(UBOOT_SFP)" -o -f "$(BUILD_DIR)/u-boot-with-spl.sfp" || { \
	  echo ""; \
	  echo "An image needs a bootloader for the A2 partition, and there is"; \
	  echo "none yet. Lift one off a MiSTer card:"; \
	  echo ""; \
	  echo "    tools/make_image.sh --extract-boot /dev/sdX boot.a2"; \
	  echo "    make image BOOT_A2=boot.a2"; \
	  echo ""; \
	  echo "Once, and the blob is reusable. MiSTer's preloader is known to work"; \
	  echo "on this hardware, and if the card already boots BlitsCRT the boot"; \
	  echo "environment comes with it."; \
	  echo ""; \
	  echo "'make uboot' builds one from source instead, which needs no MiSTer"; \
	  echo "card -- but it does not currently complete on a host with a"; \
	  echo "distribution's libfdt headers installed. See docs/UBOOT.md."; \
	  echo ""; \
	  echo "Looked for a built one at $(UBOOT_SFP)"; \
	  echo ""; \
	  exit 1; }
	@./tools/check_card.sh $(BUILD_DIR) || exit 1
	@rm -rf $(IMAGE_STAGE)
	@mkdir -p $(IMAGE_STAGE)
	@# Straight from build/, not by re-staging from sources.
	@#
	@# The bootloader is excluded: it goes into the A2 partition as raw
	@# sectors, not onto the FAT filesystem.
	@cd $(BUILD_DIR) && find . -type f ! -name 'u-boot-with-spl.sfp' \
	  -exec install -D {} $(CURDIR)/$(IMAGE_STAGE)/{} \;
	@cp tools/blitsenv.txt $(IMAGE_STAGE)/
	@BOOT_A2="$(if $(BOOT_A2),$(BOOT_A2),$(if $(wildcard $(UBOOT_SFP)),$(UBOOT_SFP),$(BUILD_DIR)/u-boot-with-spl.sfp))" \
	  OUT="$(IMAGE)" STAGE="$(IMAGE_STAGE)" \
	  FAT_MB="$(IMAGE_MB)" ./tools/make_image.sh

.PHONY: version fullversion versions
version:
	@echo $(BLITSCRT_VERSION)

fullversion:
	@echo $(BLITSCRT_FULLVER)

versions:
	@echo "version=$(BLITSCRT_VERSION)"
	@echo "daemon=$(BLITSCRTD_BUILD)"
	@echo "kernel=$(BLITSCRT_KREV)"
	@echo "full=$(BLITSCRT_FULLVER)"
	@echo "fabric=$$(python3 tools/fabric_version.py)"
	@echo "localversion=-$(BLITSCRT_NAME)-$(BLITSCRT_FULLVER)-$(BLITSCRT_KREV)"

quartus-path:
	@if [ -n "$(QUARTUS_SH)" ]; then \
	  echo "found  $(QUARTUS_SH)"; \
	  echo "       $$($(QUARTUS_SH) --version 2>/dev/null | grep -i version | head -1)"; \
	  n=$$(ls -1 /opt/intelFPGA_lite/*/quartus/bin/quartus_sh \
	            /opt/intelFPGA/*/quartus/bin/quartus_sh \
	            /opt/altera/*/quartus/bin/quartus_sh \
	            $(HOME)/intelFPGA_lite/*/quartus/bin/quartus_sh \
	            $(HOME)/intelFPGA/*/quartus/bin/quartus_sh \
	            $(HOME)/altera/*/quartus/bin/quartus_sh 2>/dev/null | wc -l); \
	  if [ "$$n" -gt 1 ]; then \
	    echo ""; \
	    echo "  $$n installs found, newest picked. To force one:"; \
	    echo "    make bitstream QUARTUS_SH=/path/to/quartus_sh"; \
	  fi; \
	  echo ""; \
	  echo "To put it on PATH for this shell:"; \
	  echo "  export PATH=\$$PATH:$$(dirname $(QUARTUS_SH))"; \
	  echo ""; \
	  echo "To make it permanent:"; \
	  echo "  echo 'export PATH=\$$PATH:$$(dirname $(QUARTUS_SH))' >> ~/.bashrc"; \
	else \
	  echo "quartus_sh not found in PATH or the usual install roots."; \
	  echo "Locate it with:  find / -name quartus_sh -type f 2>/dev/null"; \
	  echo "Then:            export PATH=\$$PATH:/path/to/quartus/bin"; \
	fi

UBOOT_TXT := quartus/output_files/blitscrt.txt
RBF       := quartus/output_files/blitscrt.rbf

# The override either halts after loading the FPGA (M1 fabric-only) or boots the
# kernel (M2 onward). Pick the kernel form automatically once a zImage has been
# staged, so a full build produces a bootable card. Force either way with
# BOOT_LINUX=1 or BOOT_LINUX=0.
BOOT_LINUX ?= $(shell [ -f build/blitscrt/zImage ] && echo 1 || echo 0)
UBOOT_FLAG := $(if $(filter 1,$(BOOT_LINUX)),--linux,)

# Where a bootable set is staged. Everything the board needs at power-on lands
# here so it can be copied to an SD card in one step.
STATIC ?= 1   # daemon: static by default, it runs on the board
BUILD_DIR ?= build

# Build intermediates that must NOT land on the card: the busybox clone and the
# initramfs staging (both are folded into the kernel image, not copied). Kept out
# of BUILD_DIR so 'build/' holds only files that go on the card.
WORK_DIR := $(BUILD_DIR)-tmp

# Kernel build. KERNEL_SRC points at a configured kernel tree; the image and
# device tree are built there and copied into BUILD_DIR. Left unset, the linux
# target explains what to set rather than failing cryptically.
# Auto-detected like QUARTUS_SH: if a configured kernel tree sits in one of the
# usual places, plain `make` / `make world` builds it with no flag. A tree
# counts only if it has a top-level Makefile (so an empty dir is not picked).
# Override with:  make world KERNEL_SRC=/path/to/linux-socfpga
KERNEL_SRC ?= $(shell for d in \
    $(HOME)/source/linux-socfpga $(HOME)/source/Linux-Kernel_MiSTer \
    $(HOME)/source/Linux-Kernel_MiSTer-master $(HOME)/source/linux \
    $(HOME)/linux-socfpga $(HOME)/Linux-Kernel_MiSTer \
    $(HOME)/Linux-Kernel_MiSTer-master \
    ../linux-socfpga ../Linux-Kernel_MiSTer; do \
      [ -f "$$d/Makefile" ] && { echo "$$d"; break; }; \
    done 2>/dev/null)
# Kernel files stage into build/blitscrt/, mirroring the card layout the u-boot
# override loads: /blitscrt/zImage and /blitscrt/blitscrt.dtb.
CARD_SUB     := $(BUILD_DIR)/blitscrt
KERNEL_IMAGE := $(CARD_SUB)/zImage
KERNEL_DTB   := $(CARD_SUB)/blitscrt.dtb

# The product name and version.
#
# The version lives in the VERSION file rather than here, so a release workflow
# can read it without parsing a Makefile:
#
#   version:  $(cat VERSION)          -- or  make version
#   full:     $(make -s fullversion)  -- with the daemon build appended
#
# Both brand the kernel through LOCALVERSION, so uname -r and dmesg carry them,
# and both are compiled into the initramfs init, which stamps them into the boot
# log. Override on the command line if needed:
#
#   make world BLITSCRT_VERSION=0.9.0
BLITSCRT_NAME    ?= BlitsCRT
BLITSCRT_VERSION ?= $(shell cat VERSION 2>/dev/null || echo 0.0.0)

# The daemon build tag, read from sw/Makefile so there is one source of truth for
# it. It is appended to the project version because the daemon is embedded in the
# initramfs: a daemon change rebuilds the kernel image, so an image that says
# 0.8.10-d42 really does carry d42 and nothing else.
BLITSCRTD_BUILD  ?= $(shell sed -n 's/^BLITSCRTD_BUILD *?*= *//p' sw/Makefile | head -1)
BLITSCRT_FULLVER  = $(BLITSCRT_VERSION)-$(BLITSCRTD_BUILD)

# Kernel image revision, separate from the project version and bumped whenever
# anything baked into the zImage changes -- the config fragments or the
# initramfs init. It rides in LOCALVERSION, so `uname -r` on the board says
# exactly which image is running.
#
# Without it every build produced 5.15.1-BlitsCRT-0.10 and there was no way to
# tell a new kernel from the one already on the card. That is the same fault as
# a fabric that does not bump its VERSION register: a fix that does not reach the
# hardware looks identical to a fix that did not work.
#
#   k1  first custom kernel: exFAT, embedded initramfs, serial console
#   k2  dr_mode patched to peripheral; g_ffs off so configfs can own FunctionFS;
#       init stages the gadget and reports why when it cannot
#   k3  init execs busybox by path for gadget-setup.sh -- there is no /bin/sh in
#       the initramfs, so k2 failed the exec silently and logged nothing
#   k4  the shell gets a controlling terminal, and the console is quietened to
#       loglevel=4: kernel messages were drowning it just when it was needed
#   k5  BLITSCRT_TRACE on by default, so the log says which control request the
#       host stopped at rather than going silent after "host attached"
#   k6  revert k4's controlling-terminal change, which broke shell input;
#       blitscrt.nogadget on the command line skips gadget staging
#   k7  gadget FIFO sizes in the device tree. Without them dwc2 leaves the bulk
#       endpoint enabled with no usable FIFO, so it NAKs forever: control works,
#       enumeration works, and bulk silently never moves
#   k8  a TX FIFO size for every endpoint the core has, not just the used ones --
#       dwc2 rejects a short list outright, leaving the sizes unapplied
#   k9  set_dr_mode.py replaces existing FIFO properties instead of skipping
#       them; a dtb patched by an earlier version kept its stale values while
#       the run reported success
#   k10 the trace is no longer forced on -- it costs more than it tells once
#       frames are flowing. LZ4 is the daemon's own default, not set here
#   k11 init creates /tmp -- scripts assume it and its absence surfaces as an
#       unrelated-looking failure halfway through something else
#   k12 the gadget RX FIFO raised from 2 KB to 16 KB. Four packets of buffering
#       throttled the bulk endpoint to 21.5 MB/s against 35-40 available, with no
#       error anywhere -- just NAKs while the daemon drained it
BLITSCRT_KREV    ?= k12

# Proof-of-concept initramfs: a static init plus a static busybox for an
# interactive debug shell, embedded into zImage via CONFIG_INITRAMFS_SOURCE.
# Built by the 'initramfs' target.
INITRAMFS_SRC := linux/initramfs/init.c
INITRAMFS_DIR := $(WORK_DIR)/initramfs
INIT_BIN      := $(INITRAMFS_DIR)/init

# Static busybox for the debug shell (dropped into the initramfs at /bin/busybox,
# built standalone so applets resolve by name). Cloned and cross-compiled once,
# then cached under build/. Override BUSYBOX_REF to pin a different tag.
BUSYBOX_REF := 1_36_1
BUSYBOX_SRC := $(WORK_DIR)/busybox-src
BUSYBOX_BIN := $(INITRAMFS_DIR)/bin/busybox

# The daemon, baked into the initramfs at /bin/blitscrtd as a fallback. init
# prefers a copy on the card (swappable during bring-up) and falls back to this.
DAEMON_EMBED := $(INITRAMFS_DIR)/bin/blitscrtd

# Cross-compiler for the ARM kernel. Auto-detected from the usual triplets;
# override with CROSS_COMPILE=... if yours differs. The trailing dash is part
# of the kernel's convention (it prepends this to gcc, ld, and so on).
CROSS_COMPILE ?= $(shell \
  for c in arm-linux-gnueabihf- arm-none-linux-gnueabihf- \
           arm-buildroot-linux-gnueabihf- \
           arm-linux-gnueabi- armv7l-linux-gnueabihf-; do \
    command -v $${c}gcc >/dev/null 2>&1 && { echo $$c; exit 0; }; \
  done; \
  for g in $(HOME)/toolchains/*/bin/*gcc; do \
    [ -x "$$g" ] || continue; \
    b=$$(basename $$g); echo $${b%gcc}; exit 0; \
  done 2>/dev/null)

# If the cross-compiler is not on PATH but lives under ~/toolchains, capture its
# bin/ so the kernel build can find it. The kernel invokes $(CROSS_COMPILE)gcc as
# a bare command, so the directory must be on PATH -- resolving the triplet name
# alone is not enough. Empty when the compiler is already on PATH.
CROSS_BIN := $(shell \
  command -v $(CROSS_COMPILE)gcc >/dev/null 2>&1 || { \
    for g in $(HOME)/toolchains/*/bin/$(CROSS_COMPILE)gcc; do \
      [ -x "$$g" ] && { dirname "$$g"; exit 0; }; \
    done; \
  } 2>/dev/null)

# PATH prefix for kernel recipes: prepend CROSS_BIN when it is set.
KPATH := $(if $(CROSS_BIN),PATH="$(CROSS_BIN):$$PATH",)

# Kernel defconfig. MiSTer's tree ships MiSTer_defconfig; a mainline socfpga
# tree uses multi_v7_defconfig. Auto-picked from the tree, override with
# KERNEL_DEFCONFIG=... if needed.
KERNEL_DEFCONFIG ?= $(shell \
  if [ -f "$(KERNEL_SRC)/arch/arm/configs/MiSTer_defconfig" ]; then \
    echo MiSTer_defconfig; \
  else echo multi_v7_defconfig; fi 2>/dev/null)
KERNEL_DEFCONFIG := $(if $(KERNEL_DEFCONFIG),$(KERNEL_DEFCONFIG),multi_v7_defconfig)

# Which board dtb the build produces. MiSTer boards use the de10_nano dtb;
# a mainline socfpga tree uses socdk. Auto-picked, override to match hardware.
KERNEL_DTB_NAME ?= $(shell \
  if [ -f "$(KERNEL_SRC)/arch/arm/configs/MiSTer_defconfig" ]; then \
    echo socfpga_cyclone5_de10_nano.dtb; \
  else echo socfpga_cyclone5_socdk.dtb; fi 2>/dev/null)
KERNEL_DTB_NAME := $(if $(KERNEL_DTB_NAME),$(KERNEL_DTB_NAME),socfpga_cyclone5_socdk.dtb)

# The override names the bitstream inside it. Generating both together stops
# the two drifting apart if the project is ever renamed.
uboot-txt: $(UBOOT_TXT)

$(UBOOT_TXT): tools/gen_uboot_txt.py
	@python3 tools/gen_uboot_txt.py $@ $(UBOOT_FLAG)

# The .rbf depends on every RTL source and generated .hex. If it is already
# newer than all of them, the fabric has not changed and a full Quartus compile
# (minutes) would be wasted -- skip it. Force a rebuild with FORCE_BITSTREAM=1
# or 'make bitstream-force'.
RTL_SRCS := $(wildcard rtl/*.v rtl/*.sv rtl/*/*.v rtl/*/*.sv rtl/*.hex) \
            quartus/blitscrt.qsf quartus/blitscrt.sdc

# Whether to recompile follows the *content* of the fabric sources, not their
# timestamps. A tree that arrives as an archive has every mtime set to the time
# of extraction, so a timestamp check sees everything as newer than the .rbf and
# runs Quartus for minutes over a release that only changed the daemon. The hash
# is written beside the .rbf after a successful compile.
RTL_HASH := quartus/output_files/blitscrt.rtlhash



bitstream: assets
	@if [ -z "$(QUARTUS_SH)" ]; then \
	  $(MAKE) --no-print-directory quartus-path; exit 1; \
	fi
	@if [ -z "$(FORCE_BITSTREAM)" ] && [ -f $(RBF) ] && \
	   python3 tools/rtl_hash.py --check $(RTL_HASH); then \
	  echo "bitstream up to date (fabric sources unchanged); skipping Quartus."; \
	  echo "  force a rebuild with: make bitstream FORCE_BITSTREAM=1"; \
	else \
	  echo "using $(QUARTUS_SH)"; \
	  ( cd quartus && $(QUARTUS_SH) --flow compile blitscrt ) && \
	  python3 tools/rtl_hash.py --write $(RTL_HASH); \
	fi
	@python3 tools/check_fit.py quartus/output_files
	@python3 tools/gen_uboot_txt.py $(UBOOT_TXT) $(UBOOT_FLAG)

# Always recompile, ignoring the up-to-date check.
bitstream-force:
	@$(MAKE) --no-print-directory bitstream FORCE_BITSTREAM=1
	@echo ""
	@if [ -f $(RBF) ]; then \
	  ls -l $(RBF); \
	  $(MAKE) --no-print-directory build; \
	else \
	  echo "No .rbf produced. Check quartus/output_files/blitscrt.*.rpt"; \
	fi

# Install the bitstream and its u-boot override onto a mounted MiSTer SD card.
.PHONY: sd
# Patch the staged device tree for peripheral mode, on its own.
#
# The kernel rule does this after staging the dtb, but that rule is skipped when
# the kernel is already up to date -- so a later `make world` can leave the dtb
# untouched. Running this directly is safe and repeatable.
dr-mode:
	@python3 tools/set_dr_mode.py $(KERNEL_DTB)

sd:
	@test -n "$(DEST)" || { echo "usage: make sd DEST=/path/to/mounted/sd"; exit 1; }
	./tools/install_sd.sh "$(DEST)"

# ---- Linux kernel image and device tree ----
#
# Builds the custom GUD kernel and the device tree, then stages them. Needs a
# configured kernel tree; point KERNEL_SRC at it. The device tree overlay in
# linux/ is applied on top of the board's base tree by the kernel build.
# Prerequisites checked in one place, with actionable messages. Kernel builds
# are heavy and fail obscurely when a piece is missing; catch it up front.
kernel-check:
	@test -n "$(KERNEL_SRC)" || { \
	  echo "no kernel tree. set KERNEL_SRC=/path, or put one where make looks"; \
	  echo "(see 'The kernel' in the README for the checkout and prereqs)."; \
	  exit 1; }
	@test -d "$(KERNEL_SRC)" || { echo "KERNEL_SRC=$(KERNEL_SRC) is not a directory"; exit 1; }
	@test -f "$(KERNEL_SRC)/Makefile" || { \
	  echo "$(KERNEL_SRC) has no top-level Makefile -- not a kernel tree"; exit 1; }
	@test -n "$(CROSS_COMPILE)" || { \
	  echo "no ARM cross-compiler found. get one with 'make get-toolchain',"; \
	  echo "or set CROSS_COMPILE=your-triplet- explicitly."; exit 1; }
	@$(KPATH) command -v $(CROSS_COMPILE)gcc >/dev/null 2>&1 || { \
	  echo "$(CROSS_COMPILE)gcc is named but not runnable."; \
	  echo "if you used 'make get-toolchain', its bin/ should be auto-added;"; \
	  echo "otherwise add the toolchain's bin/ to PATH."; exit 1; }
	@echo "kernel tree:    $(KERNEL_SRC)"
	@echo "cross-compiler: $(UBOOT_CROSS)gcc"
	@$(KPATH) $(UBOOT_CROSS)gcc --version 2>/dev/null | head -1 | sed "s/^/                /"

# Apply the base defconfig and merge our gadget fragment on top. Safe to re-run.
kernel-config: kernel-check
	@echo "configuring: $(KERNEL_DEFCONFIG) + linux/blitscrt_gadget.config"
	@# MiSTer's tree needs an empty .scmversion so the kernel version string has
	@# no trailing '+', or its modules will not load. Harmless on other trees.
	@if [ -f "$(KERNEL_SRC)/arch/arm/configs/MiSTer_defconfig" ]; then \
	  touch "$(KERNEL_SRC)/.scmversion"; \
	  echo "MiSTer tree: created .scmversion for a clean version string"; \
	fi
	$(KPATH) $(MAKE) -C $(KERNEL_SRC) ARCH=arm $(KERNEL_DEFCONFIG)
	$(KERNEL_SRC)/scripts/kconfig/merge_config.sh -m -O $(KERNEL_SRC) \
	  $(KERNEL_SRC)/.config \
	  $(CURDIR)/linux/blitscrt_gadget.config \
	  $(CURDIR)/linux/blitscrt_boot.config
	$(KPATH) $(MAKE) -C $(KERNEL_SRC) ARCH=arm CROSS_COMPILE=$(CROSS_COMPILE) olddefconfig
	@# Check the gadget options survived olddefconfig. A fragment can be
	@# overridden by a select or a dependency and the build carries on
	@# regardless -- and the symptom is EBUSY from configfs at run time, three
	@# steps away from the cause.
	@fail=0; \
	if grep -q '^CONFIG_USB_FUNCTIONFS=' $(KERNEL_SRC)/.config; then \
	  echo "ERROR: CONFIG_USB_FUNCTIONFS is set. That is the legacy g_ffs"; \
	  echo "       gadget; it claims the FunctionFS instance at boot and"; \
	  echo "       configfs then fails with EBUSY. It must be off."; \
	  fail=1; \
	fi; \
	for o in CONFIG_USB_CONFIGFS_F_FS CONFIG_USB_CONFIGFS CONFIG_USB_LIBCOMPOSITE; do \
	  grep -q "^$$o=y" $(KERNEL_SRC)/.config || { \
	    echo "ERROR: $$o is not enabled; the gadget cannot work"; fail=1; }; \
	done; \
	test $$fail -eq 0 || exit 1; \
	echo "gadget options verified in .config"

# ---- Proof-of-concept initramfs ----
#
# Cross-compiles the static init and a static busybox (debug shell), and lays out
# the mount points. The kernel build embeds this directory via
# CONFIG_INITRAMFS_SOURCE, so there is no separate cpio to ship -- the rootfs
# lives inside zImage. Needs only the ARM cross-compiler and network access for
# the busybox source; both are cached under build/ after the first run.
initramfs: $(INIT_BIN) $(BUSYBOX_BIN) $(DAEMON_EMBED)

$(INIT_BIN): $(INITRAMFS_SRC)
	@test -n "$(CROSS_COMPILE)" || { \
	  echo "no ARM cross-compiler found for the initramfs init."; \
	  echo "get one with 'make get-toolchain', or set CROSS_COMPILE=your-triplet-."; \
	  exit 1; }
	@mkdir -p $(INITRAMFS_DIR)/proc $(INITRAMFS_DIR)/sys \
	          $(INITRAMFS_DIR)/dev $(INITRAMFS_DIR)/media/fat $(INITRAMFS_DIR)/bin
	$(KPATH) $(CROSS_COMPILE)gcc -static -Os -Wall -Wextra -o $(INIT_BIN) \
	  -DBLITSCRT_NAME='"$(BLITSCRT_NAME)"' \
	  -DBLITSCRT_VERSION='"$(BLITSCRT_FULLVER)"' \
	  -DBLITSCRT_KREV='"$(BLITSCRT_KREV)"' \
	  $(INITRAMFS_SRC)
	@$(KPATH) $(CROSS_COMPILE)strip $(INIT_BIN) 2>/dev/null || true
	@echo "built initramfs init: $(BLITSCRT_NAME) $(BLITSCRT_FULLVER)-$(BLITSCRT_KREV), $$(du -h $(INIT_BIN) | cut -f1), static ARM"

# Static busybox for /bin/busybox. Cloned + built once, then cached. Configured
# static + standalone shell; the tc applet is dropped (it does not build against
# current kernel headers and we do not need it).
$(BUSYBOX_BIN):
	@test -n "$(CROSS_COMPILE)" || { \
	  echo "no ARM cross-compiler found for busybox."; \
	  echo "get one with 'make get-toolchain', or set CROSS_COMPILE=your-triplet-."; \
	  exit 1; }
	@mkdir -p $(BUILD_DIR)
	@if [ ! -d $(BUSYBOX_SRC) ]; then \
	  echo "cloning busybox $(BUSYBOX_REF)"; \
	  git clone --depth 1 --branch $(BUSYBOX_REF) \
	    https://github.com/mirror/busybox.git $(BUSYBOX_SRC); \
	fi
	$(KPATH) $(MAKE) -C $(BUSYBOX_SRC) ARCH=arm CROSS_COMPILE=$(CROSS_COMPILE) defconfig
	@cd $(BUSYBOX_SRC) && \
	  sed -i 's/^# CONFIG_STATIC is not set/CONFIG_STATIC=y/' .config; \
	  grep -q '^CONFIG_STATIC=y' .config || echo 'CONFIG_STATIC=y' >> .config; \
	  sed -i 's/^# CONFIG_FEATURE_SH_STANDALONE is not set/CONFIG_FEATURE_SH_STANDALONE=y/' .config; \
	  grep -q '^CONFIG_FEATURE_SH_STANDALONE=y' .config || echo 'CONFIG_FEATURE_SH_STANDALONE=y' >> .config; \
	  sed -i 's/^# CONFIG_FEATURE_PREFER_APPLETS is not set/CONFIG_FEATURE_PREFER_APPLETS=y/' .config; \
	  grep -q '^CONFIG_FEATURE_PREFER_APPLETS=y' .config || echo 'CONFIG_FEATURE_PREFER_APPLETS=y' >> .config; \
	  sed -i 's/^CONFIG_TC=y/# CONFIG_TC is not set/' .config
	yes "" | $(KPATH) $(MAKE) -C $(BUSYBOX_SRC) ARCH=arm CROSS_COMPILE=$(CROSS_COMPILE) -j$$(nproc)
	@mkdir -p $(INITRAMFS_DIR)/bin
	@cp $(BUSYBOX_SRC)/busybox $(BUSYBOX_BIN)
	@echo "built busybox (static ARM, $$(du -h $(BUSYBOX_BIN) | cut -f1)) -> initramfs/bin/busybox"

# Build blitscrtd (static ARM) and bake it into the initramfs. Rebuilds when any
# daemon source changes.
$(DAEMON_EMBED): $(wildcard sw/*.c sw/*.h)
	@test -n "$(CROSS_COMPILE)" || { \
	  echo "no ARM cross-compiler found for blitscrtd."; \
	  echo "get one with 'make get-toolchain', or set CROSS_COMPILE=your-triplet-."; \
	  exit 1; }
	$(KPATH) $(MAKE) -C sw CROSS_COMPILE=$(CROSS_COMPILE) STATIC=1 blitscrtd
	@mkdir -p $(INITRAMFS_DIR)/bin
	@cp sw/blitscrtd $(DAEMON_EMBED)
	@echo "embedded blitscrtd (static ARM, $$(du -h $(DAEMON_EMBED) | cut -f1)) -> initramfs/bin/blitscrtd"

# Build the image and device tree, then stage into build/blitscrt/. Runs
# kernel-config, builds the initramfs, points the kernel at it, then compiles.
# Set SKIP_CONFIG=1 to reuse an existing .config (faster rebuilds); the initramfs
# is always rebuilt and re-pointed so the embedded rootfs stays current.
linux: kernel-check initramfs
	@if [ -z "$(SKIP_CONFIG)" ]; then $(MAKE) --no-print-directory kernel-config; \
	  else echo "reusing existing .config (SKIP_CONFIG set)"; fi
	@mkdir -p $(CARD_SUB)
	@# Embed our initramfs: enable initrd and point the source at the staged dir.
	@# The path is absolute because the kernel build runs with -C $(KERNEL_SRC);
	@# owners are squashed to root so /init is uid 0 no matter who builds.
	$(KERNEL_SRC)/scripts/config --file $(KERNEL_SRC)/.config \
	  --enable  BLK_DEV_INITRD \
	  --set-str INITRAMFS_SOURCE "$(abspath $(INITRAMFS_DIR))" \
	  --set-val INITRAMFS_ROOT_UID 0 \
	  --set-val INITRAMFS_ROOT_GID 0
	$(KPATH) $(MAKE) -C $(KERNEL_SRC) ARCH=arm CROSS_COMPILE=$(CROSS_COMPILE) olddefconfig
	$(KPATH) $(MAKE) -C $(KERNEL_SRC) ARCH=arm CROSS_COMPILE=$(CROSS_COMPILE) \
	  LOCALVERSION=-$(BLITSCRT_NAME)-$(BLITSCRT_FULLVER)-$(BLITSCRT_KREV) \
	  -j$$(nproc) zImage dtbs
	@cp $(KERNEL_SRC)/arch/arm/boot/zImage $(KERNEL_IMAGE) && \
	  echo "staged blitscrt/zImage ($(BLITSCRT_NAME)-$(BLITSCRT_FULLVER)-$(BLITSCRT_KREV), initramfs embedded)"
	@if cp $(KERNEL_SRC)/arch/arm/boot/dts/$(KERNEL_DTB_NAME) $(KERNEL_DTB) 2>/dev/null || \
	     cp $(KERNEL_SRC)/arch/arm/boot/dts/*/$(KERNEL_DTB_NAME) $(KERNEL_DTB) 2>/dev/null; then \
	  echo "staged blitscrt/blitscrt.dtb ($(KERNEL_DTB_NAME))"; \
	  python3 tools/set_dr_mode.py $(KERNEL_DTB); \
	else \
	  echo "note: $(KERNEL_DTB_NAME) not found; set KERNEL_DTB_NAME= to your board's dtb"; \
	fi
	@echo "kernel staged in $(CARD_SUB)/"

# Build the userspace daemon (blitscrtd) that runs on the board. Needed for the
# heartbeat path -- the stock-kernel route in the README runs this directly.
daemon:
	@if [ -z "$(CROSS_COMPILE)" ]; then \
	  echo "-- no ARM cross-compiler; building a host daemon that will NOT run"; \
	  echo "   on the board. get one with 'make get-toolchain' for a real build."; \
	  $(MAKE) --no-print-directory -C sw STATIC=$(STATIC) blitscrtd; \
	else \
	  echo "building blitscrtd for ARM ($(CROSS_COMPILE)gcc)"; \
	  $(KPATH) $(MAKE) --no-print-directory -C sw \
	    CROSS_COMPILE=$(CROSS_COMPILE) STATIC=$(STATIC) blitscrtd; \
	fi
	@if [ -f sw/blitscrtd ]; then \
	  file sw/blitscrtd 2>/dev/null | grep -q ARM && \
	    echo "built sw/blitscrtd (ARM)" || \
	    echo "built sw/blitscrtd ($$(file sw/blitscrtd 2>/dev/null | grep -o 'x86-64\|ARM\|aarch64' | head -1))"; \
	fi

# ---- Bring-up register tool ----
#
# blitscrt-peek reads and writes fabric registers over the same gp transport the
# daemon uses. Built with the same auto-detected toolchain and staged next to the
# daemon so it lands on the card.
ddrbench:
	@if [ -z "$(CROSS_COMPILE)" ]; then \
	  echo "-- no ARM cross-compiler; building a host blitscrt-ddrbench that will NOT run on the board"; \
	  $(MAKE) --no-print-directory -C sw STATIC=$(STATIC) blitscrt-ddrbench; \
	else \
	  echo "building blitscrt-ddrbench for ARM ($(CROSS_COMPILE)gcc)"; \
	  $(KPATH) $(MAKE) --no-print-directory -C sw \
	    CROSS_COMPILE=$(CROSS_COMPILE) STATIC=$(STATIC) blitscrt-ddrbench; \
	fi

peek:
	@if [ -z "$(CROSS_COMPILE)" ]; then \
	  echo "-- no ARM cross-compiler; building a host blitscrt-peek that will NOT run on the board"; \
	  $(MAKE) --no-print-directory -C sw STATIC=$(STATIC) blitscrt-peek; \
	else \
	  echo "building blitscrt-peek for ARM ($(CROSS_COMPILE)gcc)"; \
	  $(KPATH) $(MAKE) --no-print-directory -C sw \
	    CROSS_COMPILE=$(CROSS_COMPILE) STATIC=$(STATIC) blitscrt-peek; \
	fi
	@[ -f sw/blitscrt-peek ] && \
	  echo "built sw/blitscrt-peek ($$(file sw/blitscrt-peek 2>/dev/null | grep -o 'x86-64\|ARM\|aarch64' | head -1))" || true

# ---- Stage a complete bootable set ----
#
# Collects everything the board loads at power-on into BUILD_DIR: the FPGA
# bitstream, the u-boot override that names it, and the kernel image plus
# device tree if they have been built. The result is what gets copied to an SD
# card. Pieces that need a toolchain not present are reported, not faked.
build: assets $(UBOOT_TXT) daemon peek
	@mkdir -p $(BUILD_DIR)
	@# Regenerate the override to match reality: boot the kernel if one is
	@# staged, else halt after the FPGA. Handles the same-run case where the
	@# kernel was just built.
	@if [ -f $(CARD_SUB)/zImage ]; then \
	  python3 tools/gen_uboot_txt.py $(UBOOT_TXT) --linux; \
	  echo "override: boots the staged kernel"; \
	else \
	  python3 tools/gen_uboot_txt.py $(UBOOT_TXT); \
	  echo "override: halts after FPGA (no kernel staged)"; \
	fi
	@cp $(UBOOT_TXT) $(BUILD_DIR)/ && echo "staged $(notdir $(UBOOT_TXT))"
	@if [ -f $(RBF) ]; then \
	  cp $(RBF) $(BUILD_DIR)/ && echo "staged $(notdir $(RBF))"; \
	else \
	  echo "no $(RBF) yet -- run 'make bitstream' (needs Quartus)"; \
	fi
	@if [ -f $(KERNEL_IMAGE) ]; then \
	  echo "kernel image present at blitscrt/zImage"; \
	else \
	  echo "no kernel image yet -- run 'make linux KERNEL_SRC=...'"; \
	fi
	@mkdir -p $(CARD_SUB)
	@cp tools/gadget-setup.sh $(CARD_SUB)/ && echo "staged blitscrt/gadget-setup.sh"
	@cp tools/find-io.sh $(CARD_SUB)/ && echo "staged blitscrt/find-io.sh"
	@cp tools/blitscrt-startup.sh $(CARD_SUB)/ && echo "staged blitscrt/blitscrt-startup.sh"
	@cp linux/blitscrt_gadget.config $(CARD_SUB)/ 2>/dev/null || true
	@if [ -f sw/blitscrtd ]; then \
	  cp sw/blitscrtd $(CARD_SUB)/ && echo "staged blitscrt/blitscrtd"; \
	else \
	  echo "note: sw/blitscrtd not built (run: make -C sw); needed to run on the board"; \
	fi
	@if [ -f sw/blitscrt-ddrbench ]; then \
	  cp sw/blitscrt-ddrbench $(CARD_SUB)/ && echo "staged blitscrt/blitscrt-ddrbench"; \
	fi
	@if [ -f sw/blitscrt-peek ]; then \
	  cp sw/blitscrt-peek $(CARD_SUB)/ && echo "staged blitscrt/blitscrt-peek"; \
	fi
	@echo ""
	@if [ -f "$(IMAGE)" ]; then \
	  echo ""; \
	  echo "  card image:  $$(realpath $(IMAGE)) ($$(du -h $(IMAGE) | cut -f1))"; \
	  echo "               write it with Etcher, Raspberry Pi Imager or dd"; \
	  echo ""; \
	fi
	@echo "build set in $(BUILD_DIR)/ (mirrors the SD card):"
	@find $(BUILD_DIR) -type f | sed "s|$(BUILD_DIR)|  |" | sort
	@echo ""
	@echo "copy the contents of $(BUILD_DIR)/ to the SD card root. the layout"
	@echo "already matches what blitscrt.txt loads: .rbf and .txt at the root,"
	@echo "the kernel and gadget files under blitscrt/."
