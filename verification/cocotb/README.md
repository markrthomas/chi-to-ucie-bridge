# cocotb regression

Python-driven tests for `chi_to_ucie_bridge`, runnable under Icarus or Verilator.

Tests (`test_bridge.py`):
- `test_read_translates` - directed connectivity smoke.
- `test_random_traffic` - randomized read/write stream (80 transactions) with
  backpressure on every handshake and out-of-order UCIe completions. A far-side
  model returns completions keyed only by the bridge-local tag (it never sees
  the CHI TxnID); the scoreboard correlates by the restored TxnID and checks
  read data, write-data payload, completion class, and that nothing is dropped
  or duplicated (`tag_err_cnt`/`crc_err_cnt` stay zero).
- `test_random_errors` - randomized read stream where the far side corrupts a
  fraction of completion checksums; checks that each read still completes with
  `RespErr=DERR` (clean ones `OK`) and that `crc_err_cnt` equals the corrupted
  count.

Both randomized tests carry a functional-coverage model (`CoverGroup`) over
opcode (`rd`/`wr`), completion class (`comp`/`compdata`), checksum
(`good`/`bad`), and `RespErr` (`ok`/`derr`), and fail if any bin is never hit.

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
| cocotb stimulus/scoreboard  | yes (cocotb ≥ 1.9.2)                   | yes                 |

- **Coverage + SVA together (no cocotb):** `make coverage` at the repo root
  compiles `src/chi_to_ucie_bridge_sva.sv` with `--assert --coverage` and writes
  `sim/coverage.info` (includes the SVA cover points).
- **cocotb under Icarus:** default path; Icarus does not support concurrent SVA.
- **cocotb under Verilator:** fully working with cocotb ≥ 1.9.2. cocotb 1.8.x
  did not deliver VPI value-change callbacks with Verilator 5.x, so clocks stalled.
  Upgrade with `pip3.10 install --user "cocotb==1.9.2"` if needed.

## Environment note

The oss-cad-suite shell exports `VIRTUAL_ENV` and puts a stdlib-less `python`
stub first on `PATH`, which misleads cocotb's interpreter detection. The Makefile
pins cocotb to the system Python that actually has it installed
(`COCOTB_PYTHON`, default `/usr/bin/python3.10`) and derives `PYTHONHOME` /
`PYTHONPATH` from it. Override `COCOTB_PYTHON` if your cocotb lives elsewhere.
