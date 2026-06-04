// =============================================================================
// rv_timer.sv - Machine Timer + software interrupt (SiFive CLINT-compatible)
// =============================================================================
// Standard SiFive CLINT register layout (single hart) so OpenSBI's and Linux's
// "riscv,clint0" drivers work unmodified:
//
//   0x0000 : msip[0]    R/W  (machine software interrupt pending, bit 0)
//   0x4000 : mtimecmp[31: 0]  R/W
//   0x4004 : mtimecmp[63:32]  R/W
//   0xBFF8 : mtime   [31: 0]  R  (write ignored)
//   0xBFFC : mtime   [63:32]  R  (write ignored)
//
// mtime is a 64-bit free-running counter (+1 / cycle).  timer_irq is level-high
// while mtime >= mtimecmp.  sw_irq is the msip software interrupt (level).
//
// Bus: 32-bit word accesses; addr is a byte address within the 64 KiB window.
//
// Author: Naofumi Yoshinaga
// =============================================================================

`default_nettype none
`timescale 1ns / 1ps

module rv_timer (
    input  wire         clk,
    input  wire         rst_n,

    // 32-bit memory-mapped bus (byte address within the 64 KiB CLINT window)
    input  wire  [15:0] addr,
    input  wire         req,
    input  wire         we,
    input  wire  [31:0] wdata,
    output logic [31:0] rdata,      // combinational read

    output logic        timer_irq,  // machine timer interrupt (mtime >= mtimecmp)
    output logic        sw_irq,     // machine software interrupt (msip[0])

    output logic [63:0] mtime_o     // mtime (for the core's 'time' CSR / rdtime)
);

    // Standard SiFive CLINT offsets (single hart)
    localparam logic [15:0] MSIP_OFF    = 16'h0000;
    localparam logic [15:0] MTIMECMP_LO = 16'h4000;
    localparam logic [15:0] MTIMECMP_HI = 16'h4004;
    localparam logic [15:0] MTIME_LO    = 16'hBFF8;
    localparam logic [15:0] MTIME_HI    = 16'hBFFC;

    logic [63:0] mtime;
    logic [63:0] mtimecmp;
    logic        msip;
    assign mtime_o = mtime;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mtime    <= 64'd0;
            mtimecmp <= 64'hFFFF_FFFF_FFFF_FFFF;  // disabled at reset
            msip     <= 1'b0;
        end else begin
            mtime <= mtime + 64'd1;
            if (req && we) begin
                case (addr)
                    MSIP_OFF:    msip           <= wdata[0];
                    MTIMECMP_LO: mtimecmp[31:0]  <= wdata;
                    MTIMECMP_HI: mtimecmp[63:32] <= wdata;
                    default: ;   // mtime is read-only
                endcase
            end
        end
    end

    assign timer_irq = (mtime >= mtimecmp);
    assign sw_irq    = msip;

    always_comb begin
        case (addr)
            MSIP_OFF:    rdata = {31'd0, msip};
            MTIMECMP_LO: rdata = mtimecmp[31:0];
            MTIMECMP_HI: rdata = mtimecmp[63:32];
            MTIME_LO:    rdata = mtime[31:0];
            MTIME_HI:    rdata = mtime[63:32];
            default:     rdata = 32'd0;
        endcase
    end

endmodule

`default_nettype wire
