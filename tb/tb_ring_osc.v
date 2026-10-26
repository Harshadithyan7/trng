`timescale 1ns/1ps

module tb_ring_osc;
    reg enable = 1'b0;
    wire osc;
    integer transitions = 0;

    ring_osc #(.N(3)) dut (.i_enable(enable), .o_clk(osc));

    always @(osc)
        transitions = transitions + 1;

    initial begin
        $dumpfile("build/ring_osc.vcd");
        $dumpvars(0, tb_ring_osc);
        #10 enable = 1'b1;
        #200 enable = 1'b0;
        #1;
        if (transitions < 10)
            $fatal(1, "expected oscillator transitions, saw %0d", transitions);
        else
            $display("PASS: observed %0d oscillator transitions", transitions);
        $finish;
    end
endmodule