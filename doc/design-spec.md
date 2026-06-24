# CHI to UCIe Bridge Design Spec

## Scope

This repo models an RTL bridge from a compact AMBA CHI RN-side interface to a
compact UCIe adapter interface. It exercises translation, clock-domain crossing,
link gating, credit-based flow control, QoS routing, and verification
infrastructure. The protocol model is compact and intended for bring-up, not a
bit-exact CHI or UCIe specification implementation.

## Clocks and Reset

| Domain | Clock | Interfaces |
|:---|:---|:---|
| CHI host | `clk` (10 ns) | `chi_req_data`, `chi_wr_data`, `chi_rsp_data`, `chi_comp_data`, PHY control inputs |
| UCIe adapter | `ucie_clk` (6 ns) | `ucie_tx_hdr`, `ucie_tx_data`, `ucie_rx_hdr`, `ucie_rx_data`, credits, sideband |

`rst_n` is synchronized independently into both domains via `reset_sync`.
`link_up` (from `phy_link_ctrl`) is synchronized into the CHI domain; the
bridge-open state is re-synchronized into the UCIe domain by `reset_drain`.

## Translation

### CHI requests → UCIe TX

| CHI opcode | UCIe TX header | UCIe TX data |
|:---|:---|:---|
| `ReadNoSnp`, `ReadOnce` | `AD_REQ / MEM_RD`; `length = 1 << chi_size` | — (no data) |
| `WriteNoSnpFull`, `WriteNoSnpPtl`, `WriteUniqueFull` | `AD_REQ / MEM_WR`; `length = 1 << chi_size` | Multi-beat: beat 0 = data-burst header, beats 1–N = 128-bit payload |

QoS: `chi_req_data[CHI_REQ_QOS_LSB +: 4]` is copied into `attr[3:0]` of the TX header.
Byte enables: the 64-bit CHI DAT BE field is carried through the write-data FIFO
and output on `ucie_tx_data_be[63:0]` (valid on beat 0 of a write burst).
Address: all 48 CHI address bits are carried in `addr[47:0]` of the TX header.

### UCIe RX → CHI responses

| UCIe RX | CHI output |
|:---|:---|
| `AD_CPL / SC` | `RSP / Comp` — CHI `TxnID` and `SrcID` restored from `txn_table` |
| `MEM_CPL / SC` with data | `DAT / CompData` — `DataID` from `addr[4]` of RX header |
| Bad CRC16, unknown tag, unsupported opcode | `RSP` or `DAT` with `RespErr = DERR`; `crc_err_cnt` or `tag_err_cnt` incremented |
| Poison bit set (`attr[7]`) | CHI DAT `Poison` bit set |

Split read completions: for size≥6 reads, two 32-byte MEM_CPL bursts arrive for
the same local tag. `txn_table` tracks `alloc_is_large`; the lower half
(`addr[4]=0`, DataID=0) does not free the table entry; the upper half
(`addr[4]=1`, DataID=2) always frees.

## 128-bit Adapter Header

All UCIe adapter headers are 128 bits wide.

| Field | Bits | Width | Notes |
|:---|:---|:---|:---|
| `kind` | [127:124] | 4b | Packet type |
| `code` | [123:120] | 4b | Opcode / status |
| `tag` | [119:112] | 8b | Bridge-local tag (not CHI TxnID) |
| `attr` | [111:104] | 8b | MemAttr / Order; `attr[3:0]` = QoS, `attr[7]` = poison |
| `length` | [103:96] | 8b | Transfer size: `1 << chi_size` |
| `src_id` | [95:88] | 8b | CHI node ID |
| `flit_seq` | [87:80] | 8b | TX flit sequence counter, wraps mod 256 |
| `addr` | [79:32] | 48b | Full 48-bit physical address |
| `reserved` | [31:16] | 16b | — |
| `crc16` | [15:0] | 16b | XOR of seven 16-bit slices [127:16] |

`flit_seq` increments on each request header fire and on each data-burst beat-0
fire. Consecutive request headers (with no intervening burst) differ by exactly
1 (mod 256); a burst header is exactly `req_seq + 1` when both fire in the
same cycle.

## Multi-Beat Data Protocol

512-bit transfers use a 5-beat sequence on the data channel (`UCIE_DATA_W=128`):

