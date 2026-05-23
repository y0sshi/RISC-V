// =============================================================================
// rv_imem.sv - Instruction Memory (BRAM-inferred, synchronous read)
// =============================================================================
// Synchronous-read instruction memory that reliably infers Block RAM on
// Xilinx 7-series and UltraScale+.
//
// Read latency: 1 cycle (address presented on cycle N → data valid on cycle N+1)
//
// Pipeline impact:
//   rv_core's IF stage now presents the *next* PC one cycle early; the
//   IF/ID register captures imem_rdata on the same edge it becomes valid.
//   This is identical to a "registered-output BRAM" arrangement:
//
//     cycle N  : PC_reg = addr → BRAM address registered
//     cycle N+1: imem_rdata valid → captured into IF/ID register
//
// imem_ready is asserted one cycle after req, matching the read latency.
// rv_core must stall the pipeline when imem_ready is low.
//
// Author: Naofumi Yoshinaga
// =============================================================================

`default_nettype none

module rv_imem
    import rv_pkg::*;
#(
    parameter int XLEN      = rv_pkg::XLEN,
    parameter int DEPTH      = 4096,           // Number of 32-bit words
    parameter     INIT_FILE  = ""              // Hex file path for initialization
) (
    input  wire              clk,
    input  wire              rst_n,

    input  wire  [XLEN-1:0]  addr,
    input  wire              req,
    output logic [31:0]      rdata,
    output logic             ready
);

    // -------------------------------------------------------------------------
    // Word-addressed BRAM
    // ram_style="block" + synchronous read = reliable BRAM inference on Vivado
    // -------------------------------------------------------------------------
    (* ram_style = "block" *) logic [31:0] mem [0:DEPTH-1];

    // Word address (byte address >> 2), clamped to DEPTH
    logic [$clog2(DEPTH)-1:0] word_addr;
    assign word_addr = addr[$clog2(DEPTH)+1:2];

    // Synchronous read — this is what makes Vivado infer BRAM
    always_ff @(posedge clk) begin
        if (req) begin
            rdata <= mem[word_addr];
        end
    end

    // ready is asserted one cycle after req (matches BRAM read latency)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) ready <= 1'b0;
        else        ready <= req;
    end

    // -------------------------------------------------------------------------
    // Memory initialization (simulation + Vivado init)
    // -------------------------------------------------------------------------
    initial begin
        for (int i = 0; i < DEPTH; i++) begin
            mem[i] = 32'h0000_0013;  // ADDI x0, x0, 0 (NOP)
        end
        if (INIT_FILE != "") begin
            $readmemh(INIT_FILE, mem);
        end
    end

endmodule

`default_nettype wire
