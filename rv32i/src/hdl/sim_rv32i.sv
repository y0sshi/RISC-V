`default_nettype none
`timescale 1ns/1ns

module sim_rv32i();
	localparam integer FINISH_ADDR       = 32'h0048;
	localparam integer SIMULATION_CYCLES = 200000;
	localparam integer CLK_FREQ          = 50 * 10 ** 6;
	localparam real    CLK_PERIOD_NS     = (10 ** 9) / CLK_FREQ;
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

	integer  fp, i;
	initial begin
		repeat (SIMULATION_CYCLES) begin
			#(CLK_PERIOD_NS)
			if (rv32i_inst.if_pc == FINISH_ADDR + 4) begin
				/* dump and finish */
				fp = $fopen("sim_rv32i.dump");
				i <= 16'hc000;
				for (i=16'hC000; i<=16'hFFFF; i+=8) begin
					$fwrite(fp, "@%X " , i[DMEM_DATA_WIDTH-1:0]);
					$fwrite(fp, "%X %X %X %X " , dmem_inst.mem[i  ], dmem_inst.mem[i+1], dmem_inst.mem[i+2], dmem_inst.mem[i+3]);
					$fwrite(fp, "%X %X %X %X\n", dmem_inst.mem[i+4], dmem_inst.mem[i+5], dmem_inst.mem[i+6], dmem_inst.mem[i+7]);
				end
				$finish;
			end
		end
		$finish;
	end

	wire [DATA_WIDTH-1:0] iaddr, idin;
	wire [DATA_WIDTH-1:0] daddr, ddin, ddout;
	wire dwe0, dwe1, dwe2;
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
		.dwe0  (dwe0),
		.dwe1  (dwe1),
		.dwe2  (dwe2),
		.idin  (idin),
		.iaddr (iaddr)
	);

	/* data memory */
	dmem #(
		.DATA_WIDTH (DATA_WIDTH),
		.DEPTH      (DMEM_DEPTH)
	)
	dmem_inst (
		.clk   (clk  ),
		.addr0 (iaddr),
		.addr1 (daddr),
		.din   (ddout),
		.dout0 (idin ),
		.dout1 (ddin ),
		.we0   (dwe0 ),
		.we1   (dwe1 ),
		.we2   (dwe2 )
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
	initial begin
		repeat (SIMULATION_CYCLES) begin
			#(CLK_PERIOD_NS)
			$write("# ==== clock: %1d ====\n", $rtoi($time / CLK_PERIOD_NS) - 1);  
			//$write("# if_pc: 0x%08X if_instruction: 0x%032b\n", rv32i_inst.if_pc, rv32i_inst.if_instruction);  
			//$write("# id_pc: 0x%08X id_instruction: 0x%032b\n", rv32i_inst.id_pc, rv32i_inst.id_instruction);  
			//$write("# id_rd: 0x%05X id_rs1: 0x%05X id_rs2: 0x%05X\n",
			//rv32i_inst.id_rd,rv32i_inst.id_rs1,rv32i_inst.id_rs2);  
			//$write("# id_opcode: 0b%07b id_funct3: 0b%03b id_funct7: 0b%07b\n",
			//rv32i_inst.id_opcode, rv32i_inst.id_funct3, rv32i_inst.id_funct7);  
			//$write("# id_imm: 0x%08X id_reg0: 0x%08X id_reg1: 0x%08X\n",
			//rv32i_inst.id_imm, rv32i_inst.id_reg0, rv32i_inst.id_reg1);  
			//$write("# ex_result: 0x%08X ex_rd: 0x%05X\n",
			//rv32i_inst.ex_result, rv32i_inst.ex_rd);  
			$write("# dmem[0xC000]: 0x%08X\n",
			{dmem_inst.mem['hC000], dmem_inst.mem['hC001], dmem_inst.mem['hC002], dmem_inst.mem['hC003]});  
			//for (i=0; i<32; i+=8) begin
			//	$write ("# regs: 0x%08X 0x%08X 0x%08X 0x%08X 0x%08X 0x%08X 0x%08X 0x%08X\n", 
			//		rv32i_inst.reg_file_inst.register_file[i  ], rv32i_inst.reg_file_inst.register_file[i+1],
			//		rv32i_inst.reg_file_inst.register_file[i+2], rv32i_inst.reg_file_inst.register_file[i+3],
			//		rv32i_inst.reg_file_inst.register_file[i+4], rv32i_inst.reg_file_inst.register_file[i+5],
			//		rv32i_inst.reg_file_inst.register_file[i+6], rv32i_inst.reg_file_inst.register_file[i+7]);
			//end
			//$write("\n");
			$write ("# regs: 0x%08X 0x%08X 0x%08X 0x%08X 0x%08X 0x%08X 0x%08X 0x%08X\n", 
				rv32i_inst.reg_file_inst.register_file[0], rv32i_inst.reg_file_inst.register_file[1],
				rv32i_inst.reg_file_inst.register_file[2], rv32i_inst.reg_file_inst.register_file[3],
				rv32i_inst.reg_file_inst.register_file[4], rv32i_inst.reg_file_inst.register_file[5],
				rv32i_inst.reg_file_inst.register_file[6], rv32i_inst.reg_file_inst.register_file[7]);
		end
	end
endmodule

`default_nettype wire
