# CHI to UCIe Bridge — Tutorial

This tutorial walks through the bridge from first clone to understanding a
complete transaction. It covers running the test suite, reading coverage output,
and tracing a read request through the RTL.

## Prerequisites

| Tool | Version tested | Purpose |
|:---|:---|:---|
| Icarus Verilog (`iverilog`) | ≥ 11 | Directed simulation |
| Verilator | 5.047 | Coverage + SVA + cocotb back-end |
| Python 3.10 | 3.10.x | cocotb test runner |
| cocotb | 1.9.2 | Python-driven RTL tests |
| SymbiYosys (`sby`) + yosys-smtbmc | any recent | Formal verification |
| Yosys | any recent | Synthesis smoke |
| GTKWave | any | Waveform viewer (optional) |

Install cocotb for the system Python 3.10 if it is not already present:

```bash
pip3.10 install --user "cocotb==1.9.2"
```

If you use oss-cad-suite, its bundled Python stub can confuse cocotb's
interpreter detection. The Makefile in `verification/cocotb/` already pins
`COCOTB_PYTHON=/usr/bin/python3.10`; override that variable if your cocotb is
elsewhere.

## Step 1: First run

The quickest sanity check is the directed testbench under Icarus:

```bash
make regress
```

This runs Verilator lint followed by the Icarus directed simulation. Expected
output ends with:

```
[REGRESS] lint + directed sim PASSED
```

If you see lint warnings about width mismatches, those are suppressed in the
Makefile (`-Wno-WIDTH`). Any `ERROR:` line from the testbench is a real failure.

## Step 2: Running the cocotb test suite

The 16-test cocotb suite runs under either Icarus or Verilator.

```bash
cd verification/cocotb

# Icarus (fast, no coverage or SVA)
make

# Verilator (coverage + SVA + coverage.dat written for make coverage-all)
make SIM=verilator
```

Successful completion looks like:

```
TESTS=16 PASS=16 FAIL=0 SKIP=0
```

Each test prints a one-line summary. The most informative test is
`test_random_traffic`: it drives 80 randomized read/write transactions with
backpressure on every handshake and out-of-order completions returned by a
Python far-side model. The scoreboard checks that every CHI completion arrives
exactly once with the right data and `RespErr=OK`.

## Step 3: Waveforms

To capture a VCD and view it:

```bash
make vcd        # Icarus: verification/directed/build/waves.vcd
make gtkwave    # same + opens GTKWave

make vlt-vcd    # Verilator trace: sim/obj_dir_vcd/waves.vcd
make vlt-gtkwave
```

Useful signals to add in GTKWave:

- `clk`, `ucie_clk`, `rst_n`
- `chi_req_valid`, `chi_req_ready`, `chi_req_data[CHI_REQ_W-1:0]`
- `ucie_tx_hdr_valid`, `ucie_tx_hdr_ready`, `ucie_tx_hdr[127:0]`
- `ucie_rx_hdr_valid`, `ucie_rx_hdr_ready`, `ucie_rx_hdr[127:0]`
- `chi_rsp_valid`, `chi_rsp_ready`, `chi_rsp_data[CHI_RSP_W-1:0]`
- `bridge_open`, `bridge_open_ucie`, `link_state[1:0]`

## Step 4: Coverage

```bash
# Directed-sim coverage only
make coverage
# Report is sim/coverage.info; annotated sources in sim/obj_dir_cov/annotated/

# Merged coverage (directed sim + cocotb; run step 2 with Verilator first)
make coverage-all
# Merged report: sim/coverage_merged.info
```

Annotated source files show a hit count before each covered line and `%000000`
before lines with zero hits. Lines marked `%000000` in the merged report are
either dead code or Verilator instrumentation gaps — see the Design Spec for the
full classification of the 5 remaining misses.

> **Note on duplicate SF: blocks**: `verilator_coverage --write-info` records
> directed-sim paths as relative (`src/foo.v`) and cocotb paths as absolute
> (`/home/.../src/foo.v`). The merged `.info` file therefore contains two `SF:`
> blocks per file. The `--annotate` tool uses only the last block, making
> the directed-sim coverage appear missing. The true figure (99.2%) requires
> summing `DA:` counts across both blocks per normalized path.

## Step 5: Formal verification

```bash
make formal
```

This runs five SymbiYosys BMC targets in `verification/formal/`. Each target
writes pass/fail output to its own subdirectory. All five should show
`PASS [BMC]` at the configured depth.

If a property fails, the solver writes a `*.vcd` counterexample. Open it with
GTKWave to see the failing trace. Each `.sby` file lists the RTL sources and
the properties that are checked.

## Step 6: Full CI gate

```bash
make ci   # regress + formal + synthesis
```

This is the definitive pass/fail gate. It requires Icarus, Verilator, Yosys,
and SymbiYosys to all be on `PATH`. The synthesis step checks for inferred
latches (should be zero) and prints cell statistics (~38 828 cells).

---

## Transaction walk-through: CHI read request

