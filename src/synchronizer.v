module synchronizer (
    input wire i_clk,
    input wire i_reset_n,
    input wire i_async,
    output wire o_sync
);
    (* ASYNC_REG = "TRUE" *) reg [1:0] sync_ff;

    always @(posedge i_clk or negedge i_reset_n) begin
        if (!i_reset_n)
            sync_ff <= 2'b00;
        else begin
            sync_ff[0] <= i_async;
            sync_ff[1] <= sync_ff[0];
        end
    end

    assign o_sync = sync_ff[1];
endmodule