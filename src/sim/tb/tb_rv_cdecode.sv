// =============================================================================
// tb_rv_cdecode.sv - Unit testbench for rv_cdecode (RVC -> base 32-bit expander)
// =============================================================================
// Builds for RV32C by default; pass -DRV_XLEN_64 for RV64C.
// Verifies that key compressed instructions from the rvc.S compliance test
// expand to the correct 32-bit base encodings, including XLEN-dependent slots
// (C.JAL on RV32C vs C.ADDIW on RV64C, C.LD/C.SD only on RV64C).
// =============================================================================

`timescale 1ns/1ps
`default_nettype none

module tb_rv_cdecode;
    import rv_pkg::*;

    logic [15:0] cinst;
    logic [31:0] inst_out;
    logic        is_compressed;
    logic        illegal;

    rv_cdecode #(.XLEN(XLEN)) dut (
        .cinst         (cinst),
        .inst_out      (inst_out),
        .is_compressed (is_compressed),
        .illegal       (illegal)
    );

    integer errors = 0;
    integer checks = 0;

    task automatic check(input [15:0] c, input [31:0] exp, input string name);
        begin
            cinst = c;
            #1;
            checks = checks + 1;
            if (inst_out !== exp) begin
                errors = errors + 1;
                $display("  [FAIL] %-16s cinst=%04h  got=%08h  exp=%08h",
                         name, c, inst_out, exp);
            end else begin
                $display("  [PASS] %-16s cinst=%04h -> %08h", name, c, inst_out);
            end
        end
    endtask

    initial begin
        $dumpfile("wave/tb_rv_cdecode.vcd");
        $dumpvars(0, tb_rv_cdecode);

        $display("=== rv_cdecode test (XLEN=%0d) ===", XLEN);

        // --- Common to RV32C and RV64C ---
        check(16'h1541, 32'hFF050513, "c.addi a0,-16");      // addi a0,a0,-16
        check(16'h57C1, 32'hFF000793, "c.li a5,-16");        // addi a5,x0,-16
        check(16'h82AA, 32'h00A002B3, "c.mv t0,a0");         // add  t0,x0,a0
        check(16'h92AA, 32'h00A282B3, "c.add t0,a0");        // add  t0,t0,a0
        check(16'h8282, 32'h00028067, "c.jr t0");            // jalr x0,0(t0)
        check(16'h9282, 32'h000280E7, "c.jalr t0");          // jalr x1,0(t0)
        check(16'h0412, 32'h00441413, "c.slli s0,4");        // slli s0,s0,4
        check(16'h1FE8, 32'h3FC10513, "c.addi4spn a0,1020"); // addi a0,sp,1020
        check(16'h41C8, 32'h0045A503, "c.lw a0,4(a1)");      // lw   a0,4(a1)

        // is_compressed / pass-through sanity
        cinst = 16'h0001; #1;  // c.nop
        if (!is_compressed) begin errors=errors+1; $display("  [FAIL] is_compressed for c.nop"); end
        else                       $display("  [PASS] is_compressed=1 for c.nop");
        checks = checks + 1;

`ifdef RV_XLEN_64
        // --- RV64C-specific ---
        check(16'h357D, 32'hFFF5051B, "c.addiw a0,-1");      // addiw a0,a0,-1
        check(16'h6188, 32'h0005B503, "c.ld a0,0(a1)");      // ld   a0,0(a1)
`else
        // --- RV32C-specific ---
        check(16'h2001, 32'h000000EF, "c.jal +0");           // jal  x1,0
`endif

        $display("=== %0d checks, %0d errors ===", checks, errors);
        if (errors == 0) $display("TEST PASSED");
        else             $display("TEST FAILED");
        $finish;
    end

endmodule

`default_nettype wire
