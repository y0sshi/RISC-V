MEM_SET   = 1
SIM_TOP   = sim_rv32i
MODULES   = rv32i.sv dmem.sv
SIM_FILES = $(SIM_TOP).sv $(MODULES)
MEM_FILES = mem/memset$(MEM_SET)/imem.dat mem/memset$(MEM_SET)/dmem.dat

all: $(SIM_TOP).vcd

wave: $(SIM_TOP).vcd
	open ./$(SIM_TOP).vcd

$(SIM_TOP).vcd: $(SIM_TOP).o
	vvp ./$(SIM_TOP).o

$(SIM_TOP).o: $(SIM_FILES) $(MEM_FILES)
	iverilog -DIVERILOG -o $(SIM_TOP).o -s $(SIM_TOP) $(SIM_FILES)

sim_rv32i.shm: $(SIM_FILES)
	xmverilog +access+rw +define+DXMVERILOG $(SIM_FILES)

clean:
	rm -rf *.log xmverilog.* *.shm *.o *.vcd xcelium.d *.dump
