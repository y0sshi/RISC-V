// =============================================================================
// rv_plic.sv - RISC-V Platform-Level Interrupt Controller (PLIC)
// =============================================================================
// Simplified PLIC compatible with the RISC-V Privileged Architecture and the
// de-facto SiFive PLIC register map that the Linux `riscv,plic0` driver and
// OpenSBI assume.  Supports NSRC interrupt sources and NCTX contexts.
//
// Standard SiFive PLIC memory map (byte offset from the PLIC base address;
// `addr` here is that offset, 22 bits wide -> up to 4 MiB):
//
//   Source priorities  (R/W, one 32-bit word per source):
//     0x000000 : priority[0] = 0  (source 0 reserved)
//     0x000004 : priority[1]
//       ...
//     0x000020 : priority[8]                 (NSRC=8)
//
//   Interrupt pending  (RO, bit n = source n, 32 sources per word):
//     0x001000 : pending word 0 (sources 0..31)
//
//   Interrupt enable per context (R/W, 0x80 stride per context):
//     0x002000 : enable[ctx=0] word 0  (M-mode, bit n = source n)
//     0x002080 : enable[ctx=1] word 0  (S-mode)
//
//   Per-context threshold + claim/complete (0x1000 stride per context):
//     0x200000 : threshold[ctx=0]
//     0x200004 : claim_complete[ctx=0]  (read=highest-priority ID, write=complete)
//     0x201000 : threshold[ctx=1]
//     0x201004 : claim_complete[ctx=1]
//
//   NOTE: an earlier revision used a COMPACT custom map (enable @0x200,
//   threshold/claim @0x300).  That worked for the bare-metal unit test but is
//   NOT what the upstream `riscv,plic0` driver writes, so Linux could never
//   enable an S-context source -- the userspace tty TX interrupt was lost.
//   This map matches the driver; the SoC routes the full PLIC window here.
//
// Claim/complete protocol:
//   1. CPU reads claim reg -> returns winning source ID (0 if none).
//   2. CPU services the interrupt.
//   3. CPU writes the source ID to complete reg -> clears pending.
//
// Author: Naofumi Yoshinaga
// =============================================================================

`default_nettype none
`timescale 1ns / 1ps

