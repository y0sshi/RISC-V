# syntax=docker/dockerfile:1.5
########################################
# RV64 Linux kernel build image
#   gcc-riscv64-linux-gnu (Linux/glibc cross toolchain, NOT the bare-metal elf
#   gcc) + the kernel build deps + cpio for the initramfs.  Used by build.sh to
#   produce a minimal RV64 Linux Image and wrap it into an OpenSBI fw_payload for
#   the Verilator/iverilog boot harness (see docs/linux_sim.md).
#
# Build:  docker build -t linux-rv64:latest -f Dockerfile .
########################################
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc-riscv64-linux-gnu \
    build-essential \
    make bc bison flex \
    libelf-dev libssl-dev \
    cpio xz-utils gzip \
    device-tree-compiler \
    git ca-certificates wget python3 && \
    rm -rf /var/lib/apt/lists/*

RUN riscv64-linux-gnu-gcc --version | head -1

WORKDIR /workspace
CMD ["/bin/bash"]
