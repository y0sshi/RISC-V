`default_nettype none

/* ALU OP */
`define ALU_ADD    3'b000
`define ALU_LSHIFT 3'b001
`define ALU_SLT    3'b010
`define ALU_SLTU   3'b011
`define ALU_XOR    3'b100
`define ALU_RSHIFT 3'b101
`define ALU_OR     3'b110
`define ALU_AND    3'b111

/* OPCODE */
`define OP_LUI       7'b0110111
`define OP_AUIPC     7'b0010111
`define OP_JAL       7'b1101111
`define OP_JALR      7'b1100111
`define OP_BRANCH    7'b1100011
`define OP_LOAD      7'b0000011
`define OP_STORE     7'b0100011
`define OP_IMMEDIATE 7'b0010011
`define OP_REGISTER  7'b0110011
`define OP_MISC_MEM  7'b0000111 // FENCE, FENCE.I
`define OP_SYSTEM    7'b1110011 // CSR instructions, ECALL, EBREAK

/* instruction type */
`define TYPE_R 3'd0
`define TYPE_I 3'd1
`define TYPE_S 3'd2
`define TYPE_B 3'd3
`define TYPE_U 3'd4
`define TYPE_J 3'd5

//typedef enum {
//	TYPE_R, TYPE_I, TYPE_S, TYPE_B, TYPE_U, TYPE_J
//} type_t;

