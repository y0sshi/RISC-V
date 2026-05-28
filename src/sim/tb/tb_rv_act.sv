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
    localparam int           MEM_SIZE = 256 * 1024;  // 256 KB

    logic clk   = 0;
    logic rst_n = 0;
    always #5 clk = ~clk;

    // Byte-addressed memory (loaded via $readmemh with @addr byte format)
    logic [7:0] mem_b [0 : MEM_SIZE-1];

    // rv_core memory interface
    logic [63:0] imem_addr;
    logic        imem_req;
    logic [31:0] imem_rdata;
    logic        imem_ready;

    logic [63:0] dmem_addr;
    logic [63:0] dmem_wdata;
    logic [7:0]  dmem_wstrb;
    logic        dmem_req;
    logic        dmem_we;
    logic [63:0] dmem_rdata;
    logic        dmem_ready;

    // MMU passthrough outputs (tie off in testbench)
    logic [63:0] satp_out;
    logic [1:0]  priv_out;
    logic        mstatus_sum_out, mstatus_mxr_out, tlb_flush_out;

    // Registered BRAM outputs (1-cycle latency)
    logic [31:0] imem_rdata_r = '0;
    logic        imem_ready_r = 0;
    logic [63:0] dmem_rdata_r = '0;
    logic        dmem_ready_r = 0;

    assign imem_rdata = imem_rdata_r;
    assign imem_ready = imem_ready_r;
    assign dmem_rdata = dmem_rdata_r;
    assign dmem_ready = dmem_ready_r;

    // Byte offsets into mem_b (combinational).
    // dmem_base_boff is 8-byte aligned: wstrb[i] selects byte (base+i) within
    // the 8-byte word.  imem uses the exact address since instructions are read
    // as 4 consecutive bytes from the aligned instruction address.
    logic [63:0] imem_boff;
    logic [63:0] dmem_boff;
    logic [63:0] dmem_base_boff;
    assign imem_boff      = imem_addr - MEM_BASE;
    assign dmem_boff      = dmem_addr - MEM_BASE;
    assign dmem_base_boff = dmem_boff & ~64'h7;  // 8-byte align

    // BRAM-style memory model: 1-cycle read/write latency
    always @(posedge clk) begin
        // Instruction fetch (32-bit, little-endian from byte address)
        imem_ready_r <= imem_req;
        if (imem_req)
            imem_rdata_r <= {mem_b[imem_boff+3], mem_b[imem_boff+2],
                             mem_b[imem_boff+1], mem_b[imem_boff]};

        // Data access: wstrb[i] selects byte i within the 8-byte-aligned word
        dmem_ready_r <= dmem_req;
        if (dmem_req && dmem_we) begin
            if (dmem_wstrb[0]) mem_b[dmem_base_boff]   <= dmem_wdata[7:0];
            if (dmem_wstrb[1]) mem_b[dmem_base_boff+1] <= dmem_wdata[15:8];
            if (dmem_wstrb[2]) mem_b[dmem_base_boff+2] <= dmem_wdata[23:16];
            if (dmem_wstrb[3]) mem_b[dmem_base_boff+3] <= dmem_wdata[31:24];
            if (dmem_wstrb[4]) mem_b[dmem_base_boff+4] <= dmem_wdata[39:32];
            if (dmem_wstrb[5]) mem_b[dmem_base_boff+5] <= dmem_wdata[47:40];
            if (dmem_wstrb[6]) mem_b[dmem_base_boff+6] <= dmem_wdata[55:48];
            if (dmem_wstrb[7]) mem_b[dmem_base_boff+7] <= dmem_wdata[63:56];
        end else if (dmem_req)
            dmem_rdata_r <= {mem_b[dmem_base_boff+7], mem_b[dmem_base_boff+6],
                             mem_b[dmem_base_boff+5], mem_b[dmem_base_boff+4],
                             mem_b[dmem_base_boff+3], mem_b[dmem_base_boff+2],
                             mem_b[dmem_base_boff+1], mem_b[dmem_base_boff]};
    end

    // tohost address (resolved once at init)
    longint tohost_addr_val;

    // Effective write value: mask dmem_wdata with dmem_wstrb.
    // rv_core replicates sub-word stores (e.g. SW -> wdata={val,val}), so we
    // must extract only the bytes actually written to determine the tohost value.
    logic [63:0] eff_wdata;
    always_comb begin
        eff_wdata = '0;
        if (dmem_wstrb[0]) eff_wdata[7:0]   = dmem_wdata[7:0];
        if (dmem_wstrb[1]) eff_wdata[15:8]  = dmem_wdata[15:8];
        if (dmem_wstrb[2]) eff_wdata[23:16] = dmem_wdata[23:16];
        if (dmem_wstrb[3]) eff_wdata[31:24] = dmem_wdata[31:24];
        if (dmem_wstrb[4]) eff_wdata[39:32] = dmem_wdata[39:32];
        if (dmem_wstrb[5]) eff_wdata[47:40] = dmem_wdata[47:40];
        if (dmem_wstrb[6]) eff_wdata[55:48] = dmem_wdata[55:48];
        if (dmem_wstrb[7]) eff_wdata[63:56] = dmem_wdata[63:56];
    end

    // Monitor writes to tohost address to detect test completion
    always @(posedge clk) begin
        if (dmem_req && dmem_we && dmem_addr == tohost_addr_val[63:0]) begin
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
        longint begin_addr, end_addr, i;
        integer fd, rc;
        logic [63:0] boff;
        logic [31:0] word;
        begin
            begin_addr = 0;
            end_addr   = 0;
            rc = $sscanf(`BEGIN_SIG, "%h", begin_addr);
            rc = $sscanf(`END_SIG,   "%h", end_addr);
            if (begin_addr == 0 || end_addr <= begin_addr)
                return;
            fd = $fopen(`SIG_FILE, "w");
            if (fd == 0) begin
                $display("ERROR: cannot open %s", `SIG_FILE);
                return;
            end
            for (i = begin_addr; i < end_addr; i = i + 4) begin
                boff = i - MEM_BASE;
                word = {mem_b[boff+3], mem_b[boff+2], mem_b[boff+1], mem_b[boff]};
                $fwrite(fd, "%08x\n", word);
            end
            $fclose(fd);
        end
    endtask

    // DUT: rv_core with MMU bypassed (mmu_stall=0, M-mode satp=0 => VA==PA)
    rv_core #(
        .XLEN     (64),
        .RST_ADDR (MEM_BASE)
    ) u_core (
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
        .timer_irq       (1'b0),
        .sw_irq          (1'b0),
        .ext_irq         (1'b0)
    );

    // Load hex and release reset
    initial begin
        integer rc;
        rc = $sscanf(`TOHOST_ADDR, "%h", tohost_addr_val);
        $readmemh(`HEX_FILE, mem_b);
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
