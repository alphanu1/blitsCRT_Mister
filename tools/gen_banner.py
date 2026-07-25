#!/usr/bin/env python3
"""Build the character-buffer init image for the blitsCRT_Mister overlay.

The grid is 128 cols x 64 rows of 8x8 cells, addressed as {row[5:0], col[6:0]}
= 8192 bytes, which covers 80x30 at 640x240 and 80x60 at 640x480. Everything
outside the banner is left as space.

The reported line rate and refresh are computed from the timing numbers rather
than typed in, so the picture on the CRT and the RTL parameters cannot drift
apart.

Usage:
    python3 gen_banner.py rtl/banner.hex 640x240p60
    python3 gen_banner.py rtl/banner.hex 640x480i60
"""
import sys

COLS, ROWS = 128, 64

MODES = {
    # name        pclk_hz   h_sy h_bp h_act h_fp  v_sy v_bp v_act v_fp  ilace
    '640x240p60': (12_600_000, 60, 76, 640, 24,  3, 16, 240, 3,   False),
    '640x480i60': (12_600_000, 60, 76, 640, 24,  3, 16, 240, 3,   True),
    # Standard VGA. Not a CRT mode -- it exists so a plain monitor or HDMI
    # sink will show a picture without a DAC or a SCART lead in the path.
    '640x480p60': (25_200_000, 96, 48, 640, 16,  2, 33, 480, 10,  False),
}


def build(mode_name):
    pclk, hsy, hbp, hact, hfp, vsy, vbp, vact, vfp, ilace = MODES[mode_name]

    h_tot = hsy + hbp + hact + hfp
    v_tot = vsy + vbp + vact + vfp
    frame_lines = 2 * v_tot + 1 if ilace else v_tot

    line_hz = pclk / h_tot
    frame_hz = line_hz / frame_lines
    field_hz = frame_hz * 2 if ilace else frame_hz

    cols = hact // 8
    rows = (vact * 2 if ilace else vact) // (16 if ilace else 8)

    # The idle screen. This is what the CRT shows from power-on until a host
    # attaches, so it carries everything needed to diagnose the link without a
    # serial console: what mode is running, what the hardware is really
    # generating, and which outputs are live.
    #
    # Every number below is computed from the timing parameters above, not
    # typed. The screen cannot claim a mode the RTL is not producing.
    text = [
        "BLITSCRT_MISTER",
        "FABRIC  NO HPS YET",
        "",
        "MODE   %dX%d%s %.2fHZ" % (hact, vact * 2 if ilace else vact,
                                   'I' if ilace else 'P', field_hz),
        "LINE   %.3f KHZ" % (line_hz / 1e3),
        "PIXEL  %.3f MHZ" % (pclk / 1e6),
        # Vertical values are per field. In an interlaced mode that reads as
        # a contradiction against the mode line above unless it is spelled
        # out, so it is.
        "H %d/%d/%d/%d   HTOTAL %d" % (hsy, hbp, hact, hfp, h_tot),
        ("V %d/%d/%d/%d PER FIELD  %d LINES" if ilace
         else "V %d/%d/%d/%d   %d LINES")
        % (vsy, vbp, vact, vfp, frame_lines),
        "",
        "USB    NO HOST",
        "OUT    VGA RGB666 + HDMI DV",
        "",
        "BTN_OSD CYCLES MODE",
    ]

    grid = [[0x20] * COLS for _ in range(ROWS)]

    # 0x01 is a blank glyph that still counts as "used", so it paints the
    # backing box without printing anything. Filling the whole banner
    # rectangle with it stops the colour bars showing through word gaps.
    BACKED_BLANK = 0x01

    top = 2
    width = max(len(t) for t in text) + 2
    col0 = max(0, (cols - width) // 2)

    for i, line in enumerate(text):
        row = top + i
        if row >= rows:
            break
        for j in range(width):
            if col0 + j < cols:
                grid[row][col0 + j] = BACKED_BLANK
        s = line[:width - 2]
        col = col0 + (width - len(s)) // 2
        for j, ch in enumerate(s):
            if col + j < cols:
                grid[row][col + j] = BACKED_BLANK if ch == ' ' \
                                    else (ord(ch) & 0x7F)

    return grid, dict(mode=mode_name, cols=cols, rows=rows,
                      h_tot=h_tot, frame_lines=frame_lines,
                      line_hz=line_hz, field_hz=field_hz, text=text)


def build_fabric_banner():
    """Bank 3: shown when the daemon is not writing. This is the screen you get
    when the fabric is programmed but Linux is not up or blitscrtd is not
    running -- distinct from the live banner's USB status line."""
    def put(grid, r, text):
        for i, ch in enumerate(text[:COLS]):
            grid[r][i] = ord(ch)
    grid = [[0x20] * COLS for _ in range(ROWS_PER_BANK)]
    put(grid, 2,  "BLITSCRT_MISTER")
    put(grid, 4,  "FABRIC RUNNING")
    put(grid, 5,  "NO HPS HEARTBEAT")
    put(grid, 7,  "LINUX NOT UP, OR")
    put(grid, 8,  "BLITSCRTD NOT RUNNING")
    put(grid, 10, "TEST CARD IS FABRIC")
    put(grid, 11, "GENERATED")
    put(grid, 13, "BTN_OSD CYCLES MODE")
    return grid


ROWS_PER_BANK = 16

BANKS = ['640x240p60', '640x480i60', '640x480p60']


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else 'banner.hex'

    grid = [[0x20] * COLS for _ in range(ROWS)]
    infos = []

    for bank, mode_name in enumerate(BANKS):
        g, info = build(mode_name)
        base = bank * ROWS_PER_BANK
        for r in range(ROWS_PER_BANK):
            if base + r < ROWS:
                grid[base + r] = g[r]
        infos.append((bank, mode_name, info))

    # bank 3: the fabric-only banner, no timing since it is mode-independent
    fb = build_fabric_banner()
    base = 3 * ROWS_PER_BANK
    for r in range(ROWS_PER_BANK):
        if base + r < ROWS:
            grid[base + r] = fb[r]

    with open(out, 'w') as f:
        f.write("// overlay character buffer, 3 mode banks + 1 fabric banner, %d rows each\n"
                % ROWS_PER_BANK)
        f.write("// generated by tools/gen_banner.py -- do not edit\n")
        for r in range(ROWS):
            for c in range(COLS):
                f.write("%02X\n" % grid[r][c])

    for bank, mode_name, info in infos:
        print("bank %d  %-12s rows %2d-%-2d  %.3f kHz  %.2f Hz"
              % (bank, mode_name, bank * ROWS_PER_BANK,
                 bank * ROWS_PER_BANK + ROWS_PER_BANK - 1,
                 info['line_hz'] / 1e3, info['field_hz']))
    print("wrote %s (%d bytes)" % (out, COLS * ROWS))


if __name__ == '__main__':
    main()
