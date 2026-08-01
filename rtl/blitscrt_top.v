// SPDX-License-Identifier: GPL-2.0-or-later
// -----------------------------------------------------------------------------
// blitscrt_top.v -- blitsCRT_Mister top level
//
// Drives the MiSTer analog A/V board and HDMI from one pixel stream. Two pixel
// sources feed the same point in the pipeline: the colour-bar test card, which
// needs no software at all, and scanout memory, read by scanout.v out of
// on-chip block RAM. CTRL picks between them and comes up on the test card, so
// a picture exists before any software runs and survives anything above it
// crashing later.
//
// Three modes, selected at runtime:
//
//   0  640x240p60  12.600 MHz  15.750 kHz  60.11 Hz   15kHz CRT
//   1  640x480i60  12.600 MHz  15.750 kHz  60.00 Hz   15kHz CRT, standard 480i
//
// Modes 0 and 1 share a clock, so switching between them never touches the
// PLL. altclkctrl accepts PLL outputs on only two of its four inputs, which is
// what limits the design to two pixel clocks.
//
// One mode, 640x480i60. It is a standard SD format that HDMI sinks accept and a
// 15kHz CRT takes as readily as 240p, so it is the mode most likely to produce a
// picture on whatever is plugged in -- and with nothing to choose between, the
// front-panel buttons are free for the overlay and the soft disconnect.
//
// Sync is driven active low, which is what 15kHz RGB and SCART expect. CTRL
// bit 3 puts composite sync on the HS pin for a SCART lead, and is set at reset.
// -----------------------------------------------------------------------------

`timescale 1ns/1ps
`default_nettype none

