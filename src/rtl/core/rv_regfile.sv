// =============================================================================
// rv_regfile.sv - Integer Register File
// =============================================================================
// 32 x XLEN-bit register file with 2 read ports and 1 write port.
// Register x0 is hardwired to zero.
// Author: Naofumi Yoshinaga
// =============================================================================

`default_nettype none

module rv_regfile
    import rv_pkg::*;
#(
    parameter int XLEN = rv_pkg::XLEN
) (
    input  wire              clk,
    input  wire              rst_n,

    // Read port 1
    input  reg_addr_t        rs1_addr,
    output logic [XLEN-1:0]  rs1_data,

    // Read port 2
    input  reg_addr_t        rs2_addr,
    output logic [XLEN-1:0]  rs2_data,

    // Write port
    input  reg_addr_t        rd_addr,
    input  wire  [XLEN-1:0]  rd_data,
    input  wire              rd_we
);

    // Register array
    logic [XLEN-1:0] regs [1:NUM_REGS-1];

    // Read with x0 = 0 guarantee and write-before-read bypass.
    // When WB writes and ID reads the same register in the same cycle,
    // forward the write data so the pipeline register captures the correct value.
    assign rs1_data = (rs1_addr == '0)                                          ? '0      :
                      (rd_we && (rd_addr != '0) && (rd_addr == rs1_addr))       ? rd_data :
                      regs[rs1_addr];
    assign rs2_data = (rs2_addr == '0)                                          ? '0      :
                      (rd_we && (rd_addr != '0) && (rd_addr == rs2_addr))       ? rd_data :
                      regs[rs2_addr];

    // Write (never write to x0)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 1; i < NUM_REGS; i++) begin
                regs[i] <= '0;
            end
        end else if (rd_we && (rd_addr != '0)) begin
            regs[rd_addr] <= rd_data;
        end
    end

endmodule

`default_nettype wire
