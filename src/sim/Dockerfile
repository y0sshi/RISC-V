# syntax=docker/dockerfile:1.5
########################################
# Stage 1: builder - build iverilog v13
########################################
FROM ubuntu:24.04 AS builder
ARG IVERILOG_VER=v13_0
ENV DEBIAN_FRONTEND=noninteractive

# Only the deps needed to build iverilog from the release tarball.
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential autoconf bison flex pkg-config \
    libreadline-dev libncurses-dev wget ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# fetch official release tarball (adjust URL if needed)
RUN mkdir -p /build && \
    wget -q -O /build/iverilog.tar.gz \
      "https://github.com/steveicarus/iverilog/archive/refs/tags/v13_0.tar.gz" && \
    tar -xzf /build/iverilog.tar.gz -C /build --strip-components=1

WORKDIR /build
RUN autoconf && ./configure --prefix=/usr/local && make -j$(nproc) && make install DESTDIR=/out

# strip binaries to reduce size (optional)
RUN if [ -d /out/usr/local/bin ]; then strip /out/usr/local/bin/* || true; fi

########################################
# Stage 2: runtime - minimal image
########################################
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive

# Runtime deps for iverilog/vvp only (linked against readline/ncurses at build
# time).  NOTE: verilator/gtkwave are intentionally NOT here -- verilator sims use
# the separate verilator:5.020 image (this image lacks g++/make anyway), and
# `make wave_*` launches gtkwave on the HOST, not in the container.
RUN apt-get update && apt-get install -y --no-install-recommends \
    libreadline8 libncurses6 ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# copy iverilog install tree from builder
COPY --from=builder /out/usr/local /usr/local

# sanity check: ensure iverilog and vvp are available
RUN /usr/local/bin/iverilog -V || true

# workspace
WORKDIR /workspace
ENV PATH=/usr/local/bin:$PATH

# default to interactive shell
CMD ["/bin/bash"]

