// key_gen.v — Accumulates 128 corrected random bits into a key register.
// Once all 128 bits are collected, o_key_ready is asserted and held until
// i_restart or reset asks the module to discard the key and collect another.

module key_gen (
    input  wire         i_clk,
    input  wire         i_reset_n,
    input  wire         i_restart,      // discard current key and collect a fresh one
    input  wire         i_random_bit,  // one corrected bit from TRNG
    input  wire         i_bit_valid,   // strobe: i_random_bit is valid this cycle
    output reg  [127:0] o_key,
    output reg          o_key_ready
);
    reg [6:0] bit_count; // tracks 0..127

    always @(posedge i_clk or negedge i_reset_n) begin
        if (!i_reset_n) begin
            o_key       <= 128'd0;
            o_key_ready <= 1'b0;
            bit_count   <= 7'd0;
        end else if (i_restart) begin
            o_key       <= 128'd0;
            o_key_ready <= 1'b0;
            bit_count   <= 7'd0;
        end else if (!o_key_ready && i_bit_valid) begin
            o_key <= {o_key[126:0], i_random_bit};
            if (bit_count == 7'd127) begin
                o_key_ready <= 1'b1;
            end else begin
                bit_count <= bit_count + 1'b1;
            end
        end
    end
endmodule
