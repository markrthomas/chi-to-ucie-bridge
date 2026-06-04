# cocotb regression

Python-driven tests for `chi_to_ucie_bridge`, runnable under Icarus or Verilator.

```bash
make                 # Icarus (default)
make SIM=verilator   # Verilator: also enables SVA (--assert) + coverage
make clean
```

## Verification feature matrix

| Capability            | Verilator                         | Icarus (cocotb)     |
|:----------------------|:----------------------------------|:--------------------|
| Coverage (line/toggle/user) | yes (`--coverage`, see `make coverage`) | no                  |
| SVA concurrent assertions   | yes (`--assert`, `BRIDGE_SVA`)          | not supported       |
| cocotb stimulus/scoreboard  | see note below                          | yes                 |

- **Coverage + SVA together (no cocotb):** `make coverage` at the repo root
  compiles `src/chi_to_ucie_bridge_sva.sv` with `--assert --coverage` and writes
  `sim/coverage.info` (includes the SVA cover points).
- **cocotb under Icarus:** the working stimulus path on this box today.
- **cocotb under Verilator:** the build is correct (`--assert --coverage` are
  passed through), but the installed Verilator 5.047-devel + cocotb 1.8.1 pairing
  does not deliver value-change callbacks, so cocotb clocks do not advance and
  tests time out. Use a matched cocotb/Verilator release to enable it; the
  Makefile path is ready.

## Environment note

The oss-cad-suite shell exports `VIRTUAL_ENV` and puts a stdlib-less `python`
stub first on `PATH`, which misleads cocotb's interpreter detection. The Makefile
pins cocotb to the system Python that actually has it installed
(`COCOTB_PYTHON`, default `/usr/bin/python3.10`) and derives `PYTHONHOME` /
`PYTHONPATH` from it. Override `COCOTB_PYTHON` if your cocotb lives elsewhere.
