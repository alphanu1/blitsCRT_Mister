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
    parameter [31:0] VERSION = 32'h0002_0000     // major 2, minor 0
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
    input  wire        vid_rst_n,
    input  wire        vblank,           // level, high during vertical blanking
    input  wire        field,
    input  wire        pll_locked,
    input  wire        hdmi_configured,

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

    // scanout memory, video domain
    output reg  [31:0] fb_base,
    output reg  [31:0] fb_stride,
    output reg  [2:0]  fb_format,
    output reg         fb_flip,

    // PLL counters for the reconfiguration block, bus domain
    output reg  [8:0]  pll_m, pll_n, pll_c,
    output reg         pll_apply,        // one bus-clock pulse

    // overlay character buffer write port, bus domain
    output reg         char_we,
    output reg  [12:0] char_addr,
    output reg  [7:0]  char_data
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
    reg [31:0] s_fb_base, s_fb_stride;
    reg [2:0]  s_fb_format;
    reg [4:0]  s_ctrl;

    reg        apply_req;                 // toggles to request a latch
    reg        flip_req;

    /* Driven in the video domain further down, read by the synchronisers just
     * below. Declared here because some Icarus builds reject use before
     * declaration, and Quartus is happy either way. */
    reg        apply_ack;
    reg        flip_ack;
    reg        field_toggle;

    /*
     * 0x0000..0x0FFF  registers
     * 0x1000..0x1FFF  altera_pll_reconfig, decoded outside this block
     * 0x2000..0x3FFF  character buffer, one byte per word
     */
    wire       is_char = (address[13] == 1'b1);
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
            s_fb_base   <= 32'd0;
            s_fb_stride <= 32'd1280;
            s_fb_format <= 3'd0;
            s_ctrl      <= 5'b10110;             // testcard, overlay, hdmi on
            pll_m <= 9'd63; pll_n <= 9'd2; pll_c <= 9'd125;
            apply_req <= 1'b0;
            flip_req  <= 1'b0;
            pll_apply <= 1'b0;
            char_we   <= 1'b0;
            char_addr <= 13'd0;
            char_data <= 8'd0;
        end else begin
            pll_apply <= 1'b0;
            char_we   <= 1'b0;

            if (write) begin
                if (is_char) begin
                    /* Character buffer. One byte per word, which wastes three
                     * quarters of the window and keeps addressing trivial from
                     * software. 8192 entries fit the 0x2000 span exactly. */
                    char_we   <= 1'b1;
                    char_addr <= address[12:0];
                    char_data <= writedata[7:0];
                end else begin
                    case (reg_off)
                        8'h08: s_ctrl      <= writedata[4:0];
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
                        8'h44: begin
                            /* APPLY. Toggle the request; the video side
                             * latches at the next vblank. */
                            apply_req <= ~apply_req;
                            pll_apply <= 1'b1;
                        end
                        8'h50: s_fb_base   <= writedata;
                        8'h54: s_fb_stride <= writedata;
                        8'h58: s_fb_format <= writedata[2:0];
                        8'h5C: flip_req    <= ~flip_req;
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
                8'h08: readdata <= {27'd0, s_ctrl};
                8'h0C: readdata <= {27'd0, applying, sync_vblank[1],
                                    sync_field[1], sync_hdmi[1], sync_lock[1]};
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
                8'h50: readdata <= s_fb_base;
                8'h54: readdata <= s_fb_stride;
                8'h58: readdata <= {29'd0, s_fb_format};
                8'h60: readdata <= frame_count_bus;
                default: readdata <= 32'd0;
            endcase
        end
    end

    // -------------------------------------------------------------------
    // video domain: latch the staged set on a vblank after a request
    // -------------------------------------------------------------------
    reg [1:0] sync_req;
    reg [1:0] sync_flip;
    reg       field_d;

    always @(posedge clk_pix or negedge vid_rst_n) begin
        if (!vid_rst_n) begin
            sync_req  <= 2'b00;
            apply_ack <= 1'b0;
            sync_flip <= 2'b00;
            flip_ack  <= 1'b0;
            fb_flip   <= 1'b0;
            field_toggle <= 1'b0;
            field_d   <= 1'b0;

            h_sy <= 12'd60; h_bp <= 12'd76; h_act <= 12'd640; h_fp <= 12'd24;
            v_sy <= 12'd3;  v_bp <= 12'd16; v_act <= 12'd240; v_fp <= 12'd3;
            interlace <= 1'b1;
            pclk_khz  <= 32'd12600;
            fb_base   <= 32'd0;
            fb_stride <= 32'd1280;
            fb_format <= 3'd0;
        end else begin
            sync_req  <= {sync_req[0],  apply_req};
            sync_flip <= {sync_flip[0], flip_req};
            fb_flip   <= 1'b0;

            /* count fields for the bus-side frame counter */
            field_d <= field;
            if (field != field_d) field_toggle <= ~field_toggle;

            if (vblank) begin
                if (sync_req[1] != apply_ack) begin
                    h_sy <= s_hsy; h_bp <= s_hbp; h_act <= s_hact; h_fp <= s_hfp;
                    v_sy <= s_vsy; v_bp <= s_vbp; v_act <= s_vact; v_fp <= s_vfp;
                    interlace <= s_flags[0];
                    pclk_khz  <= s_khz;
                    fb_base   <= s_fb_base;
                    fb_stride <= s_fb_stride;
                    fb_format <= s_fb_format;
                    apply_ack <= sync_req[1];
                end
                if (sync_flip[1] != flip_ack) begin
                    fb_flip  <= 1'b1;
                    flip_ack <= sync_flip[1];
                end
            end
        end
    end

    /* Control bits are static from the video side's point of view; a two-flop
     * synchroniser each is enough. */
    reg [4:0] ctrl_meta, ctrl_vid;
    always @(posedge clk_pix or negedge vid_rst_n) begin
        if (!vid_rst_n) begin ctrl_meta <= 5'b10110; ctrl_vid <= 5'b10110; end
        else begin ctrl_meta <= s_ctrl; ctrl_vid <= ctrl_meta; end
    end

    assign scanout_en  = ctrl_vid[0];
    assign testcard_en = ctrl_vid[1];
    assign overlay_en  = ctrl_vid[2];
    assign csync_en    = ctrl_vid[3];
    assign hdmi_en     = ctrl_vid[4];

endmodule

`default_nettype wire
