// -----------------------------------------------------------------------------
// i2c_master.v -- minimal write-only I2C master
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

    localparam [3:0] S_IDLE  = 4'd0,
                     S_START = 4'd1,
                     S_BIT   = 4'd2,
                     S_ACK   = 4'd3,
                     S_STOP  = 4'd4,
                     S_DONE  = 4'd5;

    reg [3:0]  state;
    reg [1:0]  phase;
    reg [2:0]  bitc;
    reg [1:0]  bytec;
    reg [7:0]  shreg;
    reg        scl_r, sda_r;

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
                                if (bytec == 2'd2) begin
                                    state <= S_STOP;
                                end else begin
                                    shreg <= (bytec == 2'd0) ? reg_addr : data;
                                    bytec <= bytec + 2'd1;
                                    state <= S_BIT;
                                end
                            end
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
