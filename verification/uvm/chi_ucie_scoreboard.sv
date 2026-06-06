// CHI-to-UCIe Scoreboard
// Performs end-to-end transaction matching and protocol checking.

`uvm_analysis_imp_decl(_chi_req)
`uvm_analysis_imp_decl(_chi_wr_dat)
`uvm_analysis_imp_decl(_chi_rsp)
`uvm_analysis_imp_decl(_chi_comp_dat)
`uvm_analysis_imp_decl(_ucie_tx_hdr)
`uvm_analysis_imp_decl(_ucie_tx_dat)
`uvm_analysis_imp_decl(_ucie_rx_hdr)
`uvm_analysis_imp_decl(_ucie_rx_dat)

class chi_ucie_scoreboard extends uvm_scoreboard;
  `uvm_component_utils(chi_ucie_scoreboard)

  // Implementation ports
  uvm_analysis_imp_chi_req      #(chi_item, chi_ucie_scoreboard) chi_req_imp;
  uvm_analysis_imp_chi_wr_dat   #(chi_item, chi_ucie_scoreboard) chi_wr_dat_imp;
  uvm_analysis_imp_chi_rsp      #(chi_item, chi_ucie_scoreboard) chi_rsp_imp;
  uvm_analysis_imp_chi_comp_dat #(chi_item, chi_ucie_scoreboard) chi_comp_dat_imp;
  
  uvm_analysis_imp_ucie_tx_hdr  #(ucie_item, chi_ucie_scoreboard) ucie_tx_hdr_imp;
  uvm_analysis_imp_ucie_tx_dat  #(ucie_item, chi_ucie_scoreboard) ucie_tx_dat_imp;
  uvm_analysis_imp_ucie_rx_hdr  #(ucie_item, chi_ucie_scoreboard) ucie_rx_hdr_imp;
  uvm_analysis_imp_ucie_rx_dat  #(ucie_item, chi_ucie_scoreboard) ucie_rx_dat_imp;

  // Queues for matching
  chi_item  chi_req_q[$];
  chi_item  chi_wr_dat_q[$];
  ucie_item ucie_rx_hdr_q[$];
  ucie_item ucie_rx_dat_q[$];

  // Tracking table: ucie_tag -> chi_txnid
  int       tag_to_txnid[int];
  bit [ADDR_W-1:0] tag_to_addr[int];

  // Mailbox shared with ucie_completion_seq for reactive completion driving
  mailbox #(ucie_item) cpl_mbox;

  function new(string name = "chi_ucie_scoreboard", uvm_component parent = null);
    super.new(name, parent);
    chi_req_imp      = new("chi_req_imp", this);
    chi_wr_dat_imp   = new("chi_wr_dat_imp", this);
    chi_rsp_imp      = new("chi_rsp_imp", this);
    chi_comp_dat_imp = new("chi_comp_dat_imp", this);
    ucie_tx_hdr_imp  = new("ucie_tx_hdr_imp", this);
    ucie_tx_dat_imp  = new("ucie_tx_dat_imp", this);
    ucie_rx_hdr_imp  = new("ucie_rx_hdr_imp", this);
    ucie_rx_dat_imp  = new("ucie_rx_dat_imp", this);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(mailbox#(ucie_item))::get(this, "", "cpl_mbox", cpl_mbox))
      `uvm_fatal("SCB", "Could not get cpl_mbox from config_db")
  endfunction

  // ---- CHI Side Handlers ----
  virtual function void write_chi_req(chi_item item);
    `uvm_info("SCB", $sformatf("Captured CHI REQ: txnid=0x%0x addr=0x%0x op=%s", item.txnid, item.addr, item.req_opcode.name()), UVM_HIGH)
    chi_req_q.push_back(item);
  endfunction

  virtual function void write_chi_wr_dat(chi_item item);
    `uvm_info("SCB", $sformatf("Captured CHI WriteData: txnid=0x%0x", item.txnid), UVM_HIGH)
    chi_wr_dat_q.push_back(item);
  endfunction

  virtual function void write_chi_rsp(chi_item item);
    // Completion restoration check
    `uvm_info("SCB", $sformatf("Captured CHI RSP: txnid=0x%0x", item.txnid), UVM_MEDIUM)
    // In a full implementation, we'd pop from a "pending_completion" queue matched by txnid
  endfunction

  virtual function void write_chi_comp_dat(chi_item item);
    `uvm_info("SCB", $sformatf("Captured CHI CompData: txnid=0x%0x data=0x%0x", item.txnid, item.data[63:0]), UVM_MEDIUM)
  endfunction

  // ---- UCIe Side Handlers ----
  virtual function void write_ucie_tx_hdr(ucie_item item);
    chi_item  chi;
    ucie_item cpl;
    `uvm_info("SCB", $sformatf("Captured UCIe TX HDR: tag=%0d addr=0x%0x code=0x%0x",
              item.tag, item.addr, item.code), UVM_MEDIUM)

    if (chi_req_q.size() == 0) begin
      `uvm_error("SCB", "UCIe TX HDR issued but no pending CHI requests")
      return;
    end

    chi = chi_req_q.pop_front();
    if (item.addr != chi.addr)
      `uvm_error("SCB", $sformatf("Address mismatch: CHI=0x%0x UCIe=0x%0x", chi.addr, item.addr))

    tag_to_txnid[item.tag] = chi.txnid;
    tag_to_addr[item.tag]  = chi.addr;

    // Queue the appropriate completion for the reactive completion sequence.
    cpl = ucie_item::type_id::create("cpl_item");
    if (item.code == UCIE_MSG_MEM_WR) begin
      // Write: expect AD_CPL (single header, no data)
      cpl.kind     = UCIE_PKT_KIND_AD_CPL;
      cpl.code     = UCIE_CPL_SC;
      cpl.tag      = item.tag;
      cpl.is_burst = 1'b0;
    end else begin
      // Read: expect MEM_CPL (header + 4 data beats, data = 0 for smoke test)
      cpl.kind     = UCIE_PKT_KIND_MEM_CPL;
      cpl.code     = UCIE_CPL_SC;
      cpl.tag      = item.tag;
      cpl.data     = '0;
      cpl.is_burst = 1'b1;
    end
    cpl_mbox.put(cpl);
  endfunction

  virtual function void write_ucie_tx_dat(ucie_item item);
    `uvm_info("SCB", $sformatf("Captured UCIe TX DATA Burst: tag=%0d", item.tag), UVM_MEDIUM)
    // Multi-beat data check should go here
  endfunction

  virtual function void write_ucie_rx_hdr(ucie_item item);
    `uvm_info("SCB", $sformatf("Captured UCIe RX HDR: tag=%0d kind=%s", item.tag, item.kind.name()), UVM_HIGH)
  endfunction

  virtual function void write_ucie_rx_dat(ucie_item item);
    `uvm_info("SCB", $sformatf("Captured UCIe RX DATA Burst: tag=%0d", item.tag), UVM_HIGH)
  endfunction

endclass
