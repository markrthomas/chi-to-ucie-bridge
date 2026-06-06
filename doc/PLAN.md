# CHI to UCIe Bridge Plan

## Phase 1 - Bring-up RTL

- Structured CHI REQ/RSP/DAT field model
- UCIe 64-bit adapter header plus 512-bit data packet model
- Dual-clock async FIFOs for host/link CDC
- Link-up gating and drain status
- Directed read/write/completion smoke test

## Phase 2 - Transaction Tracking

Goal: stop passing CHI `TxnID` straight through to the UCIe tag. Allocate a
bridge-local tag per outstanding request, remember the original CHI identity,
and restore it when the completion returns. This removes the Phase 1 shortcut
(`design-spec.md`: "CHI `TxnID` is carried directly as the UCIe tag") and is the
prerequisite for negotiated credits and multi-beat data in Phase 4.

### 2.1 Outstanding transaction table (`src/txn_table.v`)

Single-clock module living entirely in the `ucie_clk` domain, because both
events that touch it occur there:

- **Allocate** on UCIe header issue (`ucie_tx_hdr_valid && ucie_tx_hdr_ready`).
- **Free + look up** on completion arrival (`rx_hdr_fire`, `rx_dat_fire`).

No new clock-domain crossing is introduced.

Storage: `N = MAX_OUTSTANDING` (default 32) entries of `{txnid, srcid, is_write}`,
plus a `valid` bit-vector acting as the free-list. Local tag width
`LTAG_W = $clog2(N)`, zero-extended into the 8-bit UCIe tag field.

Ports:

| Group | Signals | Notes |
|:---|:---|:---|
| Allocate | `alloc_en`, `alloc_txnid`, `alloc_srcid`, `alloc_is_write` -> `alloc_tag` (comb lowest-free), `full` | `full` back-pressures header issue |
| Completion A (AD_CPL) | `a_lookup_tag` -> `a_txnid`/`a_srcid`/`a_is_write`/`a_valid` (comb), `a_free_en` | write/req completion path |
| Completion B (MEM_CPL) | `b_lookup_tag` -> `b_txnid`/`b_srcid`/`b_is_write`/`b_valid` (comb), `b_free_en` | read-data completion path |
| Observe | `outstanding`, `tag_err` | `tag_err` pulses on free of an unallocated tag |

Two independent free ports are required because the AD_CPL header channel and
the MEM_CPL data channel can both retire a transaction in the same `ucie_clk`
cycle. One allocate port suffices (at most one header issues per cycle).

Per-entry next-state: `valid[i] <= (valid[i] | set_i) & ~clr_i`, where `set_i`
is this cycle's allocation and `clr_i` is either free port targeting `i`. The
priority encoder reads pre-update `valid`, so a slot being freed this cycle is
not re-allocated until next cycle (conservative, never aliases).

### 2.2 Bridge wiring (`src/chi_to_ucie_bridge.v`)

- Header issue: substitute `alloc_tag` into the UCIe tag field instead of the
  CHI `TxnID`. Gate `ucie_tx_hdr_valid` with `!full`.
- Write-data tag side-queue (`wtag_q`): on a *write* header issue, push
  `alloc_tag`; `ucie_tx_data_valid` is additionally gated on `!wtag_q_empty`
  and the data packet's tag is `wtag_q` front, popped on data issue. This both
  supplies the data its request's local tag and enforces header-before-data
  ordering (data can never outrun its header on the independent ready paths).
- RX rsp (AD_CPL): look up `a_*` by the returned tag; restore CHI `TxnID`/`SrcID`
  from the table entry rather than from the wire tag; free on accept.
- RX data (MEM_CPL): look up `b_*`; restore CHI `TxnID`; free on accept.
- Completion to an unallocated tag: `*_valid==0`. Mark CHI `RespErr` and do not
  free; surface via new `tag_err_cnt` output (mirrors `crc_err_cnt`).

### 2.3 DBID-style write data sequencing / completion ordering

The side-queue gives in-order request->data binding per the write stream. The
`is_write` bit lets a checker confirm AD_CPL retires writes and MEM_CPL retires
reads. Full per-class reorder buffering is deferred; this phase guarantees no
tag aliasing while outstanding and correct identity restoration.

### 2.4 Verification

- Directed tb: capture the *issued* local tag off `ucie_tx_hdr`/`ucie_tx_data`,
  feed completions back with that tag, and assert the restored CHI `TxnID`
  equals the original request `TxnID`. Add a case where two requests reuse the
  same CHI `TxnID` and confirm distinct local tags are allocated.
- Formal (`verification/formal`): bounded properties - allocated tags are unique
  while valid, free only occurs on a valid tag, `outstanding` never exceeds `N`,
  and a freed tag's identity matches what was allocated.

### 2.5 Interface / doc changes

- New outputs: `tag_err_cnt[15:0]`. Update `tb` instantiation and `chk` if bound.
- `design-spec.md`: replace the direct-`TxnID` note with the local-tag scheme and
  add `txn_table` to the module list.

## Phase 3 - Verification Expansion

Goal: move beyond the directed smoke to assertion-based and coverage-driven
verification, and stand up a cocotb stimulus environment.

