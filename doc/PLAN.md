# CHI to UCIe Bridge Plan

## Phase 1 - Bring-up RTL

- Structured CHI REQ/RSP/DAT field model
- UCIe 64-bit adapter header plus 512-bit data packet model
- Dual-clock async FIFOs for host/link CDC
- Link-up gating and drain status
- Directed read/write/completion smoke test

## Phase 2 - Transaction Tracking

- Add outstanding transaction table
- Allocate bridge-local tags instead of passing CHI `TxnID` directly
- Add DBID-style write data sequencing
- Track completion ordering by class

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
