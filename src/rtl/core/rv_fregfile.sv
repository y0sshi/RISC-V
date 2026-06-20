// =============================================================================
/// @file rv_fregfile.sv
/// @brief Floating-Point Register File (f0-f31, IEEE 754 double-precision width)
///
/// Provides three simultaneous read ports (rs1, rs2, rs3) and TWO write ports.
/// rs3 is needed for the FMADD / FMSUB / FNMADD / FNMSUB instructions (R4-type).
///
/// Write port A (rd_*) is the on-time port used by FP compute results.
/// Write port B (rd2_*) is the delayed port used by the late FP-load writeback
/// (the FP-load value is registered one cycle at the core boundary to break the
/// long D$-data -> FP-datapath route; see rv_core fpld_* logic).  Because FP
/// loads write one cycle later than FP compute results, the two ports can target
/// the same f-register on the same cycle.  Program order makes the load OLDER, so
/// the on-time port (A) takes priority on an address conflict (both the write
/// commit and the write-through forward).
///
/// Each register is 64-bit to support the D-extension (double precision).
/// F-extension single-precision values are NaN-boxed (upper 32 bits = all 1s)
/// before being stored; the FPU checks NaN-boxing at read time.
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
    output logic [63:0] rs1_data,
    output logic [63:0] rs2_data,
    output logic [63:0] rs3_data,

    // Write port A: on-time (FP compute results)
    input  wire  [4:0] rd_addr,
    input  wire  [63:0] rd_data,
    input  wire        rd_we,

    // Write port B: delayed (late FP-load writeback)
    input  wire  [4:0] rd2_addr,
    input  wire  [63:0] rd2_data,
    input  wire        rd2_we
);

    // 32 x 64-bit register array (FLEN=64 for F+D extensions)
    logic [63:0] regs [32];

    // --- Combinational reads (with write-through for same-cycle write) ---
    // Port B (delayed FP-load) is the OLDER writer; port A (on-time) the YOUNGER.
    // Apply B first, then A, so A wins on an address conflict (latest in program
    // order is forwarded).
    always_comb begin
        rs1_data = regs[rs1_addr];
        rs2_data = regs[rs2_addr];
        rs3_data = regs[rs3_addr];
        // Write-through port B (delayed) first
        if (rd2_we && rd2_addr == rs1_addr) rs1_data = rd2_data;
        if (rd2_we && rd2_addr == rs2_addr) rs2_data = rd2_data;
        if (rd2_we && rd2_addr == rs3_addr) rs3_data = rd2_data;
        // Write-through port A (on-time) second -> takes priority on conflict
        if (rd_we && rd_addr == rs1_addr) rs1_data = rd_data;
        if (rd_we && rd_addr == rs2_addr) rs2_data = rd_data;
        if (rd_we && rd_addr == rs3_addr) rs3_data = rd_data;
    end

    // --- Synchronous write ---
    // Port B first, port A second: a same-address conflict resolves to port A
    // (the younger on-time write) via last-assignment-wins on the NBA.
    always_ff @(posedge clk) begin
        if (rd2_we)
            regs[rd2_addr] <= rd2_data;
        if (rd_we)
            regs[rd_addr] <= rd_data;
    end

endmodule

`default_nettype wire
