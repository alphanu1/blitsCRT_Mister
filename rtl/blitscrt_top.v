// -----------------------------------------------------------------------------
// blitscrt_top.v -- blitsCRT_Mister milestone 1
//
// Fabric only. No HPS, no SDRAM, no USB. Drives the MiSTer analog A/V board
// with a colour-bar test card and a text overlay reporting the mode, so a
// picture exists before any software runs and survives anything above it
// crashing later.
//
// Three modes, selected at runtime:
//
//   0  640x240p60  12.600 MHz  15.750 kHz  60.11 Hz   15kHz CRT
//   1  640x480i60  12.600 MHz  15.750 kHz  60.00 Hz   15kHz CRT, standard 480i
//   2  640x480p60  25.200 MHz  31.500 kHz  60.00 Hz   any VGA or HDMI display
//
// Modes 0 and 1 share a clock, so switching between them never touches the
// PLL. altclkctrl accepts PLL outputs on only two of its four inputs, which is
// what limits the design to two pixel clocks.
//
// Both defaults are mode 1. 480i is a standard SD format that HDMI sinks
// accept, and a 15kHz CRT takes it as readily as 240p, so it is the mode most
// likely to produce a picture on whatever is plugged in. BTN_OSD cycles from
// there, since no amount of detection can tell whether the cable past the
// connector works.
//
// Mode 2 exists to separate "the design works" from "the analog path works".
// Standard VGA timing needs no DAC and no SCART lead, so a dark screen in mode
// 0 and a picture in mode 2 localises the fault to the cable.
//
// Sync is driven active low, which is what 15kHz RGB and SCART expect.
// Set CSYNC to put composite sync on the HS pin for SCART pin 20 wiring.
// -----------------------------------------------------------------------------

`timescale 1ns/1ps
`default_nettype none

