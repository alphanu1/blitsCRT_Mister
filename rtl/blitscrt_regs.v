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
     *
     * Bump for a fix as well as a feature. 3.3 shipped twice -- once with the
     * clock select pointing at a clock pin and once without -- and the only way
     * to tell them apart was whether the monitor synced.
     */
    parameter [31:0] VERSION = 32'h0003_0006,

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
    input  wire        pll_wait,          // the reconfig slave's waitrequest
    input  wire        pll_accept,        // an aperture access completed
    input  wire        bus_stalled,       // the bridge abandoned one

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
    output reg  [1:0]  host_state
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
    reg [5:0]  s_ctrl;

    reg [19:0] sc_ptr;                    // next scanout write, in pixels
    reg        apply_req;                 // toggles to request a latch
    reg [31:0] hb_count;                  // last heartbeat value written
    reg [1:0]  s_host;                    // last host state written

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
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pll_wait_seen <= 1'b0; pll_accepts <= 8'd0;
        end else begin
            if (pll_wait) pll_wait_seen <= 1'b1;
            if (pll_accept && pll_accepts != 8'hFF)
                pll_accepts <= pll_accepts + 8'd1;
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
            s_ctrl      <= 6'b010110;            // testcard, overlay, hdmi on;
                                                 // front panel owns timing
            pll_m <= 9'd63; pll_n <= 9'd2; pll_c <= 9'd125;
            apply_req <= 1'b0;
            hb_count  <= 32'd0;
            s_host    <= 2'd0;
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
                        8'h08: s_ctrl      <= writedata[5:0];
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
                        8'h68: s_host      <= writedata[1:0];  // host state
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
                8'h08: readdata <= {26'd0, s_ctrl};
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
                8'h68: readdata <= {30'd0, s_host};
                8'h70: readdata <= {12'd0, sc_ptr};
                8'h78: readdata <= s_geom;
                8'h7C: readdata <= CAPS;
                8'h80: readdata <= {8'd0, ur_count, beats_sync};
                8'h84: readdata <= {4'd0, lv_hbp,  4'd0, lv_hsy};
                8'h88: readdata <= {4'd0, lv_hfp,  4'd0, lv_hact};
                8'h8C: readdata <= {4'd0, lv_vbp,  4'd0, lv_vsy};
                8'h90: readdata <= {4'd0, lv_vfp,  4'd0, lv_vact};
                8'h94: readdata <= {28'd0, lv_clksel, hps_timing_bus, lv_ilace};
                8'h98: readdata <= {16'd0, pll_accepts,
                                    5'd0, bus_stalled, pll_wait_seen, pll_wait};
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
            host_meta <= 2'd0; host_state <= 2'd0;

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

endmodule

`default_nettype wire
