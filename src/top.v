// top.v — FPGA AES-128 HSM top-level
//
// Pipeline:
//   1. Ring oscillators + Von Neumann corrector (trng_top) produce random bits.
//   2. key_gen accumulates 128 bits into the AES key (never leaves the FPGA).
//   3. aes128 expands the key schedule and accepts encrypt/decrypt requests.
//   4. Protocol FSM receives requests over UART RX and sends results over UART TX.
// One key is retained for one encrypt/decrypt pair. After decrypting the
// matching message, the old key is cleared and a fresh key is collected.
//
// PC -> FPGA protocol (over UART 115200 8N1):
//   Byte 0 : CMD  -- 0xEE = encrypt, 0xDD = decrypt
//   Byte 1 : LEN  -- number of payload bytes (1-16)
//   Byte 2+ : DATA -- LEN bytes (zero-padded to 16 inside the FPGA)
//
// FPGA -> PC: 16 bytes of AES output (MSB first)

`timescale 1ns/1ps

module top #(
    parameter CLK_FREQ  = 50_000_000,
    parameter BAUD_RATE = 115_200,
    parameter integer RO0_N = 3,
    parameter integer RO1_N = 5,
    parameter integer RO2_N = 7
) (
    input  wire i_clk,
    input  wire i_reset_n,
    input  wire i_uart_rx,
    output wire o_uart_tx
);

    // -------------------------------------------------------------------------
    // TRNG
    // -------------------------------------------------------------------------
    wire trng_bit, trng_valid;

    trng_top #(.RO0_N(RO0_N), .RO1_N(RO1_N), .RO2_N(RO2_N)) u_trng (
        .i_clk       (i_clk),
        .i_reset_n   (i_reset_n),
        .i_enable    (i_reset_n),
        .o_random_bit(trng_bit),
        .o_valid     (trng_valid)
    );

    // -------------------------------------------------------------------------
    // Key generator
    // -------------------------------------------------------------------------
    wire [127:0] raw_key;
    wire         key_ready;
    reg          key_ready_d;
    reg          key_restart;
    reg          encrypted_pending;
    wire         aes_key_valid = key_ready & ~key_ready_d;

    always @(posedge i_clk or negedge i_reset_n) begin
        if (!i_reset_n)
            key_ready_d <= 1'b0;
        else
            key_ready_d <= key_ready;
    end

    key_gen u_keygen (
        .i_clk       (i_clk),
        .i_reset_n   (i_reset_n),
        .i_restart   (key_restart),
        .i_random_bit(trng_bit),
        .i_bit_valid (trng_valid),
        .o_key       (raw_key),
        .o_key_ready (key_ready)
    );

    // -------------------------------------------------------------------------
    // AES-128 engine
    // -------------------------------------------------------------------------
    wire         aes_key_ready;
    wire [127:0] aes_result;
    wire         aes_done;

    reg  [127:0] aes_data_in;
    reg          aes_encrypt;
    reg          aes_start;

    aes128 u_aes (
        .i_clk      (i_clk),
        .i_reset_n  (i_reset_n),
        .i_key      (raw_key),
        .i_key_valid(aes_key_valid),
        .o_key_ready(aes_key_ready),
        .i_data     (aes_data_in),
        .i_encrypt  (aes_encrypt),
        .i_start    (aes_start),
        .o_data     (aes_result),
        .o_done     (aes_done)
    );

    // -------------------------------------------------------------------------
    // UART receiver
    // -------------------------------------------------------------------------
    wire [7:0] rx_data;
    wire       rx_valid;

    uart_rx #(.CLK_FREQ(CLK_FREQ), .BAUD_RATE(BAUD_RATE)) u_rx (
        .i_clk    (i_clk),
        .i_reset_n(i_reset_n),
        .i_rx     (i_uart_rx),
        .o_data   (rx_data),
        .o_valid  (rx_valid)
    );

    // -------------------------------------------------------------------------
    // UART transmitter
    // -------------------------------------------------------------------------
    reg  [7:0] tx_data;
    reg        tx_send;
    wire       tx_busy;

    uart_tx #(.CLK_FREQ(CLK_FREQ), .BAUD_RATE(BAUD_RATE)) u_tx (
        .i_clk    (i_clk),
        .i_reset_n(i_reset_n),
        .i_data   (tx_data),
        .i_send   (tx_send),
        .o_tx     (o_uart_tx),
        .o_busy   (tx_busy)
    );

    // -------------------------------------------------------------------------
    // Protocol FSM
    // -------------------------------------------------------------------------
    localparam [3:0]
        FSM_WAIT_KEY  = 4'd0,
        FSM_IDLE      = 4'd1,
        FSM_RECV_LEN  = 4'd2,
        FSM_RECV_DATA = 4'd3,
        FSM_AES_START = 4'd4,
        FSM_AES_WAIT  = 4'd5,
        FSM_SEND      = 4'd6;

    localparam CMD_ENC = 8'hEE;
    localparam CMD_DEC = 8'hDD;

    reg [3:0]   fsm_state;
    reg [3:0]   byte_cnt;
    // Five bits are required to represent the full 1..16 byte range.
    reg [4:0]   len_reg;
    reg [127:0] data_buf;
    reg [127:0] result_buf;
    reg [3:0]   tx_cnt;
    reg         cmd_enc;

    always @(posedge i_clk or negedge i_reset_n) begin
        if (!i_reset_n) begin
            fsm_state  <= FSM_WAIT_KEY;
            byte_cnt   <= 4'd0;
            len_reg    <= 5'd0;
            data_buf   <= 128'd0;
            result_buf <= 128'd0;
            tx_cnt     <= 4'd0;
            cmd_enc    <= 1'b1;
            aes_data_in<= 128'd0;
            aes_encrypt<= 1'b1;
            aes_start  <= 1'b0;
            key_restart <= 1'b0;
            encrypted_pending <= 1'b0;
            tx_data    <= 8'd0;
            tx_send    <= 1'b0;
        end else begin
            aes_start <= 1'b0;
            tx_send   <= 1'b0;
            key_restart <= 1'b0;

            case (fsm_state)

                FSM_WAIT_KEY: begin
                    if (aes_key_ready)
                        fsm_state <= FSM_IDLE;
                end

                FSM_IDLE: begin
                    if (rx_valid) begin
                        if ((rx_data == CMD_ENC && !encrypted_pending) ||
                            (rx_data == CMD_DEC && encrypted_pending)) begin
                            cmd_enc   <= (rx_data == CMD_ENC);
                            data_buf  <= 128'd0;
                            fsm_state <= FSM_RECV_LEN;
                        end
                    end
                end

                FSM_RECV_LEN: begin
                    if (rx_valid) begin
                        if (rx_data == 8'd0 || rx_data > 8'd16)
                            len_reg <= 5'd16;
                        else
                            len_reg <= {1'b0, rx_data[3:0]};
                        byte_cnt  <= 4'd0;
                        fsm_state <= FSM_RECV_DATA;
                    end
                end

                FSM_RECV_DATA: begin
                    if (rx_valid) begin
                        case (byte_cnt)
                            4'd0:  data_buf[127:120] <= rx_data;
                            4'd1:  data_buf[119:112] <= rx_data;
                            4'd2:  data_buf[111:104] <= rx_data;
                            4'd3:  data_buf[103:96]  <= rx_data;
                            4'd4:  data_buf[95:88]   <= rx_data;
                            4'd5:  data_buf[87:80]   <= rx_data;
                            4'd6:  data_buf[79:72]   <= rx_data;
                            4'd7:  data_buf[71:64]   <= rx_data;
                            4'd8:  data_buf[63:56]   <= rx_data;
                            4'd9:  data_buf[55:48]   <= rx_data;
                            4'd10: data_buf[47:40]   <= rx_data;
                            4'd11: data_buf[39:32]   <= rx_data;
                            4'd12: data_buf[31:24]   <= rx_data;
                            4'd13: data_buf[23:16]   <= rx_data;
                            4'd14: data_buf[15:8]    <= rx_data;
                            4'd15: data_buf[7:0]     <= rx_data;
                            default: ;
                        endcase
                        if ({1'b0, byte_cnt} == len_reg - 5'd1)
                            fsm_state <= FSM_AES_START;
                        else
                            byte_cnt <= byte_cnt + 1;
                    end
                end

                FSM_AES_START: begin
                    aes_data_in <= data_buf;
                    aes_encrypt <= cmd_enc;
                    aes_start   <= 1'b1;
                    fsm_state   <= FSM_AES_WAIT;
                end

                FSM_AES_WAIT: begin
                    if (aes_done) begin
                        result_buf <= aes_result;
                        tx_cnt     <= 4'd0;
                        if (cmd_enc)
                            encrypted_pending <= 1'b1;
                        else begin
                            encrypted_pending <= 1'b0;
                            key_restart <= 1'b1;
                        end
                        fsm_state  <= FSM_SEND;
                    end
                end

                FSM_SEND: begin
                    if (!tx_busy) begin
                        case (tx_cnt)
                            4'd0:  tx_data <= result_buf[127:120];
                            4'd1:  tx_data <= result_buf[119:112];
                            4'd2:  tx_data <= result_buf[111:104];
                            4'd3:  tx_data <= result_buf[103:96];
                            4'd4:  tx_data <= result_buf[95:88];
                            4'd5:  tx_data <= result_buf[87:80];
                            4'd6:  tx_data <= result_buf[79:72];
                            4'd7:  tx_data <= result_buf[71:64];
                            4'd8:  tx_data <= result_buf[63:56];
                            4'd9:  tx_data <= result_buf[55:48];
                            4'd10: tx_data <= result_buf[47:40];
                            4'd11: tx_data <= result_buf[39:32];
                            4'd12: tx_data <= result_buf[31:24];
                            4'd13: tx_data <= result_buf[23:16];
                            4'd14: tx_data <= result_buf[15:8];
                            4'd15: tx_data <= result_buf[7:0];
                            default: tx_data <= 8'd0;
                        endcase
                        tx_send <= 1'b1;
                        if (tx_cnt == 4'd15) begin
                            if (cmd_enc)
                                fsm_state <= FSM_IDLE;
                            else
                                fsm_state <= FSM_WAIT_KEY;
                        end
                        else
                            tx_cnt <= tx_cnt + 1;
                    end
                end

                default: fsm_state <= FSM_IDLE;
            endcase
        end
    end

endmodule
