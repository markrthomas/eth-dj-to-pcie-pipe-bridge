# syntax=docker/dockerfile:1.7
# =============================================================================
# eth-dj-pcie-pipe7_1-bridge — batch image for `make ci`-class runs (Railway /
# local).  Pins the same tools as .github/workflows/ci.yml:
#   OSS CAD Suite 2026-04-13 (Verilator 5.047, Yosys+slang, SBY, solvers)
#   apt Icarus + cocotb 1.8.1 / pyuvm / pyvsc in a venv (ICARUS_BIN_DIR=/usr/bin)
#   apt SystemC (libsystemc-dev) for dv/systemc
# The OSS CAD Suite goes LAST on PATH so python3/iverilog resolve to the venv /
# apt copies (the suite ships its own python + cocotb 2.x).
# ENTRYPOINT runs docker/entrypoint.sh (default: full run + metrics + dashboard).
# Optional: drop one or more *.crt files into docker/extra_ca/ before building to trust an extra CA
# (TLS-intercepting proxies).  Not a `RUN --mount=type=secret`: Railway's Dockerfile builder rejects
# every --mount type except cache.
# =============================================================================
FROM ubuntu:24.04

ARG OSS_CAD_SUITE_VERSION=2026-04-13
# 1 = also install Node + the Claude Code CLI (for docker/swarm.sh)
ARG WITH_CLAUDE=0
ENV PYTHONUNBUFFERED=1 \
    DEBIAN_FRONTEND=noninteractive \
    OSS_CAD_SUITE_VERSION=${OSS_CAD_SUITE_VERSION}

# optional extra CA certificates (*.crt in docker/extra_ca/; the directory only holds a .gitkeep by default)
COPY docker/extra_ca/ /usr/local/share/ca-certificates/extra/

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      ca-certificates curl git make g++ ccache python3 python3-venv python3-dev \
      iverilog libsystemc-dev xz-utils && \
    update-ca-certificates && \
    rm -rf /var/lib/apt/lists/*

RUN curl -fsSL "https://github.com/YosysHQ/oss-cad-suite-build/releases/download/${OSS_CAD_SUITE_VERSION}/oss-cad-suite-linux-x64-$(echo ${OSS_CAD_SUITE_VERSION} | tr -d -).tgz" \
      | tar -xz -C /opt

COPY dv/cocotb/requirements.txt /tmp/requirements.txt
RUN python3 -m venv /opt/venv && \
    /opt/venv/bin/pip install --no-cache-dir -r /tmp/requirements.txt

RUN if [ "$WITH_CLAUDE" = "1" ]; then \
      apt-get update && apt-get install -y --no-install-recommends nodejs npm && \
      npm install -g @anthropic-ai/claude-code && rm -rf /var/lib/apt/lists/*; \
    fi

ENV PATH=/opt/venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/opt/oss-cad-suite/bin \
    ICARUS_BIN_DIR=/usr/bin

WORKDIR /repo
COPY . /repo
RUN chmod +x docker/*.sh

ENTRYPOINT ["/repo/docker/entrypoint.sh"]
