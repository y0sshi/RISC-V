// =============================================================================
// rv_amo.sv - A-Extension Atomic Memory Operation Compute Unit
// =============================================================================
// Purely combinational: given the old memory value (old_data) and the register
// operand (rs2_data), produces the new value to write back to memory.
//
// funct3 selects the operand width:
//   3'b010 (W) : 32-bit operation; result is sign-extended to XLEN
//   3'b011 (D) : XLEN-bit operation (RV64A only)
//
// Operations:
//   AMO_LR   — no write (returns old_data unchanged; rv_core suppresses write)
//   AMO_SC   — new = rs2  (write rs2 to memory; rv_core applies reservation check)
//   AMO_SWAP — new = rs2
//   AMO_ADD  — new = old + rs2
//   AMO_XOR  — new = old ^ rs2
//   AMO_AND  — new = old & rs2
//   AMO_OR   — new = old | rs2
//   AMO_MIN  — new = signed_min(old, rs2)
//   AMO_MAX  — new = signed_max(old, rs2)
//   AMO_MINU — new = unsigned_min(old, rs2)
//   AMO_MAXU — new = unsigned_max(old, rs2)
//
// Author: Naofumi Yoshinaga
// =============================================================================

`default_nettype none

module rv_amo
    import rv_pkg::*;
#(
    parameter int XLEN = rv_pkg::XLEN
) (
    input  wire  [XLEN-1:0]  old_data,   // value read from memory
    input  wire  [XLEN-1:0]  rs2_data,   // register operand (store data)
    input  amo_op_t           op,
    input  wire  [2:0]        funct3,     // 010 = W (32-bit), 011 = D (XLEN-bit)
    output logic [XLEN-1:0]  new_data    // value to write back to memory
);

    // =========================================================================
    // W-type (32-bit) intermediate results
    // =========================================================================
    // Computed using only the lower 32 bits; the results are sign-extended in
    // the final mux below.  Wire-assigns avoid iverilog "sorry: constant selects"
    // in always_* procedural blocks.
    // =========================================================================
    logic [31:0] add_w,  xor_w,  and_w,  or_w;
    logic [31:0] min_w,  max_w,  minu_w, maxu_w;

    assign add_w  = old_data[31:0] + rs2_data[31:0];
    assign xor_w  = old_data[31:0] ^ rs2_data[31:0];
    assign and_w  = old_data[31:0] & rs2_data[31:0];
    assign or_w   = old_data[31:0] | rs2_data[31:0];
    assign min_w  = ($signed(old_data[31:0]) < $signed(rs2_data[31:0])) ? old_data[31:0] : rs2_data[31:0];
    assign max_w  = ($signed(old_data[31:0]) > $signed(rs2_data[31:0])) ? old_data[31:0] : rs2_data[31:0];
    assign minu_w = (old_data[31:0] < rs2_data[31:0]) ? old_data[31:0] : rs2_data[31:0];
    assign maxu_w = (old_data[31:0] > rs2_data[31:0]) ? old_data[31:0] : rs2_data[31:0];

    // =========================================================================
    // D-type (XLEN-bit) intermediate results
    // =========================================================================
    logic [XLEN-1:0] add_d,  xor_d,  and_d,  or_d;
    logic [XLEN-1:0] min_d,  max_d,  minu_d, maxu_d;

    assign add_d  = old_data + rs2_data;
    assign xor_d  = old_data ^ rs2_data;
    assign and_d  = old_data & rs2_data;
    assign or_d   = old_data | rs2_data;
    assign min_d  = ($signed(old_data) < $signed(rs2_data)) ? old_data : rs2_data;
    assign max_d  = ($signed(old_data) > $signed(rs2_data)) ? old_data : rs2_data;
    assign minu_d = (old_data < rs2_data) ? old_data : rs2_data;
    assign maxu_d = (old_data > rs2_data) ? old_data : rs2_data;

    // =========================================================================
    // Sign-extension helper (W → XLEN)
    // For XLEN=32: {{0{x}}, val} = val (zero-width replication is legal SV)
    // For XLEN=64: {{32{val[31]}}, val}
    // =========================================================================
    // Wires to carry sign-extended W results
    logic [XLEN-1:0] sx_add_w, sx_xor_w, sx_and_w, sx_or_w;
    logic [XLEN-1:0] sx_min_w, sx_max_w, sx_minu_w, sx_maxu_w;
    logic [XLEN-1:0] sx_rs2_w, sx_old_w;

    assign sx_add_w  = {{(XLEN-32){add_w[31]}},         add_w};
    assign sx_xor_w  = {{(XLEN-32){xor_w[31]}},         xor_w};
    assign sx_and_w  = {{(XLEN-32){and_w[31]}},         and_w};
    assign sx_or_w   = {{(XLEN-32){or_w[31]}},          or_w};
    assign sx_min_w  = {{(XLEN-32){min_w[31]}},         min_w};
    assign sx_max_w  = {{(XLEN-32){max_w[31]}},         max_w};
    assign sx_minu_w = {{(XLEN-32){minu_w[31]}},        minu_w};
    assign sx_maxu_w = {{(XLEN-32){maxu_w[31]}},        maxu_w};
    assign sx_rs2_w  = {{(XLEN-32){rs2_data[31]}},      rs2_data[31:0]};
    assign sx_old_w  = {{(XLEN-32){old_data[31]}},      old_data[31:0]};

    // =========================================================================
    // Result mux (funct3[0]: 0=W, 1=D)
    // =========================================================================
    always_comb begin
        new_data = '0;
        unique case (op)
            // LR: no write occurs; return old_data so the interface is defined
            AMO_LR:   new_data = funct3[0] ? old_data : sx_old_w;

            // SC / SWAP: write rs2 to memory
            AMO_SC,
            AMO_SWAP: new_data = funct3[0] ? rs2_data : sx_rs2_w;

            // Arithmetic / logical
            AMO_ADD:  new_data = funct3[0] ? add_d  : sx_add_w;
            AMO_XOR:  new_data = funct3[0] ? xor_d  : sx_xor_w;
            AMO_AND:  new_data = funct3[0] ? and_d  : sx_and_w;
            AMO_OR:   new_data = funct3[0] ? or_d   : sx_or_w;

            // Signed min/max
            AMO_MIN:  new_data = funct3[0] ? min_d  : sx_min_w;
            AMO_MAX:  new_data = funct3[0] ? max_d  : sx_max_w;

            // Unsigned min/max
            AMO_MINU: new_data = funct3[0] ? minu_d : sx_minu_w;
            AMO_MAXU: new_data = funct3[0] ? maxu_d : sx_maxu_w;

            default:  new_data = '0;
        endcase
    end

endmodule

`default_nettype wire
