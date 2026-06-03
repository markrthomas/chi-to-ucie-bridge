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
| bad checksum or unsupported completion | CHI response/data with `RespErr` set |

The CHI `TxnID` is carried directly as the UCIe tag in Phase 1.

## FIFOs

| FIFO | Write Domain | Read Domain | Payload |
|:---|:---|:---|:---|
| `u_req_fifo` | `clk` | `ucie_clk` | CHI request flit |
| `u_wdat_fifo` | `clk` | `ucie_clk` | `{TxnID, CHI DAT}` |
| `u_rsp_fifo` | `ucie_clk` | `clk` | CHI response flit |
| `u_rdat_fifo` | `ucie_clk` | `clk` | CHI CompData flit |

## Verification

The directed testbench is self-checking and runs under Icarus. Verilator lint is
the fast structural gate. Formal files are present as smoke scaffolding for the
shared FSM and bridge top.
