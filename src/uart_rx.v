// uart_rx.v — 8N1 UART receiver.
// Samples i_rx and decodes one byte at a time.
// o_valid is a single-cycle pulse; o_data is stable while o_valid is high.

`timescale 1ns/1ps

module uart_rx #(
    parameter CLK_FREQ  = 50_000_000,
    parameter BAUD_RATE = 115_200
) (
    input  wire       i_clk,
    input  wire       i_reset_n,
    input  wire       i_rx,
    output reg  [7:0] o_data,
    output reg        o_valid
);
    localparam DIVISOR  = CLK_FREQ / BAUD_RATE; // 434 @ 50MHz/115200
    localparam HALF_DIV = DIVISOR / 2;           // 217

    localparam [1:0] IDLE  = 2'd0,
                     START = 2'd1,
                     DATA  = 2'd2,
                     STOP  = 2'd3;

    reg [1:0]  state;
    reg [9:0]  baud_cnt;
    reg [2:0]  bit_cnt;
    reg [7:0]  shift_reg;

    always @(posedge i_clk or negedge i_reset_n) begin
        if (!i_reset_n) begin
            state     <= IDLE;
            baud_cnt  <= 10'd0;
            bit_cnt   <= 3'd0;
            shift_reg <= 8'd0;
            o_data    <= 8'd0;
            o_valid   <= 1'b0;
        end else begin
            o_valid <= 1'b0;
            case (state)
                IDLE: begin
                    if (!i_rx) begin              // falling edge = start bit
                        state    <= START;
                        baud_cnt <= HALF_DIV - 1; // wait to mid-start
                    end
                end
                START: begin
                    if (baud_cnt == 10'd0) begin
                        if (!i_rx) begin          // still low → valid start bit
                            state    <= DATA;
                            baud_cnt <= DIVISOR - 1;
                            bit_cnt  <= 3'd0;
                        end else begin
                            state <= IDLE;        // glitch, abort
                        end
                    end else begin
                        baud_cnt <= baud_cnt - 1;
                    end
                end
                DATA: begin
                    if (baud_cnt == 10'd0) begin
                        shift_reg <= {i_rx, shift_reg[7:1]}; // LSB first
                        baud_cnt  <= DIVISOR - 1;
                        if (bit_cnt == 3'd7) begin
                            state <= STOP;
                        end else begin
                            bit_cnt <= bit_cnt + 1;
                        end
                    end else begin
                        baud_cnt <= baud_cnt - 1;
                    end
                end
                STOP: begin
                    if (baud_cnt == 10'd0) begin
                        if (i_rx) begin           // valid stop bit
                            o_data  <= shift_reg;
                            o_valid <= 1'b1;
                        end
                        state <= IDLE;
                    end else begin
                        baud_cnt <= baud_cnt - 1;
                    end
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule
