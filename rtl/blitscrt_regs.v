// SPDX-License-Identifier: GPL-2.0-or-later
`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// blitscrt_regs.v -- the register file sw/blitscrt_regs.h describes.
//
// An Avalon-MM slave in the 50 MHz bus domain, with the video side running on
// whatever the pixel clock currently is. Everything that crosses between them
// is handled here so the rest of the fabric stays single-clock.
//
// Two crossings:
//
//   bus -> video   the timing set, moved as a block on a request/acknowledge
//                  handshake rather than bit by bit. Writing APPLY raises the
//                  request; the video side latches the whole set at the next
//                  vblank and acknowledges. A modeset therefore cannot land
//                  half-applied, and cannot tear.
//
//   video -> bus   status bits, through two-flop synchronisers. They are
//                  status, so a cycle of skew does not matter.
//
// The character RAM window is a straight write port into the overlay buffer.
// It is write-only from the bus; reading it back is not worth the second port.
// -----------------------------------------------------------------------------

`default_nettype none

module blitscrt_regs #(
    /*
     * Bump this whenever the register map gains something, not only when
     * behaviour changes. 3.1 and 3.2 differ by CAPS, SCANOUT_DIAG and a
     * writable SCANOUT_GEOM, and leaving them sharing a version meant a
     * bitstream that predated all three was indistinguishable from one that
     * had them -- CAPS simply read zero, which is also what an undecoded
     * offset reads.
     *
     *   3.0  rect write port
     *   3.1  scanout geometry override fix
     *   3.2  CAPS, SCANOUT_DIAG, SCANOUT_GEOM writable
     *   3.3  PLL aperture no longer aliases the register file;
     *        CTRL_HPS_TIMING; latched config survives a clk_sel change
     *   3.4  host-owns-timing selects the PLL slot rather than the reference
     *        pin; LIVE_H1..LIVE_MISC report the timing actually in use
     *   3.5  PLL reconfig reads work -- an extra flop on that path made it
     *        latency 2 against the bridge's 1, so every read returned zero
     *   3.6  BUS_DIAG; the bridge gives up on a slave that never accepts
     *        instead of wedging the transport
     *   3.7  blitscrt_pllbus between the bridge and the reconfig slave
     *   3.26 no functional change. Forces a rebuild so the whole staging path
     *        can be watched: bitstream, kernel, dtb, daemon and bootloader all
     *        landing in build/, which is committed
     *   3.25 no functional change. Forces a rebuild so `make bitstream` can be
     *        seen staging build_rbf/blitscrt.rbf, which is the step that was
     *        being missed
     *   3.24 no functional change. Bumped again to force a rebuild after the
     *        lint fix, so a local Quartus run and the release path are both
     *        exercised on the same tree
     *   3.23 no functional change. Bumped to force a bitstream rebuild and
     *        prove the release path end to end: Quartus, the committed .rbf,
     *        the card image, and the workflow that publishes it
     *   3.22 the user button latches on the falling edge with a hold-off, so
     *        one press is one event -- it set on the level, and a held press
     *        toggled the connection two or three times
     *   3.21 HOSTSTATE bit 2 reports the UDC bound, so the front panel can
     *        show the connection separately from a host being attached
     *   3.20 BTN_EVENT at 0xA4 latches a user-button press for the daemon, so
     *        a soft disconnect can be triggered from the front panel
     *   3.19 IO_DIAG reports the MCP23009 and its buttons; the expander drives
     *        the I/O board's real buttons when one is fitted
     *   3.18 the test card, the overlay and the scanout doubling follow the
     *        live raster rather than the front-panel mode table
     *   3.17 CTRL bit 8 inverts the DAC latch clock, on by default: the
     *        ADV712x samples on the rising edge and our data changes there
     *   3.16 composite sync in the broadcast shape -- half-line serration
     *        through vertical sync and equalising pulses either side, which is
     *        what a television needs and hs ^ vs is not
     *   3.15 CSYNC and AV_DAC on at reset: the A/V board's DAC needs a clock
     *        and a 15 kHz set through SCART needs composite sync
     *   3.14 IO_DIAG fields land where the header says. The concatenation was
     *        28 bits and everything above the LEDs was four bits low
     *   3.13 CTRL bit 7 drives the newer A/V board's DAC: clock, DE and sync
     *        on the pins the older board used for LEDs
     *   3.12 CTRL bit 6 forces the VGA outputs on regardless of VGA_EN, and
     *        IO_DIAG reports that pin -- a board that does not pull it low gives
     *        a black screen with nothing else wrong
     *   3.11 SCANOUT_MAXW at 0xA0: the line buffer width, so software can
     *        refuse a mode too wide for it
     *   3.10 IO_DIAG at 0x9C: the I/O board buttons and LEDs, live and sticky,
     *        so a dead LED can be told from a wrong pin without a scope
     *   3.9  BUS_DIAG carries the PLL's lock and counts START and counter
     *        writes reaching the reconfig slave
     *   3.8  pllbus takes the data on the accept cycle and stops asking.
     *        Holding mgmt_read re-ran the slave's read FSM, whose readdata
     *        alternates between the value and zero while it cycles
     *
     * Bump for a fix as well as a feature. 3.3 shipped twice -- once with the
     * clock select pointing at a clock pin and once without -- and the only way
     * to tell them apart was whether the monitor synced.
     */
    parameter [31:0] VERSION = 32'h0003_001A,
    parameter [11:0] SCANOUT_MAXW = 12'd1280,
    /* Cycles the user button ignores further edges for, covering contact
     * bounce. 20 ms at 50 MHz. A testbench overrides it to something it can
     * wait out. */
    parameter integer BTN_HOLD_CYCLES = 1048575,

    /* Scanout memory geometry, pixels. Zero on purpose: these MUST be passed by
     * whoever instantiates this. A plausible default here once hid a dropped
     * parameter override -- the fabric reported a real-looking 320x240 for a
     * build that was 320x480, and software believed it. Zero makes the same
     * failure announce itself: blitscrt_scanout_geom() refuses, the rect calls
     * refuse with it, and peek says the geometry is unavailable. */
    parameter [15:0] SC_W    = 16'd0,
    parameter [15:0] SC_H    = 16'd0,

    /* What this build can do, reported verbatim. See BLITSCRT_CAP_* in
     * sw/blitscrt_regs.h. Zero is a legitimate answer from an old bitstream and
     * software treats it as "capabilities unknown". */
    parameter [31:0] CAPS    = 32'd0
) (
    // ---- Avalon-MM slave, 50 MHz domain ----
    input  wire        clk,
    input  wire        rst_n,
    input  wire [13:0] address,          // byte address within a 16KB span
    input  wire        read,
    input  wire        write,
    input  wire [31:0] writedata,
    output reg  [31:0] readdata,
    output wire        waitrequest,

    // ---- video domain ----
    input  wire        clk_pix,
    /* Power-on only. vid_rst_n also drops for 256 cycles on every clk_sel
     * change, to hold the video pipeline still while the clock switches -- but
     * the latched timing must not be forgotten just because the clock moved, or
     * claiming timing and then touching the mode select silently reverts the
     * host's mode to the reset defaults. */
    input  wire        vid_cfg_rst_n,
    input  wire        vblank,           // level, high during vertical blanking
    input  wire        field,
    input  wire        pll_locked,
    input  wire        hdmi_configured,

    /* Line-fetcher diagnostics, arriving on the fetcher's own clock. Both are
     * resynchronised here. beats is multi-bit and crosses without a handshake,
     * which is safe enough in practice because it changes once a line and is
     * then stable for tens of thousands of bus clocks -- and it is a
     * diagnostic, not something anything sequences on. */
    /* Bus-side diagnostics, same clock as this block. */
    input  wire        pll_locked_raw,    // reconfig_from_pll[16], the PLL's lock
    input  wire        pll_start_wr,      // a START write reached the slave
    input  wire        pll_cnt_wr,        // an N/M/C write reached the slave
    input  wire        pll_wait,          // the reconfig slave's waitrequest
    input  wire        pll_accept,        // an aperture access completed
    input  wire        bus_stalled,       // the bridge abandoned one

    /*
     * The I/O board pins, so software can see them.
     *
     * The LEDs and buttons do not work with this fabric and do with a MiSTer
     * card, and with no way to read the pins there is no telling a wrong pin
     * assignment from wrong logic from a board that is not connected. These make
     * it a single register read: press a button and watch the sticky bit.
     */
    input  wire [2:0]  io_btn,            // raw, synchronised: reset, osd, user
    input  wire [2:0]  io_led,            // what is being driven at the pins
    input  wire        io_vga_en,         // VGA_EN pin, active low: board present
    input  wire        io_av_present,     // what the design concluded from it
    input  wire        io_mcp_present,    // the I2C expander answered a read
    input  wire [2:0]  io_mcp_btn,        // its buttons: OSD, reset, user
    input  wire        io_btn_user,       // debounced user button, active low

    input  wire        scanout_underrun_tog,
    input  wire [15:0] scanout_beats,

    /* What video_timing is actually being fed, after the ownership mux. Static
     * between mode changes, so resynchronised without a handshake -- and it is
     * a diagnostic, not something anything sequences on. */
    input  wire [11:0] live_hsy, live_hbp, live_hact, live_hfp,
    input  wire [11:0] live_vsy, live_vbp, live_vact, live_vfp,
    input  wire        live_ilace,
    input  wire [1:0]  live_clksel,

    // latched timing, stable in the video domain
    output reg  [11:0] h_sy, h_bp, h_act, h_fp,
    output reg  [11:0] v_sy, v_bp, v_act, v_fp,
    output reg         interlace,
    output reg  [31:0] pclk_khz,

    // control, video domain
    output wire        scanout_en,
    output wire        testcard_en,
    output wire        overlay_en,
    output wire        csync_en,
    output wire        hdmi_en,
    /* Whose timing video_timing obeys. Clear at reset, so the front-panel mode
     * table drives the raster until software asks for the job -- a picture that
     * needs no software is the whole point of the test card path. */
    output wire        hps_timing,
    /* The same bit, bus domain. The clock select cannot be driven from a
     * pixel-domain signal: clk_pix is what the select generates. */
    output wire        hps_timing_bus,
    /* CTRL bit 6: drive the VGA pins whatever VGA_EN says. For a board that does
     * not pull the present pin low. */
    output wire        av_force,
    /* CTRL bit 7: the newer A/V board carries a DAC and needs a clock, DE and
     * sync on the pins the older board used for LEDs. */
    output wire        av_dac,
    /* CTRL bit 8: invert the DAC's latch clock. The ADV712x samples R/G/B on the
     * rising edge, and ours change on that same edge -- half a period of setup
     * rather than none. */
    output wire        av_clk_inv,

    // scanout memory, video domain
    output reg  [31:0] sc_base,
    output reg  [31:0] sc_stride,
    output reg  [2:0]  sc_format,
    output reg  [11:0] sc_w, sc_h,          // scanout geometry, latched on APPLY

    // PLL counters for the reconfiguration block, bus domain
    output reg  [8:0]  pll_m, pll_n, pll_c,
    output reg         pll_apply,        // one bus-clock pulse

    // overlay character buffer write port, bus domain
    output reg         char_we,
    output reg  [12:0] char_addr,
    output reg  [7:0]  char_data,

    /* Scanout memory write port, bus domain. Same shape as the character port
     * above, but addressed by an auto-incrementing pointer rather than by the
     * bus address, because the memory is far too large to map into the window. */
    output reg         sc_we,
    output reg  [19:0] sc_waddr,
    output reg  [15:0] sc_wdata,

    // liveness, video domain: high when the daemon's heartbeat is fresh
    output reg         hps_alive,
    output reg  [1:0]  host_state,
    output reg         host_bound
);

    localparam [31:0] ID_MAGIC = 32'h42435254;   // "BCRT"

    assign waitrequest = 1'b0;                    // single cycle, always ready

    // -------------------------------------------------------------------
    // staged registers, bus domain
    // -------------------------------------------------------------------
    reg [11:0] s_hsy, s_hbp, s_hact, s_hfp;
    reg [11:0] s_vsy, s_vbp, s_vact, s_vfp;
    reg [3:0]  s_flags;
    reg [31:0] s_khz;
    reg [31:0] s_geom;
    reg [31:0] s_sc_base, s_sc_stride;
    reg [2:0]  s_sc_format;
    reg [8:0]  s_ctrl;              /* 6 av_force, 7 av_dac, 8 av_clk_inv */

    reg [19:0] sc_ptr;                    // next scanout write, in pixels
    reg        apply_req;                 // toggles to request a latch
    reg [31:0] hb_count;                  // last heartbeat value written
    reg [1:0]  s_host;                    // last host state written
    /* HOSTSTATE bit 2: the daemon has the UDC bound. Distinct from a host being
     * attached -- bound with no cable is the normal idle state, and the user
     * button clears this without a host ever having been there. */
    reg        s_bound;

    /* Driven in the video domain further down, read by the synchronisers just
     * below. Declared here because some Icarus builds reject use before
     * declaration, and Quartus is happy either way. */
    reg        apply_ack;
    reg        field_toggle;

    /*
     * 0x0000..0x0FFF  registers
     * 0x1000..0x1FFF  altera_pll_reconfig, decoded outside this block
     * 0x2000..0x3FFF  character buffer, one byte per word
     */
    /* The 16 KB window is three regions, and only bit 13 used to be decoded --
     * so 0x1000, the PLL reconfig aperture, landed on register 0x00 and a
     * modeset wrote the M counter into H_SY, the C counter into H_BP and the
     * START word into CTRL. It then read STATUS from VERSION, whose low bits
     * happen to mean "not busy, locked", and reported success.
     *
     *   address[13] = 1        0x2000-0x3FFF  character buffer
     *   address[12] = 1        0x1000-0x1FFF  PLL reconfig, decoded in the top
     *   otherwise              0x0000-0x0FFF  these registers
     */
    wire       is_char = (address[13] == 1'b1);
    wire       is_pll  = (address[13:12] == 2'b01);
    wire [7:0] reg_off = address[7:0];

    // -------------------------------------------------------------------
    // status, brought back across the clock boundary
    // -------------------------------------------------------------------
    reg [1:0] sync_lock, sync_hdmi, sync_field, sync_vblank, sync_ack;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sync_lock <= 2'b00; sync_hdmi <= 2'b00; sync_field <= 2'b00;
            sync_vblank <= 2'b00; sync_ack <= 2'b00;
        end else begin
            sync_lock   <= {sync_lock[0],   pll_locked};
            sync_hdmi   <= {sync_hdmi[0],   hdmi_configured};
            sync_field  <= {sync_field[0],  field};
            sync_vblank <= {sync_vblank[0], vblank};
            sync_ack    <= {sync_ack[0],    apply_ack};
        end
    end

    wire applying = (apply_req != sync_ack[1]);

    /* Underrun events arrive as a toggle so they can be counted rather than
     * merely observed: "once at startup" and "every frame" are different faults
     * and a sticky level cannot tell them apart. Saturating, because wrapping
     * to zero would read as healthy. */
    reg        pll_wait_seen;
    reg [7:0]  pll_accepts;
    reg [3:0]  pll_starts, pll_cnts;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pll_wait_seen <= 1'b0; pll_accepts <= 8'd0;
            pll_starts <= 4'd0; pll_cnts <= 4'd0;
        end else begin
            if (pll_wait) pll_wait_seen <= 1'b1;
            if (pll_accept && pll_accepts != 8'hFF)
                pll_accepts <= pll_accepts + 8'd1;
            if (pll_start_wr && pll_starts != 4'hF) pll_starts <= pll_starts + 4'd1;
            if (pll_cnt_wr   && pll_cnts   != 4'hF) pll_cnts   <= pll_cnts   + 4'd1;
        end
    end

    reg [1:0]  ur_meta;
    reg        ur_seen;
    reg [7:0]  ur_count;
    reg [15:0] beats_meta, beats_sync;
    reg [11:0] lv_hsy, lv_hbp, lv_hact, lv_hfp;
    reg [11:0] lv_vsy, lv_vbp, lv_vact, lv_vfp;
    reg        lv_ilace;
    reg [1:0]  lv_clksel;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ur_meta <= 2'b00; ur_seen <= 1'b0; ur_count <= 8'd0;
            beats_meta <= 16'd0; beats_sync <= 16'd0;
        end else begin
            ur_meta <= {ur_meta[0], scanout_underrun_tog};
            if (ur_meta[1] != ur_seen) begin
                ur_seen <= ur_meta[1];
                if (ur_count != 8'hFF) ur_count <= ur_count + 8'd1;
            end
            beats_meta <= scanout_beats;
            beats_sync <= beats_meta;
            lv_hsy <= live_hsy; lv_hbp <= live_hbp;
            lv_hact <= live_hact; lv_hfp <= live_hfp;
            lv_vsy <= live_vsy; lv_vbp <= live_vbp;
            lv_vact <= live_vact; lv_vfp <= live_vfp;
            lv_ilace <= live_ilace; lv_clksel <= live_clksel;
        end
    end

    reg [31:0] frame_count_bus;
    reg [1:0]  sync_fc;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sync_fc <= 2'b00; frame_count_bus <= 32'd0;
        end else begin
            sync_fc <= {sync_fc[0], field_toggle};
            if (sync_fc[1] != sync_fc[0])
                frame_count_bus <= frame_count_bus + 32'd1;
        end
    end

    /*
     * Sticky button capture for IO_DIAG.
     *
     * The buttons are active low, so a bit is set when its pin is seen low and
     * stays set until IO_DIAG is read. A press lasts a tenth of a second at
     * best and two register reads are seconds apart, so live state alone would
     * essentially never catch one.
     */
    reg [2:0] btn_seen;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            btn_seen <= 3'b000;
        else begin
            btn_seen <= btn_seen | ~io_btn;
            if (read && (address[7:0] == 8'h9C))
                btn_seen <= 3'b000 | ~io_btn;
        end
    end

    /*
     * The user button, latched for software.
     *
     * The daemon polls this and uses it to tear the USB gadget down cleanly --
     * a host that sees an orderly disconnect does not panic the way X11 can when
     * a live output vanishes, and the board reverts to the test card rather than
     * freezing on the last frame.
     *
     * Latched rather than live because a press lasts a tenth of a second and the
     * daemon polls once a frame at best. Cleared by writing 1 to the bit, so a
     * read is free of side effects and two readers cannot steal each other's
     * press.
     */
    reg        btn_user_latch;
    reg        btn_user_d;
    reg [19:0] btn_user_hold;           // BTN_HOLD_CYCLES, ~21 ms at 50 MHz

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            btn_user_latch <= 1'b0;
            btn_user_d     <= 1'b1;
            btn_user_hold  <= 20'd0;
        end else begin
            btn_user_d <= io_btn_user;

            if (btn_user_hold != 20'd0)
                btn_user_hold <= btn_user_hold - 20'd1;

            /*
             * Falling edge only, with a hold-off afterwards.
             *
             * This set on the level at first, which was wrong twice over. A
             * press outlasts the daemon's poll interval, so it cleared the latch
             * and the still-held button set it again -- one press toggling the
             * connection two or three times, which read as the button being
             * unreliable. And a bouncing contact gives several edges besides.
             *
             * The hold-off covers the bounce; the edge covers the hold. A press
             * shorter than 84 ms still registers, since the edge is caught the
             * moment it happens.
             */
            if (btn_user_d && !io_btn_user && (btn_user_hold == 20'd0)) begin
                btn_user_latch <= 1'b1;
                btn_user_hold  <= BTN_HOLD_CYCLES[19:0];
            end else if (write && (address[7:0] == 8'hA4) && writedata[0]) begin
                btn_user_latch <= 1'b0;
            end
        end
    end

    // -------------------------------------------------------------------
    // writes
    // -------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s_hsy <= 12'd60;  s_hbp <= 12'd76;  s_hact <= 12'd640; s_hfp <= 12'd24;
            s_vsy <= 12'd3;   s_vbp <= 12'd16;  s_vact <= 12'd240; s_vfp <= 12'd3;
            s_flags     <= 4'b0001;              // interlaced
            s_khz       <= 32'd12600;
            s_geom      <= {SC_H, SC_W};
            s_sc_base   <= 32'd0;
            s_sc_stride <= 32'd1280;
            s_sc_format <= 3'd0;
            /*
             * testcard, overlay, HDMI, composite sync, and the A/V board DAC.
             * Front panel owns timing until a host takes it.
             *
             * CSYNC and AV_DAC are on at reset because the board this is built
             * for needs both and nothing else works without them: the newer A/V
             * board carries a DAC that latches nothing without a clock, and a
             * 15 kHz set reached through SCART takes sync on the HS pin. Having
             * to write them by hand every boot made a working configuration look
             * like a broken one.
             *
             * A DE10-Nano with the older resistor-ladder board wants AV_DAC
             * clear, since those three pins really are LEDs there. Clearing it
             * is one register write; leaving the default suited to the harder
             * case is the better trade.
             */
            /*
             * 0x09E: testcard, overlay, CSYNC, HDMI, A/V board DAC.
             * Front panel owns timing until a host takes it, and the DAC clock
             * is not inverted -- tested against an ADV7125 board, which latches
             * correctly on the rising edge. CTRL bit 8 inverts it for a board
             * that wants the other phase.
             *
             * Width stated explicitly: this was an 8-bit literal in a 9-bit
             * register, which happened to give the right answer but hid what bit
             * 8 was doing.
             */
            s_ctrl      <= 9'b0_1001_1110;
            pll_m <= 9'd63; pll_n <= 9'd2; pll_c <= 9'd125;
            apply_req <= 1'b0;
            hb_count  <= 32'd0;
            s_host    <= 2'd0;
            s_bound   <= 1'b0;
            pll_apply <= 1'b0;
            char_we   <= 1'b0;
            char_addr <= 13'd0;
            char_data <= 8'd0;
            sc_we     <= 1'b0;
            sc_waddr  <= 20'd0;
            sc_wdata  <= 16'd0;
            sc_ptr    <= 20'd0;
        end else begin
            pll_apply <= 1'b0;
            char_we   <= 1'b0;
            sc_we     <= 1'b0;

            if (write && !is_pll) begin
                if (is_char) begin
                    /* Character buffer. One byte per word, which wastes three
                     * quarters of the window and keeps addressing trivial from
                     * software. 8192 entries fit the 0x2000 span exactly. */
                    char_we   <= 1'b1;
                    char_addr <= address[12:0];
                    char_data <= writedata[7:0];
                end else begin
                    case (reg_off)
                        8'h08: s_ctrl      <= writedata[8:0];
                        8'h10: s_hsy       <= writedata[11:0];
                        8'h14: s_hbp       <= writedata[11:0];
                        8'h18: s_hact      <= writedata[11:0];
                        8'h1C: s_hfp       <= writedata[11:0];
                        8'h20: s_vsy       <= writedata[11:0];
                        8'h24: s_vbp       <= writedata[11:0];
                        8'h28: s_vact      <= writedata[11:0];
                        8'h2C: s_vfp       <= writedata[11:0];
                        8'h30: s_flags     <= writedata[3:0];
                        8'h34: pll_m       <= writedata[8:0];
                        8'h38: pll_n       <= writedata[8:0];
                        8'h3C: pll_c       <= writedata[8:0];
                        8'h40: s_khz       <= writedata;
                        8'h64: hb_count    <= writedata;       // heartbeat
                        8'h68: begin s_host <= writedata[1:0];
                                     s_bound <= writedata[2]; end
                        8'h44: begin
                            /* APPLY. Toggle the request; the video side
                             * latches at the next vblank. */
                            apply_req <= ~apply_req;
                            pll_apply <= 1'b1;
                        end
                        8'h50: s_sc_base   <= writedata;
                        8'h54: s_sc_stride <= writedata;
                        8'h58: s_sc_format <= writedata[2:0];
                        8'h78: s_geom      <= writedata;
                        8'h70: sc_ptr       <= writedata[19:0];
                        8'h74: begin
                            /* One pixel, then the pointer follows. Streaming a
                             * run of pixels is therefore one bus write each with
                             * no address traffic between them. */
                            sc_we    <= 1'b1;
                            sc_waddr <= sc_ptr;
                            sc_wdata <= writedata[15:0];
                            sc_ptr   <= sc_ptr + 20'd1;
                        end
                        default: ;
                    endcase
                end
            end
        end
    end

    // -------------------------------------------------------------------
    // reads
    // -------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) readdata <= 32'd0;
        else if (read) begin
            case (reg_off)
                8'h00: readdata <= ID_MAGIC;
                8'h04: readdata <= VERSION;
                8'h08: readdata <= {23'd0, s_ctrl};
                8'h0C: readdata <= {26'd0, (ur_count != 8'd0), applying,
                                    sync_vblank[1], sync_field[1],
                                    sync_hdmi[1], sync_lock[1]};
                8'h10: readdata <= {20'd0, s_hsy};
                8'h14: readdata <= {20'd0, s_hbp};
                8'h18: readdata <= {20'd0, s_hact};
                8'h1C: readdata <= {20'd0, s_hfp};
                8'h20: readdata <= {20'd0, s_vsy};
                8'h24: readdata <= {20'd0, s_vbp};
                8'h28: readdata <= {20'd0, s_vact};
                8'h2C: readdata <= {20'd0, s_vfp};
                8'h30: readdata <= {28'd0, s_flags};
                8'h34: readdata <= {23'd0, pll_m};
                8'h38: readdata <= {23'd0, pll_n};
                8'h3C: readdata <= {23'd0, pll_c};
                8'h40: readdata <= s_khz;
                8'h50: readdata <= s_sc_base;
                8'h54: readdata <= s_sc_stride;
                8'h58: readdata <= {29'd0, s_sc_format};
                8'h60: readdata <= frame_count_bus;
                8'h68: readdata <= {29'd0, s_bound, s_host};
                8'h70: readdata <= {12'd0, sc_ptr};
                8'h78: readdata <= s_geom;
                8'h7C: readdata <= CAPS;
                /* What the scanout line buffer can hold, in pixels. Software
                 * refuses wider modes rather than scanning out wrapped lines. */
                8'hA0: readdata <= {20'd0, SCANOUT_MAXW[11:0]};
                /* BTN_EVENT: bit 0 set once the user button has been pressed.
                 * Write 1 to clear. */
                8'hA4: readdata <= {31'd0, btn_user_latch};
                8'h80: readdata <= {8'd0, ur_count, beats_sync};
                8'h84: readdata <= {4'd0, lv_hbp,  4'd0, lv_hsy};
                8'h88: readdata <= {4'd0, lv_hfp,  4'd0, lv_hact};
                8'h8C: readdata <= {4'd0, lv_vbp,  4'd0, lv_vsy};
                8'h90: readdata <= {4'd0, lv_vfp,  4'd0, lv_vact};
                8'h94: readdata <= {28'd0, lv_clksel, hps_timing_bus, lv_ilace};
                8'h98: readdata <= {pll_cnts, pll_starts, pll_accepts,
                                    4'd0, pll_locked_raw, bus_stalled,
                                    pll_wait_seen, pll_wait};
                /*
                 * IO_DIAG. Live pin state in the low bits, and a sticky record
                 * of any button seen low since the last read in bits 8..10 --
                 * a button press is far shorter than the gap between two peeks,
                 * so live alone would almost never catch one.
                 */
                /*
                 * 32 bits exactly. The first version of this concatenation came
                 * to 28 and Verilog zero-extended it on the left, so every field
                 * above the LEDs sat four bits below where the header said --
                 * and the diagnostic confidently reported the opposite of the
                 * truth about whether the VGA pins were driven.
                 *
                 *   [2:0]   buttons, live      [6:4]   buttons, sticky
                 *   [10:8]  LED pins           [16]    VGA_EN pin
                 *   [17]    av_present
                 */
                /*
                 *   [2:0]   pad buttons, live      [6:4]   pad buttons, sticky
                 *   [10:8]  LED pins               [16]    VGA_EN pin
                 *   [17]    av_present             [20]    MCP23009 answered
                 *   [23:21] its buttons, 1 = pressed
                 */
                8'h9C: readdata <= {8'd0,                   /* 31:24 */
                                    io_mcp_btn,             /* 23:21 */
                                    io_mcp_present,         /* 20    */
                                    2'd0,                   /* 19:18 */
                                    io_av_present,          /* 17    */
                                    io_vga_en,              /* 16    */
                                    5'd0, io_led,           /* 15:8  */
                                    1'b0, btn_seen,         /* 7:4   */
                                    1'b0, io_btn};          /* 3:0   */
                default: readdata <= 32'd0;
            endcase
        end
    end

    // -------------------------------------------------------------------
    // video domain: latch the staged set on a vblank after a request
    // -------------------------------------------------------------------
    reg [1:0] sync_req;
    reg       field_d;

    /*
     * Heartbeat watchdog. Bring the bus-domain count across, watch it for
     * change, and count fields since it last moved. Past the timeout the HPS
     * is declared down. host_state crosses the same way; it only means anything
     * while hps_alive holds.
     */
    reg [31:0] hb_vid;                   // heartbeat resynced to pixel clock
    reg [31:0] hb_at_field;              // its value at the last field edge
    reg [1:0]  host_meta;                // host_state synchroniser
    reg [7:0]  hb_stale;                 // fields since it last changed
    localparam [7:0] HB_TIMEOUT = 8'd90; // ~1.5 s of 60 Hz fields

    /* Reset on vid_cfg_rst_n, which is power-on only, rather than vid_rst_n.
     * vid_rst_n also drops for 256 cycles on every clk_sel change so the video
     * pipeline is held still while the clock switches -- but the configuration
     * this block latches must not be forgotten just because the clock moved.
     * Resetting it there means claiming timing and then touching the mode
     * select silently reverts the host's mode to the 480i defaults, with
     * nothing to say it happened. */
    always @(posedge clk_pix or negedge vid_cfg_rst_n) begin
        if (!vid_cfg_rst_n) begin
            sync_req  <= 2'b00;
            apply_ack <= 1'b0;
            field_toggle <= 1'b0;
            field_d   <= 1'b0;
            hb_vid <= 32'd0; hb_at_field <= 32'd0;
            hb_stale <= HB_TIMEOUT; hps_alive <= 1'b0;
            host_meta <= 2'd0; host_state <= 2'd0; host_bound <= 1'b0;

            h_sy <= 12'd60; h_bp <= 12'd76; h_act <= 12'd640; h_fp <= 12'd24;
            v_sy <= 12'd3;  v_bp <= 12'd16; v_act <= 12'd240; v_fp <= 12'd3;
            interlace <= 1'b1;
            pclk_khz  <= 32'd12600;
            sc_base   <= 32'd0;
            sc_stride <= 32'd1280;
            sc_format <= 3'd0;
            /* Reset to the build's own geometry so a picture is possible before
             * software writes anything. Left undefined these come up zero, the
             * bounds clamp in scanout.v rejects every pixel, and the screen is
             * black -- which looks exactly like the memory path having failed. */
            sc_w      <= SC_W[11:0];
            sc_h      <= SC_H[11:0];
        end else begin
            sync_req  <= {sync_req[0],  apply_req};

            /* count fields for the bus-side frame counter */
            field_d <= field;
            if (field != field_d) field_toggle <= ~field_toggle;

            /* Resync every cycle, but only compare across field boundaries:
             * snapshot the value at each field edge and see if it moved since
             * the previous field. */
            hb_vid <= hb_count;
            host_meta  <= s_host;
            host_bound <= s_bound;
            host_state <= host_meta;
            if (field != field_d) begin           // once per field
                hb_at_field <= hb_vid;
                if (hb_vid != hb_at_field) begin
                    hb_stale  <= 8'd0;
                    hps_alive <= 1'b1;
                end else if (hb_stale < HB_TIMEOUT) begin
                    hb_stale <= hb_stale + 8'd1;
                end else begin
                    hps_alive <= 1'b0;            // heartbeat lost
                end
            end

            if (vblank) begin
                if (sync_req[1] != apply_ack) begin
                    h_sy <= s_hsy; h_bp <= s_hbp; h_act <= s_hact; h_fp <= s_hfp;
                    v_sy <= s_vsy; v_bp <= s_vbp; v_act <= s_vact; v_fp <= s_vfp;
                    interlace <= s_flags[0];
                    pclk_khz  <= s_khz;
                    sc_base   <= s_sc_base;
                    sc_stride <= s_sc_stride;
                    sc_format <= s_sc_format;
                    sc_w      <= s_geom[11:0];
                    sc_h      <= s_geom[27:16];
                    apply_ack <= sync_req[1];
                end
            end
        end
    end

    /* Control bits are static from the video side's point of view; a two-flop
     * synchroniser each is enough. */
    reg [5:0] ctrl_meta, ctrl_vid;
    always @(posedge clk_pix or negedge vid_cfg_rst_n) begin
        if (!vid_cfg_rst_n) begin ctrl_meta <= 6'b010110; ctrl_vid <= 6'b010110; end
        else begin ctrl_meta <= s_ctrl; ctrl_vid <= ctrl_meta; end
    end

    assign scanout_en  = ctrl_vid[0];
    assign testcard_en = ctrl_vid[1];
    assign overlay_en  = ctrl_vid[2];
    assign csync_en    = ctrl_vid[3];
    assign hdmi_en     = ctrl_vid[4];
    assign hps_timing  = ctrl_vid[5];
    assign hps_timing_bus = s_ctrl[5];
    assign av_force      = s_ctrl[6];
    assign av_dac        = s_ctrl[7];
    assign av_clk_inv    = s_ctrl[8];

endmodule

`default_nettype wire
