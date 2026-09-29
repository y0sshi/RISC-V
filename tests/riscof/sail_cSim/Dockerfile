# =============================================================================
# Sail RISC-V reference model (legacy C emulator: riscv_sim_RV32 / riscv_sim_RV64)
# for RISCOF's sail_cSim plugin.  Heavy (OCaml/opam + Sail compiler).
#
# Build:  docker build -t sail:latest tests/riscof/sail_cSim
# Provide wrappers on PATH: riscv_sim_RV64 / riscv_sim_RV32 -> docker run sail:latest ...
#
# NOTE: the legacy sail-riscv build is sensitive to the Sail compiler / model
# commit pairing.  If `make` fails, pin SAIL_RISCV_REV to a known-good pre-cmake
# commit (the C emulator lives at c_emulator/riscv_sim_RV*).  The modern cmake
# build produces `sail_riscv_sim` with different flags and needs a wrapper.
# =============================================================================
FROM ubuntu:22.04
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        opam build-essential libgmp-dev z3 pkg-config zlib1g-dev \
        git ca-certificates m4 && \
    rm -rf /var/lib/apt/lists/*

RUN opam init -y --disable-sandboxing && opam install -y sail

ARG SAIL_RISCV_REV=master
RUN git clone https://github.com/riscv/sail-riscv.git /sail-riscv && \
    cd /sail-riscv && git checkout ${SAIL_RISCV_REV} && \
    bash -c 'eval $(opam env) && make c_emulator/riscv_sim_RV64 c_emulator/riscv_sim_RV32' && \
    cp c_emulator/riscv_sim_RV64 c_emulator/riscv_sim_RV32 /usr/local/bin/ 2>/dev/null || \
    bash -c 'eval $(opam env) && make' && \
    find /sail-riscv -name "riscv_sim_RV*" -exec cp {} /usr/local/bin/ \;

ENTRYPOINT []
CMD ["riscv_sim_RV64", "--help"]
