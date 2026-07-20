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
  input wire [2:0]             tx_dat_beat_ctr,
  input wire                   wq_empty,
  input wire                   sdq_empty,     // §9: snoop data queue empty
  input wire [3:0]             req_head_qos,  // QoS of the req_fifo head (§5.4)
  // CHI host clock domain (output completion channels)
  input wire                   clk_chi,    // clk
  input wire                   rst_chi,    // clk_rst_n
  input wire                   chi_rsp_valid,
  input wire                   chi_rsp_ready,
  input wire [CHI_RSP_W-1:0]   chi_rsp_data,
  input wire                   chi_comp_data_valid,
  input wire                   chi_comp_data_ready,
  input wire [CHI_DAT_W-1:0]   chi_comp_data
);

`ifdef BRIDGE_SVA
  // UCIe TX path (ucie_clk domain).  Explicit clocking used on every property
  // for compatibility with both Verilator --assert and yosys/SymbiYosys formal.

  // Every issued UCIe TX header carries a valid checksum.
  a_tx_hdr_csum: assert property (
    @(posedge clk) disable iff (!rst_n)
    (tx_hdr_valid && tx_hdr_ready) |-> ucie_hdr_crc16_ok(tx_hdr)
  );

  // The header flit (beat 0) of an issued write-data burst also checks.
  a_tx_data_csum: assert property (
    @(posedge clk) disable iff (!rst_n)
    (tx_data_valid && tx_data_ready && tx_dat_beat_ctr == 0) |->
      ucie_hdr_crc16_ok(tx_data)
  );

  // Handshake persistence: while the link stays open, a stalled TX header keeps
  // its valid asserted until accepted (it may drop only if the link closes).
  a_tx_hdr_persist: assert property (
    @(posedge clk) disable iff (!rst_n)
    (tx_hdr_valid && !tx_hdr_ready && open) |=> (tx_hdr_valid || !open)
  );

  // Payload stability: a stalled TX header holds its value (incl. local tag)
  // until accepted, so the local tag cannot shift mid-handshake.
  a_tx_hdr_stable: assert property (
    @(posedge clk) disable iff (!rst_n)
    (tx_hdr_valid && !tx_hdr_ready && open) |=> ($stable(tx_hdr) || !open)
  );

  // Ordering: TX data is never offered without a pending write or snoop-data entry.
  a_data_after_hdr: assert property (
    @(posedge clk) disable iff (!rst_n)
    tx_data_valid |-> !wq_empty || !sdq_empty
  );

  // QoS routing (§5.4): every issued header carries the CHI REQ QoS[3:0] in
  // UCIe attr[3:0] (header bits [107:104]).
  a_qos_routed: assert property (
    @(posedge clk) disable iff (!rst_n)
    tx_hdr_valid |-> (tx_hdr[UCIE_ATTR_LSB +: 4] == req_head_qos)
  );

  // CHI completion output channels (CHI host clock domain): a presented
  // completion holds valid and stable payload until the consumer accepts it.
  a_rsp_persist: assert property (
    @(posedge clk_chi) disable iff (!rst_chi)
    (chi_rsp_valid && !chi_rsp_ready) |=> chi_rsp_valid
  );
  a_rsp_stable: assert property (
    @(posedge clk_chi) disable iff (!rst_chi)
    (chi_rsp_valid && !chi_rsp_ready) |=> $stable(chi_rsp_data)
  );
  a_comp_persist: assert property (
    @(posedge clk_chi) disable iff (!rst_chi)
    (chi_comp_data_valid && !chi_comp_data_ready) |=> chi_comp_data_valid
  );
  a_comp_stable: assert property (
    @(posedge clk_chi) disable iff (!rst_chi)
    (chi_comp_data_valid && !chi_comp_data_ready) |=> $stable(chi_comp_data)
  );

  // Coverage: confirm the interesting events are actually exercised.
  c_hdr_issued:  cover property (@(posedge clk) disable iff (!rst_n)
                   tx_hdr_valid && tx_hdr_ready);
  c_data_issued: cover property (@(posedge clk) disable iff (!rst_n)
                   tx_data_valid && tx_data_ready);
  c_rsp_accepted:  cover property (@(posedge clk_chi) disable iff (!rst_chi)
                     chi_rsp_valid && chi_rsp_ready);
  c_comp_accepted: cover property (@(posedge clk_chi) disable iff (!rst_chi)
                     chi_comp_data_valid && chi_comp_data_ready);
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
  .tx_dat_beat_ctr(tx_dat_beat_ctr),
  .wq_empty(wq_empty),
  .sdq_empty(sdq_empty),
  .req_head_qos(req_r_data[CHI_REQ_QOS_LSB +: CHI_REQ_QOS_W]),
  .clk_chi(clk),
  .rst_chi(clk_rst_n),
  .chi_rsp_valid(chi_rsp_valid),
  .chi_rsp_ready(chi_rsp_ready),
  .chi_rsp_data(chi_rsp_data),
  .chi_comp_data_valid(chi_comp_data_valid),
  .chi_comp_data_ready(chi_comp_data_ready),
  .chi_comp_data(chi_comp_data)
);
