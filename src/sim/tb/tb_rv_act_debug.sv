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
    localparam int           MEM_SIZE = 256 * 1024;

    logic clk   = 0;
    logic rst_n = 0;
    always #5 clk = ~clk;

    logic [7:0] mem_b [0 : MEM_SIZE-1];

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

    logic [63:0] satp_out;
    logic [1:0]  priv_out;
    logic        mstatus_sum_out, mstatus_mxr_out, tlb_flush_out;

    logic [31:0] imem_rdata_r = '0;
    logic        imem_ready_r = 0;
    logic [63:0] dmem_rdata_r = '0;
    logic        dmem_ready_r = 0;

    assign imem_rdata = imem_rdata_r;
    assign imem_ready = imem_ready_r;
    assign dmem_rdata = dmem_rdata_r;
    assign dmem_ready = dmem_ready_r;

    logic [63:0] imem_boff;
    logic [63:0] dmem_boff;
    logic [63:0] dmem_base_boff;
    assign imem_boff      = imem_addr - MEM_BASE;
    assign dmem_boff      = dmem_addr - MEM_BASE;
    assign dmem_base_boff = dmem_boff & ~64'h7;

    always @(posedge clk) begin
        imem_ready_r <= imem_req;
        if (imem_req)
            imem_rdata_r <= {mem_b[imem_boff+3], mem_b[imem_boff+2],
                             mem_b[imem_boff+1], mem_b[imem_boff]};
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

    longint tohost_addr_val;
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

    always @(posedge clk) begin
        if (dmem_req && dmem_we && dmem_addr == tohost_addr_val[63:0]) begin
            if (eff_wdata == 64'd1)
                $display("TEST PASSED (priv=%0d)", priv_out);
            else
                $display("TEST FAILED: testnum=%0d (priv=%0d)", eff_wdata >> 1, priv_out);
            $finish;
        end
    end

    // Cycle counter + periodic PC display
    int cycle_cnt = 0;
    always @(posedge clk) begin
        if (rst_n) begin
            cycle_cnt <= cycle_cnt + 1;
            if (cycle_cnt < 200 || cycle_cnt % 5000 == 0)
                $display("[cyc %0d] imem_addr=%h dmem_addr=%h dmem_req=%b dmem_we=%b priv=%0d",
                         cycle_cnt, imem_addr, dmem_addr, dmem_req, dmem_we, priv_out);
        end
    end

    // Instruction trace: print fetch address for key PC regions
    // Trace: FPU busy signal and f13/f10/f11 register values
    always @(posedge clk) begin
        if (rst_n) begin
            if (u_core.fpu_busy_int || u_core.fpu_result_valid)
                $display("[cyc %0d] FPU busy=%b valid=%b ex_mem_valid=%b f10=%h f11=%h f13=%h a0=%h a3=%h",
                         cycle_cnt, u_core.fpu_busy_int, u_core.fpu_result_valid,
                         u_core.ex_mem_valid,
                         u_core.u_fregfile.regs[10],
                         u_core.u_fregfile.regs[11],
                         u_core.u_fregfile.regs[13],
                         u_core.u_regfile.regs[10],
                         u_core.u_regfile.regs[13]);
        end
    end

    // Print all dmem reads and writes for diagnosis
    always @(posedge clk) begin
        if (rst_n && dmem_req && !dmem_we)
            $display("[cyc %0d] DMEM READ  addr=%h rdata(next)=%h",
                     cycle_cnt, dmem_addr, dmem_rdata);
        if (rst_n && dmem_req && dmem_we)
            $display("[cyc %0d] DMEM WRITE addr=%h wdata=%h wstrb=%h",
                     cycle_cnt, dmem_addr, dmem_wdata, dmem_wstrb);
    end


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

    initial begin
        integer rc;
        rc = $sscanf(`TOHOST_ADDR, "%h", tohost_addr_val);
        $readmemh(`HEX_FILE, mem_b);
        #100;
        rst_n = 1;
    end

    // Extended timeout: 200000 cycles (2000000 ns)
    initial begin
        #20_000_000;
        $display("TIMEOUT after ~200000 cycles");
        $finish;
    end

endmodule

`default_nettype wire
