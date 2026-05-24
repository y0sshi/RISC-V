// =============================================================================
/// @file rv_fregfile.sv
/// @brief Floating-Point Register File (f0-f31, IEEE 754 single-precision)
///
/// Provides three simultaneous read ports (rs1, rs2, rs3) and one write port.
/// rs3 is needed for the FMADD / FMSUB / FNMADD / FNMSUB instructions (R4-type).
///
/// All reads are combinational (asynchronous).
/// Writes are registered (synchronous, posedge clk).
/// f0 is NOT hardwired to zero (unlike integer x0).
///
/// @author Naofumi Yoshinaga
// =============================================================================

`default_nettype none

module rv_fregfile (
    input  wire        clk,
    input  wire        rst_n,

    // Read ports (combinational)
    input  wire  [4:0] rs1_addr,
    input  wire  [4:0] rs2_addr,
    input  wire  [4:0] rs3_addr,
    output logic [31:0] rs1_data,
    output logic [31:0] rs2_data,
    output logic [31:0] rs3_data,

    // Write port (registered)
    input  wire  [4:0] rd_addr,
    input  wire  [31:0] rd_data,
    input  wire        rd_we
);

    // 32 x 32-bit register array
    // (FP regs are always 32-bit for F extension; extended to 64-bit for D)
    logic [31:0] regs [32];

    // --- Combinational reads (with write-through for same-cycle write) ---
    always_comb begin
        rs1_data = regs[rs1_addr];
        rs2_data = regs[rs2_addr];
        rs3_data = regs[rs3_addr];
        // Write-through: forward the just-written value to any read port
        if (rd_we && rd_addr == rs1_addr) rs1_data = rd_data;
        if (rd_we && rd_addr == rs2_addr) rs2_data = rd_data;
        if (rd_we && rd_addr == rs3_addr) rs3_data = rd_data;
    end

    // --- Synchronous write ---
    always_ff @(posedge clk) begin
        if (rd_we)
            regs[rd_addr] <= rd_data;
    end

endmodule

`default_nettype wire
