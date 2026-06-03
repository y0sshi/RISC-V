// =============================================================================
/// @file rv_unified_mem.sv
/// @brief Unified Instruction/Data Memory for the rv_soc_act (compliance) configuration (256 KB)
///
/// Single SRAM block shared by instruction fetch (Port A, 32-bit read) and
/// data access (Port B, XLEN-bit read/write with byte-enable).
/// Used exclusively in rv_soc_act; not instantiated elsewhere.
///
/// @param XLEN        Data path width (32 or 64).
/// @param DEPTH       Memory size in 32-bit words (default 65536 = 256 KB).
/// @param BASE_ADDR   Physical base address (default 0x8000_0000).
/// @param INIT_FILE   Optional hex file loaded at simulation start.
// =============================================================================

`default_nettype none

module rv_unified_mem
    import rv_pkg::*;
#(
    parameter int           XLEN      = rv_pkg::XLEN,
    parameter int           DEPTH     = 65536,           // 32-bit words → 256 KB
    parameter logic [63:0]  BASE_ADDR = 64'h8000_0000,
    parameter               INIT_FILE = ""
) (
    input  wire             clk,
    input  wire             rst_n,

    // Port A: Instruction fetch (read-only, 32-bit, 1-cycle latency)
    input  logic [XLEN-1:0] i_addr,
    input  logic             i_req,
    output logic [31:0]      i_rdata,
    output logic             i_ready,

    // Port B: Data read/write (XLEN-bit, byte-enable, 1-cycle latency)
    input  logic [XLEN-1:0]      d_addr,
    input  logic [XLEN-1:0]      d_wdata,
    input  logic [(XLEN/8)-1:0]  d_wstrb,
    input  logic                  d_req,
    input  logic                  d_we,
    output logic [XLEN-1:0]      d_rdata,
    output logic                  d_ready
);
    // -------------------------------------------------------------------------
    // Memory: byte-addressable backing store for easy $readmemh loading
    // -------------------------------------------------------------------------
    localparam int MEM_BYTES = DEPTH * 4;  // DEPTH in 32-bit words

    logic [7:0] mem_b [0:MEM_BYTES-1];

    initial begin
        for (int i = 0; i < MEM_BYTES; i++) mem_b[i] = 8'h0;
        if (INIT_FILE != "")
            $readmemh(INIT_FILE, mem_b);
    end

    // -------------------------------------------------------------------------
    // Byte offset helpers
    // -------------------------------------------------------------------------
    logic [63:0] i_boff;
    logic [63:0] d_boff;
    assign i_boff = i_addr - BASE_ADDR;
    // Align the data byte offset to the XLEN-wide word: 8-byte for RV64, 4-byte
    // for RV32.  Using a fixed ~7 mask would mis-address 4-byte RV32 accesses
    // whose address has bit[2] set.
    assign d_boff = (d_addr - BASE_ADDR) & ~64'(XLEN/8 - 1);

    // -------------------------------------------------------------------------
    // Port A: 1-cycle synchronous instruction read (BRAM model)
    // -------------------------------------------------------------------------
    logic [31:0] i_rdata_r;
    logic        i_ready_r;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            i_ready_r <= 1'b0;
            i_rdata_r <= '0;
        end else begin
            i_ready_r <= i_req;
            if (i_req)
                i_rdata_r <= {mem_b[i_boff+3], mem_b[i_boff+2],
                              mem_b[i_boff+1], mem_b[i_boff+0]};
        end
    end

    assign i_rdata = i_rdata_r;
    assign i_ready = i_ready_r;

    // -------------------------------------------------------------------------
    // Port B: 1-cycle synchronous data read/write
    // -------------------------------------------------------------------------
    logic [XLEN-1:0] d_rdata_r;
    logic            d_ready_r;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            d_ready_r <= 1'b0;
            d_rdata_r <= '0;
        end else begin
            d_ready_r <= d_req;
            if (d_req && d_we) begin
                for (int i = 0; i < XLEN/8; i++) begin
                    if (d_wstrb[i]) mem_b[d_boff + i] <= d_wdata[i*8 +: 8];
                end
            end else if (d_req) begin
                for (int i = 0; i < XLEN/8; i++) begin
                    d_rdata_r[i*8 +: 8] <= mem_b[d_boff + i];
                end
            end
        end
    end

    assign d_rdata = d_rdata_r;
    assign d_ready = d_ready_r;

endmodule

`default_nettype wire
