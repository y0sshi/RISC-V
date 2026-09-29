# riscv_gcc:latest - bare-metal RISC-V toolchain for src/software
#
# src/software builds freestanding .hex images with riscv64-unknown-elf-gcc and
# --specs=picolibc.specs (see src/software/Makefile).  Only the bare-metal elf
# toolchain is needed here -- the Linux/glibc cross gcc, g++ and gdb-multiarch
# were unused (the kernel build uses the separate linux-rv64 image).
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        gcc-riscv64-unknown-elf \
        binutils-riscv64-unknown-elf \
        picolibc-riscv64-unknown-elf \
        make \
        ca-certificates \
        && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace
CMD ["/bin/bash"]
