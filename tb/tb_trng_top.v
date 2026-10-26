`timescale 1ns/1ps

module tb_trng_top;
    reg clk = 1'b0;
    reg reset_n = 1'b0;
    reg enable = 1'b0;
    wire random_bit;
    wire valid;
    integer bit_file;
    integer bit_count = 0;
    localparam integer BITS_TO_CAPTURE = 128;
    string plaintext = "Hello harsha";
    reg [127:0] generated_key = 128'b0;
    reg [7:0] encrypted_bytes [0:15];
    reg [7:0] key_byte;
    reg [7:0] decoded_byte;
    integer text_index;

    always #5 clk = ~clk;

    trng_top dut (
        .i_clk(clk),
        .i_reset_n(reset_n),
        .i_enable(enable),
        .o_random_bit(random_bit),
        .o_valid(valid)
    );

    initial begin
        if (plaintext.len() > BITS_TO_CAPTURE / 8)
            $fatal(1, "plaintext is %0d bytes; maximum is %0d", plaintext.len(), BITS_TO_CAPTURE / 8);

        bit_file = $fopen("build/random_bits.txt", "w");
        if (bit_file == 0) begin
            $fatal(1, "could not open build/random_bits.txt");
        end
        $dumpfile("build/trng.vcd");
        $dumpvars(0, tb_trng_top);
        $write("Random bits: ");

        #20 reset_n = 1'b1;
        #10 enable = 1'b1;
    end

    always @(posedge clk) begin
        if (valid) begin
            $fwrite(bit_file, "%0d", random_bit);
            $write("%0d", random_bit);
            generated_key = {generated_key[126:0], random_bit};
            bit_count = bit_count + 1;
            if (bit_count == BITS_TO_CAPTURE) begin
                $fclose(bit_file);
                $display("");
                $display("Generated key (hex):");
                for (text_index = 0; text_index < BITS_TO_CAPTURE / 8; text_index = text_index + 1)
                    $write("%02x", generated_key[127 - 8 * text_index -: 8]);
                $display("");

                for (text_index = 0; text_index < plaintext.len(); text_index = text_index + 1) begin
                    key_byte = generated_key[127 - 8 * text_index -: 8];
                    encrypted_bytes[text_index] = plaintext[text_index] ^ key_byte;
                end

                $write("Ciphertext (hex): ");
                for (text_index = 0; text_index < plaintext.len(); text_index = text_index + 1)
                    $write("%02x", encrypted_bytes[text_index]);
                $display("");

                $write("Decoded text: ");
                for (text_index = 0; text_index < plaintext.len(); text_index = text_index + 1) begin
                    key_byte = generated_key[127 - 8 * text_index -: 8];
                    decoded_byte = encrypted_bytes[text_index] ^ key_byte;
                    if (decoded_byte !== plaintext[text_index])
                        $fatal(1, "decode mismatch at byte %0d", text_index);
                    $write("%c", decoded_byte);
                end
                $display("");
                $display("PASS: captured %0d corrected bits and decoded %0d text bytes", bit_count, plaintext.len());
                $finish;
            end
        end
    end

    initial begin
        #100000;
        $fatal(1, "timeout after capturing %0d corrected bits", bit_count);
    end
endmodule