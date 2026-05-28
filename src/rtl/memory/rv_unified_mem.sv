// =============================================================================
// @file rv_unified_mem.sv
// @brief Unified Instruction and Data Memory Model for Simulation (256 KB)
//
// 64-bit wide SRAM with byte-write enablement.
// Dual-ported (pseudo or true depending on access conflict handling):
//   Port A: Instruction Fetch (Read-Only)
//   Port B: Data Access (Read/Write)
//
// Address Space: 0x8000_0000 - 0x8003_FFFF (256 KB)
// =============================================================================

`default_nettype none

module rv_unified_mem #(
    parameter int          MEM_SIZE_BYTES = 256 * 1024, // 256 KB
    parameter int          MEM_DEPTH      = MEM_SIZE_BYTES / 8, // 32768 words
    parameter logic [63:0] BASE_ADDR      = 64'h8000_0000
) (
    input  wire        clk,
    
    // Port A: Instruction Fetch
    input  logic [63:0] imem_addr,
    output logic [63:0] imem_rdata,
    
    // Port B: Data Access
    input  logic [63:0] dmem_addr,
    input  logic [63:0] dmem_wdata,
    input  logic        dmem_we,
    input  logic [7:0]  dmem_be,
    output logic [63:0] dmem_rdata
);

    // -------------------------------------------------------------------------
    // Memory Array Definition
    // -------------------------------------------------------------------------
    logic [63:0] mem [0:MEM_DEPTH-1];

    // -------------------------------------------------------------------------
    // Address Translation (Byte Address -> Word Index)
    // -------------------------------------------------------------------------
    logic [63:0] imem_idx_raw, dmem_idx_raw;
    assign imem_idx_raw = (imem_addr - BASE_ADDR) >> 3;
    assign dmem_idx_raw = (dmem_addr - BASE_ADDR) >> 3;

    // Truncate to prevent out-of-bound warnings in simulation
    localparam int ADDR_WIDTH = $clog2(MEM_DEPTH);
    logic [ADDR_WIDTH-1:0] imem_idx, dmem_idx;
    assign imem_idx = imem_idx_raw[ADDR_WIDTH-1:0];
    assign dmem_idx = dmem_idx_raw[ADDR_WIDTH-1:0];

    // -------------------------------------------------------------------------
    // Port A: Synchronous Instruction Read
    // -------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        imem_rdata <= mem[imem_idx];
    end

    // -------------------------------------------------------------------------
    // Port B: Synchronous Data Read / Byte-Enabled Write
    // -------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (dmem_we) begin
            if (dmem_be[0]) mem[dmem_idx][7:0]   <= dmem_wdata[7:0];
            if (dmem_be[1]) mem[dmem_idx][15:8]  <= dmem_wdata[15:8];
            if (dmem_be[2]) mem[dmem_idx][23:16] <= dmem_wdata[23:16];
            if (dmem_be[3]) mem[dmem_idx][31:24] <= dmem_wdata[31:24];
            if (dmem_be[4]) mem[dmem_idx][39:32] <= dmem_wdata[39:32];
            if (dmem_be[5]) mem[dmem_idx][47:40] <= dmem_wdata[47:40];
            if (dmem_be[6]) mem[dmem_idx][55:48] <= dmem_wdata[55:48];
            if (dmem_be[7]) mem[dmem_idx][63:56] <= dmem_wdata[63:56];
        end
        dmem_rdata <= mem[dmem_idx];
    end

    // -------------------------------------------------------------------------
    // Simulation Helper Task: Dump Signature Region to File
    // -------------------------------------------------------------------------
    task automatic dump_signature(
        input string filename,
        input logic [63:0] start_addr,
        input logic [63:0] end_addr
    );
        integer fd;
        logic [63:0] start_idx, end_idx;
        begin
            start_idx = (start_addr - BASE_ADDR) >> 3;
            end_idx   = (end_addr - BASE_ADDR) >> 3;
            
            fd = $fopen(filename, "w");
            if (fd == 0) begin
                $display("ERROR: Could not open signature file: %s", filename);
                $finish;
            end
            
            $display("--- Dumping Signature [0x%0x - 0x%0x] ---", start_addr, end_addr);
            for (logic [63:0] i = start_idx; i < end_idx; i = i + 1) begin
                // Dump 32-bit words (low then high) to match riscv-arch-test requirements
                $fwrite(fd, "%08x\n", mem[i[ADDR_WIDTH-1:0]][31:0]);
                $fwrite(fd, "%08x\n", mem[i[ADDR_WIDTH-1:0]][63:32]);
            end
            $fclose(fd);
        end
    endtask

endmodule

`default_nettype wire

