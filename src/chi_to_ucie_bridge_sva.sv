// Concurrent SVA properties for chi_to_ucie_bridge, attached by `bind`.
//
// The assertion bodies are guarded by `BRIDGE_SVA` so the module compiles to an
// empty shell under tools that do not consume concurrent assertions (e.g. the
// Icarus directed flow). Define BRIDGE_SVA for Verilator (`--assert`) and for
// formal to activate them.

`include "chi_ucie_bridge_defs.vh"

module chi_to_ucie_bridge_sva (
  input wire                   clk,        // ucie_clk
  input wire                   rst_n,      // ucie_rst_n
  input wire                   open,       // bridge_open_ucie
  input wire                   tx_hdr_valid,
  input wire                   tx_hdr_ready,
  input wire [UCIE_HDR_W-1:0]  tx_hdr,
  input wire                   tx_data_valid,
  input wire                   tx_data_ready,
  input wire [UCIE_DATA_W-1:0] tx_data,
  input wire                   wq_empty
);

`ifdef BRIDGE_SVA
  default clocking cb @(posedge clk); endclocking
  default disable iff (!rst_n);

  // Every issued UCIe TX header carries a valid checksum.
  a_tx_hdr_csum: assert property (
    (tx_hdr_valid && tx_hdr_ready) |-> ucie_hdr_checksum_ok(tx_hdr)
  );

  // The header embedded in an issued write-data packet also checks.
  a_tx_data_csum: assert property (
    (tx_data_valid && tx_data_ready) |->
      ucie_hdr_checksum_ok(tx_data[UCIE_DATA_HDR_LSB +: UCIE_HDR_W])
  );

  // Handshake persistence: while the link stays open, a stalled TX header keeps
  // its valid asserted until accepted (it may drop only if the link closes).
  a_tx_hdr_persist: assert property (
    (tx_hdr_valid && !tx_hdr_ready && open) |=> (tx_hdr_valid || !open)
  );

  // Ordering: write data is never offered before its request header has been
  // issued (i.e. its local tag is queued).
  a_data_after_hdr: assert property (
    tx_data_valid |-> !wq_empty
  );

  // Coverage: confirm the interesting events are actually exercised.
  c_hdr_issued:  cover property (tx_hdr_valid && tx_hdr_ready);
  c_data_issued: cover property (tx_data_valid && tx_data_ready);
`endif

endmodule

bind chi_to_ucie_bridge chi_to_ucie_bridge_sva u_sva (
  .clk(ucie_clk),
  .rst_n(ucie_rst_n),
  .open(bridge_open_ucie),
  .tx_hdr_valid(ucie_tx_hdr_valid),
  .tx_hdr_ready(ucie_tx_hdr_ready),
  .tx_hdr(ucie_tx_hdr),
  .tx_data_valid(ucie_tx_data_valid),
  .tx_data_ready(ucie_tx_data_ready),
  .tx_data(ucie_tx_data),
  .wq_empty(wq_empty)
);
