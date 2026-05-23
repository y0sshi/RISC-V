// =============================================================================
// tb_rv_mmu.sv — Unit testbench for rv_mmu (TLB + PTW)
// =============================================================================
`timescale 1ns / 1ps

module tb_rv_mmu;

    import rv_pkg::*;
    localparam int XLEN = rv_pkg::XLEN;

    // DUT signals
    logic              clk, rst_n;
    logic [XLEN-1:0]  satp;
    priv_level_t      priv_level;
    logic             mstatus_sum, mstatus_mxr, tlb_flush;
    logic [XLEN-1:0]  if_va;
    logic             if_req;
    logic [XLEN-1:0]  if_pa;
    logic             if_req_out, if_fault;
    logic [XLEN-1:0]  mem_va;
    logic             mem_req, mem_we;
    logic [XLEN-1:0]  mem_pa;
    logic             mem_req_out, mem_we_out, mem_fault;
    logic             mmu_stall;
    logic [XLEN-1:0]  ptw_paddr;
    logic             ptw_req;
    logic [XLEN-1:0]  ptw_rdata;
    logic             ptw_ready;

    rv_mmu #(.XLEN(XLEN)) dut (
        .clk(clk), .rst_n(rst_n),
        .satp(satp), .priv_level(priv_level),
        .mstatus_sum(mstatus_sum), .mstatus_mxr(mstatus_mxr),
        .tlb_flush(tlb_flush),
        .if_va(if_va), .if_req(if_req),
        .if_pa(if_pa), .if_req_out(if_req_out), .if_fault(if_fault),
        .mem_va(mem_va), .mem_req(mem_req), .mem_we(mem_we),
        .mem_pa(mem_pa), .mem_req_out(mem_req_out),
        .mem_we_out(mem_we_out), .mem_fault(mem_fault),
        .mmu_stall(mmu_stall),
        .ptw_paddr(ptw_paddr), .ptw_req(ptw_req),
        .ptw_rdata(ptw_rdata), .ptw_ready(ptw_ready)
    );

    // Clock
    initial clk = 0;
    always #5 clk = ~clk;

    // =========================================================================
    // PTW memory model (1-cycle latency)
    // =========================================================================
    localparam int MEM_SZ = 64;
    logic [63:0] pmem_addr_arr [0:MEM_SZ-1];
    logic [63:0] pmem_data_arr [0:MEM_SZ-1];
    int pmem_n;

    function automatic [63:0] pmem_read(input [63:0] addr);
        pmem_read = 64'h0;
        for (int i = 0; i < MEM_SZ; i++)
            if (pmem_addr_arr[i] == addr) pmem_read = pmem_data_arr[i];
    endfunction

    always_ff @(posedge clk) begin
        ptw_ready <= 1'b0;
        ptw_rdata <= '0;
        if (ptw_req) begin
            ptw_ready <= 1'b1;
            ptw_rdata <= XLEN'(pmem_read({32'b0, ptw_paddr}));
        end
    end

    // =========================================================================
    // Helpers
    // =========================================================================
    int pass_cnt, fail_cnt;

    task check_x(input string name, input logic got, exp);
        if (got === exp) begin
            $display("  PASS: %-55s = %0b", name, got);
            pass_cnt++;
        end else begin
            $display("  FAIL: %-55s  got=%0b  exp=%0b", name, got, exp);
            fail_cnt++;
        end
    endtask

    task check_v(input string name, input logic [XLEN-1:0] got, exp);
        if (got === exp) begin
            $display("  PASS: %-55s = 0x%0h", name, got);
            pass_cnt++;
        end else begin
            $display("  FAIL: %-55s  got=0x%0h  exp=0x%0h", name, got, exp);
            fail_cnt++;
        end
    endtask

    // Wait for PTW to finish: poll mmu_stall, then one extra clock for TLB fill.
    // PTW_DONE→PTW_IDLE transition fills TLB.
    // mmu_stall goes low at PTW_DONE (excluded from stall).
    // Extra clock ensures TLB fill committed and state→IDLE.
    task wait_ptw;
        int t;
        t = 0;
        @(posedge clk); #1;
        while (mmu_stall && t < 60) begin
            @(posedge clk); #1;
            t++;
        end
        if (t >= 60) begin $display("  TIMEOUT in PTW"); fail_cnt++; end
        @(posedge clk); #1;   // extra: TLB fill committed
    endtask

    task idle_inputs;
        if_va = '0; if_req = 1'b0;
        mem_va = '0; mem_req = 1'b0; mem_we = 1'b0;
        tlb_flush = 1'b0;
    endtask

    // Sv32 PTE: {ppn[21:0], rsw[1:0]=00, D,A,G,U,X,W,R,V}
    function automatic [31:0] mk32(input [21:0] ppn,
                                   input d, a, g, u, x, w, r, v);
        mk32 = {ppn, 2'b00, d, a, g, u, x, w, r, v};
    endfunction

    // =========================================================================
    // VA decomposition helpers (module-level to avoid constant-select warnings)
    // =========================================================================
    // All VPN/offset calculations done in comments and used as literals.
    //
    // Sv32 VA decomposition:
    //   VPN1 = VA[31:22]  (10b)
    //   VPN0 = VA[21:12]  (10b)
    //   offset = VA[11:0]
    //
    // VA = 0x0001_2345:
    //   VPN1 = 0x0001_2345[31:22] = 0
    //   VPN0 = 0x0001_2345[21:12] = 0x12 = 18
    //   offset = 0x345
    //   L1 PTE addr = root(PPN=1)*4096 + VPN1*4 = 0x1000 + 0   = 0x1000
    //   L0 PTE addr = L0PT(PPN=2)*4096 + VPN0*4 = 0x2000 + 72  = 0x2048
    //   PA = PPN=3, off=0x345 → 0x0000_3345
    //
    // VA = 0x0002_3456:
    //   VPN1 = 0,  VPN0 = 0x23 = 35,  offset = 0x456
    //   L0 PTE addr = 0x2000 + 35*4 = 0x208C
    //   PA = PPN=4, off=0x456 → 0x0000_4456
    //
    // VA = 0x0080_0000  (fault test):
    //   VPN1 = 2,  L1 PTE addr = 0x1000 + 2*4 = 0x1008  (invalid V=0)
    //
    // VA = 0x0000_5abc  (R-only test):
    //   VPN1 = 0,  VPN0 = 5,  offset = 0xabc
    //   L0 PTE addr = 0x2000 + 5*4 = 0x2014
    //   PA = PPN=5, off=0xabc → 0x0000_5abc
    //
    // Sv39 VA = 0x0000_0000_0001_2345:
    //   VPN[2] = 0,  VPN[1] = 0,  VPN[0] = 18,  offset = 0x345
    //   L2 PTE addr = root(PPN=1)*4096 + VPN[2]*8 = 0x1000
    //   L1 PTE addr = L1PT(PPN=2)*4096 + VPN[1]*8 = 0x2000
    //   L0 PTE addr = L0PT(PPN=3)*4096 + VPN[0]*8 = 0x3000+144 = 0x3090
    //   PA = PPN=4, off=0x345 → 0x0000_4345

    // =========================================================================
    initial begin
        $dumpfile("wave/tb_rv_mmu.vcd");
        $dumpvars(0, tb_rv_mmu);
        pass_cnt = 0; fail_cnt = 0;
        ptw_ready = 0; ptw_rdata = '0;
        pmem_n = 0;
        for (int i = 0; i < MEM_SZ; i++) begin
            pmem_addr_arr[i] = 64'hFFFF_FFFF_FFFF_FFFF;
            pmem_data_arr[i] = 64'h0;
        end

        satp = '0; priv_level = PRIV_M;
        mstatus_sum = 0; mstatus_mxr = 0;
        idle_inputs();

        rst_n = 0; repeat(3) @(posedge clk); rst_n = 1; @(posedge clk); #1;

        $display("=== rv_mmu Unit Test (XLEN=%0d) ===", XLEN);

        // ----------------------------------------------------------------
        // [1] Bare mode
        // ----------------------------------------------------------------
        $display("\n[1] Bare mode (M-mode)");
        priv_level = PRIV_M; satp = '0;
        if_va  = XLEN'(32'hDEAD_1000); if_req  = 1'b1;
        mem_va = XLEN'(32'hBEEF_2000); mem_req = 1'b1; mem_we = 1'b0;
        #1;
        check_v("IF  PA==VA",    if_pa,       XLEN'(32'hDEAD_1000));
        check_v("MEM PA==VA",    mem_pa,      XLEN'(32'hBEEF_2000));
        check_x("IF  req_out=1", if_req_out,  1'b1);
        check_x("MEM req_out=1", mem_req_out, 1'b1);
        check_x("mmu_stall=0",   mmu_stall,   1'b0);
        idle_inputs(); @(posedge clk); #1;

        if (XLEN == 32) begin : g32

            // Setup Sv32: root @ PA 0x1000 (PPN=1)
            satp = 32'h8000_0001;   // MODE=1, PPN=1
            priv_level = PRIV_S;

            // Memory layout (all leaf PTEs are U=0, S-mode supervisor pages):
            // 0x1000 [VPN1=0]: non-leaf → PPN=2     (L0 table @ 0x2000)
            // 0x1008 [VPN1=2]: V=0                   (fault test)
            // 0x2014 [VPN0=5]: leaf R=1,W=0 PPN=5   (R-only test)
            // 0x2048 [VPN0=18]: leaf RWX  PPN=3      (VA=0x0001_2345)
            // 0x208C [VPN0=35]: leaf RWX  PPN=4      (VA=0x0002_3456)
            pmem_addr_arr[0] = 64'h0000_1000; pmem_data_arr[0] = {32'b0, mk32(22'd2, 0,1,0,0,0,0,0,1)}; // non-leaf
            pmem_addr_arr[1] = 64'h0000_1008; pmem_data_arr[1] = 64'h0;                                  // V=0 fault
            pmem_addr_arr[2] = 64'h0000_2014; pmem_data_arr[2] = {32'b0, mk32(22'd5, 1,1,0,0,0,0,1,1)}; // R-only (U=0, S-mode)
            pmem_addr_arr[3] = 64'h0000_2048; pmem_data_arr[3] = {32'b0, mk32(22'd3, 1,1,0,0,1,1,1,1)}; // RWX   (U=0, S-mode)
            pmem_addr_arr[4] = 64'h0000_208C; pmem_data_arr[4] = {32'b0, mk32(22'd4, 1,1,0,0,1,1,1,1)}; // RWX   (U=0, S-mode)
            pmem_n = 5;

            // --------------------------------------------------------
            // [2] IF TLB miss → PTW → correct PA
            // --------------------------------------------------------
            $display("\n[2] Sv32 IF: TLB miss → PTW → correct PA");
            if_va = XLEN'(32'h0001_2345); if_req = 1'b1;
            @(posedge clk); #1;
            check_x("IF stalls",  mmu_stall, 1'b1);
            wait_ptw();
            if_va = XLEN'(32'h0001_2345); if_req = 1'b1; #1;
            check_v("IF PA",      if_pa,       XLEN'(32'h0000_3345));
            check_x("req_out=1",  if_req_out,  1'b1);
            check_x("fault=0",    if_fault,    1'b0);
            check_x("stall=0",    mmu_stall,   1'b0);
            idle_inputs(); @(posedge clk); #1;

            // --------------------------------------------------------
            // [3] MEM TLB miss → PTW → correct PA
            // --------------------------------------------------------
            $display("\n[3] Sv32 MEM: TLB miss → PTW → correct PA");
            mem_va = XLEN'(32'h0002_3456); mem_req = 1'b1; mem_we = 1'b0;
            @(posedge clk); #1;
            check_x("MEM stalls", mmu_stall, 1'b1);
            wait_ptw();
            mem_va = XLEN'(32'h0002_3456); mem_req = 1'b1; mem_we = 1'b0; #1;
            check_v("MEM PA",     mem_pa,      XLEN'(32'h0000_4456));
            check_x("req_out=1",  mem_req_out, 1'b1);
            check_x("fault=0",    mem_fault,   1'b0);
            idle_inputs(); @(posedge clk); #1;

            // --------------------------------------------------------
            // [4] TLB hit: no stall on second access
            // --------------------------------------------------------
            $display("\n[4] Sv32 TLB hit (no PTW)");
            if_va = XLEN'(32'h0001_2345); if_req = 1'b1; #1;
            check_x("no stall",  mmu_stall,  1'b0);
            check_v("PA correct", if_pa,     XLEN'(32'h0000_3345));
            idle_inputs(); @(posedge clk); #1;

            // --------------------------------------------------------
            // [5] Page fault: V=0 at L1 level
            // PTW timeline (2-level):
            //   clk+0: IDLE→L1 (miss detected)
            //   clk+1: L1 state, req sent, testbench latches req
            //   clk+2: L1 state, ptw_ready=1 (PTE available), detects V=0 → FAULT
            //   At clk+2 edge: ptw_state→PTW_FAULT, mmu_stall=0, if_fault=1
            // --------------------------------------------------------
            $display("\n[5] Sv32 page fault (V=0 at L1)");
            // VA=0x0080_0000: VPN1=2 → L1 PTE @ 0x1008 (V=0)
            if_va = XLEN'(32'h0080_0000); if_req = 1'b1;
            @(posedge clk); #1;                        // clk+0: IDLE→L1
            check_x("stall during PTW", mmu_stall, 1'b1);
            @(posedge clk); #1;                        // clk+1: L1, ready coming
            @(posedge clk); #1;                        // clk+2: FAULT state
            check_x("if_fault=1", if_fault, 1'b1);
            check_x("stall=0",    mmu_stall, 1'b0);
            idle_inputs(); @(posedge clk); @(posedge clk); #1;   // drain

            // --------------------------------------------------------
            // [6] SFENCE.VMA → flush → re-PTW
            // --------------------------------------------------------
            $display("\n[6] SFENCE.VMA flush → re-PTW");
            // Confirm hit first
            if_va = XLEN'(32'h0001_2345); if_req = 1'b1; #1;
            check_x("hit before flush", mmu_stall, 1'b0);
            idle_inputs();
            // Flush
            @(posedge clk); tlb_flush = 1'b1; @(posedge clk); #1; tlb_flush = 1'b0;
            // Now should miss
            if_va = XLEN'(32'h0001_2345); if_req = 1'b1;
            @(posedge clk); #1;
            check_x("stall after flush", mmu_stall, 1'b1);
            wait_ptw();
            if_va = XLEN'(32'h0001_2345); if_req = 1'b1; #1;
            check_v("PA after re-PTW", if_pa, XLEN'(32'h0000_3345));
            idle_inputs(); @(posedge clk); #1;

            // --------------------------------------------------------
            // [7] Write to R-only page → mem_fault
            // VA=0x0000_5abc: VPN1=0, VPN0=5, PTE @ 0x2014 (R-only PPN=5)
            // --------------------------------------------------------
            $display("\n[7] Store to R-only page → mem_fault");
            mem_va = XLEN'(32'h0000_5abc); mem_req = 1'b1; mem_we = 1'b1;
            @(posedge clk); #1;
            if (mmu_stall) wait_ptw();
            mem_va = XLEN'(32'h0000_5abc); mem_req = 1'b1; mem_we = 1'b1; #1;
            check_x("mem_fault=1",   mem_fault,   1'b1);
            check_x("req_out=0",     mem_req_out, 1'b0);
            idle_inputs(); @(posedge clk); #1;

            // --------------------------------------------------------
            // [8] R+W+X page: load and store OK
            // --------------------------------------------------------
            $display("\n[8] R+W+X page: load/store OK");
            // VA=0x0001_2345 mapped PPN=3, RWXU, D=1
            mem_va = XLEN'(32'h0001_2345); mem_req = 1'b1; mem_we = 1'b0; #1;
            check_x("load fault=0",  mem_fault,   1'b0);
            check_x("load req=1",    mem_req_out, 1'b1);
            mem_we = 1'b1; #1;
            check_x("store fault=0", mem_fault,   1'b0);
            check_x("store req=1",   mem_req_out, 1'b1);
            idle_inputs(); @(posedge clk); #1;

        end  // g32

        if (XLEN == 64) begin : g64

            // --------------------------------------------------------
            // [9] Sv39: 3-level PTW → correct PA
            // VA=0x0000_0000_0001_2345:
            //   VPN[2]=0 VPN[1]=0 VPN[0]=18 offset=0x345
            //   L2 PTE @ 0x1000 (root PPN=1, VPN[2]=0 → 0x1000+0)
            //   L1 PTE @ 0x2000 (L1  PPN=2, VPN[1]=0 → 0x2000+0)
            //   L0 PTE @ 0x3090 (L0  PPN=3, VPN[0]=18→ 0x3000+18*8=0x3090)
            //   PA = PPN=4, off=0x345 → 0x0000_4345
            // --------------------------------------------------------
            $display("\n[9] Sv39 3-level PTW → correct PA");
            satp = {4'h8, 16'b0, 44'd1};   // MODE=8, PPN=1
            priv_level = PRIV_S;

            // Sv39 non-leaf PTE: {10'b0, PPN[43:0], 10'b0_0000_0001}
            // V=1, R=0,W=0,X=0 → non-leaf
            pmem_addr_arr[0] = 64'h0000_1000;
            pmem_data_arr[0] = {10'b0, 44'd2, 10'b00_0000_0001};  // L2→PPN=2
            pmem_addr_arr[1] = 64'h0000_2000;
            pmem_data_arr[1] = {10'b0, 44'd3, 10'b00_0000_0001};  // L1→PPN=3
            // Leaf PTE: D=1,A=1,G=0,U=0,X=1,W=1,R=1,V=1 → flags=0b00_1100_1111=0x0CF
            pmem_addr_arr[2] = 64'h0000_3090;
            pmem_data_arr[2] = {10'b0, 44'd4, 10'b00_1100_1111};  // leaf PPN=4 (U=0, S-mode)
            pmem_n = 3;

            if_va = 64'h0000_0000_0001_2345; if_req = 1'b1;
            @(posedge clk); #1;
            check_x("Sv39 stalls", mmu_stall, 1'b1);
            wait_ptw();
            if_va = 64'h0000_0000_0001_2345; if_req = 1'b1; #1;
            check_v("Sv39 IF PA",  if_pa,     64'h0000_0000_0000_4345);
            check_x("fault=0",     if_fault,  1'b0);
            check_x("stall=0",     mmu_stall, 1'b0);
            idle_inputs(); @(posedge clk); #1;

            // TLB hit on second access
            $display("\n[10] Sv39 TLB hit (no PTW)");
            if_va = 64'h0000_0000_0001_2345; if_req = 1'b1; #1;
            check_x("no stall",   mmu_stall, 1'b0);
            check_v("PA correct", if_pa,     64'h0000_0000_0000_4345);
            idle_inputs(); @(posedge clk); #1;

        end  // g64

        $display("\n=== Results: %0d passed, %0d failed ===", pass_cnt, fail_cnt);
        if (fail_cnt == 0) $display("ALL PASS");
        else               $display("SOME TESTS FAILED");
        $finish;
    end

    initial begin #500000; $display("TIMEOUT"); $finish; end

endmodule
