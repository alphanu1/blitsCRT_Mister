`timescale 1ns/1ps
`default_nettype none
//
// tb_mcp23009.v -- the I/O expander driver against a model of the device.
//
// This cannot be tried on hardware yet: the IO_SCL/IO_SDA pin numbers are still
// needed. So the protocol is checked here instead -- that the init sequence
// writes the registers it should, that a GPIO write carries the LED bits in the
// right order, that a read brings the buttons back in the right bits, and that
// an absent expander leaves present low rather than reporting phantom presses.
//
// The model is deliberately literal: it decodes START, bytes, ACK and STOP off
// the wire rather than being handed transactions, so a mistake in the master's
// repeated START would show up here rather than on a board.

module tb_mcp23009;

    reg clk = 0, rst_n = 0;
    always #10 clk = ~clk;              // 50 MHz

    reg  [2:0] led = 3'b000;
    wire [2:0] btn;
    wire       sd_cd, mode, present;
    wire       scl, sda_out;
    wire       sda_in;

    /* Open-drain: whoever pulls low wins, otherwise the pull-up. */
    wire sda_slave;
    assign sda_in = sda_out & sda_slave;

    mcp23009 #(.CLK_HZ(50_000_000)) dut (
        .clk(clk), .rst_n(rst_n),
        .led(led), .btn(btn), .sd_cd(sd_cd), .mode(mode), .present(present),
        .scl(scl), .sda_out(sda_out), .sda_in(sda_in)
    );

    // ---------------- a model MCP23009 ----------------
    //
    // A literal slave: START and STOP off SDA transitions while SCL is high,
    // data sampled on the rising edge, ACK and read data driven on the falling
    // edge. One block owns sda_drive, so there is nothing to race.

    reg present_on_bus = 1;             // 0 models a board with none fitted
    reg [7:0] gpio_in  = 8'h00;         // what a read returns
    reg [7:0] last_gpio_write = 8'hFF;

    reg [7:0] regfile [0:15];

    reg sda_drive = 1;                  // 1 = released
    assign sda_slave = sda_drive;

    reg [7:0] shift;
    reg [3:0] nbits;
    reg [1:0] phase;                    // 0 addr, 1 reg, 2 write data, 3 read
    reg       in_xfer, acking;
    reg [7:0] cur_reg;

    initial begin
        in_xfer = 0; acking = 0; nbits = 0; shift = 0;
        phase = 0; cur_reg = 0; sda_drive = 1;
    end

    // START / STOP
    always @(negedge sda_in) if (scl && !acking) begin
        in_xfer <= 1; nbits <= 0; shift <= 0; phase <= 0; sda_drive <= 1;
    end
    always @(posedge sda_in) if (scl && !acking) begin
        in_xfer <= 0; sda_drive <= 1;
    end

    // sample on the rising edge
    always @(posedge scl) if (in_xfer && !acking && phase != 2'd3) begin
        shift <= {shift[6:0], sda_in};
        nbits <= nbits + 1;
    end

    // act on the falling edge
    always @(negedge scl) if (in_xfer) begin
        if (acking) begin
            acking    <= 0;
            sda_drive <= 1;
            nbits     <= 0;
            if (phase == 2'd3) begin
                // first read bit goes out now
                sda_drive <= gpio_in[7];
                nbits     <= 1;
            end
        end else if (phase == 2'd3) begin
            if (nbits < 8) begin
                sda_drive <= gpio_in[7 - nbits];
                nbits     <= nbits + 1;
            end else begin
                sda_drive <= 1;         // let the master NACK
            end
        end else if (nbits == 8) begin
            case (phase)
                2'd0: begin
                    if (present_on_bus && shift[7:1] == 7'h20) begin
                        sda_drive <= 0;
                        acking    <= 1;
                        phase     <= shift[0] ? 2'd3 : 2'd1;
                    end else begin
                        in_xfer <= 0;   // not us
                    end
                end
                2'd1: begin
                    cur_reg   <= shift;
                    sda_drive <= present_on_bus ? 1'b0 : 1'b1;
                    acking    <= 1;
                    phase     <= 2'd2;
                end
                2'd2: begin
                    sda_drive <= present_on_bus ? 1'b0 : 1'b1;
                    acking    <= 1;
                end
                default: ;
            endcase
        end
    end

    /* The write itself, split out so the register index is cur_reg rather than
     * the byte just shifted in. */
    always @(negedge scl) begin
        if (in_xfer && !acking && phase == 2'd2 && nbits == 8) begin
            regfile[cur_reg[3:0]] <= shift;
            if (cur_reg == 8'h09) last_gpio_write <= shift;
        end
    end

    // ---------------- checks ----------------

    integer fails = 0;
    task chk(input [51*8:1] name, input ok);
        begin
            $write("  %-52s %s\n", name, ok ? "ok" : "FAIL");
            if (!ok) fails = fails + 1;
        end
    endtask

    initial begin
        $display("MCP23009 I/O expander");

        #100 rst_n = 1;

        /* Let the init sequence run. */
        #4_000_000;

        chk("IODIR set: LEDs out, buttons in", regfile[0] == 8'hF8);
        chk("IPOL set: button bits inverted",  regfile[1] == 8'h38);
        chk("IOCON set",                       regfile[5] == 8'h24);
        chk("GPPU set: pull-ups on",           regfile[6] == 8'hFF);

        /* Light the power LED only. led = {power, disk, user}, and the device
         * wants {.., user, disk, power} in bits 0..2. */
        led = 3'b100;
        #3_000_000;
        chk("LED write puts power on GP2", last_gpio_write[2] == 1'b1 &&
                                           last_gpio_write[1] == 1'b0 &&
                                           last_gpio_write[0] == 1'b0);

        led = 3'b001;
        #3_000_000;
        chk("LED write puts user on GP0",  last_gpio_write[0] == 1'b1 &&
                                           last_gpio_write[2] == 1'b0);

        /* Buttons come back in GP3..5, already inverted by IPOL. */
        gpio_in = 8'b0000_1000;         // user
        #3_000_000;
        chk("user button reads back",     btn == 3'b001);

        gpio_in = 8'b0010_0000;         // OSD
        #3_000_000;
        chk("OSD button reads back",      btn == 3'b100);

        gpio_in = 8'b1100_0000;          // flags, no buttons
        #3_000_000;
        chk("flags decode, no phantom press", btn == 3'b000 &&
                                              mode == 1'b1 && sd_cd == 1'b1);
        chk("present asserted once a read is acked", present == 1'b1);

        /*
         * No expander fitted. Every transfer NACKs; present must drop and no
         * button may appear pressed -- a phantom reset would be worse than no
         * buttons at all.
         */
        present_on_bus = 0;
        gpio_in = 8'hFF;
        #6_000_000;
        chk("absent expander clears present", present == 1'b0);
        chk("absent expander reports no presses", btn == 3'b000);

        if (fails) $display("\nFAIL  %0d checks", fails);
        else       $display("\nPASS");
        $finish;
    end

    initial begin
        #60_000_000;
        $display("\nFAIL  timed out");
        $finish;
    end

endmodule

`default_nettype wire
