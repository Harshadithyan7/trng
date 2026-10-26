module trng_top #(
    parameter integer RO0_N = 3,
    parameter integer RO1_N = 5,
    parameter integer RO2_N = 7
) (
    input wire i_clk,
    input wire i_reset_n,
    input wire i_enable,
    output wire o_random_bit,
    output wire o_valid
);
    wire [2:0] ro_sync;
    wire ro_sync_async0;
    wire ro_sync_async1;
    wire ro_sync_async2;
    wire raw_bit = ^ro_sync;

    ring_osc #(.N(RO0_N)) ro0 (.i_enable(i_enable), .o_clk(ro_sync_async0));
    ring_osc #(.N(RO1_N)) ro1 (.i_enable(i_enable), .o_clk(ro_sync_async1));
    ring_osc #(.N(RO2_N)) ro2 (.i_enable(i_enable), .o_clk(ro_sync_async2));

    synchronizer sync0 (.i_clk(i_clk), .i_reset_n(i_reset_n), .i_async(ro_sync_async0), .o_sync(ro_sync[0]));
    synchronizer sync1 (.i_clk(i_clk), .i_reset_n(i_reset_n), .i_async(ro_sync_async1), .o_sync(ro_sync[1]));
    synchronizer sync2 (.i_clk(i_clk), .i_reset_n(i_reset_n), .i_async(ro_sync_async2), .o_sync(ro_sync[2]));

    von_neumann corrector (
        .i_clk(i_clk),
        .i_reset_n(i_reset_n),
        .i_raw_bit(raw_bit),
        .i_valid(i_enable),
        .o_random_bit(o_random_bit),
        .o_valid(o_valid)
    );
endmodule