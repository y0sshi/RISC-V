`default_nettype none
`timescale 1ns/1ns

module sim_rv32i();
	localparam integer FINISH_ADDR       = 32'h0100;
	localparam integer SIMULATION_CYCLES = 1000;
	localparam integer CLK_FREQ          = 50 * 10 ** 6;
	localparam integer CLK_PERIOD_NS     = (10 ** 9) / CLK_FREQ;
	localparam integer DATA_WIDTH        = 32;
	localparam integer REGS              = 32;
	localparam integer DMEM_DATA_WIDTH   = 16;
	localparam integer DMEM_DEPTH        = 65536;

	/* generate clock */
	reg clk;
	initial begin
		clk <= 1'b0;
		forever begin
			#(CLK_PERIOD_NS / 2) clk <= ~clk;
		end
	end

	/* simulation*/
	reg rst;
	initial begin
		rst <= 1'b0;
		#(CLK_PERIOD_NS)
		rst <= 1'b1;
		#(CLK_PERIOD_NS)
		rst <= 1'b0;
	end

	initial begin
		repeat (SIMULATION_CYCLES) begin
			#(CLK_PERIOD_NS)
			if (rv32i_inst.ft_pc == FINISH_ADDR + 4) begin
				$finish;
			end
		end
		$finish;
	end

	wire [DATA_WIDTH-1:0] iaddr, idin;
	wire [DATA_WIDTH-1:0] daddr, ddin, ddout;
	wire dwe;
	rv32i #(
		.DATA_WIDTH (DATA_WIDTH),
		.REGS       (REGS)
	)
	rv32i_inst (
		.clk   (clk),
		.rst   (rst),
		.ddin  (ddin),
		.ddout (ddout),
		.daddr (daddr),
		.dwe   (dwe),
		.idin  (idin),
		.iaddr (iaddr)
	);

	/* data memory */
	dmem #(
		.DATA_WIDTH (DATA_WIDTH),
		.DEPTH      (DMEM_DEPTH)
	)
	dmem_inst (
		.clk   (clk),
		.addr0 (iaddr),
		.addr1 (daddr),
		.din   (ddout),
		.dout0 (idin),
		.dout1 (ddin),
		.we    (dwe)
	);

	/* xmverilog */
	`ifdef XMVERILOG
	initial begin
		$shm_open("sim_rv32i.shm");
		$shm_probe(rv32i_inst, "AC");
	end
`endif

	/* iverilog */
	`ifdef IVERILOG
	initial begin
		$dumpfile("sim_rv32i.vcd");
		$dumpvars(1, rv32i_inst);
	end
`endif

	/* print */
	integer i;
	initial begin
		repeat (SIMULATION_CYCLES) begin
			#(CLK_PERIOD_NS)
			$write("==== clock: %1d ====\n", $rtoi($time / CLK_PERIOD_NS) - 1);  
			$write("# ft_pc: 0x%08X ft_instruction: 0x%032b\n", rv32i_inst.ft_pc, rv32i_inst.ft_instruction);  
			$write("# dc_pc: 0x%08X dc_instruction: 0x%032b\n", rv32i_inst.dc_pc, rv32i_inst.dc_instruction);  
			$write("# dc_rd: 0x%05X dc_rs1: 0x%05X dc_rs2: 0x%05X\n",
			rv32i_inst.dc_rd,rv32i_inst.dc_rs1,rv32i_inst.dc_rs2);  
			$write("# dc_opcode: 0b%07b dc_funct3: 0b%03b dc_funct7: 0b%07b\n",
			rv32i_inst.dc_opcode, rv32i_inst.dc_funct3, rv32i_inst.dc_funct7);  
			$write("# dc_imm: 0x%08X dc_reg0: 0x%08X dc_reg1: 0x%08X\n",
			rv32i_inst.dc_imm, rv32i_inst.dc_reg0, rv32i_inst.dc_reg1);  
			$write("# ex_result: 0x%08X ex_rd: 0x%05X\n",
			rv32i_inst.ex_result, rv32i_inst.ex_rd);  
			$write("# dmem[0xC000]: 0x%08X\n",
			{dmem_inst.mem['hC000], dmem_inst.mem['hC001], dmem_inst.mem['hC002], dmem_inst.mem['hC003]});  
			for (i=0; i<32; i+=8) begin
				$write (" # regs: 0x%08X 0x%08X 0x%08X 0x%08X 0x%08X 0x%08X 0x%08X 0x%08X\n", 
					rv32i_inst.reg_file_inst.register_file[i  ], rv32i_inst.reg_file_inst.register_file[i+1],
					rv32i_inst.reg_file_inst.register_file[i+2], rv32i_inst.reg_file_inst.register_file[i+3],
					rv32i_inst.reg_file_inst.register_file[i+4], rv32i_inst.reg_file_inst.register_file[i+5],
					rv32i_inst.reg_file_inst.register_file[i+6], rv32i_inst.reg_file_inst.register_file[i+7],);
			end
			$write("\n");
		end
	end
endmodule

`default_nettype wire