| Beat | Content |
|:---|:---|
| 0 | 128-bit adapter header (`kind=AD_REQ`/`MEM_CPL`, `code=WR_DATA`/`RD_DATA`) |
| 1 | data[127:0] |
| 2 | data[255:128] |
| 3 | data[383:256] |
| 4 | data[511:384] (for size=6 only) |

The number of data beats N depends on `chi_size`:

| `chi_size` | Bytes | Data beats (N) |
|:---|:---|:---|
| 4 | 16 | 1 |
| 5 | 32 | 2 |
| 6 | 64 | 4 |

Beat counters (`tx_dat_beat_ctr`, `rx_dat_beat_ctr`) track burst progress;
credits are consumed per burst (on beat 0), not per flit.

## Transaction Tracking

Each request issued to UCIe is assigned a bridge-local tag from `txn_table`
(`MAX_OUTSTANDING` entries, default 32, in the `ucie_clk` domain). The table
records `{TxnID, SrcID, is_write, is_large}` keyed by the local tag. When a
completion returns, the local tag is looked up to restore the original CHI
identity, and the entry is freed. Back-pressure: `full` from `txn_table` gates
`ucie_tx_hdr_valid`.

The tag is chosen combinationally (lowest free slot) but latched into `held_tag`
when first offered so it remains stable while stalled. `txn_table.alloc_tag`
accepts the caller-chosen index, eliminating the aliasing hazard.

A write's local tag is carried from header issue to data issue by an in-order
side-queue (`wtag_q`), which also ensures write-data cannot outrun its request
header.

A completion referencing an unallocated tag sets CHI `RespErr = DERR` and pulses
`tag_err_cnt` without freeing anything.

## Flow Control

### TX header credits

`credit_counter #(.CREDITS(TX_HDR_CREDITS))` in the `ucie_clk` domain.
- Consumed on `ucie_tx_hdr_fire`.
- Returned via `ucie_rx_hdr_crdt` (pulsed by the far end).
- `available` gates `ucie_tx_hdr_valid`.

### TX data credits

`credit_counter #(.CREDITS(TX_DAT_CREDITS))` in the `ucie_clk` domain.
- Consumed on `data_fire && tx_dat_beat_ctr == 0` (once per burst).
- Returned via `ucie_rx_dat_crdt`.
- `available` gates `ucie_tx_data_valid`.

### RX completion flow

The bridge grants one header credit back (`ucie_tx_hdr_crdt`) per accepted
`rx_hdr_fire` and one data credit back (`ucie_tx_dat_crdt`) per accepted
`rx_dat_fire`.

## FIFOs

All FIFOs are dual-clock first-word-fall-through with Gray-code pointer
synchronization (`async_fifo`).

| FIFO | Write domain | Read domain | Payload | Depth |
|:---|:---|:---|:---|:---|
| `u_req_fifo` | `clk` | `ucie_clk` | CHI REQ flit | `REQ_FIFO_DEPTH` |
| `u_wdat_fifo` | `clk` | `ucie_clk` | CHI DAT flit (incl. BE) | `WDAT_FIFO_DEPTH` |
| `u_rsp_fifo` | `ucie_clk` | `clk` | CHI RSP flit | `RSP_FIFO_DEPTH` |
| `u_rdat_fifo` | `ucie_clk` | `clk` | CHI CompData flit | `RDAT_FIFO_DEPTH` |

Backpressure:
- `u_req_fifo` full or `u_wdat_fifo` full → `chi_req_ready = 0` (write requests
  additionally need `wdat_w_full = 0` before accepting).
- `u_rsp_fifo` full → `ucie_rx_hdr_ready = 0`.
- `u_rdat_fifo` full → `ucie_rx_data_ready = 0`.

## PHY Link Controller (`phy_link_ctrl`)

4-state FSM in the `clk` domain.

| State | Encoding | Description |
|:---|:---|:---|
| `S_WAIT_PHY` | 2'b00 | Waiting for `phy_init_done` |
| `S_ACTIVE` | 2'b01 | `link_up=1` — normal operation |
| `S_ERR_DRAIN` | 2'b10 | Error detected; draining outstanding transactions |
| `S_RETRAIN` | 2'b11 | Drain complete; `retrain_req=1` until PHY re-initiates |

Transitions:
- Bring-up: `S_WAIT_PHY` → `S_ACTIVE` on `phy_init_done`.
- Normal close: `S_ACTIVE` → `S_WAIT_PHY` on `!phy_init_done`.
- Error: `S_ACTIVE` → `S_ERR_DRAIN` on `link_error`.
- Drain: `S_ERR_DRAIN` → `S_RETRAIN` on `drain_done` (all FIFOs empty).
- Recovery: `S_RETRAIN` → `S_ACTIVE` on `phy_init_done && !link_error`.

