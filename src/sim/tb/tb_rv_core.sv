// =============================================================================
// tb_rv_core.sv - Testbench for RISC-V SoC
// =============================================================================
// Top-level testbench that instantiates rv_soc and runs a program loaded
// from a hex file. Compatible with both iverilog and Vivado xsim.
// Author: Naofumi Yoshinaga
// =============================================================================

`timescale 1ns / 1ps

module tb_rv_core;

    import rv_pkg::*;

    // =========================================================================
    // Parameters
    // =========================================================================
    parameter int CLK_PERIOD  = 10;  // 100 MHz
    parameter int TIMEOUT     = 1000;
    parameter     IMEM_FILE   = "../software/tests/test_basic.hex";
    parameter     DMEM_FILE   = "";

    // =========================================================================
    // Signals
    // =========================================================================
    logic       clk;
    logic       rst_n;
    logic [3:0] gpio_in;
    logic [3:0] gpio_out;
    logic       uart_rx;
    logic       uart_tx;

    // =========================================================================
    // Clock generation
    // =========================================================================
    initial clk = 1'b0;
    always #(CLK_PERIOD / 2) clk = ~clk;

    // =========================================================================
    // DUT instantiation
    // =========================================================================
    rv_soc_bram #(
        .IMEM_DEPTH (4096),
        .DMEM_DEPTH (4096),
        .IMEM_FILE  (IMEM_FILE),
        .DMEM_FILE  (DMEM_FILE)
    ) dut (
        .clk      (clk),
        .rst_n    (rst_n),
        .gpio_in  (gpio_in),
        .gpio_out (gpio_out),
        .uart_rx  (uart_rx),
        .uart_tx  (uart_tx)
    );

    // =========================================================================
    // Test sequence
    // =========================================================================
    initial begin
        // Waveform dump (works with iverilog + GTKWave)
        $dumpfile("wave/tb_rv_core.vcd");
        $dumpvars(0, tb_rv_core);

        // Initialize
        rst_n   = 1'b0;
        gpio_in = 4'b0000;
        uart_rx = 1'b1;

        // Reset pulse
        repeat (5) @(posedge clk);
        rst_n = 1'b1;

        $display("=== RISC-V Core Testbench Start ===");
        $display("XLEN = %0d", rv_pkg::XLEN);
        $display("Program: %s", IMEM_FILE);

        // Run for specified cycles or until ECALL
        repeat (TIMEOUT) begin
            @(posedge clk);

            // Monitor PC and instruction (useful for debugging)
            if (dut.u_cpu.u_core.if_id_valid) begin
                $display("[%0t] PC=0x%08h INST=0x%08h",
                    $time,
                    dut.u_cpu.u_core.if_id_pc,
                    dut.u_cpu.u_core.if_id_inst);
            end

            // Detect ECALL (0x00000073) as test termination
            if (dut.u_cpu.u_core.if_id_inst == 32'h00000073 &&
                dut.u_cpu.u_core.if_id_valid) begin
                $display("=== ECALL detected - Test Complete ===");
                // x10 (a0) holds return value: 0 = pass, non-zero = fail
                $display("a0 (x10) = %0d", dut.u_cpu.u_core.u_regfile.regs[10]);
                if (dut.u_cpu.u_core.u_regfile.regs[10] == 0) begin
                    $display("RESULT: PASS");
                end else begin
                    $display("RESULT: FAIL (code=%0d)",
                        dut.u_cpu.u_core.u_regfile.regs[10]);
                end
                $finish;
            end
        end

        $display("=== TIMEOUT ===");
        $finish;
    end

endmodule
