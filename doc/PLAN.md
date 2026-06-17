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

### 4.4 PHY/link-training integration hooks (done)

Replaced the single `link_up` input with a proper PHY interface and added a
4-state link controller:

**New module** `src/phy_link_ctrl.v`:

| State | Encoding | Notes |
|:---|:---|:---|
| `S_WAIT_PHY`  | 2'b00 | waiting for `phy_init_done` |
| `S_ACTIVE`    | 2'b01 | drives `link_up=1` into `reset_drain` |
| `S_ERR_DRAIN` | 2'b10 | error detected; draining outstanding transactions |
| `S_RETRAIN`   | 2'b11 | drain complete; `retrain_req=1` until PHY re-initiates |

Normal bring-up: `S_WAIT_PHY` → `S_ACTIVE` on `phy_init_done`.  
Normal tear-down: `S_ACTIVE` → `S_WAIT_PHY` on `!phy_init_done` (no error).  
Error recovery: `S_ACTIVE` → `S_ERR_DRAIN` on `link_error`, → `S_RETRAIN`
on `drain_done`, → `S_ACTIVE` on `phy_init_done && !link_error`.

**New bridge ports** (`src/chi_to_ucie_bridge.v`):
- `phy_init_done` (input) — replaces `link_up`; synchronized into clk domain
- `link_error` (input) — PHY signals unrecoverable error (clk domain)
- `retrain_req` (output) — bridge requests PHY to retrain
- `link_state[1:0]` (output) — observable FSM state
- `sb_tx_valid` / `sb_tx_data[7:0]` / `sb_tx_ready` — sideband TX
- `sb_rx_valid` / `sb_rx_data[7:0]` / `sb_rx_ready` — sideband RX (always ready)

**Sideband TX**: one pending message per link-state transition. Defined in
`chi_ucie_bridge_defs.vh`: `SB_MSG_LINK_ACTIVE=0xA0`, `SB_MSG_LINK_ERROR=0xE1`,
`SB_MSG_RETRAIN_REQ=0xC2`. Bridge sends one message on each state entry.

**Formal**: new `phy_link_ctrl.sby` target (depth 8) added alongside the three
existing targets; all 4 formal targets pass at depth 8. `phy_link_ctrl` proves:
`link_up` and `retrain_req` are mutually exclusive, `retrain_req` only fires
after passing through `S_ERR_DRAIN`, error in `S_ACTIVE` deasserts `link_up`
next cycle, full error-recovery cycle is reachable.

## Phase 5 - Polish and Protocol Completeness

### 5.1 CI gate validation (done)

`make ci` (regress + formal + synth) passes cleanly on the §4.4 source list.
Synthesis stats: 36 761 cells, 23 551 wires, 432 public wires; no latches.

### 5.2 Coverage closure (done)

Added `test_phy_error` cocotb test (`verification/cocotb/test_bridge.py`).
Strategy: issue 4 reads, wait 40 ucie_clk cycles for req_fifo to drain via
hdr_fire, then inject `link_error=1`.  All FIFOs already empty → `drain_done`
fires in ~2 clk cycles → `phy_link_ctrl` cycles ACTIVE→ERR_DRAIN→RETRAIN in ~5
cycles.  Clearing `link_error` (with `phy_init_done` held high) returns to
ACTIVE; a final `chi_req_ready` acceptance confirms the bridge reopens.

Coverage outcome (merged directed + cocotb, path-normalized):
- `phy_link_ctrl.v:49` (S_ERR_DRAIN case): 2 hits ✓
- `chi_to_ucie_bridge.v:200` (SB_MSG_LINK_ERROR branch): 1 hit ✓
- `chi_to_ucie_bridge.v:202` (SB_MSG_RETRAIN_REQ branch): 1 hit ✓
- `chi_to_ucie_bridge.v:204` (SB_MSG_LINK_ACTIVE branch): 7 hits ✓
- Line 51 (`default` in exhaustive 2-bit case) remains 0 — unreachable dead code.

All 4/4 cocotb tests pass: `make SIM=verilator` in `verification/cocotb/`.
Note: `verilator_coverage --write-info` records cocotb coverage under absolute
paths and directed-sim coverage under relative paths; the merged `.info` file
contains both; path-normalized analysis confirms all target lines are hit.

### 5.3 Sideband protocol handler (done)

Replace the inline sideband TX logic with a standalone `src/sb_msg_handler.v`
module that handles both TX and RX sideband management messages.

**New RX messages** (added to `chi_ucie_bridge_defs.vh`):
- `SB_MSG_PARAM_REQ  = 0xB0` — PHY queries bridge parameters
- `SB_MSG_PARAM_ACK  = 0xB1` — bridge responds: byte = max_outstanding[7:0]
- `SB_MSG_PM_L1_REQ  = 0xD0` — PHY requests power-management L1 entry
- `SB_MSG_PM_L1_ACK  = 0xD1` — bridge acks L1 (after current transactions drain)
- `SB_MSG_PM_L1_EXIT = 0xD2` — PHY signals L1 wake; bridge resumes

