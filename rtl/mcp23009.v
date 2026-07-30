`default_nettype none
//
// mcp23009.v -- the I/O board LEDs and buttons, over I2C
//
// Later MiSTer I/O boards, and the integrated one on a MiSTer Pi, put the three
// LEDs and three buttons behind an MCP23009 8-bit I2C expander rather than on
// GPIO pins. On such a board the LED_*/BTN_* pins do nothing -- MiSTer's sys_top
// reuses them for other signals entirely once it detects the expander -- so
// driving them, however correctly, has no effect. That is why this exists.
//
// Register layout and the bit assignments follow MiSTer's sys/mcp23009.sv,
// (C) 2019 Alexey Melnikov, GPL-2.0-or-later. This is an independent
// implementation against the same device, written to use the I2C master already
// here rather than carrying a second one.
//
//   GP0  LED user      out
//   GP1  LED disk      out
//   GP2  LED power     out
//   GP3  button user   in
//   GP4  button reset  in
//   GP5  button OSD    in
//   GP6  mode flag     in
//   GP7  SD card detect in
//
// IPOL inverts the input bits, so a pressed button reads as 1 here despite the
// pins being pulled up and grounded by the switch.
//
// present goes high only after a read has been acknowledged. Nothing is
// connected on a board without an expander, every transfer NACKs, and the
// consumer can use that to fall back to the GPIO pins.

module mcp23009 #(
    parameter integer CLK_HZ = 50_000_000
) (
    input  wire       clk,
    input  wire       rst_n,

    input  wire [2:0] led,          // power, disk, user -- 1 lights
    output reg  [2:0] btn,          // OSD, reset, user  -- 1 pressed
    output reg        sd_cd,
    output reg        mode,
    output reg        present,

    output wire       scl,
    output wire       sda_out,
    input  wire       sda_in
);

    localparam [6:0] DEV = 7'h20;   // A2..A0 strapped low

    /* Registers, in the order they are written at startup.
     *
     *   IODIR  0xF8  GP0..2 out (LEDs), GP3..7 in (buttons and flags)
     *   IPOL   0x38  invert the three button bits
     *   GPPU   0xFF  pull-ups everywhere; the buttons pull to ground
     *   IOCON  0x24  sequential addressing off, INT open-drain
     */
    localparam integer NINIT = 5;

    reg [7:0] init_reg [0:NINIT-1];
    reg [7:0] init_val [0:NINIT-1];
    initial begin
        init_reg[0] = 8'h00; init_val[0] = 8'hF8;   // IODIR
        init_reg[1] = 8'h01; init_val[1] = 8'h38;   // IPOL
        init_reg[2] = 8'h05; init_val[2] = 8'h24;   // IOCON
        init_reg[3] = 8'h06; init_val[3] = 8'hFF;   // GPPU
        init_reg[4] = 8'h09; init_val[4] = 8'h00;   // GPIO, LEDs off to begin
    end

    reg        i2c_start;
    reg  [7:0] i2c_reg, i2c_dat;
    reg        i2c_rd;
    wire       i2c_busy, i2c_done, i2c_nack;
    wire [7:0] i2c_rdata;

    i2c_master #(.CLK_HZ(CLK_HZ), .SCL_HZ(100_000)) u_i2c (
        .clk(clk), .rst_n(rst_n),
        .start(i2c_start), .dev_addr(DEV),
        .reg_addr(i2c_reg), .data(i2c_dat),
        .rd(i2c_rd), .rdata(i2c_rdata),
        .busy(i2c_busy), .done(i2c_done), .nack(i2c_nack),
        .scl(scl), .sda_out(sda_out), .sda_in(sda_in)
    );

    localparam [1:0] S_INIT = 2'd0,   // walk the init table
                     S_WR   = 2'd1,   // GPIO write, carrying the LED state
                     S_RD   = 2'd2,   // GPIO read, bringing the buttons back
                     S_WAIT = 2'd3;

    reg [1:0]  state;
    reg [2:0]  idx;
    reg        issued;

    /* A gap between transfers. Nothing needs the expander polled faster than a
     * button can be pressed, and at 100 kHz a transfer is already ~300 us. */
    reg [15:0] gap;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= S_INIT;
            idx       <= 3'd0;
            issued    <= 1'b0;
            gap       <= 16'd0;
            i2c_start <= 1'b0;
            i2c_rd    <= 1'b0;
            i2c_reg   <= 8'd0;
            i2c_dat   <= 8'd0;
            btn       <= 3'd0;
            sd_cd     <= 1'b1;
            mode      <= 1'b1;
            present   <= 1'b0;
        end else begin
            i2c_start <= 1'b0;

            case (state)
                S_INIT: begin
                    if (!issued && !i2c_busy) begin
                        i2c_reg   <= init_reg[idx];
                        i2c_dat   <= init_val[idx];
                        i2c_rd    <= 1'b0;
                        i2c_start <= 1'b1;
                        issued    <= 1'b1;
                    end else if (issued && i2c_done) begin
                        issued <= 1'b0;
                        /*
                         * Advance whether or not it was acknowledged. With no
                         * expander fitted every transfer NACKs, and retrying
                         * forever would leave this stuck; present stays low and
                         * the consumer falls back.
                         */
                        if (idx == NINIT[2:0] - 3'd1) state <= S_WR;
                        else                          idx   <= idx + 3'd1;
                    end
                end

                /* GPIO write: the LED bits. Bit 0 user, 1 disk, 2 power, to
                 * match the pin order above. */
                S_WR: begin
                    if (!issued && !i2c_busy) begin
                        i2c_reg   <= 8'h09;
                        /* led is {power, disk, user} and the device wants
                         * GP2..GP0 in that same order, so it goes straight in. */
                        i2c_dat   <= {5'd0, led};
                        i2c_rd    <= 1'b0;
                        i2c_start <= 1'b1;
                        issued    <= 1'b1;
                    end else if (issued && i2c_done) begin
                        issued <= 1'b0;
                        state  <= S_RD;
                    end
                end

                /* GPIO read: buttons and flags come back in the top five bits. */
                S_RD: begin
                    if (!issued && !i2c_busy) begin
                        i2c_reg   <= 8'h09;
                        i2c_rd    <= 1'b1;
                        i2c_start <= 1'b1;
                        issued    <= 1'b1;
                    end else if (issued && i2c_done) begin
                        issued <= 1'b0;
                        i2c_rd <= 1'b0;
                        if (!i2c_nack) begin
                            btn     <= {i2c_rdata[5], i2c_rdata[4], i2c_rdata[3]};
                            mode    <= i2c_rdata[6];
                            sd_cd   <= i2c_rdata[7];
                            present <= 1'b1;
                        end else begin
                            /* Nothing there. Report nothing pressed rather than
                             * whatever the bus floated to. */
                            btn     <= 3'd0;
                            present <= 1'b0;
                        end
                        gap   <= 16'd0;
                        state <= S_WAIT;
                    end
                end

                S_WAIT: begin
                    if (&gap) state <= S_WR;
                    else      gap   <= gap + 16'd1;
                end

                default: state <= S_INIT;
            endcase
        end
    end

endmodule

`default_nettype wire
