# Toolchain — building the DV tools (no OSS CAD Suite)

Every tool this repo needs is built from source or installed from apt/pip — **the
OSS CAD Suite is not used** (removed 2026-10-15). The canonical, version-pinned
definition is the [`Dockerfile`](../Dockerfile); CI builds that image (the `tools`
target) once per toolchain change, pushes it to GHCR, and runs the jobs inside it.
This page is the hand-build recipe for a local machine — it mirrors the Dockerfile.

## What each flow needs

| Flow / target | Tool | Source |
|---|---|---|
| `make lint`, `coverage`, `vlt*`, `systemc*`, `uvm*`, `stress` | **Verilator ≥ 5.03x** (UVM needs this) | build from source |
| `make sim` / `iverilog`, `cocotb` | **Icarus 12** | apt (`iverilog`) |
| `make systemc` | **SystemC** | apt (`libsystemc-dev`) |
| `make formal` | **SBY** + a **slang-capable Yosys** + **yices** (cover) / abc (prove) | build Yosys+sby from source; yices prebuilt |
| `make cocotb`, `pd-emu` | **cocotb 1.8.1 / pyuvm / pyvsc** | pip |
| Verilator FST traces | `lz4` + `zlib` dev headers | apt (`liblz4-dev zlib1g-dev`) |

## Quick setup (Ubuntu 24.04)

```bash
# --- apt tools + build deps ---------------------------------------------------
sudo apt-get update && sudo apt-get install -y \
  git make cmake g++ ccache autoconf flex bison libfl-dev help2man perl \
  python3 python3-venv python3-dev zlib1g-dev liblz4-dev \
  iverilog libsystemc-dev z3        # cmake on 24.04 is 3.28 (Yosys needs >= 3.28)

PREFIX=$HOME/.local        # or /usr/local with sudo; keep its bin on PATH

# --- Verilator (UVM-capable) --------------------------------------------------
git clone --depth 1 -b v5.050 https://github.com/verilator/verilator ~/src/verilator
cd ~/src/verilator && autoconf && ./configure --prefix="$PREFIX" && make -j"$(nproc)" && make install

# --- Yosys with NATIVE slang (CMake) ------------------------------------------
# tcl/readline/editline/ffi OFF (not needed for formal); abc + slang ON.
# -j capped: the slang TUs are memory-heavy (~1 GB each).
git clone --recurse-submodules https://github.com/YosysHQ/yosys ~/src/yosys
cd ~/src/yosys && git checkout 47595d984 && git submodule update --init --recursive
cmake -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DYOSYS_WITHOUT_TCL=ON -DYOSYS_WITHOUT_READLINE=ON \
  -DYOSYS_WITHOUT_EDITLINE=ON -DYOSYS_WITHOUT_LIBFFI=ON
cmake --build build -j4 && cmake --install build

# --- SBY (pure Python) --------------------------------------------------------
git clone --depth 1 https://github.com/YosysHQ/sby ~/src/sby
make -C ~/src/sby install PREFIX="$PREFIX"

# --- yices2 (prebuilt static; the formal `cover` solver) ----------------------
curl -fsSL https://github.com/SRI-CSL/yices2/releases/download/Yices-2.6.5/yices-2.6.5-x86_64-pc-linux-gnu-static-gmp.tar.gz \
  | tar -xz -C "$PREFIX"/.. 2>/dev/null; ln -sf "$HOME"/yices-2.6.5/bin/* "$PREFIX"/bin/ 2>/dev/null || true

# --- Python DV libs -----------------------------------------------------------
pip install --user -r dv/cocotb/requirements.txt   # cocotb 1.8.1, pyuvm, pyvsc
```

Then `make regress`, `make ci`, `make formal`, etc. all run against these.

## Notes / gotchas

- **Do NOT set `VERILATOR_ROOT`** — it breaks the UVM-on-Verilator flow.
- **Icarus must be ≥ 12.** `dv/cocotb/Makefile` auto-detects the first `iverilog`
  ≥ 12 on `PATH` (then `~/.local/bin`, `/usr/local/bin`, `/usr/bin`); Ubuntu
  24.04's apt `iverilog` is 12. Ubuntu 22.04's apt is 11 (too old — "syntax
  error / I give up").
- **Formal cover uses yices, not z3.** apt `z3` 4.8.12 OOMs / stalls on small CI
  runners for the deeper cover BMC ("Unexpected EOF response from solver"); yices
  is memory-light. `formal/Makefile` prefers yices when present, else falls back
  to z3.
- **Native vs plugin slang.** Upstream Yosys has slang built in (`read_slang`);
  the OSS CAD Suite shipped it as a loadable plugin (`plugin -i slang`).
  `formal/Makefile` adapts: with built-in slang it generates `_<proof>.sby` with
  the `plugin -i slang` line stripped. The committed `.sby` stay written for the
  plugin form.
- **Verilator FST traces** need `lz4.h` (`liblz4-dev`) at build time; without it
  the `vlt`/`coverage`/`systemc` C++ builds fail with `lz4.h: No such file`.
- The easiest path is to skip all of this and use the image:
  `docker build -t bridge-ci . && docker run --rm bridge-ci`.
