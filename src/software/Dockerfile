FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        gcc-riscv64-unknown-elf \
        gcc-riscv64-linux-gnu \
        g++-riscv64-linux-gnu \
        picolibc-riscv64-unknown-elf \
        binutils-riscv64-unknown-elf \
        binutils-riscv64-linux-gnu \
        gdb-multiarch \
        make \
        git \
        ca-certificates \
        && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace
CMD ["/bin/bash"]
