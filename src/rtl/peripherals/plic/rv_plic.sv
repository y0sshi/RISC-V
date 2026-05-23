// =============================================================================
// rv_plic.sv - RISC-V Platform-Level Interrupt Controller (PLIC)
// =============================================================================
// Simplified PLIC compatible with the RISC-V Privileged Architecture.
// Supports NSRC interrupt sources and NCTX contexts (M-mode/S-mode).
//
// Register map (12-bit byte offset within 4 KB window at base address):
//
//   Source priorities  (R/W, one 32-bit word per source):
//     0x000 : priority[0] = 0  (source 0 reserved)
//     0x004 : priority[1]
//     0x008 : priority[2]
//       ...
//     0x020 : priority[8]   (NSRC=8)
//
//   Interrupt pending  (RO, bit n = source n):
//     0x100 : pending[31:1]
//
//   Interrupt enable per context (R/W):
//     0x200 : enable[ctx=0][31:1]  (M-mode, bit n = source n)
//     0x204 : enable[ctx=1][31:1]  (S-mode)
//
//   Per-context threshold and claim/complete:
//     0x300 : threshold[ctx=0]
//     0x304 : claim_complete[ctx=0]  read=highest-priority ID, write=complete
//     0x308 : threshold[ctx=1]
//     0x30C : claim_complete[ctx=1]
//
// Claim/complete protocol:
//   1. CPU reads claim reg → returns winning source ID (0 if none).
//   2. CPU services the interrupt.
//   3. CPU writes winning source ID to complete reg → clears pending.
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

    // 32-bit memory-mapped bus (12-bit byte offset within 4 KB window)
    input  wire [11:0]  addr,
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
    // Priority: PRIO_BITS × NSRC  packed as [NSRC*PRIO_BITS-1:0]
    // We keep a separate word per source for clarity; use generate if needed.
    // For NSRC=8, PRIO_BITS=3 → 8 × 3 = 24 bits total.
    logic [PRIO_BITS-1:0] prio [1:8];   // prio[1..8], index 0 unused

    // Pending, enable, claimed as bit vectors (bit 0 unused for source)
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
    // Address decode (combinational helpers extracted from always blocks)
    // =========================================================================
    logic [3:0] grp;          // addr[11:8]
    logic [5:0] src_sel;      // addr[7:2] : source index for priority
    logic       ctx_sel;      // addr[2]   : context select for enable
    logic       reg_sel;      // addr[2]   : 0=threshold, 1=claim for group 3
    logic       ctx3_sel;     // addr[3]   : context select for group 3

    assign grp      = addr[11:8];
    assign src_sel  = addr[7:2];
    assign ctx_sel  = addr[2];
    assign reg_sel  = addr[2];
    assign ctx3_sel = addr[3];

    // Complete source (extracted to avoid constant-select in always_ff)
    logic [7:0] complete_src;
    assign complete_src = wdata[7:0];

    // =========================================================================
    // Priority arbitration for each context (combinational)
    // =========================================================================
    // Returns the source ID with highest priority that is pending, enabled,
    // and whose priority exceeds the context threshold.

    // Context 0 (M-mode)
    logic [PRIO_BITS-1:0] best_prio0;
    logic [7:0]            best_id0;

    // Context 1 (S-mode)
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
                case (grp)
                    4'h0: begin  // Source priority (word-indexed by addr[7:2])
                        case (src_sel)
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
                    end
                    4'h1: ; // Pending is read-only
                    4'h2: begin  // Enable (ctx_sel=0 → ctx0, ctx_sel=1 → ctx1)
                        if (!ctx_sel)
                            enable0 <= wdata[8:1];
                        else
                            enable1 <= wdata[8:1];
                    end
                    4'h3: begin
                        if (!reg_sel) begin   // Threshold
                            if (!ctx3_sel) thresh0 <= wdata[PRIO_BITS-1:0];
                            else           thresh1 <= wdata[PRIO_BITS-1:0];
                        end else begin        // Complete
                            if (!ctx3_sel && claimed0) begin
                                claimed0 <= 1'b0;
                                // Clear pending of completed source
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
                            if (ctx3_sel && claimed1) begin
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
                    default: ;
                endcase
            end

            // -- Claim: mark in-progress on claim read ----------------------
            if (req && !we && grp == 4'h3 && reg_sel) begin
                if (!ctx3_sel && !claimed0 && best_id0 != 8'd0)
                    claimed0 <= 1'b1;
                if (ctx3_sel && !claimed1 && best_id1 != 8'd0)
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
            case (grp)
                4'h0: begin  // Priority
                    case (src_sel)
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
                end
                4'h1: begin  // Pending
                    rdata = {23'h0, pending[8:1], 1'b0};
                end
                4'h2: begin  // Enable
                    if (!ctx_sel)
                        rdata = {23'h0, enable0[8:1], 1'b0};
                    else
                        rdata = {23'h0, enable1[8:1], 1'b0};
                end
                4'h3: begin
                    if (!reg_sel) begin   // Threshold
                        if (!ctx3_sel) rdata = 32'(thresh0);
                        else           rdata = 32'(thresh1);
                    end else begin        // Claim (returns best source ID)
                        if (!ctx3_sel) rdata = 32'(best_id0);
                        else           rdata = 32'(best_id1);
                    end
                end
                default: rdata = 32'h0;
            endcase
        end
    end

endmodule

`default_nettype wire