**PM flow**: on `SB_MSG_PM_L1_REQ`, the handler asserts `pm_l1_active` which
gates `chi_req_ready` (no new requests accepted).  Once `drain_done` from
`reset_drain` is high (all FIFOs empty), it sends `SB_MSG_PM_L1_ACK`.  On
`SB_MSG_PM_L1_EXIT`, `pm_l1_active` is cleared and the bridge re-opens.

**TX priority**: link-state messages (§4.4) take priority over PARAM_ACK; PM
ack is highest priority because it gates PHY power sequencing.

**New bridge port**: `pm_l1_active` output exposed for system-level monitoring.

**Formal**: new `sb_msg_handler.sby` target proving PM ack only fires after
drain, `pm_l1_active` is mutually exclusive with `bridge_open`, and PARAM_ACK
is sent within one cycle of drain after PARAM_REQ.

### 5.4 QoS field routing and observability (done)

Route the CHI REQ `QoS[3:0]` field end-to-end through the adapter and add
high-priority transaction observability.

- **Header mapping**: `attr[3:0]` in the 128-bit UCIe adapter header (bits
  `[107:104]`) now carries `chi_req[CHI_REQ_QOS_LSB +: 4]` (was zero).
  `CHI_REQ_QOS_LSB = 86` (after `TGTID` at bit 79, width 7).
- **Counter**: `qos_hi_cnt[15:0]` bridge output counts headers issued with
  QoS≥8; reset on link tear-down (`!bridge_open_ucie`); lives in ucie_clk domain.
- **Directed TB**: sends a QoS=0xF read, confirms `ucie_tx_hdr[107:104]==0xF`,
  then waits for `@(posedge ucie_clk); #1` (non-blocking assignment settle)
  and confirms `qos_hi_cnt` incremented by one.
- **cocotb**: `test_random_traffic` randomises QoS 0–15 per transaction and
  checks `attr[3:0]` against the expected value; `CoverGroup("qos_class",
  ["lo","hi"])` confirms both QoS<8 and QoS≥8 paths are hit.
- **SVA** (`chi_to_ucie_bridge_sva.sv`): `a_qos_routed` asserts
  `tx_hdr_valid |-> (tx_hdr[UCIE_ATTR_LSB +: 4] == req_head_qos)` in the
  ucie_clk domain; all 5 formal targets pass at BMC depth 8.

CI outcome: `make ci` passes — 36 881 cells, no inferred latches.

Note: full per-class reorder buffering (reads overtaking writes) is deferred;
this phase guarantees QoS observability and correctness of the priority field
end-to-end without restructuring the single-queue TX path.

## Phase 6 - Flit Protocol Completeness

The Phase 4.3 multi-beat flit implementation handles full-cacheline (64-byte)
transfers correctly but has four gaps against the full CHI protocol:

### 6.1 Variable data-burst length (scaled to CHI `size`) (done)

Currently `tx_dat_beat_ctr` always counts 0–4 (5 flits = 1 header + 4 × 128-bit
data beats = 512 bits). The data-burst header's `length` field is hardcoded to
`8'h40` (64 bytes). For transfers smaller than a full cacheline this is wrong.

**Changes required:**

- Compute `burst_beats = max(1, (1 << chi_size) / 16)` — number of 128-bit data
  beats for the given CHI `size[2:0]` (size=4 → 1 beat, size=5 → 2 beats,
  size=6 → 4 beats). Store `burst_beats-1` (fits in 2 bits for sizes 4–6) in the
  write-data side-queue alongside the existing local tag.
- On TX: replace the `tx_dat_last = (tx_dat_beat_ctr == 3'd4)` constant with a
  comparison against the popped burst-beats value.
- In `translate_chi_data_to_ucie` beat 0: derive `length` from `chi_size`
  (`8'h01 << chi_size`) instead of hardcoding `8'h40`.
- On RX: the data-burst header's `length` field already encodes the byte count;
  derive `rx_burst_beats = length[6:4]` and compare against `rx_dat_beat_ctr`.
  Replace the hardcoded `rx_dat_last = (rx_dat_beat_ctr == 3'd4)`.
- Update `rx_dat_full` assembly: for bursts shorter than 4 data beats, pack from
  `rx_dat_accum` only for the beats that arrived; zero-extend the rest.
- Directed TB: add sub-cacheline write test (size=5, 32 bytes → 2 data beats).
- Formal: add assertion `tx_dat_beat_ctr <= burst_beats` never overruns.

### 6.2 Byte-enable forwarding for partial writes (`WRITENOSNPPTL`) (done)

