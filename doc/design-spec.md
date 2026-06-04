# CHI to UCIe Bridge Design Spec

## Scope

This repo models an RTL bridge from a compact AMBA CHI RN-side interface to a
compact UCIe adapter interface. It is intended to exercise translation,
clock-domain crossing, link gating, and verification infrastructure before
adding a bit-exact protocol layer.

## Clocks and Reset

| Domain | Clock | Interfaces |
|:---|:---|:---|
| CHI host | `clk` | `chi_req`, `chi_wr_data`, `chi_rsp`, `chi_comp_data` |
| UCIe adapter | `ucie_clk` | `ucie_tx_hdr`, `ucie_tx_data`, `ucie_rx_hdr`, `ucie_rx_data` |

`rst_n` is synchronized independently into both domains. `link_up` is
synchronized into the CHI domain, then the bridge-open state is synchronized into
the UCIe domain.

## Translation

| CHI input | UCIe output |
|:---|:---|
| `ReadNoSnp`, `ReadOnce` | `AD_REQ / MEM_RD` |
| `WriteNoSnpFull`, `WriteNoSnpPtl`, `WriteUniqueFull` | `AD_REQ / MEM_WR` plus `MEM_WR_DATA` payload |

| UCIe input | CHI output |
|:---|:---|
| `AD_CPL / SC` | `RSP / Comp` |
| `MEM_CPL / SC` with data payload | `DAT / CompData` |
| bad checksum, unsupported completion, or unknown tag | CHI response/data with `RespErr` set |

## Transaction tracking

Each request issued to UCIe is assigned a bridge-local tag from `txn_table`
(`MAX_OUTSTANDING` entries, `ucie_clk` domain) instead of forwarding the CHI
`TxnID`. The table records `{TxnID, SrcID, is_write}` keyed by the local tag.
When a completion returns, the local tag in the UCIe header is looked up to
restore the original CHI identity, and the entry is freed. The table presents:

- one allocate port (header issue) with `full` back-pressuring `ucie_tx_hdr`;
- two free/lookup ports, because the `AD_CPL` header and `MEM_CPL` data channels
  can each retire a transaction in the same cycle.

A write's local tag is carried from header issue to data issue by an in-order
side-queue, which also prevents the `MEM_WR_DATA` packet from being issued ahead
of its request header on the independent ready paths. A completion to a tag that
is not currently allocated does not free anything, sets CHI `RespErr`, and pulses
the `tag_err_cnt` counter.

## FIFOs

| FIFO | Write Domain | Read Domain | Payload |
|:---|:---|:---|:---|
| `u_req_fifo` | `clk` | `ucie_clk` | CHI request flit |
| `u_wdat_fifo` | `clk` | `ucie_clk` | `{TxnID, CHI DAT}` |
| `u_rsp_fifo` | `ucie_clk` | `clk` | CHI response flit |
| `u_rdat_fifo` | `ucie_clk` | `clk` | CHI CompData flit |

## Verification

The directed testbench is self-checking and runs under Icarus, including
Phase 2 checks that the bridge issues distinct local tags (even for reused CHI
`TxnID`s), tags the write-data packet correctly, and restores the original CHI
`TxnID` on completion. Verilator lint is the fast structural gate. Formal
covers the `reset_drain` FSM and the bridge top as smoke, plus bounded
`txn_table` properties (allocation only targets free slots; the outstanding
count stays within the table size).
