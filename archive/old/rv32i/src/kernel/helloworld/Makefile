PREFIX=riscv32-unknown-elf-
CC=$(PREFIX)gcc
LD=$(PREFIX)ld
AS=$(PREFIX)as

BASE_CFLAGS=-fno-stack-protector -fno-zero-initialized-in-bss -ffreestanding
OPT_CFLAGS=-fno-builtin -nostdlib -nodefaultlibs -nostartfiles -mstrict-align
WARN_CFLAGS=-Wall -Wextra
ARCH_CFLAGS=-march=rv32i

CFLAGS=$(BASE_CFLAGS) $(OPT_CFLAGS) $(WARN_CFLAGS) $(ARCH_CFLAGS)
ASFLAGS=$(ARCH_CFLAGS)
LDFLAGS=-T link.ld

C_SRC=$(wildcard *.c **/*.c)
S_SRC=$(wildcard *.s **/*.s)
OBJ_FILES=$(C_SRC:.c=.o) $(S_SRC:.s=.o)

TARGET = helloworld.x

$(TARGET): $(OBJ_FILES)
	$(LD) $(LDFLAGS) -o $@ $^

%.o: %.c
	$(CC) $(CFLAGS) -c -o $@ $<

%.o: %.s
	$(AS) $(ASFLAGS) -c -o $@ $<

clean:
	rm -rf $(OBJ_FILES) $(TARGET)

run: $(TARGET)
	qemu-system-riscv32 -smp 1 -serial mon:stdio --no-reboot -m 128 -machine virt,aclint=on -bios none -kernel $^

.PHONY: clean run

