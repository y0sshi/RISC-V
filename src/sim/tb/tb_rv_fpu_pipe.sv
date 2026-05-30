// =============================================================================
// tb_rv_fpu_pipe.sv - FP Pipeline Integration Testbench
// =============================================================================
// Validates F-extension integration into the 5-stage pipeline:
//   Test 1: EX/MEM FP forwarding (frs1)  - back-to-back FADD
//   Test 2: MEM/WB FP forwarding (frs1)  - 1-NOP gap FMUL
//   Test 3: EX/MEM FP forwarding (FSW frs2)
//   Test 4: FP load-use stall (FLW -> FADD)
//   Test 5: FMADD rs3 forwarding
//
// Test program (assembled inline as 32-bit constants):
//   LUI  x1,  0x80000        ; x1 = 0x80000000  (DMEM base)
//   FLW  f2,  0(x1)          ; f2 = 1.0
//   FLW  f3,  4(x1)          ; f3 = 2.0
//   -- Test 1 --
//   FADD.S f1, f2, f3        ; f1 = 3.0  [EX]
//   FADD.S f4, f1, f2        ; f4 = 4.0  [ID->EX, needs f1 from EX/MEM]
//   FSW  f4,  8(x1)          ; store 4.0
//   -- Test 2 --
//   FADD.S f1, f2, f3        ; f1 = 3.0  [EX]
//   ADDI x0, x0, 0           ; NOP
//   FMUL.S f5, f1, f2        ; f5 = 3.0  [EX, needs f1 from MEM/WB]
//   FSW  f5, 12(x1)          ; store 3.0
//   -- Test 3 --
//   FADD.S f1, f2, f3        ; f1 = 3.0  [EX]
//   FSW  f1, 16(x1)          ; store 3.0 [MEM, frs2=f1 from EX/MEM]
//   -- Test 4 --
//   FLW  f1,  4(x1)          ; f1 = 2.0  (load-use stall next)
//   FADD.S f6, f1, f3        ; f6 = 4.0
//   FSW  f6, 20(x1)          ; store 4.0
//   -- Test 5 --
//   FADD.S f1, f2, f3        ; f1 = 3.0  [EX, will be frs3]
//   FMADD.S f7, f2, f3, f1  ; f7 = 1.0*2.0+3.0 = 5.0 [frs3=f1 from EX/MEM]
//   FSW  f7, 24(x1)          ; store 5.0
//   JAL  x0, 0               ; done loop
//
// Author: Naofumi Yoshinaga
// =============================================================================

