`timescale 1ns/1ps
// tb_top.v — Full-system testbench for the FPGA AES-128 HSM.
//
// Simulates the PC side: sends UART bytes, receives the 16-byte response,
// then verifies encrypt/decrypt roundtrip.

module tb_top;
    // -------------------------------------------------------------------------
    // Timing constants
    // -------------------------------------------------------------------------
    localparam CLK_PERIOD  = 20;       // 50 MHz clock
    localparam BAUD_PERIOD = 8681;     // 1/115200 s * 1e9 ns/s ≈ 8681 ns
    localparam HALF_BAUD   = BAUD_PERIOD / 2;

    // -------------------------------------------------------------------------
    // Signals
    // -------------------------------------------------------------------------
    reg  clk     = 1'b0;
    reg  reset_n = 1'b0;
    reg  tb_tx   = 1'b1;   // PC -> FPGA (idle high)
    wire fpga_tx;           // FPGA -> PC

    // -------------------------------------------------------------------------
    // DUT
    // -------------------------------------------------------------------------
    top #(
        .CLK_FREQ (50_000_000),
        .BAUD_RATE(115_200)
    ) dut (
        .i_clk    (clk),
        .i_reset_n(reset_n),
        .i_uart_rx(tb_tx),
        .o_uart_tx(fpga_tx)
    );

    always #(CLK_PERIOD / 2) clk = ~clk;

    // -------------------------------------------------------------------------
    // UART tasks
    // -------------------------------------------------------------------------
    task send_byte;
        input [7:0] data;
        integer j;
        begin
            tb_tx = 1'b0;           // start bit
            #(BAUD_PERIOD);
            for (j = 0; j < 8; j = j + 1) begin
                tb_tx = data[j];    // LSB first
                #(BAUD_PERIOD);
            end
            tb_tx = 1'b1;           // stop bit
            #(BAUD_PERIOD);
        end
    endtask

    // Wait for one byte on fpga_tx and decode it.
    // Sampling at mid-bit using baud rate.
    task recv_byte;
        output [7:0] data;
        integer j;
        begin
            @(negedge fpga_tx);                  // falling edge = start bit
            #(BAUD_PERIOD + HALF_BAUD);          // skip start bit, land at mid of bit 0
            for (j = 0; j < 8; j = j + 1) begin
                data[j] = fpga_tx;
                #(BAUD_PERIOD);
            end
        end
    endtask

    // -------------------------------------------------------------------------
    // Test stimulus
    // -------------------------------------------------------------------------
    integer      i;
    reg [7:0]    ciphertext [0:15];
    reg [7:0]    decrypted  [0:15];
    reg          pass;

    initial begin
        $dumpfile("build/trng_hsm.vcd");
        $dumpvars(0, tb_top);

        // Release reset after 200 ns
        #200;
        reset_n = 1'b1;
        $display("[TB] Reset released. Waiting for TRNG + AES key schedule (~50 us)...");

        // Wait long enough for TRNG (~500 cycles) + key schedule (10 cycles)
        // At 50 MHz: 510 cycles * 20 ns = 10.2 us. Use 50 us to be safe.
        #50_000;
        $display("[TB] Sending ENCRYPT command: 0xEE 0x05 'Hello'");

        // ---- ENCRYPT: CMD=0xEE, LEN=5, DATA="Hello" ----
        send_byte(8'hEE);
        send_byte(8'd5);
        send_byte("H"); send_byte("e"); send_byte("l");
        send_byte("l"); send_byte("o");

        $display("[TB] Waiting for 16-byte ciphertext...");
        for (i = 0; i < 16; i = i + 1)
            recv_byte(ciphertext[i]);

        $write("[TB] Ciphertext:");
        for (i = 0; i < 16; i = i + 1)
            $write(" %02h", ciphertext[i]);
        $display("");

        // ---- DECRYPT: CMD=0xDD, LEN=16, DATA=ciphertext ----
        $display("[TB] Sending DECRYPT command: 0xDD 0x10 <ciphertext>");
        send_byte(8'hDD);
        send_byte(8'd16);
        for (i = 0; i < 16; i = i + 1)
            send_byte(ciphertext[i]);

        $display("[TB] Waiting for 16-byte plaintext...");
        for (i = 0; i < 16; i = i + 1)
            recv_byte(decrypted[i]);

        $write("[TB] Decrypted:");
        for (i = 0; i < 16; i = i + 1)
            $write(" %02h", decrypted[i]);
        $display("");

        // ---- Verify roundtrip ----
        pass = 1;
        if (decrypted[0] !== "H") pass = 0;
        if (decrypted[1] !== "e") pass = 0;
        if (decrypted[2] !== "l") pass = 0;
        if (decrypted[3] !== "l") pass = 0;
        if (decrypted[4] !== "o") pass = 0;
        // bytes 5..15 should be zero padding
        for (i = 5; i < 16; i = i + 1)
            if (decrypted[i] !== 8'd0) pass = 0;

        if (pass)
            $display("[TB] PASS: AES-128 encrypt/decrypt roundtrip verified ('Hello' + 11 zero bytes)");
        else begin
            $display("[TB] FAIL: roundtrip mismatch");
            $fatal(1, "AES-128 HSM roundtrip test FAILED");
        end

        $finish;
    end

    // Safety timeout
    initial begin
        #20_000_000;
        $fatal(1, "[TB] TIMEOUT after 20 ms of simulation");
    end
endmodule
