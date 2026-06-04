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

- Add cocotb scoreboard and randomized backpressure
- Add interface SVA bindings for all valid/ready channels
- Add functional coverage over opcode/status/checksum combinations
- Raise formal checks from smoke to bounded protocol properties

## Phase 4 - Protocol Refinement

- Replace compact UCIe header model with a closer adapter/flit abstraction
- Add negotiated credit accounting
- Add multi-beat data support
- Define integration hooks for a UCIe PHY/link-training block