`timescale 1ns / 1ps

module tb_rv_fpu_pipe;

    import rv_pkg::*;

    localparam int XLEN       = rv_pkg::XLEN;
    localparam int CLK_PERIOD = 10;
    localparam int MAX_CYCLES = 500;

    logic clk, rst_n;

    logic [XLEN-1:0]   imem_addr, dmem_addr, dmem_wdata, dmem_rdata;
    logic              imem_req, dmem_req, dmem_we;
    logic [31:0]       imem_rdata;
    logic              imem_ready, dmem_ready;
    logic [XLEN/8-1:0] dmem_wstrb;

    logic [XLEN-1:0]   satp_out;
    priv_level_t       priv_out;
    logic              mstatus_sum_out, mstatus_mxr_out, tlb_flush_out;

    logic timer_irq = 1'b0, sw_irq = 1'b0, ext_irq = 1'b0;

    // Behavioral IMEM/DMEM (synchronous read, 1-cycle latency)
    logic [31:0] imem_bram [0:255];
    logic [31:0] dmem_bram [0:255];

    // =========================================================================
    // DUT
    // =========================================================================
    rv_core #(.XLEN(XLEN), .RST_ADDR(64'h0)) dut (
        .clk             (clk),
        .rst_n           (rst_n),
        .imem_addr       (imem_addr),
        .imem_req        (imem_req),
        .imem_rdata      (imem_rdata),
        .imem_ready      (imem_ready),
        .dmem_addr       (dmem_addr),
        .dmem_wdata      (dmem_wdata),
        .dmem_wstrb      (dmem_wstrb),
        .dmem_req        (dmem_req),
        .dmem_we         (dmem_we),
        .dmem_rdata      (dmem_rdata),
        .dmem_ready      (dmem_ready),
        .satp_out        (satp_out),
        .priv_out        (priv_out),
        .mstatus_sum_out (mstatus_sum_out),
        .mstatus_mxr_out (mstatus_mxr_out),
        .tlb_flush_out   (tlb_flush_out),
        .mmu_stall       (1'b0),
        .mem_stall       (1'b0),
        .if_fault        (1'b0),
        .mem_fault       (1'b0),
        .timer_irq       (timer_irq),
        .sw_irq          (sw_irq),
        .ext_irq         (ext_irq)
    );

    initial clk = 1'b0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // Synchronous IMEM model
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            imem_rdata <= 32'h0000_0013;
            imem_ready <= 1'b0;
        end else begin
            imem_ready <= imem_req;
            if (imem_req)
                imem_rdata <= imem_bram[imem_addr[$clog2(256)+1:2]];
        end
    end

    // Synchronous DMEM model (byte-enable write, word read)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dmem_rdata <= '0;
            dmem_ready <= 1'b0;
        end else begin
            dmem_ready <= dmem_req;
            if (dmem_req && dmem_we) begin
                if (dmem_wstrb[0]) dmem_bram[dmem_addr[9:2]][ 7: 0] <= dmem_wdata[ 7: 0];
                if (dmem_wstrb[1]) dmem_bram[dmem_addr[9:2]][15: 8] <= dmem_wdata[15: 8];
                if (dmem_wstrb[2]) dmem_bram[dmem_addr[9:2]][23:16] <= dmem_wdata[23:16];
                if (dmem_wstrb[3]) dmem_bram[dmem_addr[9:2]][31:24] <= dmem_wdata[31:24];
            end
            if (dmem_req && !dmem_we)
                dmem_rdata <= dmem_bram[dmem_addr[9:2]];
        end
    end

    // =========================================================================
    // Test helpers
    // =========================================================================
    int pass_cnt = 0, fail_cnt = 0;

    task check_dmem;
        input int     word_idx;   // dmem_bram index (= (offset from 0x80000000) / 4)
        input [31:0]  expected;
        input string  name;
        begin
            if (dmem_bram[word_idx] === expected) begin
                $display("  PASS  %s: dmem[%0d] = 0x%08X", name, word_idx, dmem_bram[word_idx]);
                pass_cnt++;
            end else begin
                $display("  FAIL  %s: dmem[%0d] = 0x%08X (expected 0x%08X)",
                         name, word_idx, dmem_bram[word_idx], expected);
                fail_cnt++;
            end
        end
    endtask

    // =========================================================================
    // Program load
    // =========================================================================
    // Instruction encodings (see file header comments for sources)
    // All integers are RISC-V encoded 32-bit words.
    initial begin : load_program
        // Fill IMEM with NOPs first
        for (int i = 0; i < 256; i++) imem_bram[i] = 32'h0000_0013;

        // Setup
        imem_bram[ 0] = 32'h8000_00B7; // LUI  x1, 0x80000
        imem_bram[ 1] = 32'h0000_A107; // FLW  f2, 0(x1)
        imem_bram[ 2] = 32'h0040_A187; // FLW  f3, 4(x1)

        // Test 1: EX/MEM forwarding for frs1
        imem_bram[ 3] = 32'h0031_00D3; // FADD.S f1, f2, f3
        imem_bram[ 4] = 32'h0020_8253; // FADD.S f4, f1, f2   <- f1 via EX/MEM fwd
        imem_bram[ 5] = 32'h0040_A427; // FSW  f4,  8(x1)     -> dmem[2] = 4.0

        // Test 2: MEM/WB forwarding for frs1
        imem_bram[ 6] = 32'h0031_00D3; // FADD.S f1, f2, f3
        imem_bram[ 7] = 32'h0000_0013; // ADDI x0, x0, 0  (NOP)
        imem_bram[ 8] = 32'h1020_82D3; // FMUL.S f5, f1, f2   <- f1 via MEM/WB fwd
        imem_bram[ 9] = 32'h0050_A627; // FSW  f5, 12(x1)     -> dmem[3] = 3.0

        // Test 3: EX/MEM forwarding for FSW frs2
        imem_bram[10] = 32'h0031_00D3; // FADD.S f1, f2, f3
        imem_bram[11] = 32'h0010_A827; // FSW  f1, 16(x1)     -> dmem[4] = 3.0

        // Test 4: FP load-use stall
        imem_bram[12] = 32'h0040_A087; // FLW  f1, 4(x1)      f1=2.0 (stall next)
        imem_bram[13] = 32'h0030_8353; // FADD.S f6, f1, f3   f6=4.0
        imem_bram[14] = 32'h0060_AA27; // FSW  f6, 20(x1)     -> dmem[5] = 4.0

        // Test 5: FMADD rs3 forwarding
        imem_bram[15] = 32'h0031_00D3; // FADD.S f1, f2, f3   f1=3.0 (rs3)
        imem_bram[16] = 32'h0831_03C3; // FMADD.S f7,f2,f3,f1 f7=5.0 <- f1 as rs3 via EX/MEM
        imem_bram[17] = 32'h0070_AC27; // FSW  f7, 24(x1)     -> dmem[6] = 5.0

        // Test 6: FDIV in pipeline (fpu_start_stall regression)
        // Verify FDIV result is committed to f-regfile and forwarded/stored.
        // f3=2.0, f2=1.0 -> f8 = 2.0/1.0 = 2.0 (exact, fflags=0)
        imem_bram[18] = 32'h1821_8453; // FDIV.S f8, f3, f2   f8 = 2.0
        imem_bram[19] = 32'h0080_AE27; // FSW    f8, 28(x1)   -> dmem[7]

        // Test 7: FSQRT special case - no pipeline hang (special_pending regression)
        // sqrt(-1.0) must produce qNaN+NV in 2 cycles (not hang forever).
        // -1.0 pre-loaded at dmem[9] (offset 36).
        imem_bram[20] = 32'h0240_A487; // FLW    f9, 36(x1)   f9 = -1.0
        imem_bram[21] = 32'h5804_8553; // FSQRT.S f10, f9     f10 = qNaN
        imem_bram[22] = 32'h02A0_A027; // FSW    f10, 32(x1)  -> dmem[8]

        // Done: infinite loop
        imem_bram[23] = 32'h0000_006F; // JAL  x0, 0
    end

    // =========================================================================
    // DMEM pre-initialization
    // =========================================================================
    // IEEE 754 single-precision:
    //   1.0 = 0x3F800000
    //   2.0 = 0x40000000
    initial begin : init_dmem
        for (int i = 0; i < 256; i++) dmem_bram[i] = 32'h0;
        dmem_bram[0] = 32'h3F80_0000; // 1.0  (FLW f2, 0(x1))
        dmem_bram[1] = 32'h4000_0000; // 2.0  (FLW f3, 4(x1))
        // T7: -1.0 at offset 36 (dmem[9]) for FSQRT special-case regression
        dmem_bram[9] = 32'hBF80_0000; // -1.0 (FLW f9, 36(x1))
    end

    // =========================================================================
    // Simulation
    // =========================================================================
    initial begin : sim
        rst_n = 1'b0;
        repeat(4) @(posedge clk);
        rst_n = 1'b1;

        repeat(MAX_CYCLES) @(posedge clk);

        $display("\n=== tb_rv_fpu_pipe results ===");
        //                     idx   expected     name
        check_dmem(2, 32'h4080_0000, "T1 EX/MEM frs1 fwd     f4=4.0");
        check_dmem(3, 32'h4040_0000, "T2 MEM/WB frs1 fwd     f5=3.0");
        check_dmem(4, 32'h4040_0000, "T3 EX/MEM FSW frs2     f1=3.0");
        check_dmem(5, 32'h4080_0000, "T4 FP load-use stall   f6=4.0");
        check_dmem(6, 32'h40A0_0000, "T5 FMADD rs3 fwd       f7=5.0");
        // T6: FDIV pipeline (fpu_start_stall regression)
        //     FDIV.S f8=2.0/1.0=2.0 must commit to freg and store correctly.
        check_dmem(7, 32'h4000_0000, "T6 FDIV pipeline       f8=2.0");
        // T7: FSQRT special case no-hang (special_pending regression)
        //     FSQRT.S(-1.0) must produce canonical NaN (0x7FC00000) in finite cycles.
        check_dmem(8, 32'h7FC0_0000, "T7 FSQRT(-1.0)=qNaN   f10=NaN");

        $display("\n=== Summary: %0d/%0d PASS ===\n", pass_cnt, pass_cnt+fail_cnt);
        if (fail_cnt == 0)
            $display("ALL PASS");
        else
            $display("FAIL count: %0d", fail_cnt);
        $finish;
    end

endmodule
