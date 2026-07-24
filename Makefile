# Simulation and asset generation. Quartus is driven from quartus/blitscrt.qsf.

IV      := iverilog -g2012
RTL     := rtl/video_timing.v rtl/testcard.v rtl/overlay.v \
           rtl/char_ram.v rtl/font_rom.v

.PHONY: all world manifest assets sim render render-i clean distclean tools bitstream quartus-path lint check-pins check-decl uboot-txt preview

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
	@if [ -n "$(QUARTUS_SH)" ]; then $(MAKE) --no-print-directory bitstream; \
	  else echo "-- skipping bitstream, quartus_sh not found (try: make quartus-path)"; fi
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
  quartus/output_files/blitscrt.sta.rpt

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
tools:
	@echo "python3    $$(python3 --version 2>&1)"
	@echo "iverilog   $${IV:-$(if $(HAVE_IVERILOG),$(HAVE_IVERILOG),NOT FOUND -- testbenches unavailable)}"
	@echo "Pillow     $(if $(HAVE_PILLOW),present,NOT FOUND -- make render unavailable)"
	@echo "quartus_sh $$(command -v quartus_sh || echo 'NOT FOUND -- cannot build the bitstream')"

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

# Elaborate the real top level with stand-ins for the Quartus primitives.
.PHONY: lint
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

clean:
	rm -f sim/*.vvp rtl/render.txt $(UBOOT_TXT) README_preview.html

# Regenerate the assets from scratch as well.
distclean: clean
	rm -f rtl/font8x8.hex rtl/banner.hex

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

# The override names the bitstream inside it. Generating both together stops
# the two drifting apart if the project is ever renamed.
uboot-txt: $(UBOOT_TXT)

$(UBOOT_TXT): tools/gen_uboot_txt.py
	@python3 tools/gen_uboot_txt.py $@

bitstream: assets
	@if [ -z "$(QUARTUS_SH)" ]; then \
	  $(MAKE) --no-print-directory quartus-path; exit 1; \
	fi
	@echo "using $(QUARTUS_SH)"
	cd quartus && $(QUARTUS_SH) --flow compile blitscrt
	@python3 tools/gen_uboot_txt.py $(UBOOT_TXT)
	@echo ""
	@ls -l quartus/output_files/blitscrt.rbf 2>/dev/null && \
	  echo "Next: check the Fitter pin report, then 'make sd DEST=...'" || \
	  echo "No .rbf produced. Check quartus/output_files/blitscrt.*.rpt"

# Install the bitstream and its u-boot override onto a mounted MiSTer SD card.
.PHONY: sd
sd:
	@test -n "$(DEST)" || { echo "usage: make sd DEST=/path/to/mounted/sd"; exit 1; }
	./tools/install_sd.sh "$(DEST)"
