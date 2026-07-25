# Simulation and asset generation. Quartus is driven from quartus/blitscrt.qsf.

IV      := iverilog -g2012
RTL     := rtl/video_timing.v rtl/testcard.v rtl/overlay.v \
           rtl/char_ram.v rtl/font_rom.v

.PHONY: all world manifest assets sim render render-i clean distclean tools setup setup-dry get-toolchain kernel-clone daemon bitstream bitstream-force quartus-path lint check-pins check-decl check-ip uboot-txt preview linux build kernel-check kernel-config initramfs

# iverilog and Pillow are for verification only. Neither is needed to build the
# bitstream -- Quartus consumes rtl/ and the generated .hex files, nothing else.
HAVE_IVERILOG := $(shell command -v iverilog 2>/dev/null)
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
	  $(MAKE) --no-print-directory linux KERNEL_SRC="$(KERNEL_SRC)" || \
	    echo "-- kernel build failed; staging the rest anyway"; \
	fi
	@$(MAKE) --no-print-directory daemon CROSS_COMPILE="$(CROSS_COMPILE)" STATIC="$(STATIC)" || echo "-- daemon build skipped"
	@$(MAKE) --no-print-directory build   # build is idempotent (cp -f); safe
	@$(MAKE) --no-print-directory manifest

# Every output this project can produce, and whether it is there.
MANIFEST := \
  rtl/font8x8.hex \
  rtl/banner.hex \
  rtl/banner_i.hex \
  sim/tb_timing.vvp \
  sim/tb_i2c.vvp \
  sim/tb_render.vvp \
  sim/testcard_640x240p60.png \
  sim/testcard_640x240p60_x2.png \
  sim/testcard_640x480i60.png \
  sim/testcard_640x480i60_x2.png \
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
  build/initramfs/init

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
get-toolchain:
	./tools/get-toolchain.sh

# Clone the MiSTer kernel tree, non-interactively, where the build auto-detects
# it. Use this instead of the setup prompt if you skipped it. The tree is large;
# --depth 1 keeps it to one revision. Override the destination with
# KERNEL_CLONE_DIR=.
KERNEL_CLONE_DIR ?= $(HOME)/source/Linux-Kernel_MiSTer
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

# Proper dependencies so 'make all' does not regenerate these for every
# downstream target.
assets: rtl/font8x8.hex rtl/banner.hex

rtl/font8x8.hex: tools/gen_font.py
	python3 tools/gen_font.py $@

# One image, three banks. The overlay indexes the bank with the live mode.
rtl/banner.hex: tools/gen_banner.py
	python3 tools/gen_banner.py $@

sim: assets
	$(need_iverilog)
	$(IV) -o sim/tb_timing.vvp sim/tb_timing.v rtl/video_timing.v
	cd rtl && vvp ../sim/tb_timing.vvp
	$(IV) -o sim/tb_i2c.vvp sim/tb_i2c.v rtl/adv7513_init.v rtl/i2c_master.v
	vvp sim/tb_i2c.vvp
	$(IV) -o sim/tb_modes.vvp sim/tb_modes.v rtl/video_timing.v rtl/mode_table.v
	vvp sim/tb_modes.vvp
	$(IV) -o sim/tb_regs.vvp sim/tb_regs.v rtl/blitscrt_regs.v
	vvp sim/tb_regs.vvp
	$(IV) -o sim/tb_bridge.vvp sim/tb_bridge.v rtl/blitscrt_bridge.v
	vvp sim/tb_bridge.vvp

# Elaborate the real top level with stand-ins for the Quartus primitives.
.PHONY: lint
# Verify the generated PLL megafunctions carry the settings the design needs.
# Reads what came out rather than trusting what was ticked, since GUI labels
# move between Quartus releases. See docs/MEGAFUNCTIONS.md.
check-ip:
	@python3 tools/check_ip.py

