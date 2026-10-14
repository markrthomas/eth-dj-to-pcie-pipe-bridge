# syntax=docker/dockerfile:1.7
# =============================================================================
# eth-dj-pcie-pipe7_1-bridge — batch image for `make ci`-class runs (Railway /
# local) and the GitHub CI `container:`.  NO OSS CAD Suite: every tool is built
# from source or installed from apt/pip, pinned below.
#
#   Verilator  : built from source (VERILATOR_REF), UVM-capable  -> /opt/verilator
#   Yosys+slang: built from source via CMake, NATIVE slang       -> /opt/yosys
#   SBY        : YosysHQ/sby (pure Python)                        -> /opt/sby
#   Icarus 12  : apt iverilog (ubuntu 24.04 = 12.0)
#   SystemC    : apt libsystemc-dev
#   z3         : apt (SMT solver for the formal `cover` tasks; formal/Makefile
#                auto-selects z3 when yices is absent, and strips `plugin -i
#                slang` because this Yosys has slang BUILT IN)
#   cocotb/pyuvm/pyvsc : pip into /opt/venv (dv/cocotb/requirements.txt)
#
# ENTRYPOINT runs docker/entrypoint.sh (default: full run + metrics + dashboard).
# Optional: drop *.crt into docker/extra_ca/ before building to trust an extra CA.
# =============================================================================

# ----------------------------------------------------------------------------
# builder: compile Verilator + Yosys(+slang) + SBY, install under /opt
# ----------------------------------------------------------------------------
FROM ubuntu:24.04 AS builder

ARG VERILATOR_REF=v5.050
# Yosys master commit with the native slang frontend (frontends/slang) + CMake build.
ARG YOSYS_REF=47595d984
ARG SBY_REF=main
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git make cmake g++ ccache \
      autoconf flex bison libfl-dev help2man perl \
      python3 python3-dev zlib1g-dev liblz4-dev \
    && rm -rf /var/lib/apt/lists/*

# --- Verilator (from source) ------------------------------------------------
RUN git clone --depth 1 -b "${VERILATOR_REF}" https://github.com/verilator/verilator /src/verilator \
    && cd /src/verilator \
    && autoconf && ./configure --prefix=/opt/verilator \
    && make -j"$(nproc)" && make install \
    && rm -rf /src/verilator

# --- Yosys + native slang (CMake) -------------------------------------------
# tcl/readline/editline/ffi OFF (not needed for formal; avoids those -dev pkgs);
# abc + slang ON.  -j limited so the heavy slang TUs fit a CI runner's RAM.
RUN git clone --recurse-submodules https://github.com/YosysHQ/yosys /src/yosys \
    && cd /src/yosys && git checkout "${YOSYS_REF}" && git submodule update --init --recursive \
    && cmake -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/opt/yosys \
        -DYOSYS_WITHOUT_TCL=ON -DYOSYS_WITHOUT_READLINE=ON \
        -DYOSYS_WITHOUT_EDITLINE=ON -DYOSYS_WITHOUT_LIBFFI=ON \
    && cmake --build build -j"$(( $(nproc) < 4 ? $(nproc) : 4 ))" \
    && cmake --install build \
    && rm -rf /src/yosys

# --- SBY (pure Python) ------------------------------------------------------
RUN git clone --depth 1 -b "${SBY_REF}" https://github.com/YosysHQ/sby /src/sby \
    && make -C /src/sby install PREFIX=/opt/sby \
    && rm -rf /src/sby

# ----------------------------------------------------------------------------
# tools: everything needed to RUN the DV flows, but WITHOUT the repo baked in.
# Verilator re-compiles C++ sims at run time, so g++/make + verilator headers +
# lz4/zlib must be present here too.  GitHub CI builds `--target tools` and runs
# the jobs against a checkout, so this image is a pure, source-independent
# toolchain (cache key = tool versions, not the source).
# ----------------------------------------------------------------------------
FROM ubuntu:24.04 AS tools

ARG WITH_CLAUDE=0
ENV PYTHONUNBUFFERED=1 DEBIAN_FRONTEND=noninteractive

# optional extra CA certificates (*.crt in docker/extra_ca/)
COPY docker/extra_ca/ /usr/local/share/ca-certificates/extra/

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git make g++ ccache \
      python3 python3-venv python3-dev \
      iverilog libsystemc-dev z3 zlib1g-dev liblz4-dev xz-utils \
    && update-ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# built-from-source toolchain
COPY --from=builder /opt/verilator /opt/verilator
COPY --from=builder /opt/yosys     /opt/yosys
COPY --from=builder /opt/sby       /opt/sby

COPY dv/cocotb/requirements.txt /tmp/requirements.txt
RUN python3 -m venv /opt/venv \
    && /opt/venv/bin/pip install --no-cache-dir -r /tmp/requirements.txt

RUN if [ "$WITH_CLAUDE" = "1" ]; then \
      apt-get update && apt-get install -y --no-install-recommends nodejs npm \
      && npm install -g @anthropic-ai/claude-code && rm -rf /var/lib/apt/lists/*; \
    fi

# venv first (python3 + cocotb), then the built tools, then the apt tools
# (iverilog 12 at /usr/bin; dv/cocotb/Makefile auto-detects it).
ENV PATH=/opt/venv/bin:/opt/verilator/bin:/opt/yosys/bin:/opt/sby/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# ----------------------------------------------------------------------------
# full: the tools image + the repo baked in, for Railway / local batch runs.
# GitHub CI does NOT use this stage — it builds `--target tools` and runs the
# jobs against an actions/checkout, so the CI image depends only on tool
# versions (good cache behaviour), not on the source.
# ----------------------------------------------------------------------------
FROM tools AS full

WORKDIR /repo
COPY . /repo
RUN chmod +x docker/*.sh

ENTRYPOINT ["/repo/docker/entrypoint.sh"]