### 3.1 Toolchain enablement (done)

- **SVA**: `src/chi_to_ucie_bridge_sva.sv` holds concurrent assertions + cover
  points, attached by `bind`, guarded by `BRIDGE_SVA`. Active under Verilator
  `--assert` (Icarus' concurrent-assertion support is too limited, so the file
  is Verilator/formal-only).
- **Coverage + SVA in one flow**: `make coverage` compiles the SVA module with
  `--coverage --assert` and writes `sim/coverage.info` (line/toggle/user,
  including the SVA cover points).
- **cocotb**: `verification/cocotb/` runs under Icarus today (`make`). The
  Verilator path (`make SIM=verilator`) is wired for `--assert --coverage` but
  is blocked by a Verilator-5.047-devel / cocotb-1.8.1 value-change-callback
  mismatch; see `verification/cocotb/README.md`.

Current SVA properties: issued TX header/data checksums valid; TX header valid
persists and payload (incl. local tag) stays stable while stalled; write data
never precedes its header; CHI completion outputs (RSP, CompData) hold valid and
stable payload until the consumer accepts them.

### 3.2 cocotb scoreboard + randomized backpressure (done)

`verification/cocotb/test_bridge.py::test_random_traffic`: a far-side UCIe model
captures each issued local tag and returns completions out of order, with
randomized ready on every handshake. The scoreboard correlates CHI completions
by the restored TxnID (the model never sees the original TxnID), checking read
data, write-data payload, completion class, and exactly-once delivery
(`tag_err_cnt`/`crc_err_cnt` stay zero). Runs under Icarus today.

### 3.3 Randomized error injection (done)

`test_random_errors`: a randomized read stream where the far side corrupts a
fraction of MEM_CPL header checksums. The scoreboard confirms every read still
completes (tag freed), corrupted ones carry CHI `RespErr=DERR`, clean ones
`OK`, and `crc_err_cnt` exactly equals the number of corrupted completions
delivered (`tag_err_cnt` stays zero).

### 3.4 Functional coverage (done)

Coverage is collected as a Python model in the cocotb tests (works under the
Icarus flow that the randomized stimulus runs on) with a pass/fail goal that
every bin is exercised:
- `test_random_traffic`: `tx_opcode{rd,wr}`, `cpl_class{comp,compdata}`.
- `test_random_errors`: `rx_checksum{good,bad}`, `read_resperr{ok,derr}`.

The Verilator `cover property` points (in the SVA module) remain the
assertion-engine path; they are exercised once the cocotb-on-Verilator issue
below is resolved.

### 3.5 Bridge formal: bounded protocol invariants (done)

The bridge top proof is no longer a vacuous smoke. An `ifdef FORMAL` block adds
bounded, single-domain invariants on the UCIe TX path (ucie_clk): every
presented header (request and write-data) carries a correct checksum, and write
data is never offered before its request header (`!tx_data_valid || !wq_empty`).
These are CDC-independent so they prove without extra reachability constraints,
alongside the existing `txn_table` allocation proof.

### 3.6 cocotb-on-Verilator resolved (done)

Upgrading cocotb from 1.8.1 to 1.9.2 (for the pinned `/usr/bin/python3.10`
interpreter) resolved the VPI value-change callback incompatibility with
Verilator 5.047-devel. All three randomized cocotb tests (`test_read_translates`,
`test_random_traffic`, `test_random_errors`) now pass under `make SIM=verilator`
with `--assert` (SVA) and `--coverage` active, alongside the Icarus path.

### 3.7 Unified coverage report (done)

`make coverage-all` merges the directed-sim `sim/obj_dir_cov/coverage.dat` with
the cocotb/Verilator `verification/cocotb/coverage.dat` into
`sim/coverage_merged.info` using `verilator_coverage --write-info`. The target
depends on `coverage` so the directed-sim run is always fresh. The merge adds
`chi_ucie_bridge_defs.vh` at 100% line coverage (function bodies exercised only
under cocotb randomized stimulus).

### 3.8 Async-FIFO CDC formal + temporal handshake invariants (done)

The async-FIFO `ifdef FORMAL` block now carries three layers of reachability
constraints that let the SMT solver start from physically possible states:

1. **Gray-code consistency** — each pointer's Gray code matches its binary value.
2. **Fill-level bounds** — apparent fill from either domain stays in `[0, DEPTH]`.
3. **Sync-chain monotonicity** — the intermediate sync stage is never ahead of
   the output stage (pointer only advances).
4. **Cross-domain fill ordering** (new) — the read side's apparent fill cannot
   exceed the write side's actual fill.  This cross-domain assume rules out the
   class of spurious initial states where the synced write pointer shows more
   items than actually exist (impossible because the sync chain only lags, never
   leads the actual pointer).

With those constraints in place the bridge's `ifdef FORMAL` block was extended
with `$past()`-based temporal assertions (yosys-compatible form of the SVA
`|=>` properties):

- **UCIe TX header persistence** — a stalled valid header stays valid until
  accepted or the link closes (`$past(ucie_rst_n)` guard mirrors SVA
  `disable iff (!rst_n)` semantics over the two-cycle window).
