// uart_tx.v — 8N1 UART transmitter.
// Assert i_send (only when o_busy=0) to begin transmitting i_data.
// o_busy stays high until the stop bit has been clocked out.

`timescale 1ns/1ps

module uart_tx #(
    parameter CLK_FREQ  = 50_000_000,
    parameter BAUD_RATE = 115_200
) (
    input  wire       i_clk,
    input  wire       i_reset_n,
    input  wire [7:0] i_data,
    input  wire       i_send,
    output reg        o_tx,
    output reg        o_busy
);
    localparam DIVISOR = CLK_FREQ / BAUD_RATE; // 434 @ 50 MHz/115200

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
            o_tx      <= 1'b1;   // UART idle line = high
            o_busy    <= 1'b0;
        end else begin
            case (state)
                IDLE: begin
                    o_tx   <= 1'b1;
                    o_busy <= 1'b0;
                    if (i_send) begin
                        shift_reg <= i_data;
                        baud_cnt  <= DIVISOR - 1;
                        o_tx      <= 1'b0;  // start bit
                        o_busy    <= 1'b1;
                        state     <= START;
                    end
                end
                START: begin
                    if (baud_cnt == 10'd0) begin
                        o_tx     <= shift_reg[0]; // LSB first
                        baud_cnt <= DIVISOR - 1;
                        bit_cnt  <= 3'd0;
                        state    <= DATA;
                    end else begin
                        baud_cnt <= baud_cnt - 1;
                    end
                end
                DATA: begin
                    if (baud_cnt == 10'd0) begin
                        baud_cnt <= DIVISOR - 1;
                        if (bit_cnt == 3'd7) begin
                            o_tx  <= 1'b1; // stop bit
                            state <= STOP;
                        end else begin
                            bit_cnt   <= bit_cnt + 1;
                            shift_reg <= {1'b0, shift_reg[7:1]};
                            o_tx      <= shift_reg[1];
                        end
                    end else begin
                        baud_cnt <= baud_cnt - 1;
                    end
                end
                STOP: begin
                    if (baud_cnt == 10'd0) begin
                        o_busy <= 1'b0;
                        state  <= IDLE;
                    end else begin
                        baud_cnt <= baud_cnt - 1;
                    end
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule
