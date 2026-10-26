`timescale 1ns/1ps

module ring_osc #(
    parameter integer N = 3,
    parameter integer SIM_HALF_PERIOD = N + 2,
    parameter integer SIM_JITTER = 2
) (
    input wire i_enable,
    output wire o_clk
);

`ifdef SYNTHESIS
    (* keep = "true", dont_touch = "true" *) wire [N-1:0] loop_stage;
    assign loop_stage[0] = i_enable ? ~loop_stage[N-1] : 1'b0;

    genvar stage;
    generate
        for (stage = 1; stage < N; stage = stage + 1) begin : g_inverter
            assign loop_stage[stage] = i_enable ? ~loop_stage[stage-1] : 1'b0;
        end
    endgenerate

    assign o_clk = loop_stage[N-1];
`else
    reg sim_clk = 1'b0;
    integer jitter_delay;

    always begin
        if (!i_enable) begin
            sim_clk = 1'b0;
            @(posedge i_enable);
        end else begin
            jitter_delay = (($random & 32'h7fffffff) % (2 * SIM_JITTER + 1)) - SIM_JITTER;
            #(SIM_HALF_PERIOD + jitter_delay);
            if (i_enable)
                sim_clk = ~sim_clk;
            else
                sim_clk = 1'b0;
        end
    end

    assign o_clk = sim_clk;
`endif
endmodule