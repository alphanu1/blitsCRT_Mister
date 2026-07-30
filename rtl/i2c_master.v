// SPDX-License-Identifier: GPL-2.0-or-later
// -----------------------------------------------------------------------------
// i2c_master.v -- minimal I2C master: register writes, and single-byte reads
//
// Enough to push {device, register, value} triples at an ADV7513 and nothing
// more. Open drain throughout: lines are either driven low or released, never
// driven high.
// -----------------------------------------------------------------------------

`timescale 1ns/1ps
`default_nettype none

module i2c_master #(
    parameter integer CLK_HZ = 50_000_000,
    parameter integer SCL_HZ = 100_000
) (
    input  wire       clk,
    input  wire       rst_n,

    input  wire       start,          // one-clock pulse
    input  wire [6:0] dev_addr,
    input  wire [7:0] reg_addr,
    input  wire [7:0] data,

    /*
     * rd = 1 reads instead of writing: address the device, send reg_addr, then
     * a repeated START, address it again for reading, take one byte and NACK it.
     * rd = 0 behaves exactly as before, which is what the HDMI transmitter path
     * relies on.
     */
    input  wire       rd,
    output reg  [7:0] rdata,

    output reg        busy,
    output reg        done,           // one-clock pulse
    output reg        nack,

    output wire       scl,            // 1 = release, 0 = drive low
    output wire       sda_out,
    input  wire       sda_in
);

    // four phases per SCL period
    localparam integer DIV = CLK_HZ / (SCL_HZ * 4);

    reg [15:0] divcnt;
    reg        tick;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            divcnt <= 16'd0;
            tick   <= 1'b0;
        end else if (divcnt == DIV[15:0] - 16'd1) begin
            divcnt <= 16'd0;
            tick   <= 1'b1;
        end else begin
            divcnt <= divcnt + 16'd1;
            tick   <= 1'b0;
        end
    end

    localparam [3:0] S_IDLE   = 4'd0,
                     S_START  = 4'd1,
                     S_BIT    = 4'd2,
                     S_ACK    = 4'd3,
                     S_STOP   = 4'd4,
                     S_DONE   = 4'd5,
                     S_RSTART = 4'd6,   // repeated START before the read
                     S_RBIT   = 4'd7,   // shifting the byte in
                     S_RNACK  = 4'd8;   // NACK it, so the slave stops

    reg [3:0]  state;
    reg [1:0]  phase;
    reg [2:0]  bitc;
    reg [1:0]  bytec;
    reg [7:0]  shreg;
    reg        scl_r, sda_r;
    reg        rd_l;               // latched at start, so it cannot move mid-transfer

    assign scl     = scl_r;
    assign sda_out = sda_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            phase <= 2'd0;
            bitc  <= 3'd0;
            bytec <= 2'd0;
            shreg <= 8'd0;
            scl_r <= 1'b1;
            sda_r <= 1'b1;
            busy  <= 1'b0;
            done  <= 1'b0;
            nack  <= 1'b0;
            rd_l  <= 1'b0;
            rdata <= 8'd0;
        end else begin
            done <= 1'b0;

            if (state == S_IDLE) begin
                scl_r <= 1'b1;
                sda_r <= 1'b1;
                busy  <= 1'b0;
                if (start) begin
                    shreg <= {dev_addr, 1'b0};      // write transaction
                    bytec <= 2'd0;
                    bitc  <= 3'd7;
                    phase <= 2'd0;
                    state <= S_START;
                    busy  <= 1'b1;
                    nack  <= 1'b0;
                    rd_l  <= rd;
                end
            end else if (tick) begin
                phase <= phase + 2'd1;

                case (state)
                    // SDA falls while SCL is high
                    S_START: begin
                        case (phase)
                            2'd0: begin scl_r <= 1'b1; sda_r <= 1'b1; end
                            2'd1: sda_r <= 1'b0;
                            2'd2: ;
                            2'd3: begin scl_r <= 1'b0; state <= S_BIT; end
                        endcase
                    end

                    S_BIT: begin
                        case (phase)
                            2'd0: sda_r <= shreg[7];
                            2'd1: scl_r <= 1'b1;
                            2'd2: ;
                            2'd3: begin
                                scl_r <= 1'b0;
                                shreg <= {shreg[6:0], 1'b0};
                                if (bitc == 3'd0) state <= S_ACK;
                                else              bitc <= bitc - 3'd1;
                            end
                        endcase
                    end

                    S_ACK: begin
                        case (phase)
                            2'd0: sda_r <= 1'b1;            // release for the slave
                            2'd1: scl_r <= 1'b1;
                            2'd2: if (sda_in) nack <= 1'b1; // high on the ninth clock
                            2'd3: begin
                                scl_r <= 1'b0;
                                bitc  <= 3'd7;
                                /*
                                 * A read stops after the register address and
                                 * turns the bus around; a write carries on and
                                 * sends the data byte.
                                 */
                                if (bytec == 2'd3) begin
                                    /* that was the read address; the slave
                                     * drives the next eight bits */
                                    state <= S_RBIT;
                                end else if (rd_l && bytec == 2'd1) begin
                                    state <= S_RSTART;
                                end else if (bytec == 2'd2) begin
                                    state <= S_STOP;
                                end else begin
                                    shreg <= (bytec == 2'd0) ? reg_addr : data;
                                    bytec <= bytec + 2'd1;
                                    state <= S_BIT;
                                end
                            end
                        endcase
                    end

                    /* Repeated START: SDA released high, then pulled low with
                     * SCL high, without a STOP in between. */
                    S_RSTART: begin
                        case (phase)
                            2'd0: sda_r <= 1'b1;
                            2'd1: scl_r <= 1'b1;
                            2'd2: sda_r <= 1'b0;
                            2'd3: begin
                                scl_r <= 1'b0;
                                shreg <= {dev_addr, 1'b1};   // read
                                bitc  <= 3'd7;
                                bytec <= 2'd3;               // marks the read address
                                state <= S_BIT;
                            end
                        endcase
                    end

                    S_RBIT: begin
                        case (phase)
                            2'd0: sda_r <= 1'b1;             // let the slave drive
                            2'd1: scl_r <= 1'b1;
                            2'd2: rdata <= {rdata[6:0], sda_in};
                            2'd3: begin
                                scl_r <= 1'b0;
                                if (bitc == 3'd0) state <= S_RNACK;
                                else              bitc <= bitc - 3'd1;
                            end
                        endcase
                    end

                    /* NACK the byte: SDA held high through the ninth clock, which
                     * tells the slave not to send another. */
                    S_RNACK: begin
                        case (phase)
                            2'd0: sda_r <= 1'b1;
                            2'd1: scl_r <= 1'b1;
                            2'd2: ;
                            2'd3: begin scl_r <= 1'b0; state <= S_STOP; end
                        endcase
                    end

                    // SDA rises while SCL is high
                    S_STOP: begin
                        case (phase)
                            2'd0: sda_r <= 1'b0;
                            2'd1: scl_r <= 1'b1;
                            2'd2: sda_r <= 1'b1;
                            2'd3: state <= S_DONE;
                        endcase
                    end

                    S_DONE: begin
                        busy  <= 1'b0;
                        done  <= 1'b1;
                        state <= S_IDLE;
                    end

                    default: state <= S_IDLE;
                endcase
            end
        end
    end

endmodule

`default_nettype wire
