// =============================================================================
// tb_rv_alu.sv - ALU Unit Testbench
// =============================================================================
// Tests all ALU operations with known input/output pairs.
// Author: Naofumi Yoshinaga
// =============================================================================

`timescale 1ns / 1ps

module tb_rv_alu;

    import rv_pkg::*;

    parameter int XLEN = 32;

    logic [XLEN-1:0] op_a, op_b, result;
    alu_op_t          alu_op;
    logic             zero;

    int pass_count, fail_count;

    // DUT
    rv_alu #(.XLEN(XLEN)) dut (
        .op_a   (op_a),
        .op_b   (op_b),
        .alu_op (alu_op),
        .result (result),
        .zero   (zero)
    );

    // Check helper
    task automatic check(
        input string     name,
        input [XLEN-1:0] expected
    );
        #1;
        if (result === expected) begin
            pass_count++;
        end else begin
            $display("FAIL: %s | op_a=0x%08h op_b=0x%08h | got=0x%08h expected=0x%08h",
                name, op_a, op_b, result, expected);
            fail_count++;
        end
    endtask

    initial begin
        $dumpfile("wave/tb_rv_alu.vcd");
        $dumpvars(0, tb_rv_alu);

        pass_count = 0;
        fail_count = 0;

        $display("=== ALU Testbench Start ===");

        // --- ADD ---
        alu_op = ALU_ADD;
        op_a = 32'd10; op_b = 32'd20;
        check("ADD: 10+20", 32'd30);

        op_a = 32'hFFFF_FFFF; op_b = 32'd1;
        check("ADD: overflow", 32'd0);

        // --- SUB ---
        alu_op = ALU_SUB;
        op_a = 32'd30; op_b = 32'd10;
        check("SUB: 30-10", 32'd20);

        op_a = 32'd0; op_b = 32'd1;
        check("SUB: 0-1", 32'hFFFF_FFFF);

        // --- AND ---
        alu_op = ALU_AND;
        op_a = 32'hFF00_FF00; op_b = 32'h0F0F_0F0F;
        check("AND", 32'h0F00_0F00);

        // --- OR ---
        alu_op = ALU_OR;
        op_a = 32'hFF00_0000; op_b = 32'h00FF_0000;
        check("OR", 32'hFFFF_0000);

        // --- XOR ---
        alu_op = ALU_XOR;
        op_a = 32'hAAAA_AAAA; op_b = 32'h5555_5555;
        check("XOR", 32'hFFFF_FFFF);

        // --- SLL ---
        alu_op = ALU_SLL;
        op_a = 32'h0000_0001; op_b = 32'd4;
        check("SLL: 1<<4", 32'h0000_0010);

        // --- SRL ---
        alu_op = ALU_SRL;
        op_a = 32'h8000_0000; op_b = 32'd4;
        check("SRL: 0x80000000>>4", 32'h0800_0000);

        // --- SRA ---
        alu_op = ALU_SRA;
        op_a = 32'h8000_0000; op_b = 32'd4;
        check("SRA: 0x80000000>>>4", 32'hF800_0000);

        // --- SLT ---
        alu_op = ALU_SLT;
        op_a = 32'hFFFF_FFFF; op_b = 32'd0;  // -1 < 0
        check("SLT: -1 < 0", 32'd1);

        op_a = 32'd0; op_b = 32'hFFFF_FFFF;   // 0 < -1
        check("SLT: 0 < -1", 32'd0);

        // --- SLTU ---
        alu_op = ALU_SLTU;
        op_a = 32'd0; op_b = 32'hFFFF_FFFF;
        check("SLTU: 0 < 0xFFFFFFFF", 32'd1);

        // --- PASS_B ---
        alu_op = ALU_PASS_B;
        op_a = 32'hDEAD_BEEF; op_b = 32'h1234_5678;
        check("PASS_B", 32'h1234_5678);

        // --- Summary ---
        $display("=== ALU Testbench Done ===");
        $display("PASS: %0d / %0d", pass_count, pass_count + fail_count);
        if (fail_count > 0)
            $display("FAIL: %0d tests failed!", fail_count);
        else
            $display("All tests passed!");

        $finish;
    end

endmodule
