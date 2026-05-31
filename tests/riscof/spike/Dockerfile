# =============================================================================
# Spike (riscv-isa-sim) reference model for RISCOF.
# Build:  docker build -t spike:latest tests/riscof/spike
# Use:    provide a `spike` wrapper on PATH that runs this image, e.g.
#   #!/bin/sh
#   exec docker run --rm -v "$PWD:$PWD" -w "$PWD" spike:latest spike "$@"
# (or build Spike natively and skip Docker — see README.md.)
# =============================================================================
FROM ubuntu:24.04

RUN apt-get update && apt-get install -y --no-install-recommends \
        git build-essential autoconf automake autotools-dev \
        device-tree-compiler libboost-all-dev ca-certificates && \
    rm -rf /var/lib/apt/lists/*

ARG SPIKE_REV=master
RUN git clone https://github.com/riscv-software-src/riscv-isa-sim.git /tmp/spike && \
    cd /tmp/spike && git checkout ${SPIKE_REV} && \
    mkdir build && cd build && \
    ../configure --prefix=/usr/local && \
    make -j"$(nproc)" && make install && \
    rm -rf /tmp/spike

ENTRYPOINT []
CMD ["spike", "--help"]
