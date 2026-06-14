// =============================================================================
// rv_soc_wrap.v - Plain-Verilog wrapper around rv_soc (SystemVerilog).
// =============================================================================
// Vivado forbids a SystemVerilog file as the *top file* of a block-design module
// reference ("[filemgmt 56-195] ... not allowed as the top file in the
// reference").  This thin Verilog-2001 wrapper has a .v top file, so it can be
// referenced by create_bd_cell -type module -reference, while internally just
// instantiating the SV rv_soc with a straight 1:1 port passthrough.  The AXI
// master interfaces (m_axi / m_axi_if) are inferred by Vivado from the identical
// port names, exactly as they would be on rv_soc directly.
//
// XLEN follows the same RV_XLEN_64 define applied to the source fileset, so the
// wrapper's AXI port widths match rv_pkg::XLEN inside rv_soc.
// =============================================================================
`default_nettype none

module rv_soc_wrap #(
`ifdef RV_XLEN_64
    parameter integer XLEN         = 64,
`else
    parameter integer XLEN         = 32,
`endif
    parameter integer AXI_ID_WIDTH = 4
) (
    input  wire                    clk,
    input  wire                    rst_n,

    input  wire  [3:0]             gpio_in,
    output wire  [3:0]             gpio_out,
    input  wire                    uart_rx,
    output wire                    uart_tx,

    // Data / PTW AXI master (read/write, XLEN-wide data)
    output wire  [AXI_ID_WIDTH-1:0] m_axi_awid,
    output wire  [XLEN-1:0]         m_axi_awaddr,
    output wire  [7:0]              m_axi_awlen,
    output wire  [2:0]              m_axi_awsize,
    output wire  [1:0]              m_axi_awburst,
    output wire                     m_axi_awvalid,
    input  wire                     m_axi_awready,
    output wire  [XLEN-1:0]         m_axi_wdata,
    output wire  [XLEN/8-1:0]       m_axi_wstrb,
    output wire                     m_axi_wlast,
    output wire                     m_axi_wvalid,
    input  wire                     m_axi_wready,
    input  wire  [AXI_ID_WIDTH-1:0] m_axi_bid,
    input  wire  [1:0]              m_axi_bresp,
    input  wire                     m_axi_bvalid,
    output wire                     m_axi_bready,
    output wire  [AXI_ID_WIDTH-1:0] m_axi_arid,
    output wire  [XLEN-1:0]         m_axi_araddr,
    output wire  [7:0]              m_axi_arlen,
    output wire  [2:0]              m_axi_arsize,
    output wire  [1:0]              m_axi_arburst,
    output wire                     m_axi_arvalid,
    input  wire                     m_axi_arready,
    input  wire  [AXI_ID_WIDTH-1:0] m_axi_rid,
    input  wire  [XLEN-1:0]         m_axi_rdata,
    input  wire  [1:0]              m_axi_rresp,
    input  wire                     m_axi_rlast,
    input  wire                     m_axi_rvalid,
    output wire                     m_axi_rready,

    // Instruction-fetch AXI master (read-only, 32-bit data)
    output wire  [AXI_ID_WIDTH-1:0] m_axi_if_awid,
    output wire  [XLEN-1:0]         m_axi_if_awaddr,
    output wire  [7:0]              m_axi_if_awlen,
    output wire  [2:0]              m_axi_if_awsize,
    output wire  [1:0]              m_axi_if_awburst,
    output wire                     m_axi_if_awvalid,
    input  wire                     m_axi_if_awready,
    output wire  [31:0]             m_axi_if_wdata,
    output wire  [3:0]              m_axi_if_wstrb,
    output wire                     m_axi_if_wlast,
    output wire                     m_axi_if_wvalid,
    input  wire                     m_axi_if_wready,
    input  wire  [AXI_ID_WIDTH-1:0] m_axi_if_bid,
    input  wire  [1:0]              m_axi_if_bresp,
    input  wire                     m_axi_if_bvalid,
    output wire                     m_axi_if_bready,
    output wire  [AXI_ID_WIDTH-1:0] m_axi_if_arid,
    output wire  [XLEN-1:0]         m_axi_if_araddr,
    output wire  [7:0]              m_axi_if_arlen,
    output wire  [2:0]              m_axi_if_arsize,
    output wire  [1:0]              m_axi_if_arburst,
    output wire                     m_axi_if_arvalid,
    input  wire                     m_axi_if_arready,
    input  wire  [AXI_ID_WIDTH-1:0] m_axi_if_rid,
    input  wire  [31:0]             m_axi_if_rdata,
    input  wire  [1:0]              m_axi_if_rresp,
    input  wire                     m_axi_if_rlast,
    input  wire                     m_axi_if_rvalid,
    output wire                     m_axi_if_rready
);

    rv_soc #(
        .XLEN         (XLEN),
        .AXI_ID_WIDTH (AXI_ID_WIDTH)
    ) u_rv_soc (
        .clk            (clk),
        .rst_n          (rst_n),
        .gpio_in        (gpio_in),
        .gpio_out       (gpio_out),
        .uart_rx        (uart_rx),
        .uart_tx        (uart_tx),

        .m_axi_awid     (m_axi_awid),
        .m_axi_awaddr   (m_axi_awaddr),
        .m_axi_awlen    (m_axi_awlen),
        .m_axi_awsize   (m_axi_awsize),
        .m_axi_awburst  (m_axi_awburst),
        .m_axi_awvalid  (m_axi_awvalid),
        .m_axi_awready  (m_axi_awready),
        .m_axi_wdata    (m_axi_wdata),
        .m_axi_wstrb    (m_axi_wstrb),
        .m_axi_wlast    (m_axi_wlast),
        .m_axi_wvalid   (m_axi_wvalid),
        .m_axi_wready   (m_axi_wready),
        .m_axi_bid      (m_axi_bid),
        .m_axi_bresp    (m_axi_bresp),
        .m_axi_bvalid   (m_axi_bvalid),
        .m_axi_bready   (m_axi_bready),
        .m_axi_arid     (m_axi_arid),
        .m_axi_araddr   (m_axi_araddr),
        .m_axi_arlen    (m_axi_arlen),
        .m_axi_arsize   (m_axi_arsize),
        .m_axi_arburst  (m_axi_arburst),
        .m_axi_arvalid  (m_axi_arvalid),
        .m_axi_arready  (m_axi_arready),
        .m_axi_rid      (m_axi_rid),
        .m_axi_rdata    (m_axi_rdata),
        .m_axi_rresp    (m_axi_rresp),
        .m_axi_rlast    (m_axi_rlast),
        .m_axi_rvalid   (m_axi_rvalid),
        .m_axi_rready   (m_axi_rready),

        .m_axi_if_awid    (m_axi_if_awid),
        .m_axi_if_awaddr  (m_axi_if_awaddr),
        .m_axi_if_awlen   (m_axi_if_awlen),
        .m_axi_if_awsize  (m_axi_if_awsize),
        .m_axi_if_awburst (m_axi_if_awburst),
        .m_axi_if_awvalid (m_axi_if_awvalid),
        .m_axi_if_awready (m_axi_if_awready),
        .m_axi_if_wdata   (m_axi_if_wdata),
        .m_axi_if_wstrb   (m_axi_if_wstrb),
        .m_axi_if_wlast   (m_axi_if_wlast),
        .m_axi_if_wvalid  (m_axi_if_wvalid),
        .m_axi_if_wready  (m_axi_if_wready),
        .m_axi_if_bid     (m_axi_if_bid),
        .m_axi_if_bresp   (m_axi_if_bresp),
        .m_axi_if_bvalid  (m_axi_if_bvalid),
        .m_axi_if_bready  (m_axi_if_bready),
        .m_axi_if_arid    (m_axi_if_arid),
        .m_axi_if_araddr  (m_axi_if_araddr),
        .m_axi_if_arlen   (m_axi_if_arlen),
        .m_axi_if_arsize  (m_axi_if_arsize),
        .m_axi_if_arburst (m_axi_if_arburst),
        .m_axi_if_arvalid (m_axi_if_arvalid),
        .m_axi_if_arready (m_axi_if_arready),
        .m_axi_if_rid     (m_axi_if_rid),
        .m_axi_if_rdata   (m_axi_if_rdata),
        .m_axi_if_rresp   (m_axi_if_rresp),
        .m_axi_if_rlast   (m_axi_if_rlast),
        .m_axi_if_rvalid  (m_axi_if_rvalid),
        .m_axi_if_rready  (m_axi_if_rready)
    );

endmodule

`default_nettype wire