- **UCIe TX header stability** — a stalled header's payload (including the local
  tag) does not change while the handshake is unresolved.
- **CHI completion persistence and stability** — both RSP and CompData outputs
  hold valid and stable payload until the CHI consumer accepts them.

All three SymbiYosys targets (`reset_drain`, `txn_table`, `chi_to_ucie_bridge`)
pass at BMC depth 8.  The `chi_to_ucie_bridge_sva.sv` module was updated to use
explicit `@(posedge clk) disable iff (…)` on every property (removing
`default clocking` and `default disable iff`) so the same file compiles cleanly
under both Verilator `--assert` and a future yosys SVA flow.

### Resolved (found via SVA review)

Previously, while `ucie_tx_hdr_valid` was stalled (`!ready`), the local tag in
the header could change if a completion freed a lower-indexed slot, because the
presented tag tracked the lowest free slot combinationally — a valid/ready
payload-stability violation. Fixed: the bridge latches the chosen tag
(`held_tag`) when a header is first offered and reuses it until acceptance, and
`txn_table` now allocates that caller-chosen index. The SVA property
`a_tx_hdr_stable` guards against regression.

## Phase 4 - Protocol Refinement

### 4.1 Negotiated credit accounting (done)

Replaced the placeholder `POSTED_CREDITS`/`NP_CREDITS` parameters with runtime
credit counters on the UCIe TX path:

- **Parameters**: `TX_HDR_CREDITS` (default 8) and `TX_DAT_CREDITS` (default 8)
  gate how many in-flight header and data packets the bridge may have outstanding
  toward the far end at any instant.
- **New ports**: `ucie_rx_hdr_crdt` / `ucie_rx_dat_crdt` (inputs, far end returns
  a credit) and `ucie_tx_hdr_crdt` / `ucie_tx_dat_crdt` (outputs, bridge grants
  a completion slot back to the far end on each `rx_hdr_fire` / `rx_dat_fire`).
- **Credit counters** (`credit_counter` module, existing): one per TX direction,
  both in the `ucie_clk` domain; `consume` fires on `hdr_fire`/`data_fire`,
  `ret` wired to the far-end return port.  `available` gates `ucie_tx_hdr_valid`
  and `ucie_tx_data_valid` respectively.
- **cocotb credit model**: `rx_hdr_driver` (write completions) returns 1 header +
  1 data credit per accepted AD_CPL; `rx_data_driver` (read completions) returns 1
  header credit per accepted MEM_CPL.  Dedicated `hdr_crdt_returner` /
  `dat_crdt_returner` coroutines pulse the credit inputs at 1-per-cycle rate.
- All three sby formal targets still pass at depth 8; the persistence assertion
  remains sound because credits never change during a stall (`hdr_fire = 0` while
  `!ucie_tx_hdr_ready`).

### 4.2 128-bit UCIe adapter header with full address and flit sequencing (done)

Replaced the compact 64-bit header model with a 128-bit adapter header:

| Field | Bits | Width | Notes |
|:---|:---|:---|:---|
| kind | [127:124] | 4b | packet type (unchanged values) |
| code | [123:120] | 4b | opcode / status |
| tag | [119:112] | 8b | local tag |
| attr | [111:104] | 8b | MemAttr / Order |
| length | [103:96] | 8b | transfer size |
| src_id | [95:88] | 8b | requester node ID |
| flit_seq | [87:80] | 8b | TX flit sequence counter (wraps mod 256) |
| addr | [79:32] | 48b | **full 48-bit address** (was 16-bit truncated) |
| reserved | [31:16] | 16b | — |
| crc16 | [15:0] | 16b | XOR of seven 16-bit slices [127:16] |

Key improvements: (1) `addr` now carries all 48 CHI address bits end-to-end
instead of the low 16; the directed testbench now checks the full address.
(2) 16-bit XOR integrity field replaces the old 8-bit XOR.
(3) `flit_seq` counter (increments on each `hdr_fire`/`data_fire`) is wired
up in the bridge and piped through all translation functions, ready for §4.3
sequencing assertions.  `UCIE_DATA_W` widened from 577 to 641 bits accordingly.

All directed sim, lint, cocotb (3/3), and sby formal (3/3 at depth 8) pass.

### 4.3 Multi-beat data support (done)

Implemented multi-beat data protocol (§4.3): 512-bit data bursts are split into
a 5-beat sequence on the data channel (ucie_tx_data / ucie_rx_data).
- Beat 0: 128-bit adapter header (kind=AD_REQ/MEM_CPL, code=WR_DATA/RD_DATA).
- Beat 1..4: 128-bit data payload flits (pure data).
- Poison bit is carried in the Beat 0 header (attr[7]).
- Beat counters (tx_dat_beat_ctr, rx_dat_beat_ctr) track burst progress.
- Credit accounting updated to be per-burst (packet) rather than per-flit.
- Stability latches added for flit_seq_ctr to ensure stalled headers remain valid.
- cocotb and formal verification updated to match the new protocol.

### 4.4 integration hooks for a UCIe PHY/link-training block (planned)
