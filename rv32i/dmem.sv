`default_nettype none

module dmem
	#(
		parameter integer DATA_WIDTH = -1,
		parameter integer DEPTH      = -1
	)
	(
		input  wire                     clk,
		input  wire [$clog2(DEPTH)-1:0] addr0, addr1,
		input  wire [DATA_WIDTH-1:0]    din,
		input  wire                     we,
		output wire [DATA_WIDTH-1:0]    dout0, dout1
	);

	localparam integer DMEM_WIDTH = 8;
	localparam integer BYTES_PER_DATA = DATA_WIDTH / DMEM_WIDTH;

	integer i;
	reg [DMEM_WIDTH-1:0] mem [DEPTH-1:0];
	initial begin
		for (i=0; i<DEPTH; i+=1) begin
			mem[i] = 'd0;
		end
		$readmemb("mem/imem.dat", mem);
		$readmemh("mem/dmem.dat", mem);
	end
	always @(posedge clk) begin
		if (we) begin
			mem[addr1  ] <= din[31:24];
			mem[addr1+1] <= din[23:16];
			mem[addr1+2] <= din[15: 8];
			mem[addr1+3] <= din[ 7: 0];
		end
	end
	assign dout0 = {mem[addr0], mem[addr0+1], mem[addr0+2], mem[addr0+3]};
	assign dout1 = {mem[addr1], mem[addr1+1], mem[addr1+2], mem[addr1+3]};

endmodule

`default_nettype wire
