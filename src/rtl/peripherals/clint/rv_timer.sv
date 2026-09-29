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
// Bus: XLEN-wide data with byte strobes.  On RV64 the mtimecmp / mtime pairs
// occupy a single naturally-aligned 64-bit word, so 64-bit accesses (OpenSBI's
// RV64 ACLINT driver uses writeq/readq -- has_64bit_mmio) update / return BOTH
// halves, and 32-bit accesses select the half via the byte strobes (the core
// pre-shifts sub-word store data onto the correct byte lanes).  Without 64-bit
// write support, OpenSBI's "sd" to mtimecmp left mtimecmp[63:32] at its reset
// value 0xFFFFFFFF, so the timer NEVER fired (Linux: no tick, no scheduling).
// On RV32 the bus is 32 bits and each register word is addressed individually
// (original behavior).
//
// Author: Naofumi Yoshinaga
// =============================================================================

`default_nettype none
`timescale 1ns / 1ps

module rv_timer #(
    parameter int XLEN = 32,
    // mtime prescaler: mtime increments once every MTIME_DIV clk cycles.
    // 1 (default) = +1/cycle (original behavior; the simulated CPU then runs at
    // "1 MHz" relative to a 1 MHz device-tree timebase, making a 250 Hz Linux
    // tick fire every 4000 cycles -- the periodic-tick handler costs more than
    // that, so the kernel livelocks in tick_handle_periodic catch-up).  Boot
    // harnesses set e.g. 64 to emulate a 64 MHz core with a 1 MHz timebase.
    parameter int MTIME_DIV = 1
) (
    input  wire             clk,
    input  wire             rst_n,

    // XLEN-wide memory-mapped bus (byte address within the 64 KiB CLINT window)
    input  wire  [15:0]          addr,
    input  wire                  req,
    input  wire                  we,
    input  wire  [XLEN-1:0]      wdata,
    input  wire  [XLEN/8-1:0]    wstrb,      // byte strobes (lane-aligned, as the core drives)
    output logic [XLEN-1:0]      rdata,      // combinational read

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

    // mtime prescaler tick: 1 every MTIME_DIV cycles (constant 1 when DIV=1).
    localparam int DIVW = (MTIME_DIV > 1) ? $clog2(MTIME_DIV) : 1;
    logic [DIVW-1:0] div_cnt;
    wire             mtime_tick = (MTIME_DIV == 1) || (div_cnt == DIVW'(MTIME_DIV - 1));

    generate
    if (XLEN == 64) begin : gen_bus64
        // 64-bit bus: decode on the 8-byte-aligned offset; byte strobes select
        // the 32-bit half (or both, for a 64-bit access).  Store data arrives
        // already positioned on the correct byte lanes.
        wire [15:0] addr8  = {addr[15:3], 3'b000};
        wire        w_lo   = |wstrb[3:0];
        wire        w_hi   = |wstrb[7:4];

        always_ff @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin
                mtime    <= 64'd0;
                mtimecmp <= 64'hFFFF_FFFF_FFFF_FFFF;  // disabled at reset
                msip     <= 1'b0;
                div_cnt  <= '0;
            end else begin
                div_cnt <= mtime_tick ? '0 : div_cnt + 1'b1;
                if (mtime_tick) mtime <= mtime + 64'd1;
                if (req && we) begin
                    case (addr8)
                        MSIP_OFF: begin
                            if (w_lo) msip <= wdata[0];
                        end
                        MTIMECMP_LO: begin
                            if (w_lo) mtimecmp[31:0]  <= wdata[31:0];
                            if (w_hi) mtimecmp[63:32] <= wdata[63:32];
                        end
                        default: ;   // mtime is read-only
                    endcase
                end
            end
        end

        // Reads return the naturally-aligned 64-bit pair; a 32-bit load picks
        // its half via the core's byte-lane shift (addr[2]), a 64-bit load
        // takes the whole value.
        always_comb begin
            case (addr8)
                MSIP_OFF:    rdata = {63'd0, msip};
                MTIMECMP_LO: rdata = mtimecmp;
                MTIME_LO:    rdata = mtime;
                default:     rdata = 64'd0;
            endcase
        end
    end else begin : gen_bus32
        // 32-bit bus: word-addressed registers (original behavior).
        always_ff @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin
                mtime    <= 64'd0;
                mtimecmp <= 64'hFFFF_FFFF_FFFF_FFFF;  // disabled at reset
                msip     <= 1'b0;
                div_cnt  <= '0;
            end else begin
                div_cnt <= mtime_tick ? '0 : div_cnt + 1'b1;
                if (mtime_tick) mtime <= mtime + 64'd1;
                if (req && we && (|wstrb)) begin
                    case (addr)
                        MSIP_OFF:    msip            <= wdata[0];
                        MTIMECMP_LO: mtimecmp[31:0]  <= wdata[31:0];
                        MTIMECMP_HI: mtimecmp[63:32] <= wdata[31:0];
                        default: ;   // mtime is read-only
                    endcase
                end
            end
        end

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
    end
    endgenerate

    assign timer_irq = (mtime >= mtimecmp);
    assign sw_irq    = msip;

endmodule

`default_nettype wire