module blitscrt_top #(
    /*
     * Widest line the scanout buffer holds, in pixels.
     *
     * Must cover the widest advertised mode: Switchres generates 1280-wide
     * super-resolution timings at 15 kHz, so this is 1280 rather than the 1024
     * it began at. Reported to software in SCANOUT_MAXW, so the daemon refuses
     * modes the buffer cannot hold rather than scanning out wrapped lines --
     * which looks like two pictures side by side and is not obviously a buffer
     * problem when it happens.
     */
    parameter integer SCANOUT_MAXW = 1280,

    parameter integer CSYNC        = 0,
    parameter integer DEFAULT_VGA  = 1,   // analog board fitted
    parameter integer DEFAULT_HDMI = 1,   // HDMI only; 2 for 31kHz VGA timing
    parameter integer FORCE_MODE   = -1,  // >= 0 pins the mode and ignores detect
    parameter integer WITH_HPS     = 1,   // 0 builds a bare fabric, no HPS

    /*
     * On-chip scanout memory, in pixels, one pixel per 16-bit word. 320x480 is
     * 2.46 Mbit of the 5.57 Mbit of M10K on this device -- see rtl/scanout_ram.v
     * for what the other geometries cost.
     *
     * 480 lines rather than 240 because 480i has to be genuinely interlaced.
     * video_timing hands over the field-interleaved frame line, so 480 distinct
     * lines in memory means the raster reads 0,2,4.. on one field and 1,3,5.. on
     * the other: full vertical resolution, both fields carrying different
     * content. Fitting 240 and line-doubling would show 240 lines twice, which
     * is 240p wearing a 480i timing.
     *
     * 640x480 at 16 bits is 4.92 Mbit, 86% of the M10K on the device, and will
     * not fit alongside the overlay. So the horizontal half is what gives: 320
     * wide, pixel-doubled to fill the 640 active area. Full horizontal *and*
     * vertical at once is what M3c and DDR3 are for -- 640x480 RGB565 is 600 KB,
     * which is nothing off-chip and impossible on it.
     */
    parameter integer SCANOUT_W         = 320,
    parameter integer SCANOUT_H         = 480,

    /* "ONCHIP" or "DDR3" -- see the scanout block below. ONCHIP is what builds
     * today; DDR3 needs the f2sdram port wired from a Platform Designer system,
     * and the ports for it are on this module either way so the two builds have
     * the same footprint. */
    /* Defaulted here rather than left to the .qsf. A set_parameter override that
     * Quartus quietly declines leaves a build that looks fine and behaves as the
     * other configuration -- which has already cost a day once on SCANOUT_H. The
     * RTL default always applies; the .qsf line is belt and braces. */
    parameter         SCANOUT_SRC       = "DDR3",
    parameter integer F2SDRAM_DW        = 64,

    /* Only ever 0 for lint. A DDR3 build wants the real sysmem_lite, and having
     * this as a second thing to remember to flip is how a build ends up with the
     * fetcher talking to a stub that accepts every read and answers none --
     * which looks exactly like a black screen from six other causes. Icarus has
     * no Intel HPS primitives, so sim/lint_ddr3.v passes 0 and nothing else
     * should. */
    parameter integer WITH_QSYS         = 1
) (

    input  wire        FPGA_CLK1_50,

    // analog A/V board
    input  wire        VGA_EN,          // active low: board present
    output wire [5:0]  VGA_R,
    output wire [5:0]  VGA_G,
    output wire [5:0]  VGA_B,
    output wire        VGA_HS,
    output wire        VGA_VS,

    // HDMI -- ADV7513 transmitter, MiSTer Direct Video
    output wire        HDMI_TX_CLK,
    output wire [23:0] HDMI_TX_D,
    output wire        HDMI_TX_DE,
    output wire        HDMI_TX_HS,
    output wire        HDMI_TX_VS,
    input  wire        HDMI_TX_INT,
    output wire        HDMI_I2C_SCL,
    inout  wire        HDMI_I2C_SDA,

    // I/O board
    input  wire        BTN_RESET,       // active low
    input  wire        BTN_OSD,
    input  wire        BTN_USER,

    /*
     * I2C to the I/O board's MCP23009 expander, which is where the buttons and
     * LEDs really are on a board fitted with the newer A/V board -- BTN_* above
     * carry nothing there, and LED_* carry video for the DAC.
     *
     * inout because the bus is open drain: the master drives low and releases
     * high, and reads what the slave does with the line in between.
     */
    inout  wire        IO_SCL,
    inout  wire        IO_SDA,
    output wire        LED_POWER,
    output wire        LED_HDD,
    output wire        LED_USER
);


    /* Driven further down, referenced by the mode table just below. Declared
     * here because some Icarus builds reject use before declaration. Quartus
     * accepts either, so this only shows up on someone else's machine. */
    wire hdmi_scl, hdmi_sda_o, hdmi_configured, hdmi_nack;
    /* Driven by the MCP23009 block further down; declared here because the
     * button mux above reads them. */
    wire       mcp_present;
    wire [2:0] mcp_btn;                 // OSD, reset, user -- 1 while pressed
    wire rst_n;                       // video-domain reset, driven below

    /*
     * Everything blitscrt_regs drives. The register block is instantiated well
     * below, but the overlay, the scanout mux and the pad drivers all read these
     * before that point, so they are declared once here rather than scattered.
     *
     * Reset defaults reproduce M1/M2 behaviour exactly (s_ctrl = 5'b10110): test
     * card and overlay on, HDMI on, scanout off. Wiring the control bits up
     * therefore changes nothing until the daemon writes CTRL.
     */
    wire [11:0] r_hsy, r_hbp, r_hact, r_hfp, r_vsy, r_vbp, r_vact, r_vfp;
    wire        r_interlace;
    wire [31:0] r_pclk_khz, r_sc_base, r_sc_stride;
    wire [2:0]  r_sc_format;
    wire        r_scanout_en, r_testcard_en, r_overlay_en, r_csync_en, r_hdmi_en;
    wire        r_av_force;      // CTRL bit 6: drive VGA whatever VGA_EN says
    wire        r_av_dac;        // CTRL bit 7: newer A/V board, clock the DAC
    wire        r_av_clk_inv;    // CTRL bit 8: invert that clock
    wire [8:0]  r_pll_m, r_pll_n, r_pll_c;
    wire        r_pll_apply, r_char_we;
    wire [12:0] r_char_addr;
    wire [7:0]  r_char_data;
    wire [11:0] r_sc_w, r_sc_h;
    wire        r_sc_underrun_tog;
    wire [15:0] r_sc_beats;
    wire        r_sc_we;
    wire [19:0] r_sc_waddr;
    wire [15:0] r_sc_wdata;
    wire        hps_alive;
    /* Read back over the bus and used by the daemon for the overlay text.
     * Nothing in the fabric consumes it since the LEDs moved to host_bound. */
    wire [1:0]  host_state;
    wire        host_bound;   // the daemon has the UDC bound

    // ---------------- mode selection, in the 50 MHz domain ----------------
    reg [3:0] rst50_sr = 4'b0000;
    /*
     * Buttons, from whichever source is fitted.
     *
     * On a board with the newer A/V board the BTN_* pads carry nothing: the real
     * buttons are behind the MCP23009, instantiated further down. It reports 1
     * while pressed; the pads are active low, so the expander's value inverts
     * and everything downstream keeps the active-low convention it already had.
     *
     * mcp_present is low until a read has been acknowledged, so a board without
     * an expander falls through to the pads -- correct for a DE10-Nano with the
     * older I/O board, and correct during the first few milliseconds after
     * power-on before the expander has answered.
     */
    /*
     * The expander reports {GP5, GP4, GP3} = {OSD, reset, user}, so bit 0 is
     * user and bit 2 is OSD. These were the other way round at first, which put
     * the overlay toggle on the OSD button and the mode cycle on the user
     * button -- visible immediately on hardware, and the mapping to check first
     * if a button does the wrong thing.
     */
    wire btn_reset_eff = mcp_present ? ~mcp_btn[1] : BTN_RESET;
    wire btn_osd_eff   = mcp_present ? ~mcp_btn[2] : BTN_OSD;
    wire btn_user_eff  = mcp_present ? ~mcp_btn[0] : BTN_USER;

    always @(posedge FPGA_CLK1_50) rst50_sr <= {rst50_sr[2:0], btn_reset_eff};
    wire rst50_n = rst50_sr[3];

    /*
     * The analog board pulls VGA_EN low to say it is there, and every VGA output
     * is tri-stated when it is not -- so a board that does not pull it low gives
     * a black screen with nothing else wrong.
     *
     * CTRL bit 6 forces it on. An integrated A/V board may have nothing to
     * detect, since it is always present, and there is no way to tell that apart
     * from a genuinely absent board except by trying. IO_DIAG reports both the
     * raw pin and the conclusion.
     */
    wire av_present = ~VGA_EN | r_av_force;

    // Debounce BTN_OSD. The buttons are active low with weak pull-ups.
    reg [19:0] db_cnt;
    reg        btn_osd_s, btn_osd_clean;
    always @(posedge FPGA_CLK1_50 or negedge rst50_n) begin
        if (!rst50_n) begin
            db_cnt <= 20'd0; btn_osd_s <= 1'b1; btn_osd_clean <= 1'b1;
        end else begin
            btn_osd_s <= btn_osd_eff;
            if (btn_osd_s != btn_osd_clean) begin
                db_cnt <= db_cnt + 20'd1;
                if (db_cnt == 20'hFFFFF) btn_osd_clean <= btn_osd_s;
            end else begin
                db_cnt <= 20'd0;
            end
        end
    end

    wire [11:0] t_hsy, t_hbp, t_hact, t_hfp;
    wire [11:0] t_vsy, t_vbp, t_vact, t_vfp;
    wire        t_ilace;
    wire [1:0]  clk_sel, cur_mode;

    /* Driven by blitscrt_regs well below, but read by the clock select and the
     * raster mux above it. check-decl enforces declaring before use. */
    wire        r_hps_timing, r_hps_timing_bus;

    wire [13:0] reg_address;
    wire        reg_read, reg_write;
    wire [31:0] reg_writedata, reg_readdata;
    wire        reg_waitrequest;
    wire        bus_stalled;

    /* When the host owns timing it also owns the pixel clock: the reconfig block
     * retunes the PLL, so the select is pinned to the full-rate output rather
     * than following the mode table between the two.
     *
     * CLK_FULL is 2, not 0. altclkctrl on Cyclone V accepts PLL outputs only on
     * inclk[2] and inclk[3] -- slots 0 and 1 must be real clock pins, so
     * pll_modes puts the reference there. Pinning to 0 does not select c0, it
     * selects FPGA_CLK1_50, and the raster then runs 640x480i timing off a
     * 50 MHz clock at roughly 62 kHz of line rate. Which is exactly what
     * happened the first time this bit was set.
     *
     * Taken from the bus-domain copy of the ownership bit, because this feeds
     * the mux that generates clk_pix and a pixel-domain signal would be
     * selecting the clock that clocks it. */
    localparam [1:0] CLK_FULL = 2'd2;      // must match mode_table's CLK_12M6
    wire [1:0]  clk_sel_eff = r_hps_timing_bus ? CLK_FULL : clk_sel;
    wire [31:0] cur_khz;

    mode_table #(
        .DEFAULT_VGA(DEFAULT_VGA),
        .DEFAULT_HDMI(DEFAULT_HDMI),
        .FORCE_MODE(FORCE_MODE)
    ) u_modes (
        .clk(FPGA_CLK1_50), .rst_n(rst50_n),
        .av_present(av_present),
        .hdmi_hpd(hdmi_configured),   // transmitter acking I2C implies a sink
        .btn_cycle(btn_osd_clean),
        .mode(cur_mode),
        .h_sy(t_hsy), .h_bp(t_hbp), .h_act(t_hact), .h_fp(t_hfp),
        .v_sy(t_vsy), .v_bp(t_vbp), .v_act(t_vact), .v_fp(t_vfp),
        .interlace(t_ilace), .clk_sel(clk_sel), .pclk_khz(cur_khz)
    );

    // ---------------- clocking and reset ----------------
    wire clk_pix, pll_locked;

    wire [63:0] reconfig_to_pll, reconfig_from_pll;

    /* The PLL reconfig aperture at 0x1000, decoded here and nowhere else. The
     * register block declines anything with address[12] set; without that these
     * writes landed on H_SY, H_BP and CTRL, and the status poll read VERSION
     * and took its low bits for "not busy, locked". */
    wire        avm_is_pll = (reg_address[13:12] == 2'b01);
    wire [31:0] pll_avs_readdata;
    wire        pll_avs_waitrequest;
    wire [5:0]  pll_avs_address;
    wire        pll_avs_read, pll_avs_write;
    wire [31:0] pll_avs_writedata;
    wire [31:0] pll_rdata;
    wire        pll_stall;

    /* The bridge drops avm_read before sampling readdata, which a registered
     * slave survives and a combinational one does not -- see blitscrt_pllbus.v.
     * The adapter holds the request until the data has been taken. */
    blitscrt_pllbus u_pllbus (
        .clk(FPGA_CLK1_50), .rst_n(rst50_n),
        .sel(avm_is_pll), .read(reg_read), .write(reg_write),
        .address(reg_address[7:2]), .writedata(reg_writedata),
        .readdata(pll_rdata), .waitrequest(pll_stall),
        .m_read(pll_avs_read), .m_write(pll_avs_write),
        .m_address(pll_avs_address), .m_writedata(pll_avs_writedata),
        .m_readdata(pll_avs_readdata), .m_waitrequest(pll_avs_waitrequest)
    );

    /*
     * Both slaves are read latency 1 and the mux into the bridge is
     * combinational for both. There used to be an extra flop on this path,
     * added to "give it the same shape" as the register slave -- but that slave
     * already registers its readdata internally, so the flop made this path
     * latency 2 while the bridge samples at 1. Every read came back one cycle
     * early, which on an idle bus is zero: the reconfig block looked absent
     * while its writes were plainly working, because writes are never read back.
     */
    wire [31:0] regs_readdata;
    wire        regs_waitrequest;
    /* These feed the bridge. Named reg_* deliberately: an earlier edit left them
     * as avm_*, which nothing else referenced -- so the mux drove two dead wires
     * and the bridge's readback and waitrequest had no driver at all. Quartus
     * ties an undriven wire to zero, so every register read came back 0x00000000
     * and the strobe echo never appeared: the fabric looked absent. */
    assign reg_readdata    = avm_is_pll ? pll_rdata : regs_readdata;
    assign reg_waitrequest = avm_is_pll ? pll_stall : regs_waitrequest;


    pll_modes u_pll (
        .refclk  (FPGA_CLK1_50),
        .rst     (~rst50_n),
        .sel     (clk_sel_eff),
        .reconfig_to_pll   (reconfig_to_pll),
        .reconfig_from_pll (reconfig_from_pll),
        .clk_pix (clk_pix),
        .locked  (pll_locked)
    );

    /*
     * altera_pll_reconfig on the lightweight bridge at the 0x1000 window. The
     * register slave decodes 0x0000 and 0x2000 and leaves this range alone;
     * software drives it directly through sw/pll_reconfig.c.
     *
     * The Avalon master side is wired when the HPS bridge lands. Until then the
     * reconfig block sits idle and the PLL runs at its power-on frequencies,
     * which is exactly M1/early-M2 behaviour.
     */
    pll_reconfig u_pll_reconfig (
        .mgmt_clk         (FPGA_CLK1_50),
        .mgmt_reset       (~rst50_n),
        .mgmt_address     (pll_avs_address),
        .mgmt_read        (pll_avs_read),
        .mgmt_readdata    (pll_avs_readdata),
        .mgmt_write       (pll_avs_write),
        .mgmt_writedata   (pll_avs_writedata),
        .mgmt_waitrequest (pll_avs_waitrequest),
        .reconfig_to_pll  (reconfig_to_pll),
        .reconfig_from_pll(reconfig_from_pll)
    );

    // Hold the video pipeline in reset across a mode change. The clock is
    // switching and the timing inputs move with it, so nothing downstream
    // should be running while that happens.
    reg [1:0] sel_d;
    reg [7:0] mode_hold;
    always @(posedge FPGA_CLK1_50 or negedge rst50_n) begin
        if (!rst50_n) begin
            sel_d <= 2'd0; mode_hold <= 8'hFF;
        end else begin
            sel_d <= clk_sel_eff;
            if (sel_d != clk_sel_eff) mode_hold <= 8'hFF;
            else if (mode_hold)   mode_hold <= mode_hold - 8'd1;
        end
    end

    reg [3:0] rst_sr = 4'b0000;
    always @(posedge clk_pix or negedge pll_locked) begin
        if (!pll_locked) rst_sr <= 4'b0000;
        else             rst_sr <= {rst_sr[2:0], 1'b1};
    end
    assign rst_n = rst_sr[3] & btn_reset_eff & ~(|mode_hold);

    // ---------------- timing ----------------
    wire        hs, vs, cs, de;
    wire [11:0] hcnt, lcnt, xpos, ypos;
    wire        field, vblank, field_start;

    /*
     * Who owns the raster. CTRL's HPS_TIMING bit picks between the front-panel
     * mode table and the timing the daemon applied, and it is clear at reset --
     * so the fabric produces a picture with no software, which is the whole
     * reason the mode table exists. Software claims the job explicitly rather
     * than taking it by turning up.
     *
     * The mode table stays the way back: clear the bit and the raster returns
     * to a known-good mode without a reflash, which is worth having when a host
     * has just asked for something the display cannot show.
     */
    wire        own_hps = r_hps_timing;
    wire [11:0] v_hsy   = own_hps ? r_hsy  : t_hsy;
    wire [11:0] v_hbp   = own_hps ? r_hbp  : t_hbp;
    wire [11:0] v_hact  = own_hps ? r_hact : t_hact;
    wire [11:0] v_hfp   = own_hps ? r_hfp  : t_hfp;
    wire [11:0] v_vsy   = own_hps ? r_vsy  : t_vsy;
    wire [11:0] v_vbp   = own_hps ? r_vbp  : t_vbp;
    wire [11:0] v_vact  = own_hps ? r_vact : t_vact;
    wire [11:0] v_vfp   = own_hps ? r_vfp  : t_vfp;
    wire        v_ilace = own_hps ? r_interlace : t_ilace;

    video_timing u_timing (
        .clk(clk_pix), .rst_n(rst_n),
        .h_sy(v_hsy), .h_bp(v_hbp), .h_act(v_hact), .h_fp(v_hfp),
        .v_sy(v_vsy), .v_bp(v_vbp), .v_act(v_vact), .v_fp(v_vfp),
        .interlace(v_ilace),
        .hs(hs), .vs(vs), .cs(cs), .de(de),
        .hcnt(hcnt), .lcnt(lcnt), .xpos(xpos), .ypos(ypos),
        .field(field), .vblank(vblank), .field_start(field_start)
    );

    // ---------------- test card ----------------
    wire [5:0] tc_r, tc_g, tc_b;

    /*
     * The active area actually being scanned, from the same mux the timing
     * generator uses.
     *
     * These read t_hact/t_vact/t_ilace directly until it was noticed on a CRT:
     * the front-panel table's geometry rather than the host's. With a host
     * driving 320x240 the raster ran 320 wide while the test card was drawn 640
     * wide, so half the bars filled the screen -- and hdouble below compared the
     * table's 640 against the host's 320 and doubled when it should not have.
     * Every mode narrower than the table's own looked broken; every mode the
     * same width looked fine, which is why 640x480 always worked.
     */
    wire [11:0] frame_h = v_hact;
    wire [11:0] frame_v = v_ilace ? {v_vact[10:0], 1'b0} : v_vact;

    testcard u_card (
        .clk(clk_pix), .rst_n(rst_n),
        .h_act(frame_h), .v_act(frame_v),
        .de(de), .xpos(xpos), .ypos(ypos),
        .r(tc_r), .g(tc_g), .b(tc_b)
    );

    // testcard registers its output, so de must be delayed one clock to match
    reg de_card;
    reg [11:0] x_card, y_card;
    always @(posedge clk_pix or negedge rst_n) begin
        if (!rst_n) begin
            de_card <= 1'b0; x_card <= 12'd0; y_card <= 12'd0;
        end else begin
            de_card <= de; x_card <= xpos; y_card <= ypos;
        end
    end

    // ---------------- scanout ----------------
    //
    // The scanout path, alongside the test card and muxed into the same
    // point in the pipeline. scanout costs exactly one clock from xpos to
    // r/g/b, which is what the test card costs, so the mux is transparent and
    // PIPE below stays at 5. sim/tb_scanout.v holds that to account.
    //
    // Where the pixels live is a parameter, in the same spirit as BRIDGE on
    // blitscrt_bridge: one place knows, and changing it does not touch anything
    // downstream. scanout.v is identical either way -- it takes a pixel word and
    // a position and knows nothing about where memory is.
    //
    //   "ONCHIP"  M3a/M3b. A whole picture in M10K, written a pixel at a time
    //             over gp, preloaded with gen_scanout_test.py's pattern so it
    //             works with no software at all. Capped by block RAM: 320x480
    //             is 43% of the device and 640x480 will not fit.
    //
    //   "DDR3"    M3c. One line at a time out of HPS DDR3 over f2sdram. The
    //             pixels are already there -- the gadget receives into DDR3 and
    //             the daemon memcpys rects into a reserved window at a measured
    //             110 MB/s -- so the fabric goes to them and nothing pushes a
    //             pixel across a bridge. Geometry stops being a build-time
    //             limit; 640x480 RGB565 is 600 KB, which is nothing off-chip.
    //
    // Only one is instantiated, so a DDR3 build gets that 43% of M10K back and
    // spends about 64 Kbit on line buffers instead.
    localparam integer SCANOUT_WORDS = SCANOUT_W * SCANOUT_H;
    localparam integer SCANOUT_AW    = $clog2(SCANOUT_W * SCANOUT_H);

    wire [19:0] sc_addr;
    wire [11:0] sc_x, sc_y;
    wire [31:0] sc_word;
    wire        sc_underrun;
    wire [15:0] sc_beats;

    generate
    if (SCANOUT_SRC == "DDR3") begin : g_ddr3

        /* One request per line, raised at the line boundary for the line about
         * to be displayed. The fetch then has the whole horizontal blanking
         * interval -- 136 pixels, about 10.8 us at 12.6 MHz -- against roughly
         * 2 us to move 160 beats, so five times the margin at the slowest mode
         * and half that at 25.2 MHz. Requesting a line ahead instead would give
         * a full line time, but needs the *next* line's source row, which is
         * awkward across a field boundary and buys margin that is not short. */
        wire [11:0] h_act_start = t_hsy + t_hbp;

        reg  req_pulse, show_pulse;
        always @(posedge clk_pix or negedge rst_n) begin
            if (!rst_n) begin
                req_pulse <= 1'b0; show_pulse <= 1'b0;
            end else begin
                req_pulse  <= (hcnt == 12'd0);
                /* Four clocks before active video: the read port is registered,
                 * so the buffer has to be swapped before scanout presents the
                 * first column or pixel zero comes out of the old line. */
                show_pulse <= (h_act_start > 12'd4) &&
                              (hcnt == h_act_start - 12'd4);
            end
        end

        /* The one module that touches the Platform Designer system, isolated the
         * same way blitscrt_hps.v isolates the HPS primitive. Its ports are
         * internal, so no pin assignments appear and check-pins stays clean. */
        wire        f2s_clk, f2s_rst_n, f2s_waitrequest, f2s_readdatavalid;
        wire [31:0] f2s_address;
        wire        f2s_read;
        wire [9:0]  f2s_burstcount;
        wire [F2SDRAM_DW-1:0] f2s_readdata;

        blitscrt_f2sdram #(.DW(F2SDRAM_DW), .WITH_QSYS(WITH_QSYS)) u_f2sdram (
            .ref_clk(FPGA_CLK1_50), .ref_rst_n(rst50_n),
            .m_clk(f2s_clk), .m_rst_n(f2s_rst_n),
            .m_address(f2s_address), .m_read(f2s_read),
            .m_burstcount(f2s_burstcount), .m_waitrequest(f2s_waitrequest),
            .m_readdata(f2s_readdata), .m_readdatavalid(f2s_readdatavalid)
        );

        scanout_fetch #(
            /* MAXW must cover the widest advertised mode. Switchres generates
             * 1280-wide super-resolution timings at 15 kHz, so 1024 is not
             * enough -- and overriding the module's default here is how a change
             * to that default silently did nothing. SCANOUT_MAXW reports this
             * to software so the daemon can refuse what the buffer cannot hold. */
            .DW(F2SDRAM_DW), .AW(32), .MAXW(SCANOUT_MAXW), .MAX_BURST(128)
        ) u_fetch (
            .clk_mem(f2s_clk), .rst_mem_n(f2s_rst_n),
            .avm_address(f2s_address), .avm_read(f2s_read),
            .avm_burstcount(f2s_burstcount), .avm_waitrequest(f2s_waitrequest),
            .avm_readdata(f2s_readdata), .avm_readdatavalid(f2s_readdatavalid),
            .sc_base(r_sc_base), .sc_stride(r_sc_stride[15:0]),
            .sc_w(r_sc_w), .sc_format(r_sc_format),
            .clk_pix(clk_pix), .rst_pix_n(rst_n),
            .line_req(req_pulse), .line_y(sc_y), .line_show(show_pulse),
            .line_valid(), .line_done(), .busy(),
            .underrun_tog(sc_underrun), .beats_last(sc_beats),
            .rd_x(sc_x), .rd_q(sc_word)
        );

    end else begin : g_onchip

        wire [15:0] sc_q;

        scanout_ram #(
            .DW(16), .AW(SCANOUT_AW), .WORDS(SCANOUT_WORDS),
            .INIT_FILE("scanout_init.hex")
        ) u_sc_ram (
            .wclk(FPGA_CLK1_50), .we(r_sc_we),
            .waddr(r_sc_waddr[SCANOUT_AW-1:0]), .wdata(r_sc_wdata),
            .rclk(clk_pix), .raddr(sc_addr[SCANOUT_AW-1:0]), .rdata(sc_q)
        );

        assign sc_word     = {16'd0, sc_q};
        assign sc_underrun = 1'b0;
        assign sc_beats    = 16'd0;

    end
    endgenerate

    /* Replication is derived from the geometry rather than a register bit: a
     * buffer half the width of the active area is doubled, and one half the
     * height is line-doubled. With SCANOUT_W=320 that puts a true 320-wide picture
     * across all three modes, and the 240-line buffer covers 480i as well. */
    /* Doubling is judged against the live raster, not the mode table. */
    wire hdouble = (v_hact  > r_sc_w);
    wire vdouble = (frame_v > r_sc_h);

    wire [5:0] sc_r, sc_g, sc_b;

    scanout #(.AW(20)) u_scanout (
        .clk(clk_pix), .rst_n(rst_n),
        .de(de), .xpos(xpos), .ypos(ypos),
        .sc_w(r_sc_w), .sc_h(r_sc_h), .sc_pitch(r_sc_w),
        .sc_format(r_sc_format),
        .hdouble(hdouble), .vdouble(vdouble),
        .mem_addr(sc_addr), .mem_q(sc_word),
        .x_src(sc_x), .y_src_o(sc_y),
        .r(sc_r), .g(sc_g), .b(sc_b)
    );

    /* CTRL_TESTCARD outranks CTRL_ENABLE. The register header defines it as
     * "show the card instead of the fb", and that ordering is what makes a
     * dropped host safe: blitscrt_dev_on_host() clears scanout on
     * FUNCTIONFS_DISABLE, and a stale frame left on screen would look exactly
     * like a crash. */
    wire src_scanout = r_scanout_en && !r_testcard_en;

    wire [5:0] src_r = src_scanout ? sc_r : tc_r;
    wire [5:0] src_g = src_scanout ? sc_g : tc_g;
    wire [5:0] src_b = src_scanout ? sc_b : tc_b;

    // ---------------- overlay ----------------
    wire [12:0] char_addr;
    wire [7:0]  char_data;
    wire [9:0]  font_addr;
    wire [7:0]  font_data;

    /*
     * The daemon writes overlay text through the register slave's character
     * window; those writes land here. When the daemon is quiet the buffer keeps
     * whatever it last held, and the overlay banking below shows the fabric's
     * own baked banner instead, so a dead HPS reads differently from a live one.
     */
    /*
     * The daemon writes overlay text through the register slave's character
     * window (bus clock); the overlay reads it in the pixel domain. When the
     * daemon is quiet the buffer keeps its baked banner, and hps_alive below
     * selects which the viewer sees, so a dead HPS reads differently from a
     * live one.
     */
    char_ram u_chars (
        .wclk(FPGA_CLK1_50), .we(r_char_we),
        .waddr(r_char_addr), .wdata(r_char_data),
        .rclk(clk_pix), .raddr(char_addr), .rdata(char_data)
    );

    font_rom u_font (
        .clk(clk_pix), .addr(font_addr), .data(font_data)
    );

    /*
     * BTN_OSD hides the on-screen text, so the bars can be judged unobstructed.
     *
     * It used to cycle the mode table and BTN_USER did this. With one mode left
     * there is nothing to cycle, and this is the button people reach for.
     *
     * btn_osd_clean is debounced in the 50 MHz domain, so it is resynchronised
     * here before the edge is taken -- a single flop would be enough for a
     * signal this slow, but two costs nothing and the edge detect needs a stable
     * previous value anyway.
     */
    reg overlay_btn = 1'b1;
    reg [2:0] osd_sync = 3'b111;
    always @(posedge clk_pix or negedge rst_n) begin
        if (!rst_n) begin
            overlay_btn <= 1'b1;
            osd_sync    <= 3'b111;
        end else begin
            osd_sync <= {osd_sync[1:0], btn_osd_clean};
            if (osd_sync[2] && !osd_sync[1]) overlay_btn <= ~overlay_btn;
        end
    end

    /* Either the button or CTRL_OVERLAY can hide the text. The button stays
     * authoritative for judging the bars unobstructed with no software running. */
    wire overlay_show = overlay_btn && r_overlay_en;

    wire       de_px;
    wire [5:0] px_r, px_g, px_b;

    overlay u_overlay (
        /* The live interlace flag, not the mode table's -- same bug as
         * frame_h/frame_v had, and it would leave the overlay half-height on a
         * host mode whose interlace differs from the front panel's. */
        .double_h(v_ilace),
        .bank(cur_mode),
        .hps_alive(hps_alive),
        .clk(clk_pix), .rst_n(rst_n),
        .de_in(de_card), .xpos(x_card), .ypos(y_card),
        .r_in(src_r), .g_in(src_g), .b_in(src_b),
        .enable(overlay_show),
        .char_addr(char_addr), .char_data(char_data),
        .font_addr(font_addr), .font_data(font_data),
        .de_out(de_px), .r_out(px_r), .g_out(px_g), .b_out(px_b)
    );

    // ---------------- HPS bridge and register file ----------------
    //
    // The bridge is the one module that knows how the HPS reaches the fabric.
    // BRIDGE = "LWH2F" is the lightweight-bridge pass-through the software
    // targets today; "GP" marshals MiSTer's gp_in/gp_out. Changing it is a
    // parameter, not a rewrite -- see rtl/blitscrt_bridge.v.
    //
    // The HPS side is stubbed idle. M1 stands on its own: the runtime mode
    // table drives the video timing, and the register slave is present and
    // addressable but not yet the source of truth. Handing timing over to the
    // HPS is the step that comes with a real bridge master, and it is a
    // deliberate one because the two must not drive the timing at once.
    wire [13:0] hps_lw_address   = 14'd0;
    wire        hps_lw_read      = 1'b0;
    wire        hps_lw_write     = 1'b0;
    wire [31:0] hps_lw_writedata = 32'd0;
    wire [31:0] hps_lw_readdata;
    wire        hps_lw_waitrequest;
    wire [31:0] hps_gp_out;
    wire [31:0] hps_gp_in;

    // The one module that touches HPS primitives. WITH_HPS=0 stubs it for a
    // bare-fabric build. gp_out is the ARM's writes; gp_in is the response the
    // bridge assembles.
    blitscrt_hps #(.WITH_HPS(WITH_HPS)) u_hps (
        .gp_out(hps_gp_out),
        .gp_in (hps_gp_in)
    );

    // GP is MiSTer's proven interface: the gp primitive is already on this
    // silicon, no Platform Designer, no extra HPS blocks. The seam means
    // flipping to "LWH2F" later is a parameter plus the bridge primitive.
    blitscrt_bridge #(.BRIDGE("GP")) u_bridge (
        .clk(FPGA_CLK1_50), .rst_n(rst50_n),
        .lw_address(hps_lw_address), .lw_read(hps_lw_read),
        .lw_write(hps_lw_write), .lw_writedata(hps_lw_writedata),
        .lw_readdata(hps_lw_readdata), .lw_waitrequest(hps_lw_waitrequest),
        .gp_out(hps_gp_out), .gp_in(hps_gp_in),
        .avm_address(reg_address), .avm_read(reg_read),
        .avm_write(reg_write), .avm_writedata(reg_writedata),
        .avm_readdata(reg_readdata), .avm_waitrequest(reg_waitrequest),
        .bus_stalled(bus_stalled)
    );

    /* Everything this block drives is live. Timing is obeyed when CTRL's
     * HPS_TIMING bit is set; until then the front-panel mode table owns the
     * raster, so a picture exists before any software runs. */
    /* Passed whole, not part-selected. SC_W/SC_H are declared [15:0] in the
     * slave, so the value truncates to the parameter's own range on the way in.
     * SCANOUT_W[15:0] looks equivalent and is not: `parameter integer` has no
     * declared vector range, so the part-select is not a well-formed constant
     * expression. Icarus evaluates it anyway; Quartus dropped the override and
     * used the default, which is how a 320x480 build came up reporting 320x240. */
    /* Capabilities are a build-time fact reported at runtime. DDR3 and on-chip
     * need different write paths, and choosing wrong fails silently: rect writes
     * on a DDR3 build land in a register nothing is listening to. */
    localparam [31:0] CAPS_WORD = (SCANOUT_SRC == "DDR3") ? 32'h0000_0001
                                                          : 32'h0000_0002;

    blitscrt_regs #(
        .SC_W(SCANOUT_W), .SC_H(SCANOUT_H), .CAPS(CAPS_WORD),
        .SCANOUT_MAXW(SCANOUT_MAXW[11:0])
    ) u_regs (
        .clk(FPGA_CLK1_50), .rst_n(rst50_n),
        .address(reg_address), .read(reg_read), .write(reg_write),
        .writedata(reg_writedata), .readdata(regs_readdata),
        .waitrequest(regs_waitrequest),
        /* Power-on reset only, without the mode-change hold: the configuration
         * this block latches must survive a clk_sel change. */
        .clk_pix(clk_pix), .vid_cfg_rst_n(rst_sr[3] & btn_reset_eff),
        .vblank(vblank), .field(field),
        .pll_locked(pll_locked), .hdmi_configured(hdmi_configured),
        .h_sy(r_hsy), .h_bp(r_hbp), .h_act(r_hact), .h_fp(r_hfp),
        .v_sy(r_vsy), .v_bp(r_vbp), .v_act(r_vact), .v_fp(r_vfp),
        .interlace(r_interlace), .pclk_khz(r_pclk_khz),
        .scanout_en(r_scanout_en), .testcard_en(r_testcard_en),
        .overlay_en(r_overlay_en), .csync_en(r_csync_en), .hdmi_en(r_hdmi_en),
        .av_force(r_av_force), .av_dac(r_av_dac),
        .av_clk_inv(r_av_clk_inv),
        .hps_timing(r_hps_timing), .hps_timing_bus(r_hps_timing_bus),
        .sc_base(r_sc_base), .sc_stride(r_sc_stride),
        .sc_format(r_sc_format), .sc_w(r_sc_w), .sc_h(r_sc_h),
        /* reconfig_from_pll[16] is the PLL's lock, the input the reconfig core
         * gates everything on. Bringing it out separately distinguishes "the
         * core is not being told the PLL is locked" from every other reason a
         * reconfiguration might not start. */
        .pll_locked_raw(reconfig_from_pll[16]),
        .pll_start_wr(pll_avs_write && !pll_avs_waitrequest &&
                      pll_avs_address == 6'd2),
        .pll_cnt_wr(pll_avs_write && !pll_avs_waitrequest &&
                    (pll_avs_address >= 6'd3) && (pll_avs_address <= 6'd5)),
        .pll_wait(pll_avs_waitrequest),
        .pll_accept((pll_avs_read || pll_avs_write) && !pll_avs_waitrequest),
        .bus_stalled(bus_stalled),
        /* Raw pins for IO_DIAG, synchronised into the bus domain. */
        .io_btn({btn_sync_rst, btn_sync_osd, btn_sync_usr}),
        .io_led({LED_POWER, LED_HDD, LED_USER}),
        .io_vga_en(VGA_EN), .io_av_present(av_present),
        .io_mcp_present(mcp_present), .io_mcp_btn(mcp_btn),
        .io_btn_user(btn_user_eff),
        .scanout_underrun_tog(sc_underrun), .scanout_beats(sc_beats),
        /* Post-mux, so this reports what the raster is really running on
         * rather than what was asked for. */
        .live_hsy(v_hsy),   .live_hbp(v_hbp),
        .live_hact(v_hact), .live_hfp(v_hfp),
        .live_vsy(v_vsy),   .live_vbp(v_vbp),
        .live_vact(v_vact), .live_vfp(v_vfp),
        .live_ilace(v_ilace), .live_clksel(clk_sel_eff),
        .pll_m(r_pll_m), .pll_n(r_pll_n), .pll_c(r_pll_c),
        .pll_apply(r_pll_apply),
        .char_we(r_char_we), .char_addr(r_char_addr), .char_data(r_char_data),
        .sc_we(r_sc_we), .sc_waddr(r_sc_waddr), .sc_wdata(r_sc_wdata),
        .hps_alive(hps_alive), .host_state(host_state),
        .host_bound(host_bound)
    );

    // ---------------- sync alignment ----------------
    // Pixel latency from the raw counters:
    //   1  de/xpos registered inside video_timing
    //   1  testcard output register
    //   3  overlay (char RAM, font ROM, output mux)
    // Sync is combinational from hcnt, so it needs all five back to land on the
    // same pixel. Getting this wrong only shifts the picture within the active
    // window, but the porches are what the CRT centres on.
    localparam integer PIPE = 5;

    reg [PIPE-1:0] hs_sr, vs_sr, cs_sr;
    always @(posedge clk_pix or negedge rst_n) begin
        if (!rst_n) begin
            hs_sr <= {PIPE{1'b0}}; vs_sr <= {PIPE{1'b0}}; cs_sr <= {PIPE{1'b0}};
        end else begin
            hs_sr <= {hs_sr[PIPE-2:0], hs};
            vs_sr <= {vs_sr[PIPE-2:0], vs};
            cs_sr <= {cs_sr[PIPE-2:0], cs};
        end
    end

    /* CTRL_CSYNC ORs with the compile-time parameter, so a build pinned to
     * composite sync stays that way regardless of what software writes. */
    wire use_csync = (CSYNC != 0) || r_csync_en;
    wire hs_out = use_csync ? cs_sr[PIPE-1] : hs_sr[PIPE-1];
    wire vs_out = vs_sr[PIPE-1];

    // ---------------- pads ----------------
    // VGA_EN is pulled up on the FPGA; the analog board pulls it low. With no
    // board fitted the pins are released rather than driven.
    assign VGA_R  = av_present ? (de_px ? px_r : 6'd0) : 6'bzzzzzz;
    assign VGA_G  = av_present ? (de_px ? px_g : 6'd0) : 6'bzzzzzz;
    assign VGA_B  = av_present ? (de_px ? px_b : 6'd0) : 6'bzzzzzz;
    assign VGA_HS = av_present ? ~hs_out : 1'bz;
    assign VGA_VS = av_present ? ~vs_out : 1'bz;

    // ---------------- HDMI, Direct Video ----------------
    // The raw 15kHz stream goes out the connector unscaled. The ADV7513 is set
    // to automatic pixel repetition, so it copes with a pixel clock well under
    // its own minimum by repeating internally. An HDMI-to-VGA DAC or a
    // direct-video SCART cable turns it back into analog RGB at the far end,
    // still 15.7kHz because nothing ever retimed it.

    // Clock out through a DDR register instead of routing a clock to a normal
    // IO. Same approach sys_top.v takes. altddio_out is a legacy megafunction;
    // if a newer Quartus refuses it, build with HDMI_CLK_DIRECT to drive the
    // pin straight from the pixel clock. That works at these rates and costs a
    // timing warning.
`ifdef HDMI_CLK_DIRECT
    assign HDMI_TX_CLK = ~clk_pix;
`else
    altddio_out #(
        .extend_oe_disable("OFF"),
        .intended_device_family("Cyclone V"),
        .invert_output("OFF"),
        .lpm_type("altddio_out"),
        .oe_reg("UNREGISTERED"),
        .power_up_high("OFF"),
        .width(1)
    ) u_hdmi_clk (
        .datain_h(1'b0),
        .datain_l(1'b1),
        .outclock(clk_pix),
        .dataout(HDMI_TX_CLK),
        .aclr(1'b0), .aset(1'b0), .oe(1'b1),
        .outclocken(1'b1), .sclr(1'b0), .sset(1'b0)
    );
`endif

    // 6 bits per channel widened to 8 by repeating the top bits, so full scale
    // stays full scale. Normal bus order: D[23:16] red, [15:8] green, [7:0] blue.
    wire hdmi_active = de_px && r_hdmi_en;
    assign HDMI_TX_D  = hdmi_active ? {px_r, px_r[5:4], px_g, px_g[5:4], px_b, px_b[5:4]}
                                    : 24'd0;
    assign HDMI_TX_DE = hdmi_active;

    // Separate sync regardless of the CSYNC parameter -- that setting is for
    // the analog pads. The DAC downstream makes its own VGA sync.
    assign HDMI_TX_HS = hs_sr[PIPE-1];
    assign HDMI_TX_VS = vs_sr[PIPE-1];

    // I2C runs in the 50 MHz domain, sharing the reset with mode selection

    adv7513_init #(.CLK_HZ(50_000_000)) u_hdmi_cfg (
        .clk(FPGA_CLK1_50), .rst_n(rst50_n),
        .scl(hdmi_scl), .sda_out(hdmi_sda_o), .sda_in(HDMI_I2C_SDA),
        .configured(hdmi_configured), .last_nack(hdmi_nack)
    );

    // open drain: drive low or release, never drive high
    assign HDMI_I2C_SCL = hdmi_scl   ? 1'bz : 1'b0;
    assign HDMI_I2C_SDA = hdmi_sda_o ? 1'bz : 1'b0;

    /*
     * The I/O board's MCP23009, on its own bit-banged bus.
     *
     * On a board fitted with the newer A/V board this is where the buttons and
     * LEDs actually are: BTN_* carry nothing and LED_* carry the DAC's clock,
     * blank and sync. mcp_present goes high only after a read is acknowledged,
     * so a board without an expander leaves it low and the GPIO pins are used
     * instead -- which is right for a DE10-Nano with the older I/O board.
     */
    wire mcp_scl, mcp_sda_o, mcp_sd_cd, mcp_mode;

    mcp23009 #(.CLK_HZ(50_000_000)) u_iob (
        .clk(FPGA_CLK1_50), .rst_n(rst50_n),
        /* {power, disk, user}, active high -- the expander inverts for us. Taken
         * from the meanings above rather than from the pads, since on this board
         * the pads are carrying video. */
        .led({led_power_on, led_disk_on, led_user_on}),
        .btn(mcp_btn), .sd_cd(mcp_sd_cd), .mode(mcp_mode),
        .present(mcp_present),
        .scl(mcp_scl), .sda_out(mcp_sda_o), .sda_in(IO_SDA)
    );

    assign IO_SCL = mcp_scl   ? 1'bz : 1'b0;
    assign IO_SDA = mcp_sda_o ? 1'bz : 1'b0;



    // ---------------- diagnostics ----------------
    // LEDs are active low on the I/O board.
    reg [24:0] beat;
    always @(posedge clk_pix) beat <= beat + 25'd1;

    /*
     * Active low: the LEDs sit between +5V and the GPIO pins, so one lights when
     * the FPGA pulls its pin to ground. Hence the inversions.
     *
     * These do nothing on a MiSTer Pi with the newer A/V board. That board puts
     * the LEDs and buttons behind an MCP23009 on IO_SCL/IO_SDA -- driven by
     * u_iob above, from the same three signals -- and repurposes these pins for
     * video when it is detected. MiSTer's sys_top does the same: LED_USER becomes
     * VGA_TX_CLK. Driving them here is correct for a DE10-Nano with a classic
     * I/O board and inert otherwise. See the README.
     */
    /* Two flops each, so IO_DIAG reports something stable rather than a pin
     * caught mid-bounce. */
    reg [1:0] sy_rst, sy_osd, sy_usr;
    always @(posedge FPGA_CLK1_50) begin
        sy_rst <= {sy_rst[0], BTN_RESET};
        sy_osd <= {sy_osd[0], BTN_OSD};
        sy_usr <= {sy_usr[0], BTN_USER};
    end
    wire btn_sync_rst = sy_rst[1];
    wire btn_sync_osd = sy_osd[1];
    wire btn_sync_usr = sy_usr[1];

    /*
     * These three pins are LEDs on the old resistor-ladder A/V board and video
     * signals on the newer one, which carries an ADV7125. MiSTer's sys_top does
     * the same, keyed on the MCP23009 being present, and the AV board schematic
     * confirms which is which:
     *
     *   LED_USER  Y15    VCLK    the DAC's latch clock
     *   LED_POWER AG28   BLANK*  active low, so data enable drives it directly
     *   LED_HDD   AA15   SYNC*   active low composite sync
     *
     * The pin assignments come from MiSTer's sys/sys_analog.tcl. They were once
     * swapped here on the strength of a forum post, which put the clock on the
     * BLANK pin and the data enable on the clock -- the DAC then never latched,
     * and the picture was meaningless while sync stayed perfect.
     *
     * A DAC with no clock latches nothing, so a board of that kind gives a black
     * screen while every other signal is correct -- which is exactly what
     * happened here, and why the LEDs appeared not to work at the same time.
     *
     * CTRL bit 7 selects. It is a runtime bit rather than a parameter so both
     * board types work from one bitstream, and so this can be tried without a
     * Quartus rebuild.
     */
    /* Sync for the DAC. With CSYNC selected it takes composite sync, otherwise
     * it is held inactive and the separate HS/VS pins carry sync as before. */
    wire sog_out = use_csync ? cs_sr[PIPE-1] : 1'b1;

    /*
     * What the LEDs mean, on a board where they are LEDs.
     *
     *   POWER  solid whenever the PLL is locked, which is to say whenever the
     *          board is generating video at all. A dark power LED means the
     *          clock never came up.
     *   USER   green on this panel. On while the USB gadget is bound: the
     *          display is available to a host, whether or not one is looking.
     *   DISK   orange. On while it is not -- after the user button has
     *          disconnected, or before the daemon has come up.
     *
     * The two are complementary rather than two views of the same thing, which
     * is what having two colours is worth: green means the display is there,
     * orange means it has been taken away. Exactly one is lit once the board is
     * running, so a dark pair is itself a fault.
     *
     * They tracked "bound" and "host attached" separately at first. That reads
     * well written down and badly on a panel: with a host connected both were
     * lit and neither told you anything the other did not.
     *
     * Active low: the pads sink current to light. On the newer A/V board these
     * three carry video instead, selected by r_av_dac, and the real LEDs are on
     * the MCP23009 -- see u_iob, which takes the same three values.
     */
    wire led_power_on = pll_locked;
    wire led_user_on  =  host_bound;
    wire led_disk_on  = ~host_bound;

    assign LED_POWER = r_av_dac ? de_px    : ~led_power_on;
    assign LED_HDD   = r_av_dac ? ~sog_out : ~led_disk_on;
    /*
     * The DAC latches R/G/B on the rising edge of this clock, and VGA_R/G/B are
     * registered on clk_pix -- so an un-inverted clock samples the data exactly
     * as it changes. Inverting gives half a period of setup, which is why it is
     * the default. CTRL bit 8 clears it if a board wants the other phase.
     */
    assign LED_USER  = r_av_dac ? (r_av_clk_inv ? ~clk_pix : clk_pix)
                                : ~led_user_on;

endmodule

`default_nettype wire
