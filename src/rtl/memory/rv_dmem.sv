// =============================================================================
// rv_dmem.sv - Data Memory (BRAM-inferred, synchronous read/write)
// =============================================================================
// Word-array layout with byte-enable write strobes for reliable BRAM inference
// on Xilinx 7-series and UltraScale+.
//
// Read latency: 1 cycle (synchronous output register).
// Write latency: 0 cycles (write-first / read-during-write = undefined,
//   but the pipeline never reads and writes the same address in the same cycle
//   due to the load-use stall).
//
// wstrb width: XLEN/8 bits
//   RV32: [3:0]  — SB(1b), SH(2b), SW(4b)
//   RV64: [7:0]  — SB(1b), SH(2b), SW(4b), SD(8b)
//
// Memory is word-addressed internally (32-bit words).
// For RV64 double-word accesses (LD/SD), two consecutive 32-bit words are
// combined/split by the read/write logic below.
//
// Author: Naofumi Yoshinaga
// =============================================================================

`default_nettype none

module rv_dmem
    import rv_pkg::*;
#(
    parameter int XLEN      = rv_pkg::XLEN,
    parameter int DEPTH      = 4096,           // Number of 32-bit words
    parameter     INIT_FILE  = ""              // Hex file path for initialization
) (
    input  wire                    clk,
    input  wire                    rst_n,

    input  wire  [XLEN-1:0]        addr,
    input  wire  [XLEN-1:0]        wdata,
    input  wire  [XLEN/8-1:0]      wstrb,       // byte enables (4b RV32 / 8b RV64)
    input  wire                    req,
    input  wire                    we,
    output logic [XLEN-1:0]        rdata,
    output logic                   ready
);

    // -------------------------------------------------------------------------
    // Word-array BRAM
    // Using [31:0] words with explicit byte-enable write → Vivado infers BRAM
    // with byte-write enables (BRAM primitive has WEA port).
    // -------------------------------------------------------------------------
    (* ram_style = "block" *) logic [31:0] mem [0:DEPTH-1];

    // Word address: for RV64 align to the 8-byte boundary so that wstrb[7:0]
    // correctly maps to the two 32-bit words within one 8-byte block.
    // RV32: addr >> 2 (4-byte word index); RV64: (addr & ~7) >> 2 (even index).
    logic [$clog2(DEPTH)-1:0] word_addr;
    assign word_addr = (XLEN == 64) ? {addr[$clog2(DEPTH)+1:3], 1'b0}
                                    : addr[$clog2(DEPTH)+1:2];

    // For RV64 double-word: upper word is at word_addr+1
    logic [$clog2(DEPTH)-1:0] word_addr_hi;
    assign word_addr_hi = word_addr + 1'b1;

    // -------------------------------------------------------------------------
    // Synchronous Write (byte-enable)
    // -------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (req && we) begin
            // Lower word (always present)
            if (wstrb[0]) mem[word_addr][ 7: 0] <= wdata[ 7: 0];
            if (wstrb[1]) mem[word_addr][15: 8] <= wdata[15: 8];
            if (wstrb[2]) mem[word_addr][23:16] <= wdata[23:16];
            if (wstrb[3]) mem[word_addr][31:24] <= wdata[31:24];
            // Upper word (RV64 SD only — wstrb[7:4] non-zero)
            if (XLEN == 64) begin
                if (wstrb[4]) mem[word_addr_hi][ 7: 0] <= wdata[39:32];
                if (wstrb[5]) mem[word_addr_hi][15: 8] <= wdata[47:40];
                if (wstrb[6]) mem[word_addr_hi][23:16] <= wdata[55:48];
                if (wstrb[7]) mem[word_addr_hi][31:24] <= wdata[63:56];
            end
        end
    end

    // -------------------------------------------------------------------------
    // Synchronous Read
    // -------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rdata <= '0;
            ready <= 1'b0;
        end else begin
            ready <= req;
            if (req && !we) begin
                if (XLEN == 64) begin
                    // Double-word read: combine two 32-bit words
                    rdata <= {mem[word_addr_hi], mem[word_addr]};
                end else begin
                    rdata <= XLEN'(mem[word_addr]);
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // Memory initialization
    // -------------------------------------------------------------------------
    initial begin
        for (int i = 0; i < DEPTH; i++) begin
            mem[i] = 32'h0;
        end
        if (INIT_FILE != "") begin
            $readmemh(INIT_FILE, mem);
        end
    end

endmodule

`default_nettype wire