module rv_plic #(
    parameter int NSRC      = 8,   // interrupt sources (1..NSRC)
    parameter int NCTX      = 2,   // contexts (0=M-mode, 1=S-mode)
    parameter int PRIO_BITS = 3    // priority field width (0=disabled)
) (
    input  wire         clk,
    input  wire         rst_n,

    // 32-bit memory-mapped bus.  `addr` is the byte offset from the PLIC base
    // (22 bits = 4 MiB, enough for the standard map up to 0x201004).
    input  wire [21:0]  addr,
    input  wire         req,
    input  wire         we,
    input  wire [31:0]  wdata,
    output logic [31:0] rdata,

    // Interrupt source inputs: src_irq[NSRC:1] (source 0 unused)
    input  wire [NSRC:1] src_irq,

    // External interrupt outputs per context (0=M-mode, 1=S-mode)
    output logic [NCTX-1:0] ext_irq
);

    // =========================================================================
    // Register declarations (flat, no multi-dim array index tricks)
    // =========================================================================
    logic [PRIO_BITS-1:0] prio [1:8];   // prio[1..8], index 0 unused

    // Pending, enable as bit vectors (bit 0 unused for source)
    logic [8:1] pending;   // pending[n] = source n pending
    logic [8:1] enable0;   // enable for context 0 (M-mode)
    logic [8:1] enable1;   // enable for context 1 (S-mode)

    logic [PRIO_BITS-1:0] thresh0;  // threshold for context 0
    logic [PRIO_BITS-1:0] thresh1;  // threshold for context 1

    logic claimed0;   // context 0 claim in-progress
    logic claimed1;   // context 1 claim in-progress

    // Previous src_irq for edge detection
    logic [8:1] src_irq_r;

    // =========================================================================
    // Address decode (standard SiFive PLIC map)
    // =========================================================================
    //   priority region : [0x000000, 0x001000)
    //   pending  region : [0x001000, 0x002000)
    //   enable   region : [0x002000, 0x200000)  (0x80 per context)
    //   context  region : [0x200000, ...     )  (0x1000 per context)
    wire is_prio_acc = (addr <  22'h001000);
    wire is_pend_acc = (addr >= 22'h001000) && (addr < 22'h002000);
    wire is_en_acc   = (addr >= 22'h002000) && (addr < 22'h200000);
    wire is_ctx_acc  = (addr >= 22'h200000);

    wire [5:0] prio_id  = addr[7:2];   // source index (priority region word-select)
    wire       en_ctx   = addr[7];     // 0x2000 -> ctx0, 0x2080 -> ctx1
    wire       ctx_id   = addr[12];    // 0x200000 -> ctx0, 0x201000 -> ctx1
    wire       ctx_claim= addr[2];     // +0x0 = threshold, +0x4 = claim/complete

    // Complete source (extracted to avoid constant-select in always_ff)
    logic [7:0] complete_src;
    assign complete_src = wdata[7:0];

    // =========================================================================
    // Priority arbitration for each context (combinational)
    // Returns the source ID with highest priority that is pending, enabled,
    // and whose priority exceeds the context threshold.
    // =========================================================================
    logic [PRIO_BITS-1:0] best_prio0;
    logic [7:0]            best_id0;
    logic [PRIO_BITS-1:0] best_prio1;
    logic [7:0]            best_id1;

    always_comb begin
        best_prio0 = '0; best_id0 = 8'd0;
        best_prio1 = '0; best_id1 = 8'd0;
        for (int s = 1; s <= NSRC; s++) begin
            // Context 0
            if (pending[s] && enable0[s]
                    && (prio[s] > thresh0)
                    && (prio[s] > best_prio0)) begin
                best_prio0 = prio[s];
                best_id0   = 8'(s);
            end
            // Context 1
            if (pending[s] && enable1[s]
                    && (prio[s] > thresh1)
                    && (prio[s] > best_prio1)) begin
                best_prio1 = prio[s];
                best_id1   = 8'(s);
            end
        end
    end

    // Interrupt output: asserted when a winner exists and no outstanding claim
    assign ext_irq[0] = (best_id0 != 8'd0) && !claimed0;
    assign ext_irq[1] = (best_id1 != 8'd0) && !claimed1;

    // =========================================================================
    // Sequential: pending edge-latch, register writes, claim/complete
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            src_irq_r <= '0;
            pending   <= '0;
            enable0   <= '0;
            enable1   <= '0;
            thresh0   <= '0;
            thresh1   <= '0;
            claimed0  <= 1'b0;
            claimed1  <= 1'b0;
            for (int s = 1; s <= NSRC; s++)
                prio[s] <= PRIO_BITS'(1);   // default priority = 1
        end else begin
            src_irq_r <= src_irq[8:1];

            // -- Edge-latch: set pending on rising edge of src_irq ----------
            for (int s = 1; s <= NSRC; s++) begin
                if (src_irq[s] && !src_irq_r[s])
                    pending[s] <= 1'b1;
            end

            // -- Bus writes -------------------------------------------------
            if (req && we) begin
                if (is_prio_acc) begin            // Source priority
                    case (prio_id)
                        6'd1: prio[1] <= wdata[PRIO_BITS-1:0];
                        6'd2: prio[2] <= wdata[PRIO_BITS-1:0];
                        6'd3: prio[3] <= wdata[PRIO_BITS-1:0];
                        6'd4: prio[4] <= wdata[PRIO_BITS-1:0];
                        6'd5: prio[5] <= wdata[PRIO_BITS-1:0];
                        6'd6: prio[6] <= wdata[PRIO_BITS-1:0];
                        6'd7: prio[7] <= wdata[PRIO_BITS-1:0];
                        6'd8: prio[8] <= wdata[PRIO_BITS-1:0];
                        default: ;
                    endcase
                end else if (is_en_acc) begin     // Enable (word 0: sources 1..8)
                    if (!en_ctx) enable0 <= wdata[8:1];
                    else         enable1 <= wdata[8:1];
                end else if (is_ctx_acc) begin
                    if (!ctx_claim) begin         // Threshold
                        if (!ctx_id) thresh0 <= wdata[PRIO_BITS-1:0];
                        else         thresh1 <= wdata[PRIO_BITS-1:0];
                    end else begin                // Complete
                        if (!ctx_id && claimed0) begin
                            claimed0 <= 1'b0;
                            case (complete_src)
                                8'd1: pending[1] <= 1'b0;
                                8'd2: pending[2] <= 1'b0;
                                8'd3: pending[3] <= 1'b0;
                                8'd4: pending[4] <= 1'b0;
                                8'd5: pending[5] <= 1'b0;
                                8'd6: pending[6] <= 1'b0;
                                8'd7: pending[7] <= 1'b0;
                                8'd8: pending[8] <= 1'b0;
                                default: ;
                            endcase
                        end
                        if (ctx_id && claimed1) begin
                            claimed1 <= 1'b0;
                            case (complete_src)
                                8'd1: pending[1] <= 1'b0;
                                8'd2: pending[2] <= 1'b0;
                                8'd3: pending[3] <= 1'b0;
                                8'd4: pending[4] <= 1'b0;
                                8'd5: pending[5] <= 1'b0;
                                8'd6: pending[6] <= 1'b0;
                                8'd7: pending[7] <= 1'b0;
                                8'd8: pending[8] <= 1'b0;
                                default: ;
                            endcase
                        end
                    end
                end
            end

            // -- Claim: mark in-progress on claim read ----------------------
            if (req && !we && is_ctx_acc && ctx_claim) begin
                if (!ctx_id && !claimed0 && best_id0 != 8'd0)
                    claimed0 <= 1'b1;
                if (ctx_id && !claimed1 && best_id1 != 8'd0)
                    claimed1 <= 1'b1;
            end
        end
    end

    // =========================================================================
    // Combinational read
    // =========================================================================
    always_comb begin
        rdata = 32'h0;
        if (req && !we) begin
            if (is_prio_acc) begin
                case (prio_id)
                    6'd1: rdata = 32'(prio[1]);
                    6'd2: rdata = 32'(prio[2]);
                    6'd3: rdata = 32'(prio[3]);
                    6'd4: rdata = 32'(prio[4]);
                    6'd5: rdata = 32'(prio[5]);
                    6'd6: rdata = 32'(prio[6]);
                    6'd7: rdata = 32'(prio[7]);
                    6'd8: rdata = 32'(prio[8]);
                    default: rdata = 32'h0;
                endcase
            end else if (is_pend_acc) begin
                rdata = {23'h0, pending[8:1], 1'b0};
            end else if (is_en_acc) begin
                if (!en_ctx) rdata = {23'h0, enable0[8:1], 1'b0};
                else         rdata = {23'h0, enable1[8:1], 1'b0};
            end else if (is_ctx_acc) begin
                if (!ctx_claim) begin   // Threshold
                    if (!ctx_id) rdata = 32'(thresh0);
                    else         rdata = 32'(thresh1);
                end else begin          // Claim (returns best source ID)
                    if (!ctx_id) rdata = 32'(best_id0);
                    else         rdata = 32'(best_id1);
                end
            end
        end
    end

endmodule

`default_nettype wire
