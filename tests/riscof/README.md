# RISCOF Architectural Compliance Environment

RISCOF (RISC-V Architectural Test Framework) setup for this core, using **Spike**
as the golden reference model.  Managed with **uv** (Python) per the project preference.

> Status (2026-05-31): **working end-to-end vs Spike.**  The `rv64i_m/C` suite passes fully
> and base-I tests pass (beq-01 etc.).  Run everything inside the all-in-one `riscof_run`
> image (host `riscv64-unknown-elf-gcc` is a rv32 Xilinx GCC, unusable):
>
> ```bash
> docker build -t spike:latest      tests/riscof/spike
> docker build -t riscof_run:latest -f tests/riscof/Dockerfile.run tests/riscof
> git -C tests/riscof clone --depth 1 -b 3.9.1 \
>     https://github.com/riscv-non-isa/riscv-arch-test.git arch-test-suite   # RISCOF-compatible layout
> docker run --rm -v "$PWD:/workspace" -w /workspace/tests/riscof riscof_run:latest \
>   riscof run --config=config.ini \
>     --suite=arch-test-suite/riscv-test-suite/rv64i_m/C \
>     --env=arch-test-suite/riscv-test-suite/env --no-browser
> ```
> Notes: `jobs=1` in config.ini (jobs=4 OOMs on parallel iverilog compiles); ACT memory was
> raised to 1 MB and the tb_rv_act timeout to 200 ms (arch-test signatures sit above 256 KB
> and I tests run ~16 M cycles).  Point `--suite` at the suite root to run all of I/M/A/F/D/C.

## Quick commands (Makefile)
Run from `tests/riscof/` (or `make -C tests/riscof <target>`).  Uses the all-in-one
`riscof_run` Docker image so no host toolchain is needed.
```bash
make setup                 # build spike + runner images, clone the arch-test suite (one time)
make run EXT=C             # run the C suite vs Spike  (EXT = I/M/A/F/D/C; omit EXT for all)
make run                   # run ALL applicable extensions
make run REF=sail_cSim EXT=C   # use the Sail reference (needs `make sail-image` + sail in runner)
make debug EXT=I NAME=jal-01   # run one test on the DUT only (prints TEST PASSED / TIMEOUT)
make validate              # riscof validateyaml
make report                # show the HTML report path (riscof_work/report.html)
make clean                 # remove run artifacts
```
Verified vs Spike: **I 51/51, M 13/13, A 18/18, C 25/25**.  (F/D run via the same flow but are
slow; `jobs=1` in config.ini avoids OOM; ACT memory is 2 MB and tb_rv_act timeout 200 ms.)

## Layout
```
tests/riscof/
├── pyproject.toml          # uv project: riscof 1.25.3 (+ gitpython override)
├── uv.lock                 # pinned, reproducible deps
├── config.ini              # RISCOF config: DUT=rvcore, REF=spike
├── rvcore/                 # DUT plugin (this RTL core, via iverilog ACT_MODE)
│   ├── riscof_rvcore.py    #   compile -> objcopy hex -> iverilog tb_rv_act -> signature
│   ├── rvcore_isa.yaml     #   RV64IMAFDC + Zicsr/Zifencei (validated)
│   ├── rvcore_platform.yaml
│   └── env/{link.ld,model_test.h}   # RVMODEL macros (tohost + begin/end_signature)
└── spike/                  # reference plugin (Spike / riscv-isa-sim)
    ├── riscof_spike.py
    ├── Dockerfile          # builds spike:latest
    └── env/{link.ld,model_test.h}
```

## 1. Python env (uv)
```bash
cd tests/riscof
uv sync                       # creates .venv with riscof 1.25.3 + deps
uv run riscof --version
uv run riscof validateyaml --config=config.ini   # verified OK
```
Version notes (already encoded in pyproject.toml):
- `riscof==1.25.3` pins `gitpython==3.1.17` which is **yanked** on PyPI; we override it via
  `[tool.uv] override-dependencies = ["gitpython>=3.1.30"]`.
- Older riscof (1.21.1) is incompatible with current `riscv-config` (imports the removed
  `warl_interpreter`), so 1.25.3 is required.
- riscof emits harmless `SyntaxWarning` (regex escapes) on Python 3.12 — ignore.

## 2. Toolchain + simulator (must be on PATH)
- `riscv64-unknown-elf-gcc` / `objcopy` / `objdump` (e.g. MSYS2 `mingw64`, or Vivado's GNU).
- `iverilog` / `vvp` (v12 or v13; both verified for this core).
The DUT plugin runs the same native ACT flow as `src/sim` `sim_act_internal`.

## 3. Spike reference
Build the image, then put a `spike` wrapper on PATH:
```bash
docker build -t spike:latest tests/riscof/spike
# create a `spike` wrapper somewhere on PATH:
#   #!/bin/sh
#   exec docker run --rm -v "$PWD:$PWD" -w "$PWD" spike:latest spike "$@"
```
(Or build riscv-isa-sim natively and put `spike` on PATH; then set `[spike] PATH=` to its dir.)

## 4. Arch-test suite (IMPORTANT caveat)
The `tests/riscv-arch-test` submodule is pinned to **v3.10** (new `tests/` layout). Classic
RISCOF expects the older `riscv-test-suite/<rvXX_m>/...` layout; the submodule's
`riscv-test-suite/` is empty.  For the initial bring-up, clone a RISCOF-compatible arch-test
into `tests/riscof/arch-test-suite/` (git-ignored):
```bash
cd tests/riscof
git clone https://github.com/riscv-non-isa/riscv-arch-test.git arch-test-suite
# pick a tag whose riscv-test-suite/ has the I/M/C/F/D suites (e.g. a 3.x release that still
# ships riscv-test-suite), then:
uv run riscof run --config=config.ini \
    --suite=arch-test-suite/riscv-test-suite \
    --env=arch-test-suite/riscv-test-suite/env
```

## 5. Run
```bash
uv run riscof run --config=config.ini --suite=<suite> --env=<suite>/env
```
RISCOF compiles each test for both DUT (rvcore) and reference (spike), runs them, and diffs
the signatures, producing an HTML report under `riscof_work/`.

## Remaining steps to first green run
1. Build the Spike image and add the `spike` wrapper (section 3).
2. Provide a RISCOF-compatible arch-test suite (section 4).
3. First run will likely need small iterations on signature formatting / `model_test.h`;
   our `tb_rv_act.sv` dumps `begin_signature..end_signature` as 32-bit LE words, matching
   Spike's `+signature +signature-granularity=4`.
4. Once user-level RV64IMAFDC passes, extend `rvcore_isa.yaml` with S/U + PMP and run the
   `privilege`/`pmp` suites — that is where **PMP access enforcement** gets implemented and
   validated (see the PMP note in `/CLAUDE.md`).