This section traces a single `ReadNoSnp` from the CHI input to a CHI
`CompData` response, following the code in `src/chi_to_ucie_bridge.v`.

### 1. CHI REQ accepted into the request FIFO

When `chi_req_valid=1`, `chi_req_ready=1`, and the bridge is open
(`bridge_open=1`), the REQ flit is written into `u_req_fifo` (CHI `clk` domain,
write side). `chi_req_ready` is deasserted when `req_w_full=1` (FIFO full) or
the bridge is closed.

The REQ flit is a packed struct containing (among others): `TxnID`, `SrcID`,
`Addr[47:0]`, `Opcode`, `Size[2:0]`, `QoS[3:0]`.

### 2. Tag allocation and UCIe TX header assembly

On the `ucie_clk` side, once `u_req_fifo` has an entry (`!req_r_empty`) and the
bridge is open (`bridge_open_ucie=1`) and a TX header credit is available
(`hdr_crdt_avail=1`) and `txn_table` is not full, the bridge:

1. Reads the REQ flit from `u_req_fifo` (combinationally, FWFT).
2. Calls `alloc_en=1` on `txn_table`; receives `alloc_tag` (the lowest free
   local tag index). The chosen tag is latched into `held_tag` on the first
   offer cycle so it stays stable while stalled.
3. Calls `translate_chi_req_to_ucie` (defined in `chi_ucie_bridge_defs.vh`) to
   pack the 128-bit TX header:
   - `kind = AD_REQ`
   - `code = MEM_RD`
   - `tag = held_tag`
   - `attr[3:0] = chi_req_data[CHI_REQ_QOS_LSB +: 4]` (QoS)
   - `length = 1 << chi_size`
   - `src_id = chi_req_data[CHI_REQ_SRCID_LSB +: 8]`
   - `flit_seq = flit_seq_ctr` (wrapping counter)
   - `addr = chi_req_data[CHI_REQ_ADDR_LSB +: 48]`
   - `crc16 = XOR of [127:16]`
4. Presents the header on `ucie_tx_hdr` with `ucie_tx_hdr_valid=1`.

### 3. UCIe TX header handshake

When `ucie_tx_hdr_ready=1` from the far end (simulated in the testbench or
cocotb model), `hdr_fire=1`:
- `flit_seq_ctr` increments.
- `txn_table` commits the allocation for this tag.
- `u_req_fifo` is popped.

### 4. UCIe completion arrives (MEM_CPL)

The far end returns a read completion on `ucie_rx_hdr` with:
- `kind = MEM_CPL`, `code = SC`
- `tag` = the bridge-local tag issued in step 2
- `addr[4]` = 0 or 1 (determines DataID for split completions)
- `crc16` = correct checksum

When `ucie_rx_hdr_valid=1` and `ucie_rx_hdr_ready=1` (bridge has space in
`u_rsp_fifo`):
- The bridge computes CRC16 and compares; mismatch sets `RespErr=DERR` and
  pulses `crc_err_cnt`.
- `txn_table` looks up the tag via the `b_*` port; `b_txnid` and `b_srcid`
  restore the original CHI identity. If `b_valid=0` (unknown tag),
  `tag_err_cnt` is pulsed.
- For size≥6 (large) reads the lower-half completion does not free the table;
  the upper-half always frees.

### 5. Multi-beat RX data

Read-completion data arrives on `ucie_rx_data` in N+1 beats. Beat 0 is the
burst header (`kind=MEM_CPL`, `code=RD_DATA`); beats 1–N are 128-bit payload.
`rx_dat_beat_ctr` counts 0…N; `rx_dat_last = (rx_dat_beat_ctr == burst_beats)`.

The data is accumulated in `rx_dat_accum` across beats 1…N-1; on the last beat,
`rx_dat_full` assembles the full data word from `{ucie_rx_data, rx_dat_accum[...]}`.

### 6. CHI CompData response

On the `clk` side, once `u_rdat_fifo` has an entry and `chi_comp_data_ready=1`,
the bridge presents a CHI DAT flit with:
- `Opcode = CompData`
- `TxnID` = restored from `txn_table`
- `SrcID` = restored from `txn_table`
- `DataID` = derived from `addr[4]`
- `Data[511:0]` = assembled 512-bit payload
- `Poison` = `attr[7]` from the MEM_CPL beat-0 header

---

## Transaction walk-through: CHI write request

### 1–2. REQ accepted; WDAT accepted

A write request (`WriteNoSnpFull`, etc.) is accepted into `u_req_fifo` as above.
Simultaneously (same valid cycle), the write data flit is accepted into
`u_wdat_fifo` if `wdat_w_full=0`. Both `chi_req_ready` and `chi_wr_data_ready`
must be asserted in the same cycle (the cocotb and directed testbench both drive
them simultaneously).

### 3. TX request header and data burst

On the `ucie_clk` side:
- The request header fires first (same as the read path; `code=MEM_WR`).
- On header fire, `alloc_tag` is also pushed into the write-tag side-queue
  (`wtag_q`).
- `ucie_tx_data_valid` is gated on `!wdat_r_empty && !wq_empty && dat_crdt_avail`.
  Once all conditions are met, the data burst starts.