`CHI_DAT_BE[63:0]` carries a per-byte write-enable mask but the bridge discards
it. On RX completions the bridge reconstructs with `dat[CHI_DAT_BE] = {BE_W{1'b1}}`
(all enables asserted), so a partial write silently becomes a full 64-byte write
at the far-side memory controller.

**Changes required:**

- Carry `CHI_DAT_BE[63:0]` through the `wdat_fifo` (it is already part of
  `CHI_DAT_W`; the FIFO already stores the full CHI DAT flit including BE).
- In `translate_chi_data_to_ucie` beat 0: pack `dat[CHI_DAT_BE_LSB +: BE_W]`
  into reserved bits of the data-burst header (bits [31:16] are currently zero;
  a 64-bit BE does not fit there). Options: (a) carry BE in a new beat-0 payload
  word (requires extending the `UCIE_DATA_W` beat to 256 bits), or (b) add a
  dedicated BE side-channel port alongside `ucie_tx_data`. Simplest for this
  bridge: add `ucie_tx_data_be[63:0]` output valid only on beat 0.
- Update `translate_ucie_data_to_chi` to propagate the recovered BE instead of
  all-ones.
- Directed TB: `WRITENOSNPPTL` with size=5 (32 bytes), BE=`64'h0000_FFFF_FFFF_FFFF`,
  verify correct BE arrives at `chi_wr_data` and is forwarded to UCIe.

### 6.3 Split read-completion handling (`DataID`) — DONE

Two 32-byte MEM_CPL bursts for the same local tag map to two CHI `COMPDATA`
flits. `DataID` is derived from `addr[4]` of the MEM_CPL beat-0 header:
`0 → DataID=0` (lower half, data at `[255:0]`), `1 → DataID=2` (upper half,
data shifted to `[511:256]`).

`txn_table` gained `alloc_is_large` (set for size≥6 reads) and `b_is_large`
output. `rx_cpl_frees_tbl` uses `b_is_large` to distinguish a standalone 32B
completion (size=5 read, `b_is_large=0`) — which must free the table — from the
lower half of a split (size=6 read, `b_is_large=1`) — which must not. The upper
half (`rx_cpl_upper=1`) always frees regardless of `b_is_large`.

### 6.4 Per-flit sequence number in data beats 1–4

`flit_seq_ctr` increments once per flit (counting all `hdr_fire` and
`data_fire` pulses), so the sequence space is per-flit rather than per-burst.
However, beats 1–4 of a data burst carry raw 128-bit data with no embedded
header, so the receiver cannot independently verify their order within a burst.

**Changes required (if spec mandates per-flit sequence in data flits):**

- Widen the data-beat payload from 128 to 144 bits (add a 16-bit metadata field
  carrying `{flit_seq[7:0], 8'h00}`), or use a reserved prefix word.
- Pass `tx_dat_beat_seq` (pre-computed as `dat_flit_seq + beat`) into the data
  flit for beats 1–4.
- RX: strip the metadata before accumulation.
- Alternatively: treat all 5 beats of a burst as a single sequenced unit (use
  the beat-0 header `flit_seq` as the burst sequence number and accept that
  individual data beats are not independently sequenced). Document the choice.
- Formal: assert that `flit_seq` in consecutive issued headers is monotonically
  increasing (mod 256).

## UVM Testbench — verification/uvm/ (complete, requires commercial simulator)

Full UVM-1.2 environment targeting a commercial EDA tool (Xcelium / VCS):

**Components**

| File | Role |
|:---|:---|
| `chi_if.sv` / `ucie_if.sv` | Clocking-block interfaces (drv_cb + mon_cb) |
| `chi_agent/ucie_agent` | Active agents: sequencer + driver + monitor |
| `chi_ucie_scoreboard` | End-to-end tag-tracking and address translation checks |
| `chi_ucie_env` | Creates agents, scoreboard, and `cpl_mbox` mailbox |
| `read_write_test` | Runs randomised CHI read/write mix + reactive UCIe completions |

**Key design decisions**

- **Atomic write drive**: bridge requires `chi_req_valid` and `chi_wr_data_valid`
  simultaneously; `chi_base_seq::send_write` packs both into one item; `chi_driver`
  drives both channels until both ready signals assert.
- **Reactive completions via mailbox**: scoreboard fills `cpl_mbox` (AD_CPL for
  writes, MEM_CPL for reads) on each observed UCIe TX_HDR; `ucie_completion_seq`
  pops and drives completions with a 20 ns turn-around.
- **CRC16 in `pack_hdr`**: `ucie_item::pack_hdr()` computes and inserts the XOR
  CRC16 field so the bridge accepts all RX completions without marking DERR.
- **Credit return**: `ucie_driver` pulses `rx_hdr_crdt` (and `rx_dat_crdt` for
  AD_CPL) for one cycle after each accepted completion to prevent TX stalls.
