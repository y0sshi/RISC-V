# syntax=docker/dockerfile:1.5
########################################
# riscv_act:latest - riscv-tests (ISA compliance) runner for rv_soc
#
#   = the shared iverilog:13.0 base image + the RISC-V bare-metal toolchain.
#   Previously this rebuilt iverilog v13 from source itself (a 2nd ~10-min copy);
#   basing off iverilog:13.0 removes that duplication.
#
#   ORDER: build iverilog:13.0 FIRST (src/sim: `make image`, or the top-level
#   `make images` which builds them in dependency order).
########################################
FROM iverilog:13.0
ENV DEBIAN_FRONTEND=noninteractive

# gcc-riscv64-unknown-elf      : RISC-V cross compiler + binutils (objcopy/objdump)
# picolibc-riscv64-unknown-elf : C headers (string.h etc.) for riscv-tests v-variants
# make                         : riscv-tests isa/Makefile is pre-committed
RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc-riscv64-unknown-elf picolibc-riscv64-unknown-elf make \
    && rm -rf /var/lib/apt/lists/*

# gcc-riscv64-unknown-elf was built with --with-headers=no, so it does not search
# the picolibc header tree by default. Symlink the path gcc DOES search
# (/usr/lib/riscv64-unknown-elf/include) at the picolibc headers so that
# #include <string.h> etc. resolve correctly.
RUN ln -sf /usr/lib/picolibc/riscv64-unknown-elf/include \
           /usr/lib/riscv64-unknown-elf/include

WORKDIR /workspace
CMD ["/bin/bash"]
