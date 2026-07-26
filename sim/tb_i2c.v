// SPDX-License-Identifier: GPL-2.0-or-later
// Decodes the I2C bus the ADV7513 initialiser drives and checks every
// transaction against the register table.
`timescale 1ns/1ps

module tb_i2c;

    localparam integer CLK_HZ = 2_000_000;

    reg clk = 0, rst_n = 0;
    always #250 clk = ~clk;              // 2 MHz

    wire scl, sda_out, configured, last_nack;

    // open drain with pull-ups; the slave model never stretches.
    // slave_sda must be declared before the continuous assign that reads it --
    // some Icarus builds reject declaration after use.
    reg  slave_sda = 1'b1;
    wire sda_line = sda_out & slave_sda;
    wire scl_line = scl;

    adv7513_init #(.CLK_HZ(CLK_HZ)) dut (
        .clk(clk), .rst_n(rst_n),
        .scl(scl), .sda_out(sda_out), .sda_in(sda_line),
        .configured(configured), .last_nack(last_nack)
    );

    // ---------------- I2C slave decoder ----------------
    reg [7:0]  shift;
    integer    nbits, nbytes, ntrans, nerr;
    reg [7:0]  cap_dev, cap_reg, cap_val;
    reg        active;
    reg        scl_d, sda_d;

    // expected table, mirrored from the RTL
    reg [15:0] expect_rom [0:46];
    initial begin
        expect_rom[ 0]=16'h9803; expect_rom[ 1]=16'hD6C0; expect_rom[ 2]=16'h4110;
        expect_rom[ 3]=16'h9A70; expect_rom[ 4]=16'h9C30; expect_rom[ 5]=16'h9D61;
        expect_rom[ 6]=16'hA2A4; expect_rom[ 7]=16'hA3A4; expect_rom[ 8]=16'hE0D0;
        expect_rom[ 9]=16'h3540; expect_rom[10]=16'h36D9; expect_rom[11]=16'h370A;
        expect_rom[12]=16'h3800; expect_rom[13]=16'h392D; expect_rom[14]=16'h3A00;
        expect_rom[15]=16'h1638; expect_rom[16]=16'h1700; expect_rom[17]=16'h3B00;
        expect_rom[18]=16'h3C00; expect_rom[19]=16'h4808; expect_rom[20]=16'h49A8;
        expect_rom[21]=16'h4000; expect_rom[22]=16'h4A80; expect_rom[23]=16'h4C00;
        expect_rom[24]=16'h5510; expect_rom[25]=16'h5608; expect_rom[26]=16'h5708;
        expect_rom[27]=16'h5900; expect_rom[28]=16'h7301; expect_rom[29]=16'h96FF;
        expect_rom[30]=16'hC900; expect_rom[31]=16'h9902; expect_rom[32]=16'h9B18;
        expect_rom[33]=16'h9F00; expect_rom[34]=16'hA100; expect_rom[35]=16'hA408;
        expect_rom[36]=16'hA504; expect_rom[37]=16'hA600; expect_rom[38]=16'hA700;
        expect_rom[39]=16'hA800; expect_rom[40]=16'hA900; expect_rom[41]=16'hAA00;
        expect_rom[42]=16'hAB40; expect_rom[43]=16'hAF04; expect_rom[44]=16'hBA60;
        expect_rom[45]=16'hE201; expect_rom[46]=16'hFA7D;
    end

    initial begin
        nbits = 0; nbytes = 0; ntrans = 0; nerr = 0; active = 0;
        shift = 0; scl_d = 1; sda_d = 1;
        #2000 rst_n = 1;
    end

    always @(posedge clk) begin
        // START: SDA falls while SCL high
        if (scl_line && scl_d && !sda_line && sda_d) begin
            active = 1; nbits = 0; nbytes = 0; shift = 0;
        end
        // STOP: SDA rises while SCL high
        else if (scl_line && scl_d && sda_line && !sda_d) begin
            if (active && nbytes == 3) begin
                if ({cap_reg, cap_val} !== expect_rom[ntrans]) begin
                    $display("  MISMATCH at %0d: got %02X=%02X expected %04X",
                             ntrans, cap_reg, cap_val, expect_rom[ntrans]);
                    nerr = nerr + 1;
                end
                if (cap_dev !== 8'h72) begin
                    $display("  BAD ADDR at %0d: %02X (expect 72 = 0x39<<1|W)",
                             ntrans, cap_dev);
                    nerr = nerr + 1;
                end
                ntrans = ntrans + 1;
                if (ntrans == 47) begin
                    $display("");
                    $display("decoded %0d transactions, %0d errors", ntrans, nerr);
                    $display("device address byte: %02X", cap_dev);
                    $display("first: %02X=%02X   last: %02X=%02X",
                             expect_rom[0][15:8], expect_rom[0][7:0],
                             cap_reg, cap_val);
                    $display("direct video markers: 0x3B=%02X (auto pixel repeat), 0xAF=%02X (DVI)",
                             expect_rom[17][7:0], expect_rom[43][7:0]);
                    $display("configured=%0b last_nack=%0b", configured, last_nack);
                    if (nerr) $display("FAIL"); else $display("PASS");
                    $finish;
                end
            end
            active = 0;
        end
        // sample data on rising SCL
        else if (scl_line && !scl_d && active) begin
            if (nbits < 8) begin
                shift = {shift[6:0], sda_line};
                nbits = nbits + 1;
            end else begin
                // ninth clock is the ack we drive low below
                case (nbytes)
                    0: cap_dev = shift;
                    1: cap_reg = shift;
                    2: cap_val = shift;
                endcase
                nbytes = nbytes + 1;
                nbits  = 0;
            end
        end
        scl_d = scl_line;
        sda_d = sda_line;
    end

    // pull SDA low for the ack bit
    always @(negedge scl_line) begin
        if (active && nbits == 8) slave_sda <= 1'b0;
        else                      slave_sda <= 1'b1;
    end

    initial begin
        #500_000_000;
        $display("TIMEOUT after %0d transactions, %0d errors", ntrans, nerr);
        $finish;
    end

endmodule
