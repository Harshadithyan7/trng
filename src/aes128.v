// aes128.v — AES-128 ECB encrypt/decrypt (iterative, one round per clock)
//
// Key schedule : expanded sequentially over 10 cycles when i_key_valid pulses.
// Encrypt/decrypt: 11 cycles (init ARK + 10 rounds) after i_start is asserted.
// Latency from i_start to o_done : 12 clock cycles.
//
// State layout (128-bit register, column-major, MSB-first):
//   [127:96]  = column 0  {a00,a10,a20,a30}
//   [95:64]   = column 1  {a01,a11,a21,a31}
//   [63:32]   = column 2  {a02,a12,a22,a32}
//   [31:0]    = column 3  {a03,a13,a23,a33}

`timescale 1ns/1ps

module aes128 (
    input  wire         i_clk,
    input  wire         i_reset_n,
    // Key interface
    input  wire [127:0] i_key,
    input  wire         i_key_valid,   // pulse to load/expand a new key
    output reg          o_key_ready,   // held high after key schedule is done
    // Data interface
    input  wire [127:0] i_data,
    input  wire         i_encrypt,     // 1=encrypt, 0=decrypt
    input  wire         i_start,       // pulse to start (only when o_key_ready)
    output reg  [127:0] o_data,
    output reg          o_done         // 1-cycle pulse when o_data is valid
);

    // =========================================================================
    // FSM states
    // =========================================================================
    localparam [2:0] ST_IDLE     = 3'd0,
                     ST_KEY_EXP  = 3'd1,
                     ST_READY    = 3'd2,
                     ST_AES_RUN  = 3'd3,
                     ST_AES_DONE = 3'd4;

    reg [2:0]   state;
    reg [3:0]   ks_cnt;      // key-schedule counter 1..10
    reg [3:0]   round_cnt;   // AES round counter 1..10
    reg         encrypt_r;   // latched i_encrypt at start
    reg [127:0] aes_state;
    reg [127:0] rk [0:10];   // 11 × 128-bit round keys
    integer     ki;

    // =========================================================================
    // Helper functions
    // =========================================================================

    // --- GF(2^8) multiply by 2 ---
    function [7:0] xtime;
        input [7:0] a;
        xtime = {a[6:0], 1'b0} ^ (a[7] ? 8'h1b : 8'h00);
    endfunction

    // --- GF(2^8) multiplications for InvMixColumns ---
    function [7:0] mul9;
        input [7:0] a;
        mul9 = xtime(xtime(xtime(a))) ^ a;
    endfunction
    function [7:0] mul11;
        input [7:0] a;
        mul11 = xtime(xtime(xtime(a))) ^ xtime(a) ^ a;
    endfunction
    function [7:0] mul13;
        input [7:0] a;
        mul13 = xtime(xtime(xtime(a))) ^ xtime(xtime(a)) ^ a;
    endfunction
    function [7:0] mul14;
        input [7:0] a;
        mul14 = xtime(xtime(xtime(a))) ^ xtime(xtime(a)) ^ xtime(a);
    endfunction

    // --- Rcon[1..10] ---
    function [31:0] rcon_f;
        input [3:0] r;
        case (r)
            4'd1:  rcon_f = 32'h01000000;
            4'd2:  rcon_f = 32'h02000000;
            4'd3:  rcon_f = 32'h04000000;
            4'd4:  rcon_f = 32'h08000000;
            4'd5:  rcon_f = 32'h10000000;
            4'd6:  rcon_f = 32'h20000000;
            4'd7:  rcon_f = 32'h40000000;
            4'd8:  rcon_f = 32'h80000000;
            4'd9:  rcon_f = 32'h1b000000;
            4'd10: rcon_f = 32'h36000000;
            default: rcon_f = 32'h00000000;
        endcase
    endfunction

    // --- AES S-box ---
    function [7:0] sbox_f;
        input [7:0] in;
        case (in)
8'h00:sbox_f=8'h63;8'h01:sbox_f=8'h7c;8'h02:sbox_f=8'h77;8'h03:sbox_f=8'h7b;
8'h04:sbox_f=8'hf2;8'h05:sbox_f=8'h6b;8'h06:sbox_f=8'h6f;8'h07:sbox_f=8'hc5;
8'h08:sbox_f=8'h30;8'h09:sbox_f=8'h01;8'h0a:sbox_f=8'h67;8'h0b:sbox_f=8'h2b;
8'h0c:sbox_f=8'hfe;8'h0d:sbox_f=8'hd7;8'h0e:sbox_f=8'hab;8'h0f:sbox_f=8'h76;
8'h10:sbox_f=8'hca;8'h11:sbox_f=8'h82;8'h12:sbox_f=8'hc9;8'h13:sbox_f=8'h7d;
8'h14:sbox_f=8'hfa;8'h15:sbox_f=8'h59;8'h16:sbox_f=8'h47;8'h17:sbox_f=8'hf0;
8'h18:sbox_f=8'had;8'h19:sbox_f=8'hd4;8'h1a:sbox_f=8'ha2;8'h1b:sbox_f=8'haf;
8'h1c:sbox_f=8'h9c;8'h1d:sbox_f=8'ha4;8'h1e:sbox_f=8'h72;8'h1f:sbox_f=8'hc0;
8'h20:sbox_f=8'hb7;8'h21:sbox_f=8'hfd;8'h22:sbox_f=8'h93;8'h23:sbox_f=8'h26;
8'h24:sbox_f=8'h36;8'h25:sbox_f=8'h3f;8'h26:sbox_f=8'hf7;8'h27:sbox_f=8'hcc;
8'h28:sbox_f=8'h34;8'h29:sbox_f=8'ha5;8'h2a:sbox_f=8'he5;8'h2b:sbox_f=8'hf1;
8'h2c:sbox_f=8'h71;8'h2d:sbox_f=8'hd8;8'h2e:sbox_f=8'h31;8'h2f:sbox_f=8'h15;
8'h30:sbox_f=8'h04;8'h31:sbox_f=8'hc7;8'h32:sbox_f=8'h23;8'h33:sbox_f=8'hc3;
8'h34:sbox_f=8'h18;8'h35:sbox_f=8'h96;8'h36:sbox_f=8'h05;8'h37:sbox_f=8'h9a;
8'h38:sbox_f=8'h07;8'h39:sbox_f=8'h12;8'h3a:sbox_f=8'h80;8'h3b:sbox_f=8'he2;
8'h3c:sbox_f=8'heb;8'h3d:sbox_f=8'h27;8'h3e:sbox_f=8'hb2;8'h3f:sbox_f=8'h75;
8'h40:sbox_f=8'h09;8'h41:sbox_f=8'h83;8'h42:sbox_f=8'h2c;8'h43:sbox_f=8'h1a;
8'h44:sbox_f=8'h1b;8'h45:sbox_f=8'h6e;8'h46:sbox_f=8'h5a;8'h47:sbox_f=8'ha0;
8'h48:sbox_f=8'h52;8'h49:sbox_f=8'h3b;8'h4a:sbox_f=8'hd6;8'h4b:sbox_f=8'hb3;
8'h4c:sbox_f=8'h29;8'h4d:sbox_f=8'he3;8'h4e:sbox_f=8'h2f;8'h4f:sbox_f=8'h84;
8'h50:sbox_f=8'h53;8'h51:sbox_f=8'hd1;8'h52:sbox_f=8'h00;8'h53:sbox_f=8'hed;
8'h54:sbox_f=8'h20;8'h55:sbox_f=8'hfc;8'h56:sbox_f=8'hb1;8'h57:sbox_f=8'h5b;
8'h58:sbox_f=8'h6a;8'h59:sbox_f=8'hcb;8'h5a:sbox_f=8'hbe;8'h5b:sbox_f=8'h39;
8'h5c:sbox_f=8'h4a;8'h5d:sbox_f=8'h4c;8'h5e:sbox_f=8'h58;8'h5f:sbox_f=8'hcf;
8'h60:sbox_f=8'hd0;8'h61:sbox_f=8'hef;8'h62:sbox_f=8'haa;8'h63:sbox_f=8'hfb;
8'h64:sbox_f=8'h43;8'h65:sbox_f=8'h4d;8'h66:sbox_f=8'h33;8'h67:sbox_f=8'h85;
8'h68:sbox_f=8'h45;8'h69:sbox_f=8'hf9;8'h6a:sbox_f=8'h02;8'h6b:sbox_f=8'h7f;
8'h6c:sbox_f=8'h50;8'h6d:sbox_f=8'h3c;8'h6e:sbox_f=8'h9f;8'h6f:sbox_f=8'ha8;
8'h70:sbox_f=8'h51;8'h71:sbox_f=8'ha3;8'h72:sbox_f=8'h40;8'h73:sbox_f=8'h8f;
8'h74:sbox_f=8'h92;8'h75:sbox_f=8'h9d;8'h76:sbox_f=8'h38;8'h77:sbox_f=8'hf5;
8'h78:sbox_f=8'hbc;8'h79:sbox_f=8'hb6;8'h7a:sbox_f=8'hda;8'h7b:sbox_f=8'h21;
8'h7c:sbox_f=8'h10;8'h7d:sbox_f=8'hff;8'h7e:sbox_f=8'hf3;8'h7f:sbox_f=8'hd2;
8'h80:sbox_f=8'hcd;8'h81:sbox_f=8'h0c;8'h82:sbox_f=8'h13;8'h83:sbox_f=8'hec;
8'h84:sbox_f=8'h5f;8'h85:sbox_f=8'h97;8'h86:sbox_f=8'h44;8'h87:sbox_f=8'h17;
8'h88:sbox_f=8'hc4;8'h89:sbox_f=8'ha7;8'h8a:sbox_f=8'h7e;8'h8b:sbox_f=8'h3d;
8'h8c:sbox_f=8'h64;8'h8d:sbox_f=8'h5d;8'h8e:sbox_f=8'h19;8'h8f:sbox_f=8'h73;
8'h90:sbox_f=8'h60;8'h91:sbox_f=8'h81;8'h92:sbox_f=8'h4f;8'h93:sbox_f=8'hdc;
8'h94:sbox_f=8'h22;8'h95:sbox_f=8'h2a;8'h96:sbox_f=8'h90;8'h97:sbox_f=8'h88;
8'h98:sbox_f=8'h46;8'h99:sbox_f=8'hee;8'h9a:sbox_f=8'hb8;8'h9b:sbox_f=8'h14;
8'h9c:sbox_f=8'hde;8'h9d:sbox_f=8'h5e;8'h9e:sbox_f=8'h0b;8'h9f:sbox_f=8'hdb;
8'ha0:sbox_f=8'he0;8'ha1:sbox_f=8'h32;8'ha2:sbox_f=8'h3a;8'ha3:sbox_f=8'h0a;
8'ha4:sbox_f=8'h49;8'ha5:sbox_f=8'h06;8'ha6:sbox_f=8'h24;8'ha7:sbox_f=8'h5c;
8'ha8:sbox_f=8'hc2;8'ha9:sbox_f=8'hd3;8'haa:sbox_f=8'hac;8'hab:sbox_f=8'h62;
8'hac:sbox_f=8'h91;8'had:sbox_f=8'h95;8'hae:sbox_f=8'he4;8'haf:sbox_f=8'h79;
8'hb0:sbox_f=8'he7;8'hb1:sbox_f=8'hc8;8'hb2:sbox_f=8'h37;8'hb3:sbox_f=8'h6d;
8'hb4:sbox_f=8'h8d;8'hb5:sbox_f=8'hd5;8'hb6:sbox_f=8'h4e;8'hb7:sbox_f=8'ha9;
8'hb8:sbox_f=8'h6c;8'hb9:sbox_f=8'h56;8'hba:sbox_f=8'hf4;8'hbb:sbox_f=8'hea;
8'hbc:sbox_f=8'h65;8'hbd:sbox_f=8'h7a;8'hbe:sbox_f=8'hae;8'hbf:sbox_f=8'h08;
8'hc0:sbox_f=8'hba;8'hc1:sbox_f=8'h78;8'hc2:sbox_f=8'h25;8'hc3:sbox_f=8'h2e;
8'hc4:sbox_f=8'h1c;8'hc5:sbox_f=8'ha6;8'hc6:sbox_f=8'hb4;8'hc7:sbox_f=8'hc6;
8'hc8:sbox_f=8'he8;8'hc9:sbox_f=8'hdd;8'hca:sbox_f=8'h74;8'hcb:sbox_f=8'h1f;
8'hcc:sbox_f=8'h4b;8'hcd:sbox_f=8'hbd;8'hce:sbox_f=8'h8b;8'hcf:sbox_f=8'h8a;
8'hd0:sbox_f=8'h70;8'hd1:sbox_f=8'h3e;8'hd2:sbox_f=8'hb5;8'hd3:sbox_f=8'h66;
8'hd4:sbox_f=8'h48;8'hd5:sbox_f=8'h03;8'hd6:sbox_f=8'hf6;8'hd7:sbox_f=8'h0e;
8'hd8:sbox_f=8'h61;8'hd9:sbox_f=8'h35;8'hda:sbox_f=8'h57;8'hdb:sbox_f=8'hb9;
8'hdc:sbox_f=8'h86;8'hdd:sbox_f=8'hc1;8'hde:sbox_f=8'h1d;8'hdf:sbox_f=8'h9e;
8'he0:sbox_f=8'he1;8'he1:sbox_f=8'hf8;8'he2:sbox_f=8'h98;8'he3:sbox_f=8'h11;
8'he4:sbox_f=8'h69;8'he5:sbox_f=8'hd9;8'he6:sbox_f=8'h8e;8'he7:sbox_f=8'h94;
8'he8:sbox_f=8'h9b;8'he9:sbox_f=8'h1e;8'hea:sbox_f=8'h87;8'heb:sbox_f=8'he9;
8'hec:sbox_f=8'hce;8'hed:sbox_f=8'h55;8'hee:sbox_f=8'h28;8'hef:sbox_f=8'hdf;
8'hf0:sbox_f=8'h8c;8'hf1:sbox_f=8'ha1;8'hf2:sbox_f=8'h89;8'hf3:sbox_f=8'h0d;
8'hf4:sbox_f=8'hbf;8'hf5:sbox_f=8'he6;8'hf6:sbox_f=8'h42;8'hf7:sbox_f=8'h68;
8'hf8:sbox_f=8'h41;8'hf9:sbox_f=8'h99;8'hfa:sbox_f=8'h2d;8'hfb:sbox_f=8'h0f;
8'hfc:sbox_f=8'hb0;8'hfd:sbox_f=8'h54;8'hfe:sbox_f=8'hbb;8'hff:sbox_f=8'h16;
        endcase
    endfunction

    // --- AES Inverse S-box ---
    function [7:0] inv_sbox_f;
        input [7:0] in;
        case (in)
8'h00:inv_sbox_f=8'h52;8'h01:inv_sbox_f=8'h09;8'h02:inv_sbox_f=8'h6a;8'h03:inv_sbox_f=8'hd5;
8'h04:inv_sbox_f=8'h30;8'h05:inv_sbox_f=8'h36;8'h06:inv_sbox_f=8'ha5;8'h07:inv_sbox_f=8'h38;
8'h08:inv_sbox_f=8'hbf;8'h09:inv_sbox_f=8'h40;8'h0a:inv_sbox_f=8'ha3;8'h0b:inv_sbox_f=8'h9e;
8'h0c:inv_sbox_f=8'h81;8'h0d:inv_sbox_f=8'hf3;8'h0e:inv_sbox_f=8'hd7;8'h0f:inv_sbox_f=8'hfb;
8'h10:inv_sbox_f=8'h7c;8'h11:inv_sbox_f=8'he3;8'h12:inv_sbox_f=8'h39;8'h13:inv_sbox_f=8'h82;
8'h14:inv_sbox_f=8'h9b;8'h15:inv_sbox_f=8'h2f;8'h16:inv_sbox_f=8'hff;8'h17:inv_sbox_f=8'h87;
8'h18:inv_sbox_f=8'h34;8'h19:inv_sbox_f=8'h8e;8'h1a:inv_sbox_f=8'h43;8'h1b:inv_sbox_f=8'h44;
8'h1c:inv_sbox_f=8'hc4;8'h1d:inv_sbox_f=8'hde;8'h1e:inv_sbox_f=8'he9;8'h1f:inv_sbox_f=8'hcb;
8'h20:inv_sbox_f=8'h54;8'h21:inv_sbox_f=8'h7b;8'h22:inv_sbox_f=8'h94;8'h23:inv_sbox_f=8'h32;
8'h24:inv_sbox_f=8'ha6;8'h25:inv_sbox_f=8'hc2;8'h26:inv_sbox_f=8'h23;8'h27:inv_sbox_f=8'h3d;
8'h28:inv_sbox_f=8'hee;8'h29:inv_sbox_f=8'h4c;8'h2a:inv_sbox_f=8'h95;8'h2b:inv_sbox_f=8'h0b;
8'h2c:inv_sbox_f=8'h42;8'h2d:inv_sbox_f=8'hfa;8'h2e:inv_sbox_f=8'hc3;8'h2f:inv_sbox_f=8'h4e;
8'h30:inv_sbox_f=8'h08;8'h31:inv_sbox_f=8'h2e;8'h32:inv_sbox_f=8'ha1;8'h33:inv_sbox_f=8'h66;
8'h34:inv_sbox_f=8'h28;8'h35:inv_sbox_f=8'hd9;8'h36:inv_sbox_f=8'h24;8'h37:inv_sbox_f=8'hb2;
8'h38:inv_sbox_f=8'h76;8'h39:inv_sbox_f=8'h5b;8'h3a:inv_sbox_f=8'ha2;8'h3b:inv_sbox_f=8'h49;
8'h3c:inv_sbox_f=8'h6d;8'h3d:inv_sbox_f=8'h8b;8'h3e:inv_sbox_f=8'hd1;8'h3f:inv_sbox_f=8'h25;
8'h40:inv_sbox_f=8'h72;8'h41:inv_sbox_f=8'hf8;8'h42:inv_sbox_f=8'hf6;8'h43:inv_sbox_f=8'h64;
8'h44:inv_sbox_f=8'h86;8'h45:inv_sbox_f=8'h68;8'h46:inv_sbox_f=8'h98;8'h47:inv_sbox_f=8'h16;
8'h48:inv_sbox_f=8'hd4;8'h49:inv_sbox_f=8'ha4;8'h4a:inv_sbox_f=8'h5c;8'h4b:inv_sbox_f=8'hcc;
8'h4c:inv_sbox_f=8'h5d;8'h4d:inv_sbox_f=8'h65;8'h4e:inv_sbox_f=8'hb6;8'h4f:inv_sbox_f=8'h92;
8'h50:inv_sbox_f=8'h6c;8'h51:inv_sbox_f=8'h70;8'h52:inv_sbox_f=8'h48;8'h53:inv_sbox_f=8'h50;
8'h54:inv_sbox_f=8'hfd;8'h55:inv_sbox_f=8'hed;8'h56:inv_sbox_f=8'hb9;8'h57:inv_sbox_f=8'hda;
8'h58:inv_sbox_f=8'h5e;8'h59:inv_sbox_f=8'h15;8'h5a:inv_sbox_f=8'h46;8'h5b:inv_sbox_f=8'h57;
8'h5c:inv_sbox_f=8'ha7;8'h5d:inv_sbox_f=8'h8d;8'h5e:inv_sbox_f=8'h9d;8'h5f:inv_sbox_f=8'h84;
8'h60:inv_sbox_f=8'h90;8'h61:inv_sbox_f=8'hd8;8'h62:inv_sbox_f=8'hab;8'h63:inv_sbox_f=8'h00;
8'h64:inv_sbox_f=8'h8c;8'h65:inv_sbox_f=8'hbc;8'h66:inv_sbox_f=8'hd3;8'h67:inv_sbox_f=8'h0a;
8'h68:inv_sbox_f=8'hf7;8'h69:inv_sbox_f=8'he4;8'h6a:inv_sbox_f=8'h58;8'h6b:inv_sbox_f=8'h05;
8'h6c:inv_sbox_f=8'hb8;8'h6d:inv_sbox_f=8'hb3;8'h6e:inv_sbox_f=8'h45;8'h6f:inv_sbox_f=8'h06;
8'h70:inv_sbox_f=8'hd0;8'h71:inv_sbox_f=8'h2c;8'h72:inv_sbox_f=8'h1e;8'h73:inv_sbox_f=8'h8f;
8'h74:inv_sbox_f=8'hca;8'h75:inv_sbox_f=8'h3f;8'h76:inv_sbox_f=8'h0f;8'h77:inv_sbox_f=8'h02;
8'h78:inv_sbox_f=8'hc1;8'h79:inv_sbox_f=8'haf;8'h7a:inv_sbox_f=8'hbd;8'h7b:inv_sbox_f=8'h03;
8'h7c:inv_sbox_f=8'h01;8'h7d:inv_sbox_f=8'h13;8'h7e:inv_sbox_f=8'h8a;8'h7f:inv_sbox_f=8'h6b;
8'h80:inv_sbox_f=8'h3a;8'h81:inv_sbox_f=8'h91;8'h82:inv_sbox_f=8'h11;8'h83:inv_sbox_f=8'h41;
8'h84:inv_sbox_f=8'h4f;8'h85:inv_sbox_f=8'h67;8'h86:inv_sbox_f=8'hdc;8'h87:inv_sbox_f=8'hea;
8'h88:inv_sbox_f=8'h97;8'h89:inv_sbox_f=8'hf2;8'h8a:inv_sbox_f=8'hcf;8'h8b:inv_sbox_f=8'hce;
8'h8c:inv_sbox_f=8'hf0;8'h8d:inv_sbox_f=8'hb4;8'h8e:inv_sbox_f=8'he6;8'h8f:inv_sbox_f=8'h73;
8'h90:inv_sbox_f=8'h96;8'h91:inv_sbox_f=8'hac;8'h92:inv_sbox_f=8'h74;8'h93:inv_sbox_f=8'h22;
8'h94:inv_sbox_f=8'he7;8'h95:inv_sbox_f=8'had;8'h96:inv_sbox_f=8'h35;8'h97:inv_sbox_f=8'h85;
8'h98:inv_sbox_f=8'he2;8'h99:inv_sbox_f=8'hf9;8'h9a:inv_sbox_f=8'h37;8'h9b:inv_sbox_f=8'he8;
8'h9c:inv_sbox_f=8'h1c;8'h9d:inv_sbox_f=8'h75;8'h9e:inv_sbox_f=8'hdf;8'h9f:inv_sbox_f=8'h6e;
8'ha0:inv_sbox_f=8'h47;8'ha1:inv_sbox_f=8'hf1;8'ha2:inv_sbox_f=8'h1a;8'ha3:inv_sbox_f=8'h71;
8'ha4:inv_sbox_f=8'h1d;8'ha5:inv_sbox_f=8'h29;8'ha6:inv_sbox_f=8'hc5;8'ha7:inv_sbox_f=8'h89;
8'ha8:inv_sbox_f=8'h6f;8'ha9:inv_sbox_f=8'hb7;8'haa:inv_sbox_f=8'h62;8'hab:inv_sbox_f=8'h0e;
8'hac:inv_sbox_f=8'haa;8'had:inv_sbox_f=8'h18;8'hae:inv_sbox_f=8'hbe;8'haf:inv_sbox_f=8'h1b;
8'hb0:inv_sbox_f=8'hfc;8'hb1:inv_sbox_f=8'h56;8'hb2:inv_sbox_f=8'h3e;8'hb3:inv_sbox_f=8'h4b;
8'hb4:inv_sbox_f=8'hc6;8'hb5:inv_sbox_f=8'hd2;8'hb6:inv_sbox_f=8'h79;8'hb7:inv_sbox_f=8'h20;
8'hb8:inv_sbox_f=8'h9a;8'hb9:inv_sbox_f=8'hdb;8'hba:inv_sbox_f=8'hc0;8'hbb:inv_sbox_f=8'hfe;
8'hbc:inv_sbox_f=8'h78;8'hbd:inv_sbox_f=8'hcd;8'hbe:inv_sbox_f=8'h5a;8'hbf:inv_sbox_f=8'hf4;
8'hc0:inv_sbox_f=8'h1f;8'hc1:inv_sbox_f=8'hdd;8'hc2:inv_sbox_f=8'ha8;8'hc3:inv_sbox_f=8'h33;
8'hc4:inv_sbox_f=8'h88;8'hc5:inv_sbox_f=8'h07;8'hc6:inv_sbox_f=8'hc7;8'hc7:inv_sbox_f=8'h31;
8'hc8:inv_sbox_f=8'hb1;8'hc9:inv_sbox_f=8'h12;8'hca:inv_sbox_f=8'h10;8'hcb:inv_sbox_f=8'h59;
8'hcc:inv_sbox_f=8'h27;8'hcd:inv_sbox_f=8'h80;8'hce:inv_sbox_f=8'hec;8'hcf:inv_sbox_f=8'h5f;
8'hd0:inv_sbox_f=8'h60;8'hd1:inv_sbox_f=8'h51;8'hd2:inv_sbox_f=8'h7f;8'hd3:inv_sbox_f=8'ha9;
8'hd4:inv_sbox_f=8'h19;8'hd5:inv_sbox_f=8'hb5;8'hd6:inv_sbox_f=8'h4a;8'hd7:inv_sbox_f=8'h0d;
8'hd8:inv_sbox_f=8'h2d;8'hd9:inv_sbox_f=8'he5;8'hda:inv_sbox_f=8'h7a;8'hdb:inv_sbox_f=8'h9f;
8'hdc:inv_sbox_f=8'h93;8'hdd:inv_sbox_f=8'hc9;8'hde:inv_sbox_f=8'h9c;8'hdf:inv_sbox_f=8'hef;
8'he0:inv_sbox_f=8'ha0;8'he1:inv_sbox_f=8'he0;8'he2:inv_sbox_f=8'h3b;8'he3:inv_sbox_f=8'h4d;
8'he4:inv_sbox_f=8'hae;8'he5:inv_sbox_f=8'h2a;8'he6:inv_sbox_f=8'hf5;8'he7:inv_sbox_f=8'hb0;
8'he8:inv_sbox_f=8'hc8;8'he9:inv_sbox_f=8'heb;8'hea:inv_sbox_f=8'hbb;8'heb:inv_sbox_f=8'h3c;
8'hec:inv_sbox_f=8'h83;8'hed:inv_sbox_f=8'h53;8'hee:inv_sbox_f=8'h99;8'hef:inv_sbox_f=8'h61;
8'hf0:inv_sbox_f=8'h17;8'hf1:inv_sbox_f=8'h2b;8'hf2:inv_sbox_f=8'h04;8'hf3:inv_sbox_f=8'h7e;
8'hf4:inv_sbox_f=8'hba;8'hf5:inv_sbox_f=8'h77;8'hf6:inv_sbox_f=8'hd6;8'hf7:inv_sbox_f=8'h26;
8'hf8:inv_sbox_f=8'he1;8'hf9:inv_sbox_f=8'h69;8'hfa:inv_sbox_f=8'h14;8'hfb:inv_sbox_f=8'h63;
8'hfc:inv_sbox_f=8'h55;8'hfd:inv_sbox_f=8'h21;8'hfe:inv_sbox_f=8'h0c;8'hff:inv_sbox_f=8'h7d;
        endcase
    endfunction

    // --- SubWord / RotWord for key schedule ---
    function [31:0] sub_word;
        input [31:0] w;
        sub_word = {sbox_f(w[31:24]), sbox_f(w[23:16]), sbox_f(w[15:8]), sbox_f(w[7:0])};
    endfunction

    function [31:0] rot_word;
        input [31:0] w;
        rot_word = {w[23:0], w[31:24]};
    endfunction

    // --- Expand one round key from the previous ---
    function [127:0] expand_key;
        input [127:0] prev;
        input [3:0]   round;
        reg [31:0] pw0, pw1, pw2, pw3, temp, nw0, nw1, nw2, nw3;
        begin
            pw0  = prev[127:96]; pw1 = prev[95:64];
            pw2  = prev[63:32];  pw3 = prev[31:0];
            temp = sub_word(rot_word(pw3)) ^ rcon_f(round);
            nw0  = pw0 ^ temp;
            nw1  = pw1 ^ nw0;
            nw2  = pw2 ^ nw1;
            nw3  = pw3 ^ nw2;
            expand_key = {nw0, nw1, nw2, nw3};
        end
    endfunction

    // --- SubBytes / InvSubBytes ---
    function [127:0] sub_bytes;
        input [127:0] s;
        sub_bytes = {
            sbox_f(s[127:120]), sbox_f(s[119:112]),
            sbox_f(s[111:104]), sbox_f(s[103:96]),
            sbox_f(s[95:88]),   sbox_f(s[87:80]),
            sbox_f(s[79:72]),   sbox_f(s[71:64]),
            sbox_f(s[63:56]),   sbox_f(s[55:48]),
            sbox_f(s[47:40]),   sbox_f(s[39:32]),
            sbox_f(s[31:24]),   sbox_f(s[23:16]),
            sbox_f(s[15:8]),    sbox_f(s[7:0])
        };
    endfunction

    function [127:0] inv_sub_bytes;
        input [127:0] s;
        inv_sub_bytes = {
            inv_sbox_f(s[127:120]), inv_sbox_f(s[119:112]),
            inv_sbox_f(s[111:104]), inv_sbox_f(s[103:96]),
            inv_sbox_f(s[95:88]),   inv_sbox_f(s[87:80]),
            inv_sbox_f(s[79:72]),   inv_sbox_f(s[71:64]),
            inv_sbox_f(s[63:56]),   inv_sbox_f(s[55:48]),
            inv_sbox_f(s[47:40]),   inv_sbox_f(s[39:32]),
            inv_sbox_f(s[31:24]),   inv_sbox_f(s[23:16]),
            inv_sbox_f(s[15:8]),    inv_sbox_f(s[7:0])
        };
    endfunction

    // --- ShiftRows ---
    // Row r shifts left by r.  New byte(r,c) = old byte(r, (c+r) mod 4).
    // Encoding: col c occupies s[127-32c -: 32], row r in col at s[127-32c-8r -: 8].
    function [127:0] shift_rows;
        input [127:0] s;
        shift_rows = {
            s[127:120], s[87:80],   s[47:40],   s[7:0],     // col0 rows 0-3
            s[95:88],   s[55:48],   s[15:8],    s[103:96],  // col1 rows 0-3
            s[63:56],   s[23:16],   s[111:104], s[71:64],   // col2 rows 0-3
            s[31:24],   s[119:112], s[79:72],   s[39:32]    // col3 rows 0-3
        };
    endfunction

    // --- InvShiftRows ---
    // Row r shifts right by r.  New byte(r,c) = old byte(r, (c-r+4) mod 4).
    function [127:0] inv_shift_rows;
        input [127:0] s;
        inv_shift_rows = {
            s[127:120], s[23:16],   s[47:40],   s[71:64],   // col0
            s[95:88],   s[119:112], s[15:8],    s[39:32],   // col1
            s[63:56],   s[87:80],   s[111:104], s[7:0],     // col2
            s[31:24],   s[55:48],   s[79:72],   s[103:96]   // col3
        };
    endfunction

    // --- MixColumns (one 32-bit column) ---
    function [31:0] mix_col;
        input [31:0] col;
        reg [7:0] a0, a1, a2, a3;
        begin
            a0 = col[31:24]; a1 = col[23:16]; a2 = col[15:8]; a3 = col[7:0];
            mix_col[31:24] = xtime(a0) ^ xtime(a1) ^ a1       ^ a2       ^ a3;
            mix_col[23:16] = a0        ^ xtime(a1) ^ xtime(a2) ^ a2       ^ a3;
            mix_col[15:8]  = a0        ^ a1        ^ xtime(a2) ^ xtime(a3)^ a3;
            mix_col[7:0]   = xtime(a0) ^ a0        ^ a1        ^ a2       ^ xtime(a3);
        end
    endfunction

    // --- InvMixColumns (one 32-bit column) ---
    function [31:0] inv_mix_col;
        input [31:0] col;
        reg [7:0] a0, a1, a2, a3;
        begin
            a0 = col[31:24]; a1 = col[23:16]; a2 = col[15:8]; a3 = col[7:0];
            inv_mix_col[31:24] = mul14(a0)^mul11(a1)^mul13(a2)^mul9(a3);
            inv_mix_col[23:16] = mul9(a0) ^mul14(a1)^mul11(a2)^mul13(a3);
            inv_mix_col[15:8]  = mul13(a0)^mul9(a1) ^mul14(a2)^mul11(a3);
            inv_mix_col[7:0]   = mul11(a0)^mul13(a1)^mul9(a2) ^mul14(a3);
        end
    endfunction

    // --- Full MixColumns / InvMixColumns ---
    function [127:0] mix_columns;
        input [127:0] s;
        mix_columns = {mix_col(s[127:96]), mix_col(s[95:64]),
                       mix_col(s[63:32]),  mix_col(s[31:0])};
    endfunction

    function [127:0] inv_mix_columns;
        input [127:0] s;
        inv_mix_columns = {inv_mix_col(s[127:96]), inv_mix_col(s[95:64]),
                           inv_mix_col(s[63:32]),  inv_mix_col(s[31:0])};
    endfunction

    // =========================================================================
    // Main FSM
    // =========================================================================
    always @(posedge i_clk or negedge i_reset_n) begin
        if (!i_reset_n) begin
            state       <= ST_IDLE;
            ks_cnt      <= 4'd1;
            round_cnt   <= 4'd0;
            o_key_ready <= 1'b0;
            o_done      <= 1'b0;
            o_data      <= 128'd0;
            aes_state   <= 128'd0;
            encrypt_r   <= 1'b0;
            for (ki = 0; ki <= 10; ki = ki + 1)
                rk[ki] <= 128'd0;
        end else begin
            o_done <= 1'b0;
            case (state)

                // ---- Wait for key_gen to finish ----
                ST_IDLE: begin
                    if (i_key_valid) begin
                        rk[0]  <= i_key;
                        ks_cnt <= 4'd1;
                        state  <= ST_KEY_EXP;
                    end
                end

                // ---- Expand key schedule (one round key per cycle) ----
                ST_KEY_EXP: begin
                    rk[ks_cnt] <= expand_key(rk[ks_cnt - 1], ks_cnt);
                    if (ks_cnt == 4'd10) begin
                        o_key_ready <= 1'b1;
                        state       <= ST_READY;
                    end else begin
                        ks_cnt <= ks_cnt + 1;
                    end
                end

                // ---- Idle: waiting for start pulse ----
                ST_READY: begin
                    if (i_key_valid) begin
                        // A fresh key may be loaded after the previous message pair.
                        rk[0]         <= i_key;
                        ks_cnt        <= 4'd1;
                        o_key_ready   <= 1'b0;
                        state         <= ST_KEY_EXP;
                    end else if (i_start) begin
                        encrypt_r <= i_encrypt;
                        // Initial AddRoundKey
                        aes_state <= i_data ^ (i_encrypt ? rk[0] : rk[10]);
                        round_cnt <= 4'd1;
                        state     <= ST_AES_RUN;
                    end
                end

                // ---- AES rounds 1..10 ----
                ST_AES_RUN: begin
                    if (encrypt_r) begin
                        if (round_cnt < 4'd10)
                            // Rounds 1-9: SubBytes → ShiftRows → MixColumns → AddRoundKey
                            aes_state <= mix_columns(
                                             shift_rows(sub_bytes(aes_state))
                                         ) ^ rk[round_cnt];
                        else begin
                            // Round 10: no MixColumns
                            aes_state <= shift_rows(sub_bytes(aes_state)) ^ rk[10];
                            state     <= ST_AES_DONE;
                        end
                    end else begin
                        if (round_cnt < 4'd10)
                            // Inv rounds 1-9: InvShiftRows → InvSubBytes → ARK → InvMixColumns
                            aes_state <= inv_mix_columns(
                                             inv_sub_bytes(inv_shift_rows(aes_state))
                                             ^ rk[4'd10 - round_cnt]
                                         );
                        else begin
                            // Inv round 10 (final): no InvMixColumns
                            aes_state <= inv_sub_bytes(inv_shift_rows(aes_state)) ^ rk[0];
                            state     <= ST_AES_DONE;
                        end
                    end
                    round_cnt <= round_cnt + 1;
                end

                // ---- Done: output result ----
                ST_AES_DONE: begin
                    o_data <= aes_state;
                    o_done <= 1'b1;
                    state  <= ST_READY;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end
endmodule
