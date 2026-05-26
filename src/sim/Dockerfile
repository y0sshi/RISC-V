# syntax=docker/dockerfile:1.5
########################################
# Stage 1: builder - build iverilog v13
########################################
FROM ubuntu:24.04 AS builder
ARG IVERILOG_VER=v13_0
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential autoconf bison flex pkg-config \
    libreadline-dev libncurses-dev wget ca-certificates git \
    python3 python3-pip curl && \
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

# runtime deps for iverilog and tools
RUN apt-get update && apt-get install -y --no-install-recommends \
    libreadline8 libncurses6 ca-certificates \
    verilator gtkwave wget && \
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