`link_up` and `retrain_req` are mutually exclusive (proven by formal).

## Sideband Handler (`sb_msg_handler`)

Handles 8-bit sideband messages on `sb_tx` / `sb_rx` ports (both in the `ucie_clk`
domain).

### TX messages (bridge → PHY)

| Message | Value | Trigger |
|:---|:---|:---|
| `SB_MSG_LINK_ACTIVE` | 0xA0 | Entry into `S_ACTIVE` |
| `SB_MSG_LINK_ERROR` | 0xE1 | Entry into `S_ERR_DRAIN` |
| `SB_MSG_RETRAIN_REQ` | 0xC2 | Entry into `S_RETRAIN` |
| `SB_MSG_PARAM_ACK` | 0xB1 | Response to `PARAM_REQ`; payload = `max_outstanding[7:0]` |
| `SB_MSG_PM_L1_ACK` | 0xD1 | PM L1 ack after drain completes |

TX priority (highest first): PM L1 ACK → link-state messages → PARAM ACK.

### RX messages (PHY → bridge)

| Message | Value | Effect |
|:---|:---|:---|
| `SB_MSG_PARAM_REQ` | 0xB0 | Bridge responds with `PARAM_ACK` next cycle |
| `SB_MSG_PM_L1_REQ` | 0xD0 | Asserts `pm_l1_active`; gates `chi_req_ready` |
| `SB_MSG_PM_L1_EXIT` | 0xD2 | Clears `pm_l1_active`; bridge re-opens |

PM L1 flow: `PM_L1_REQ` → bridge drains FIFOs → sends `PM_L1_ACK` → PHY cuts
power → `PM_L1_EXIT` → bridge resumes.

## Verification

### Directed testbench (`src/tb_chi_to_ucie_bridge.v`)

Self-checking Icarus simulation covering read, write, sub-cacheline write, split
completion, QoS, and flit-sequence ordering. Runs via `make sim`.

### cocotb (16 tests, `verification/cocotb/test_bridge.py`)

Runs under Icarus (default) or Verilator (`make SIM=verilator`). Verilator mode
enables SVA (`--assert`) and coverage (`--coverage`). Requires cocotb ≥ 1.9.2
with Python 3.10.

### SVA (`src/chi_to_ucie_bridge_sva.sv`)

Concurrent assertions bound to the bridge via `bind`, guarded by `BRIDGE_SVA`.
Active under Verilator `--assert`. Key properties:

- TX header CRC16 is always valid when presented.
- A stalled TX header stays valid and payload-stable until accepted.
- Write data is never offered before its request header.
- CHI RSP and CompData outputs hold valid and stable until accepted.
- `attr[3:0]` of every TX header equals the CHI REQ QoS field (`a_qos_routed`).

### Formal (`verification/formal/`)

5 SymbiYosys BMC targets (depth 8–16):

| Target | Key properties proved |
|:---|:---|
| `reset_drain` | Bridge-open deasserts before `link_up` in drain, no phantom opens |
| `txn_table` | Allocated tags are unique; outstanding ≤ N; freed entry matches allocated |
| `chi_to_ucie_bridge` | TX header/data CRC correct; write data after header; temporal persistence |
| `phy_link_ctrl` | `link_up` ⊕ `retrain_req` always; error-recovery cycle is reachable |
| `sb_msg_handler` | PM ACK only after drain; `pm_l1_active` ⊕ `bridge_open`; PARAM_ACK timing |

### Coverage

Merged coverage (directed sim + cocotb/Verilator): **99.2% (597/602 lines)**.
5 remaining misses: 3 defensive FSM `default:` arms (structurally unreachable),
one dead write to `rx_dat_accum[511:384]` (dead code — slot never read), and one
Verilator instrumentation gap for an inlined automatic function.

`make coverage` produces `sim/coverage.info` from the directed sim.
`make coverage-all` (after running cocotb with Verilator) merges both into
`sim/coverage_merged.info`. Note: the merged `.info` file contains two `SF:`
blocks per source file (absolute paths from directed sim, relative paths from
cocotb); accurate reporting requires summing `DA:` counts across both blocks for
each normalized path.