module blitscrt_top #(
    parameter integer CSYNC        = 0,
    parameter integer DEFAULT_VGA  = 1,   // analog board fitted
    parameter integer DEFAULT_HDMI = 1,   // HDMI only; 2 for 31kHz VGA timing
    parameter integer FORCE_MODE   = -1,  // >= 0 pins the mode and ignores detect
    parameter integer WITH_HPS     = 1    // 0 builds a bare fabric, no HPS
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
    output wire        LED_POWER,
    output wire        LED_HDD,
    output wire        LED_USER
);


    /* Driven further down, referenced by the mode table just below. Declared
     * here because some Icarus builds reject use before declaration. Quartus
     * accepts either, so this only shows up on someone else's machine. */
    wire hdmi_scl, hdmi_sda_o, hdmi_configured, hdmi_nack;
    wire rst_n;                       // video-domain reset, driven below

    // ---------------- mode selection, in the 50 MHz domain ----------------
    reg [3:0] rst50_sr = 4'b0000;
    always @(posedge FPGA_CLK1_50) rst50_sr <= {rst50_sr[2:0], BTN_RESET};
    wire rst50_n = rst50_sr[3];

    wire av_present = ~VGA_EN;      // the analog board pulls this low

    // Debounce BTN_OSD. The buttons are active low with weak pull-ups.
    reg [19:0] db_cnt;
    reg        btn_osd_s, btn_osd_clean;
    always @(posedge FPGA_CLK1_50 or negedge rst50_n) begin
        if (!rst50_n) begin
            db_cnt <= 20'd0; btn_osd_s <= 1'b1; btn_osd_clean <= 1'b1;
        end else begin
            btn_osd_s <= BTN_OSD;
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

    /* Avalon master stubs for the reconfig slave. Held idle until the HPS
     * bridge decode at 0x1000 replaces them, so the PLL free-runs at its
     * power-on frequencies. Declared before use; check-decl enforces it. */
    wire [5:0]  pll_avs_address    = 6'd0;
    wire        pll_avs_read       = 1'b0;
    wire        pll_avs_write      = 1'b0;
    wire [31:0] pll_avs_writedata  = 32'd0;
    wire [31:0] pll_avs_readdata;
    wire        pll_avs_waitrequest;


    pll_modes u_pll (
        .refclk  (FPGA_CLK1_50),
        .rst     (~rst50_n),
        .sel     (clk_sel),
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
            sel_d <= clk_sel;
            if (sel_d != clk_sel) mode_hold <= 8'hFF;
            else if (mode_hold)   mode_hold <= mode_hold - 8'd1;
        end
    end

    reg [3:0] rst_sr = 4'b0000;
    always @(posedge clk_pix or negedge pll_locked) begin
        if (!pll_locked) rst_sr <= 4'b0000;
        else             rst_sr <= {rst_sr[2:0], 1'b1};
    end
    assign rst_n = rst_sr[3] & BTN_RESET & ~(|mode_hold);

    // ---------------- timing ----------------
    wire        hs, vs, cs, de;
    wire [11:0] hcnt, lcnt, xpos, ypos;
    wire        field, vblank, field_start;

    video_timing u_timing (
        .clk(clk_pix), .rst_n(rst_n),
        .h_sy(t_hsy), .h_bp(t_hbp), .h_act(t_hact), .h_fp(t_hfp),
        .v_sy(t_vsy), .v_bp(t_vbp), .v_act(t_vact), .v_fp(t_vfp),
        .interlace(t_ilace),
        .hs(hs), .vs(vs), .cs(cs), .de(de),
        .hcnt(hcnt), .lcnt(lcnt), .xpos(xpos), .ypos(ypos),
        .field(field), .vblank(vblank), .field_start(field_start)
    );

    // ---------------- test card ----------------
    wire [5:0] tc_r, tc_g, tc_b;

    wire [11:0] frame_h = t_hact;
    wire [11:0] frame_v = t_ilace ? {t_vact[10:0], 1'b0} : t_vact;

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

    // BTN_USER hides the text so the bars can be judged unobstructed
    reg overlay_en = 1'b1;
    reg btn_user_d = 1'b1;
    always @(posedge clk_pix or negedge rst_n) begin
        if (!rst_n) begin
            overlay_en <= 1'b1;
            btn_user_d <= 1'b1;
        end else begin
            btn_user_d <= BTN_USER;
            if (btn_user_d && !BTN_USER) overlay_en <= ~overlay_en;
        end
    end

    wire       de_px;
    wire [5:0] px_r, px_g, px_b;

    overlay u_overlay (
        .double_h(t_ilace),
        .bank(cur_mode),
        .hps_alive(hps_alive),
        .clk(clk_pix), .rst_n(rst_n),
        .de_in(de_card), .xpos(x_card), .ypos(y_card),
        .r_in(tc_r), .g_in(tc_g), .b_in(tc_b),
        .enable(overlay_en),
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

    wire [13:0] reg_address;
    wire        reg_read, reg_write;
    wire [31:0] reg_writedata, reg_readdata;
    wire        reg_waitrequest;

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
        .avm_readdata(reg_readdata), .avm_waitrequest(reg_waitrequest)
    );

    // Register-slave outputs, observed but not yet wired to the video path.
    wire [11:0] r_hsy, r_hbp, r_hact, r_hfp, r_vsy, r_vbp, r_vact, r_vfp;
    wire        r_interlace;
    wire [31:0] r_pclk_khz, r_fb_base, r_fb_stride;
    wire [2:0]  r_fb_format;
    wire        r_fb_flip;
    wire [4:0]  r_ctrl_unused;
    wire [8:0]  r_pll_m, r_pll_n, r_pll_c;
    wire        r_pll_apply, r_char_we;
    wire [12:0] r_char_addr;
    wire [7:0]  r_char_data;
    wire        hps_alive;
    wire [1:0]  host_state;

    blitscrt_regs u_regs (
        .clk(FPGA_CLK1_50), .rst_n(rst50_n),
        .address(reg_address), .read(reg_read), .write(reg_write),
        .writedata(reg_writedata), .readdata(reg_readdata),
        .waitrequest(reg_waitrequest),
        .clk_pix(clk_pix), .vid_rst_n(rst_n),
        .vblank(vblank), .field(field),
        .pll_locked(pll_locked), .hdmi_configured(hdmi_configured),
        .h_sy(r_hsy), .h_bp(r_hbp), .h_act(r_hact), .h_fp(r_hfp),
        .v_sy(r_vsy), .v_bp(r_vbp), .v_act(r_vact), .v_fp(r_vfp),
        .interlace(r_interlace), .pclk_khz(r_pclk_khz),
        .scanout_en(), .testcard_en(), .overlay_en(),
        .csync_en(), .hdmi_en(),
        .fb_base(r_fb_base), .fb_stride(r_fb_stride),
        .fb_format(r_fb_format), .fb_flip(r_fb_flip),
        .pll_m(r_pll_m), .pll_n(r_pll_n), .pll_c(r_pll_c),
        .pll_apply(r_pll_apply),
        .char_we(r_char_we), .char_addr(r_char_addr), .char_data(r_char_data),
        .hps_alive(hps_alive), .host_state(host_state)
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

    wire hs_out = (CSYNC != 0) ? cs_sr[PIPE-1] : hs_sr[PIPE-1];
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
    assign HDMI_TX_D  = de_px ? {px_r, px_r[5:4], px_g, px_g[5:4], px_b, px_b[5:4]}
                              : 24'd0;
    assign HDMI_TX_DE = de_px;

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

    // ---------------- diagnostics ----------------
    // LEDs are active low on the I/O board.
    reg [24:0] beat;
    always @(posedge clk_pix) beat <= beat + 25'd1;

    // LED_HDD blinks the mode number: one flash for 320x240p, two for 640x480i,
    // three for 640x480p. Enough to know what is being generated with no
    // picture and no serial console.
    reg [2:0] blink_n;
    reg [3:0] blink_i;
    always @(posedge clk_pix) begin
        if (beat[21:0] == 22'd0) begin
            if (blink_i == 4'd9) begin blink_i <= 4'd0; blink_n <= 3'd0; end
            else begin
                blink_i <= blink_i + 4'd1;
                if (blink_i[0] == 1'b0 && blink_n <= cur_mode) blink_n <= blink_n + 3'd1;
            end
        end
    end
    wire mode_blink = (blink_i < ((cur_mode + 3'd1) << 1)) & ~blink_i[0];

    assign LED_POWER = ~pll_locked;
    assign LED_HDD   = ~mode_blink;
    assign LED_USER  = ~beat[22];

endmodule

`default_nettype wire