# Icarus builds disagree about use before declaration; mine accepts it and
# others reject it outright. Quartus never complains, so this only surfaces on
# somebody else's machine. Checked here instead.
check-decl:
	@python3 tools/check_decl_order.py rtl/*.v sim/*.v

lint: check-decl
	$(need_iverilog)
	$(IV) -o /dev/null -s blitscrt_top rtl/*.v sim/vendor_stubs.v && echo "top elaborates clean"

render: assets
	$(need_iverilog)
	@python3 -c "import PIL" 2>/dev/null || \
	  { echo "Pillow not found:  sudo pacman -S python-pillow"; exit 1; }
	$(IV) -o sim/tb_render.vvp sim/tb_render.v $(RTL)
	cd rtl && vvp ../sim/tb_render.vvp
	python3 tools/render_png.py 640x240p60

render-i: assets
	$(need_iverilog)
	@python3 -c "import PIL" 2>/dev/null || \
	  { echo "Pillow not found:  sudo pacman -S python-pillow"; exit 1; }
	$(IV) -DRENDER_INTERLACED -o sim/tb_render_i.vvp sim/tb_render.v $(RTL)
	cd rtl && vvp ../sim/tb_render_i.vvp
	python3 tools/render_png.py 640x480i60

# Remove transient build products. Every rm uses -f / -rf, so a missing file is
# never an error -- clean works whether or not a full build ran. The tracked
# sim/*.png renders are left alone; the README embeds them.
clean:
	rm -f  sim/*.vvp sim/*.vcd sim/*.fst sim/*.lxt
	rm -f  rtl/render.txt $(UBOOT_TXT) README_preview.html
	rm -f  sw/*.o sw/blitscrtd sw/test_pll sw/test_pll_reconfig sw/test_modes sw/test_device
	rm -rf build/
	rm -rf __pycache__ tools/__pycache__ sw/__pycache__
	find . -name '*.pyc' -delete 2>/dev/null || true

# Also remove generated assets and the Quartus output. Leaves only tracked
# sources.
distclean: clean
	rm -f  rtl/font8x8.hex rtl/banner.hex rtl/banner_i.hex
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

# The one place the product name and version are set. They brand the kernel
# (LOCALVERSION, so uname -r and dmesg carry them) and are compiled into the
# initramfs init, which stamps them into the boot log. Override on the command
# line if needed:  make world BLITSCRT_VERSION=0.11
BLITSCRT_NAME    ?= BlitsCRT
BLITSCRT_VERSION ?= 0.10

# Proof-of-concept initramfs: a static init plus a static busybox for an
# interactive debug shell, embedded into zImage via CONFIG_INITRAMFS_SOURCE.
# Built by the 'initramfs' target.
INITRAMFS_SRC := linux/initramfs/init.c
INITRAMFS_DIR := $(BUILD_DIR)/initramfs
INIT_BIN      := $(INITRAMFS_DIR)/init

# Static busybox for the debug shell (dropped into the initramfs at /bin/busybox,
# built standalone so applets resolve by name). Cloned and cross-compiled once,
# then cached under build/. Override BUSYBOX_REF to pin a different tag.
BUSYBOX_REF := 1_36_1
BUSYBOX_SRC := $(BUILD_DIR)/busybox-src
BUSYBOX_BIN := $(INITRAMFS_DIR)/bin/busybox

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
RTL_SRCS := $(wildcard rtl/*.v rtl/*/*.v rtl/*.hex) quartus/blitscrt.qsf quartus/blitscrt.sdc

bitstream: assets
	@if [ -z "$(QUARTUS_SH)" ]; then \
	  $(MAKE) --no-print-directory quartus-path; exit 1; \
	fi
	@if [ -z "$(FORCE_BITSTREAM)" ] && [ -f $(RBF) ] && \
	   [ -z "$$(find $(RTL_SRCS) -newer $(RBF) 2>/dev/null)" ]; then \
	  echo "bitstream up to date ($(RBF) newer than all RTL); skipping Quartus."; \
	  echo "  force a rebuild with: make bitstream FORCE_BITSTREAM=1"; \
	else \
	  echo "using $(QUARTUS_SH)"; \
	  ( cd quartus && $(QUARTUS_SH) --flow compile blitscrt ); \
	fi
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
	@echo "cross-compiler: $(CROSS_COMPILE)gcc$(if $(CROSS_BIN), (from $(CROSS_BIN)),)"

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

# ---- Proof-of-concept initramfs ----
#
# Cross-compiles the static init and a static busybox (debug shell), and lays out
# the mount points. The kernel build embeds this directory via
# CONFIG_INITRAMFS_SOURCE, so there is no separate cpio to ship -- the rootfs
# lives inside zImage. Needs only the ARM cross-compiler and network access for
# the busybox source; both are cached under build/ after the first run.
initramfs: $(INIT_BIN) $(BUSYBOX_BIN)

$(INIT_BIN): $(INITRAMFS_SRC)
	@test -n "$(CROSS_COMPILE)" || { \
	  echo "no ARM cross-compiler found for the initramfs init."; \
	  echo "get one with 'make get-toolchain', or set CROSS_COMPILE=your-triplet-."; \
	  exit 1; }
	@mkdir -p $(INITRAMFS_DIR)/proc $(INITRAMFS_DIR)/sys \
	          $(INITRAMFS_DIR)/dev $(INITRAMFS_DIR)/media/fat $(INITRAMFS_DIR)/bin
	$(KPATH) $(CROSS_COMPILE)gcc -static -Os -Wall -Wextra -o $(INIT_BIN) \
	  -DBLITSCRT_NAME='"$(BLITSCRT_NAME)"' \
	  -DBLITSCRT_VERSION='"$(BLITSCRT_VERSION)"' \
	  $(INITRAMFS_SRC)
	@$(KPATH) $(CROSS_COMPILE)strip $(INIT_BIN) 2>/dev/null || true
	@echo "built initramfs init: $(BLITSCRT_NAME) $(BLITSCRT_VERSION), $$(du -h $(INIT_BIN) | cut -f1), static ARM"

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
	  LOCALVERSION=-$(BLITSCRT_NAME)-$(BLITSCRT_VERSION) -j$$(nproc) zImage dtbs
	@cp $(KERNEL_SRC)/arch/arm/boot/zImage $(KERNEL_IMAGE) && \
	  echo "staged blitscrt/zImage ($(BLITSCRT_NAME)-$(BLITSCRT_VERSION), initramfs embedded)"
	@if cp $(KERNEL_SRC)/arch/arm/boot/dts/$(KERNEL_DTB_NAME) $(KERNEL_DTB) 2>/dev/null || \
	     cp $(KERNEL_SRC)/arch/arm/boot/dts/*/$(KERNEL_DTB_NAME) $(KERNEL_DTB) 2>/dev/null; then \
	  echo "staged blitscrt/blitscrt.dtb ($(KERNEL_DTB_NAME))"; \
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