- Beat 0: `translate_chi_data_to_ucie` packs a 128-bit data-burst header
  (`kind=AD_REQ`, `code=WR_DATA`); `tag` comes from the front of `wtag_q`;
  `attr[7]` carries the CHI `Poison` flag; `length = 1 << chi_size`.
  The write data is popped from `u_wdat_fifo` on beat 0.
- Beats 1–N: 128-bit data slices from the CHI DAT payload.
- On the last beat (`tx_dat_last`), `wtag_q` is popped.

### 4. Write completion

The far end returns `AD_CPL / SC` on `ucie_rx_hdr`. The bridge looks up the
tag via the `a_*` port, restores `TxnID`/`SrcID`, and pushes a CHI RSP flit
into `u_rsp_fifo`. On the `clk` side this appears as a `Comp` response.

---

## Writing a new cocotb test

All tests live in `verification/cocotb/test_bridge.py`. The actual helper
functions defined there are:

| Helper | Purpose |
|:---|:---|
| `reset_and_open(dut)` | Full reset sequence + assert `phy_init_done`; waits for bridge to open |
| `make_chi_read(txnid, addr, srcid, size, qos)` | Packs a CHI REQ flit for a read |
| `make_chi_write_req(txnid, addr, srcid, size, qos)` | Packs a CHI REQ flit for a write |
| `make_chi_write_data(txnid, data)` | Packs a CHI DAT flit |
| `pack_ucie_hdr(kind, code, tag, ...)` | Packs a 128-bit UCIe adapter header with CRC16 |
| `pack_mem_cpl_burst(tag, data, poison, size, addr48)` | Packs a full MEM_CPL burst (header + data beats) |
| `_send_rx_hdr(dut, hdr, timeout)` | Drives one RX header and waits for `ucie_rx_hdr_ready` |
| `_send_rx_data_burst(dut, flits)` | Drives a list of 128-bit data flits on `ucie_rx_data` |

The typical pattern:

```python
@cocotb.test(timeout_time=50, timeout_unit="us")
async def test_my_feature(dut):
    await reset_and_open(dut)

    # issue a read
    txnid = 0x7
    dut.chi_req_data.value = make_chi_read(txnid, addr=0x1000)
    dut.chi_req_valid.value = 1
    for _ in range(100):
        await RisingEdge(dut.clk)
        if dut.chi_req_ready.value == 1:
            break
    dut.chi_req_valid.value = 0

    # wait for UCIe TX header; capture bridge-local tag
    for _ in range(50):
        await RisingEdge(dut.ucie_clk)
        if dut.ucie_tx_hdr_valid.value == 1:
            break
    ltag = int(dut.ucie_tx_hdr.value >> 112) & 0xFF   # bits [119:112]

    # return a MEM_CPL completion with known data
    data = b"\xAB" * 64
    flits = pack_mem_cpl_burst(ltag, data, addr48=0x1000)
    await _send_rx_hdr(dut, flits[0])
    await _send_rx_data_burst(dut, flits[1:])

    # check CHI CompData
    for _ in range(50):
        await RisingEdge(dut.clk)
        if dut.chi_comp_data_valid.value == 1:
            break
    assert dut.chi_comp_data_valid.value == 1, "no CompData"
```

The `CoverGroup` class provides a lightweight Python functional coverage model
— add bins for any new feature you want to confirm is exercised:

```python
cov = CoverGroup("my_feature", ["path_a", "path_b"])
# ... in the test loop ...
cov.hit("path_a")
assert not cov.uncovered(), f"coverage gaps: {cov.uncovered()}"
```

Run your new test in isolation:

```bash
cd verification/cocotb
make SIM=verilator TESTCASE=test_my_feature
```

or under Icarus for a faster iteration cycle:

```bash
make TESTCASE=test_my_feature
```

## Common issues

| Symptom | Likely cause | Fix |
|:---|:---|:---|
| `chi_req_ready` never asserts | Bridge not open | Check `phy_init_done` is driven; wait for `bridge_open` |
| `ucie_tx_hdr_valid` never asserts | No header credits, or `txn_table` full | Check `ucie_rx_hdr_crdt` is being returned after each accepted header |
| `ucie_tx_data_valid` never asserts | No data credits, or write-data FIFO empty, or `wtag_q` empty | Check `ucie_rx_dat_crdt` is being returned; verify write fired before querying data |
| `chi_rsp_valid` never asserts | RSP FIFO empty | Check that `ucie_rx_hdr` was accepted (`ucie_rx_hdr_ready=1`) |
| `crc_err_cnt` increments | Bad CRC16 in RX header | Recompute CRC16 with `XOR of hdr[127:16]` in 16-bit slices |
| `tag_err_cnt` increments | Completion uses a tag not in `txn_table` | Verify you captured `held_tag` off `ucie_tx_hdr[119:112]` at fire time |
| cocotb clocks stall | cocotb < 1.9.2 with Verilator 5.x | `pip3.10 install --user "cocotb==1.9.2"` |
