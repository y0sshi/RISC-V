// =============================================================================
// rv_timer.sv - Memory-Mapped Machine Timer (CLINT-compatible subset)
// =============================================================================
// Implements the mtime / mtimecmp registers as required by the RISC-V
// Privileged Architecture specification (Section 3.2.1).
//
// mtime    : 64-bit free-running counter, incremented every clock cycle.
// mtimecmp : 64-bit comparator register.  Software writes this to schedule
//            the next timer interrupt.
//
// timer_irq is asserted (level-sensitive) whenever mtime >= mtimecmp.
// The interrupt is cleared by writing a larger value to mtimecmp.
//
// Register map (byte addresses within this peripheral's 16-byte window):
//   0x00 : mtimecmp[31: 0]  R/W
//   0x04 : mtimecmp[63:32]  R/W
//   0x08 : mtime   [31: 0]  R  (write ignored)
//   0x0C : mtime   [63:32]  R  (write ignored)
//
// Bus interface: 32-bit word accesses; addr is a byte address.
// Write: req & we & wstrb → update selected word register.
// Read : rdata always reflects the current register value (no latency).
//
// Author: Naofumi Yoshinaga
// =============================================================================

`default_nettype none
`timescale 1ns / 1ps

module rv_timer (
    input  wire         clk,
    input  wire         rst_n,

    // 32-bit memory-mapped bus (byte address within 16-byte window)
    input  wire  [3:0]  addr,       // [3:2] selects the 32-bit register
    input  wire         req,        // bus request (read or write)
    input  wire         we,         // write enable
    input  wire  [31:0] wdata,      // write data
    output logic [31:0] rdata,      // read data (combinational)

    // Timer interrupt output (level-sensitive, active high)
    output logic        timer_irq
);

    logic [63:0] mtime;
    logic [63:0] mtimecmp;

    // =========================================================================
    // Sequential: mtime free-run, mtimecmp write
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mtime    <= 64'd0;
            mtimecmp <= 64'hFFFF_FFFF_FFFF_FFFF;  // disabled at reset (max value)
        end else begin
            mtime <= mtime + 64'd1;

            if (req && we) begin
                case (addr[3:2])
                    2'b00: mtimecmp[31: 0] <= wdata;
                    2'b01: mtimecmp[63:32] <= wdata;
                    default: ;   // mtime is read-only; ignore writes to 0x08/0x0C
                endcase
            end
        end
    end

    // =========================================================================
    // Timer interrupt: fires when mtime catches up with mtimecmp
    // =========================================================================
    assign timer_irq = (mtime >= mtimecmp);

    // =========================================================================
    // Combinational read
    // =========================================================================
    always_comb begin
        case (addr[3:2])
            2'b00: rdata = mtimecmp[31: 0];
            2'b01: rdata = mtimecmp[63:32];
            2'b10: rdata = mtime[31: 0];
            2'b11: rdata = mtime[63:32];
        endcase
    end

endmodule

`default_nettype wire