# ---- Stage a complete bootable set ----
#
# Collects everything the board loads at power-on into BUILD_DIR: the FPGA
# bitstream, the u-boot override that names it, and the kernel image plus
# device tree if they have been built. The result is what gets copied to an SD
# card. Pieces that need a toolchain not present are reported, not faked.
build: assets $(UBOOT_TXT) daemon
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
	@cp tools/blitscrt-startup.sh $(CARD_SUB)/ && echo "staged blitscrt/blitscrt-startup.sh"
	@cp linux/blitscrt_gadget.config $(CARD_SUB)/ 2>/dev/null || true
	@if [ -f sw/blitscrtd ]; then \
	  cp sw/blitscrtd $(CARD_SUB)/ && echo "staged blitscrt/blitscrtd"; \
	else \
	  echo "note: sw/blitscrtd not built (run: make -C sw); needed to run on the board"; \
	fi
	@echo ""
	@echo "build set in $(BUILD_DIR)/ (mirrors the SD card):"
	@find $(BUILD_DIR) -type f | sed "s|$(BUILD_DIR)|  |" | sort
	@echo ""
	@echo "copy the contents of $(BUILD_DIR)/ to the SD card root. the layout"
	@echo "already matches what blitscrt.txt loads: .rbf and .txt at the root,"
	@echo "the kernel and gadget files under blitscrt/."
