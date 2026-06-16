`timescale 1ns/1ps
`default_nettype none

// Debug variant of tb_rv_act: short timeout + PC/cycle display
`ifndef HEX_FILE
`define HEX_FILE "test.hex"
`endif
`ifndef TOHOST_ADDR
`define TOHOST_ADDR "80001000"
`endif

module tb_rv_act_debug;
    import rv_pkg::*;

    localparam logic [63:0] MEM_BASE = 64'h8000_0000;

    logic clk   = 0;
    logic rst_n = 0;
    always #5 clk = ~clk;

    // DUT: rv_soc_act (includes rv_core + rv_mmu + rv_unified_mem).
    // INIT_FILE propagates to rv_unified_mem's INIT_FILE for internal $readmemh.
    // XLEN follows rv_pkg::XLEN (32 by default, 64 with -DRV_XLEN_64).
    rv_soc_act #(
        .XLEN      (XLEN),
        .RST_ADDR  (MEM_BASE),
        .INIT_FILE (`HEX_FILE)
    ) u_soc (
        .clk      (clk),
        .rst_n    (rst_n),
        .gpio_in  (4'b0),
        .gpio_out (),
        .uart_rx  (1'b1),
        .uart_tx  ()
    );

    // Effective write data masked by wstrb
    logic [63:0] eff_wdata;
    always_comb begin
        eff_wdata = '0;
        for (int i = 0; i < XLEN/8; i++) begin
            if (u_soc.core_dmem_wstrb[i])
                eff_wdata[i*8 +: 8] = u_soc.core_dmem_wdata[i*8 +: 8];
        end
    end

    longint tohost_addr_val;

    always @(posedge clk) begin
        if (u_soc.core_dmem_req && u_soc.core_dmem_we
                && u_soc.core_dmem_va == tohost_addr_val[63:0]) begin
            if (eff_wdata == 64'd1)
                $display("TEST PASSED (priv=%0d)", u_soc.u_cpu.priv_out);
            else
                $display("TEST FAILED: testnum=%0d (priv=%0d)",
                         eff_wdata >> 1, u_soc.u_cpu.priv_out);
            $finish;
        end
    end

    // Cycle counter + periodic PC display
    int cycle_cnt = 0;
    always @(posedge clk) begin
        if (rst_n) begin
            cycle_cnt <= cycle_cnt + 1;
            if (cycle_cnt < 200 || cycle_cnt % 5000 == 0)
                $display("[cyc %0d] imem_pa=%h dmem_addr=%h dmem_req=%b dmem_we=%b priv=%0d",
                         cycle_cnt,
                         u_soc.mmu_imem_pa,
                         u_soc.core_dmem_va,
                         u_soc.core_dmem_req,
                         u_soc.core_dmem_we,
                         u_soc.u_cpu.priv_out);
        end
    end

    // FPU trace
    always @(posedge clk) begin
        if (rst_n) begin
            if (u_soc.u_cpu.u_core.fpu_busy_int || u_soc.u_cpu.u_core.fpu_result_valid)
                $display("[cyc %0d] FPU busy=%b valid=%b ex_mem_valid=%b f10=%h f11=%h f13=%h a0=%h a3=%h",
                         cycle_cnt, u_soc.u_cpu.u_core.fpu_busy_int, u_soc.u_cpu.u_core.fpu_result_valid,
                         u_soc.u_cpu.u_core.ex_mem_valid,
                         u_soc.u_cpu.u_core.u_fregfile.regs[10],
                         u_soc.u_cpu.u_core.u_fregfile.regs[11],
                         u_soc.u_cpu.u_core.u_fregfile.regs[13],
                         u_soc.u_cpu.u_core.u_regfile.regs[10],
                         u_soc.u_cpu.u_core.u_regfile.regs[13]);
        end
    end

    // DMEM access trace
    always @(posedge clk) begin
        if (rst_n && u_soc.core_dmem_req && !u_soc.core_dmem_we)
            $display("[cyc %0d] DMEM READ  addr=%h rdata(next)=%h",
                     cycle_cnt, u_soc.core_dmem_va, u_soc.dmem_rdata);
        if (rst_n && u_soc.core_dmem_req && u_soc.core_dmem_we)
            $display("[cyc %0d] DMEM WRITE addr=%h wdata=%h wstrb=%h",
                     cycle_cnt, u_soc.core_dmem_va, u_soc.core_dmem_wdata, u_soc.core_dmem_wstrb);
    end

    // Release reset (hex loaded via rv_unified_mem's INIT_FILE parameter)
    initial begin
        integer rc;
        rc = $sscanf(`TOHOST_ADDR, "%h", tohost_addr_val);
        #100;
        rst_n = 1;
    end

    // Extended timeout: 200000 cycles
    initial begin
        #20_000_000;
        $display("TIMEOUT after ~200000 cycles");
        $finish;
    end

endmodule

`default_nettype wire
