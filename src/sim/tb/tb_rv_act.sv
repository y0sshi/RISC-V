`timescale 1ns/1ps
`default_nettype none

// Compile-time macros set by sim_act_internal in src/sim/Makefile
`ifndef HEX_FILE
`define HEX_FILE "test.hex"
`endif
`ifndef SIG_FILE
`define SIG_FILE "test.signature"
`endif
`ifndef BEGIN_SIG
`define BEGIN_SIG "0"
`endif
`ifndef END_SIG
`define END_SIG "0"
`endif
`ifndef TOHOST_ADDR
`define TOHOST_ADDR "80001000"
`endif

module tb_rv_act;
    import rv_pkg::*;

    localparam logic [63:0] MEM_BASE = 64'h8000_0000;

    logic clk   = 0;
    logic rst_n = 0;
    always #5 clk = ~clk;

    // DUT: rv_soc in ACT_MODE (includes rv_core + rv_mmu + rv_unified_mem).
    // INIT_FILE propagates to rv_unified_mem's INIT_FILE, which calls $readmemh
    // internally -- no explicit $readmemh needed in this testbench.
    rv_soc #(
        .XLEN      (64),
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

    // Effective write data: mask with wstrb to extract actual bytes written
    logic [63:0] eff_wdata;
    always_comb begin
        eff_wdata = '0;
        for (int i = 0; i < 8; i++) begin
            if (u_soc.core_dmem_wstrb[i])
                eff_wdata[i*8 +: 8] = u_soc.core_dmem_wdata[i*8 +: 8];
        end
    end

    // Monitor writes to tohost address to detect test completion.
    // The core drives core_dmem_va (virtual address). In M-mode (where tohost
    // is always written) VA == PA, so this is equivalent to the physical address.
    longint tohost_addr_val;
    always @(posedge clk) begin
        if (u_soc.core_dmem_req && u_soc.core_dmem_we
                && u_soc.core_dmem_va == tohost_addr_val[63:0]) begin
            if (eff_wdata == 64'd1)
                $display("TEST PASSED");
            else
                $display("TEST FAILED: testnum=%0d", eff_wdata >> 1);
            dump_signature();
            $finish;
        end
    end

    // Dump begin_signature..end_signature region to SIG_FILE (32-bit words, little-endian)
    task dump_signature;
        longint begin_addr, end_addr, base;
        integer fd, rc;
        logic [7:0] b0, b1, b2, b3;
        begin
            begin_addr = 0; end_addr = 0;
            rc = $sscanf(`BEGIN_SIG, "%h", begin_addr);
            rc = $sscanf(`END_SIG,   "%h", end_addr);
            if (begin_addr == 0 || end_addr <= begin_addr)
                return;
            fd = $fopen(`SIG_FILE, "w");
            if (fd == 0) begin
                $display("ERROR: cannot open %s", `SIG_FILE);
                return;
            end
            for (longint i = begin_addr; i < end_addr; i = i + 4) begin
                base = i - MEM_BASE;
                b0 = u_soc.u_umem.mem_b[base+0];
                b1 = u_soc.u_umem.mem_b[base+1];
                b2 = u_soc.u_umem.mem_b[base+2];
                b3 = u_soc.u_umem.mem_b[base+3];
                $fwrite(fd, "%02x%02x%02x%02x\n", b3, b2, b1, b0);
            end
            $fclose(fd);
        end
    endtask

    // Release reset (hex already loaded via rv_unified_mem's INIT_FILE parameter)
    initial begin
        integer rc;
        rc = $sscanf(`TOHOST_ADDR, "%h", tohost_addr_val);
        #100;
        rst_n = 1;
    end

    // Simulation timeout
    initial begin
        #10_000_000;
        $display("TIMEOUT");
        $finish;
    end

endmodule

`default_nettype wire
