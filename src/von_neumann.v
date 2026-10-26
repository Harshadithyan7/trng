module von_neumann (
    input wire i_clk,
    input wire i_reset_n,
    input wire i_raw_bit,
    input wire i_valid,
    output reg o_random_bit,
    output reg o_valid
);
    reg first_bit;
    reg have_first;

    always @(posedge i_clk or negedge i_reset_n) begin
        if (!i_reset_n) begin
            first_bit <= 1'b0;
            have_first <= 1'b0;
            o_random_bit <= 1'b0;
            o_valid <= 1'b0;
        end else begin
            o_valid <= 1'b0;
            if (i_valid) begin
                if (!have_first) begin
                    first_bit <= i_raw_bit;
                    have_first <= 1'b1;
                end else begin
                    have_first <= 1'b0;
                    if (first_bit != i_raw_bit) begin
                        o_random_bit <= first_bit;
                        o_valid <= 1'b1;
                    end
                end
            end else begin
                have_first <= 1'b0;
            end
        end
    end
endmodule