module rv32i
	#(
		parameter integer DATA_WIDTH = -1,
		parameter integer REGS       = -1
	)
	(
		input  wire                  clk, rst,
		input  wire [DATA_WIDTH-1:0] ddin,
		output reg  [DATA_WIDTH-1:0] ddout,
		output wire [DATA_WIDTH-1:0] daddr,
		output reg                   dwe0, dwe1, dwe2,
		input  wire [DATA_WIDTH-1:0] idin,
		output wire [DATA_WIDTH-1:0] iaddr
	);

	/* IF (Instruction Fetch) stage */
	reg [DATA_WIDTH-1:0] if_instruction;
	always @(posedge clk) begin
		if (rst) begin
			if_instruction <= 32'd0;
		end
		else begin
			if_instruction <= idin;
		end
	end

	reg [DATA_WIDTH-1:0] ex_result, ex_pc;
	reg [DATA_WIDTH-1:0] if_pc;
	reg if_pc_we;
	wire pc_jump_en;
	always @(posedge clk) begin
		if (rst) begin
			if_pc <= 32'd0;
		end
		else begin
			if_pc <= (if_pc_we) ? ex_result : if_pc + 32'd4;
		end
	end
	assign iaddr = if_pc;

	/* ID (Instruction Decode) stage */
	reg [DATA_WIDTH-1:0] id_instruction;
	always @(posedge clk) begin
		if (rst) begin
			id_instruction <= 32'd0;
		end
		else begin
			id_instruction <= if_instruction;
		end
	end

	wire [6:0]  opcode;
	wire [4:0]  rd, rs1, rs2;
	wire [2:0]  funct3;
	wire [6:0]  funct7;
	wire [11:0] imm_i, imm_s;
	wire [12:0] imm_b;
	wire [31:0] imm_u;
	wire [20:0] imm_j;
	wire [DATA_WIDTH-1:0] reg_file_dout0, reg_file_dout1;

	decoder #(
		.DATA_WIDTH(DATA_WIDTH)
	)
	decoder_inst (
		.instruction (if_instruction),
		.opcode      (opcode        ),
		.rd          (rd            ),
		.funct3      (funct3        ),
		.rs1         (rs1           ),
		.rs2         (rs2           ),
		.funct7      (funct7        ),
		.imm_i       (imm_i         ),
		.imm_s       (imm_s         ),
		.imm_b       (imm_b         ),
		.imm_u       (imm_u         ),
		.imm_j       (imm_j         )
	);

	wire [2:0] instruction_type;
	function [2:0] ir_type (input [6:0] opcode);
	begin
		case (opcode)
			`OP_LUI       : ir_type = `TYPE_U;
			`OP_AUIPC     : ir_type = `TYPE_U;
			`OP_JAL       : ir_type = `TYPE_J;
			`OP_JALR      : ir_type = `TYPE_I;
			`OP_BRANCH    : ir_type = `TYPE_B;
			`OP_LOAD      : ir_type = `TYPE_I;
			`OP_STORE     : ir_type = `TYPE_S;
			`OP_IMMEDIATE : ir_type = `TYPE_I;
			`OP_REGISTER  : ir_type = `TYPE_R;
			`OP_MISC_MEM  : ir_type = `TYPE_R;
			`OP_SYSTEM    : ir_type = `TYPE_R;
			default       : ir_type = `TYPE_R;
		endcase
	end
	endfunction
	assign instruction_type = ir_type(opcode);

	reg [6:0]  id_opcode;
	reg [4:0]  id_rd, id_rs1, id_rs2;
	reg [2:0]  id_funct3;
	reg [6:0]  id_funct7;
	reg [DATA_WIDTH-1:0] id_imm, id_imm_s, id_reg0, id_reg1;
	reg [2:0] id_type;
	always @(posedge clk) begin
		if (rst) begin
			id_opcode   <= 7'd0;
			id_rd       <= 32'd0;
			id_rs1      <= 32'd0;
			id_rs2      <= 32'd0;
			id_funct3   <= 3'd0;
			id_funct7   <= 7'd0;
			id_imm      <= 32'd0;
			id_imm_s    <= 32'd0;
			id_reg0     <= 32'd0;
			id_reg1     <= 32'd0;
			id_type     <= instruction_type;
		end
		else begin
			id_opcode <= opcode;
			id_rd     <= rd;
			id_rs1    <= rs1;
			id_rs2    <= rs2;
			id_funct3 <= funct3;
			id_funct7 <= funct7;
			id_reg0   <= reg_file_dout0;
			id_reg1   <= reg_file_dout1;
			id_type   <= instruction_type;
			case (instruction_type)
				`TYPE_R : begin
					id_imm   <= 32'dx;
					id_imm_s <= 32'dx;
				end
				`TYPE_I : begin
					id_imm   <= {20'd0, imm_i};
					id_imm_s <= {{20{imm_i[11]}}, imm_i};
				end
				`TYPE_S : begin
					id_imm   <= {20'd0, imm_s};
					id_imm_s <= {{20{imm_s[11]}}, imm_s};
				end
				`TYPE_B : begin
					id_imm   <= {19'd0, imm_b};
					id_imm_s <= {{19{imm_b[12]}}, imm_b};
				end
				`TYPE_U : begin
					id_imm   <= imm_u;
					id_imm_s <= imm_u;
				end
				`TYPE_J : begin
					id_imm   <= {19'd0, imm_j};
					id_imm_s <= {{11{imm_j[20]}}, imm_j};
				end
			endcase
		end
	end

	reg [31:0] id_pc;
	always @(posedge clk) begin
		if (rst) begin
			id_pc <= 32'd0;
		end
		else begin
			id_pc <= if_pc;
		end
	end

	/* EX (Execution) stage */
	wire [DATA_WIDTH-1:0] alu_ain, alu_bin, alu_dout;
	wire [2:0] alu_func;
	wire       alu_ext, alu_addcom;

	assign alu_addcom = (id_opcode==`OP_LOAD | id_opcode == `OP_STORE | id_opcode==`OP_BRANCH | id_opcode==`OP_JAL);
	assign alu_ext    = (id_opcode==`OP_REGISTER) & id_funct7[5];
	assign alu_func   = id_funct3;
	assign alu_ain    = (id_opcode==`OP_BRANCH | id_opcode==`OP_JAL) ? id_pc : id_reg0;
	assign alu_bin    = (id_opcode==`OP_REGISTER) ? id_reg1 : id_imm_s;

	alu_rv32i #(
		.DATA_WIDTH(DATA_WIDTH)
	)
	alu_inst (
		.ain    (alu_ain),
		.bin    (alu_bin),
		.funct3 (alu_func),
		.ext    (alu_ext),
		.addcom (alu_addcom),
		.dout   (alu_dout)
	);

	wire [DATA_WIDTH-1:0] alu_result;
	assign alu_result =
	(id_opcode==`OP_LUI  ) ? id_imm :
	(id_opcode==`OP_AUIPC) ? id_pc + (id_imm<<12):
	alu_dout;
	reg [6:0]  ex_opcode;
	reg [4:0]  ex_rd, ex_rs1, ex_rs2;
	reg [2:0]  ex_funct3;
	always @(posedge clk) begin
		if (rst) begin
			ex_result   <=  'd0;
			ex_pc       <=  'd0;
			ex_opcode   <= 7'd0;
			ex_rd       <= 5'd0;
			ex_rs1      <= 5'd0;
			ex_rs2      <= 5'd0;
			ex_funct3   <= 3'd0;
			if_pc_we    <= 1'b0;
			ddout       <=  'd0;
			dwe0        <= 1'b0;
			dwe1        <= 1'b0;
			dwe2        <= 1'b0;
		end
		else begin
			ex_result   <= alu_result;
			ex_pc       <= id_pc;
			ex_rd       <= id_rd;
			ex_rs1      <= 5'd0;
			ex_rs2      <= 5'd0;
			ex_funct3   <= id_funct3;
			ex_opcode   <= id_opcode;
			if (id_funct3[1]) begin // SW
				ddout     <= id_reg1;
				dwe0      <= (id_opcode==`OP_STORE);
				dwe1      <= (id_opcode==`OP_STORE);
				dwe2      <= (id_opcode==`OP_STORE);
			end
			else if (id_funct3[0]) begin // SH
				ddout     <= {id_reg1[15:8], id_reg1[7:0], 16'd0};
				dwe0      <= (id_opcode==`OP_STORE);
				dwe1      <= (id_opcode==`OP_STORE);
				dwe2      <= 1'b0;
			end
			else begin // SB
				ddout     <= {id_reg1[7:0], 24'd0};
				dwe0      <= (id_opcode==`OP_STORE);
				dwe1      <= 1'b0;
				dwe2      <= 1'b0;
			end
			if (id_opcode==`OP_BRANCH) begin
				if      (id_funct3==3'b000 && id_reg0 == id_reg1) begin // BEQ
					if_pc_we    <= 1'b1;
				end
				else if (id_funct3==3'b001 && id_reg0 != id_reg1) begin // BNE
					if_pc_we    <= 1'b1;
				end
				else if (id_funct3==3'b100 && $signed(id_reg0) <  $signed(id_reg1)) begin // BLT
					if_pc_we    <= 1'b1;
				end
				else if (id_funct3==3'b101 && $signed(id_reg0) >= $signed(id_reg1)) begin // BGE
					if_pc_we    <= 1'b1;
				end
				else if (id_funct3==3'b110 && id_reg0 <  id_reg1) begin // BLTU
					if_pc_we    <= 1'b1;
				end
				else if (id_funct3==3'b111 && id_reg0 >= id_reg1) begin // BGEU
					if_pc_we    <= 1'b1;
				end
				else begin
					if_pc_we    <= 1'b0;
				end
			end
			else begin
				if_pc_we    <= (id_opcode==`OP_JAL || id_opcode==`OP_JALR);
			end
		end
	end
	assign daddr = ex_result;

	/* MEM (Memory Access) stage */
	wire [DATA_WIDTH-1:0] load;
	assign load = 
		(ex_funct3==3'b000) ? {{24{ddin[DATA_WIDTH-1]}}, ddin[DATA_WIDTH-1:DATA_WIDTH-8]}  : // LB
		(ex_funct3==3'b001) ? {{16{ddin[DATA_WIDTH-1]}}, ddin[DATA_WIDTH-1:DATA_WIDTH-15]} : // LH
		(ex_funct3==3'b100) ? {24'd0, ddin[DATA_WIDTH-1:DATA_WIDTH-8]}                     : // LBU
		(ex_funct3==3'b101) ? {16'd0, ddin[DATA_WIDTH-1:DATA_WIDTH-15]}                    : // LHU
		ddin; // LW

	reg [DATA_WIDTH-1:0] mem_result;
	reg [4:0]  mem_rd;
	reg reg_file_we;
	always @(posedge clk) begin
		if (rst) begin
			mem_result   <=  'd0;
			mem_rd       <= 5'd0;
			reg_file_we <= 1'b0;
		end
		else begin
			mem_result   <= 
			(ex_opcode==`OP_LOAD) ? load :
			(ex_opcode==`OP_JAL | ex_opcode==`OP_JALR) ? ex_pc: 
			ex_result;
			mem_rd       <= ex_rd;
			reg_file_we <= (ex_opcode==`OP_REGISTER | ex_opcode==`OP_LOAD | ex_opcode==`OP_IMMEDIATE | ex_opcode==`OP_LUI | ex_opcode==`OP_AUIPC | ex_opcode==`OP_JAL | ex_opcode==`OP_JALR);
		end
	end

	/* WB (Write Back) stage */
	wire [DATA_WIDTH-1:0] reg_file_din;
	assign reg_file_din = mem_result;

	reg_file #(
		.DATA_WIDTH (DATA_WIDTH),
		.REGS       (REGS)
	)
	reg_file_inst (
		.clk   (clk),
		.rst   (rst),
		.addr0 (rs1),
		.addr1 (rs2),
		.addr2 (mem_rd),
		.din   (reg_file_din),
		.we    (reg_file_we),
		.dout0 (reg_file_dout0),
		.dout1 (reg_file_dout1)
	);

endmodule

module decoder
	#(
		parameter DATA_WIDTH = -1
	)
	(
		input  wire  [DATA_WIDTH-1:0] instruction,
		output wire  [6:0]            opcode,
		output wire  [4:0]            rd, rs1, rs2,
		output wire  [2:0]            funct3,
		output wire  [6:0]            funct7,
		output wire  [11:0]           imm_i, imm_s,
		output wire  [12:0]           imm_b,
		output wire  [31:0]           imm_u,
		output wire  [20:0]           imm_j
	);
	
	assign opcode = instruction[6:0];
	assign rd     = instruction[11:7];
	assign funct3 = instruction[14:12];
	assign rs1    = instruction[19:15];
	assign rs2    = instruction[24:20];
	assign funct7 = instruction[31:25];
	assign imm_i  = instruction[31:20];
	assign imm_s  = {instruction[31:25], instruction[11:7]};
	assign imm_b  = {instruction[31],instruction[7],instruction[30:25],instruction[11:8], 1'd0};
	assign imm_u  = {instruction[31:12], 12'd0};
	assign imm_j  = {instruction[31],instruction[19:12],instruction[20],instruction[30:21], 1'd0};
	//assign imm_s  = instruction[31:25|11:7];
	//assign imm_b  = {instruction[31|7|30:25|11:8], 1'd0};
	//assign imm_u  = {instruction[31:12], 12'd0};
	//assign imm_j  = {instruction[31|19:12|20|30:21], 1'd0};

endmodule

module reg_file
	#(
		parameter integer DATA_WIDTH = -1,
		parameter integer REGS       = -1
	)
	(
		input  wire                    clk, rst,
		input  wire [$clog2(REGS)-1:0] addr0, addr1, addr2,
		input  wire [DATA_WIDTH-1:0]   din,
		input  wire                    we,
		output wire [DATA_WIDTH-1:0]   dout0, dout1
	);

	reg [DATA_WIDTH-1:0] register_file [REGS-1:0];
	initial begin
		register_file[0] <= 'd0;
	end
	always @(posedge clk) begin
		if (we & addr2!='d0) begin
			register_file[addr2] <= din;
		end
	end
	assign dout0 = (addr0 == 0) ? 0 : register_file[addr0];
	assign dout1 = (addr1 == 0) ? 0 : register_file[addr1];

endmodule

module alu_rv32i
	#(
		parameter integer DATA_WIDTH = -1
	)
	(
		input  wire [DATA_WIDTH-1:0] ain, bin,
		input  wire [2:0]            funct3,
		input  wire                  ext, addcom,
		output wire [DATA_WIDTH-1:0] dout
	);

	function [DATA_WIDTH-1:0] alu (
		input [DATA_WIDTH-1:0] ain, bin,
		input [2:0] func,
		input       ext);
	begin
		case (funct3)
			`ALU_ADD    : alu = (ext) ? ain - bin : ain + bin;
			`ALU_LSHIFT : alu = ain << bin[4:0];
			`ALU_SLT    : alu = $signed(ain) < $signed(bin);
			`ALU_SLTU   : alu = ain < bin;
			`ALU_XOR    : alu = ain ^ bin;
			`ALU_RSHIFT : alu = (ext) ? $signed(ain) >>> bin[4:0] : ain >> bin[4:0];
			`ALU_OR     : alu = ain | bin;
			`ALU_AND    : alu = ain & bin;
			default     : alu = 'dx;
		endcase
	end
	endfunction
	assign dout = (addcom) ? (ain + bin) : alu(ain, bin, funct3, ext);

endmodule

`default_nettype wire
