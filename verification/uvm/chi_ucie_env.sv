// CHI-to-UCIe UVM Environment

class chi_ucie_env extends uvm_env;
  `uvm_component_utils(chi_ucie_env)

  chi_agent           chi_agt;
  ucie_agent          ucie_agt;
  chi_ucie_scoreboard scb;

  // Mailbox fed by scoreboard (on each observed UCIe TX_HDR) and consumed
  // by ucie_completion_seq to drive reactive completions back to the bridge.
  mailbox #(ucie_item) cpl_mbox;

  function new(string name = "chi_ucie_env", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    cpl_mbox = new();   // unbounded mailbox
    uvm_config_db#(mailbox#(ucie_item))::set(this, "*", "cpl_mbox", cpl_mbox);
    chi_agt  = chi_agent::type_id::create("chi_agt", this);
    ucie_agt = ucie_agent::type_id::create("ucie_agt", this);
    scb      = chi_ucie_scoreboard::type_id::create("scb", this);
  endfunction

  virtual function void connect_phase(uvm_phase phase);
    // Connect CHI Monitor to Scoreboard
    chi_agt.monitor.req_port.connect(scb.chi_req_imp);
    chi_agt.monitor.wr_data_port.connect(scb.chi_wr_dat_imp);
    chi_agt.monitor.rsp_port.connect(scb.chi_rsp_imp);
    chi_agt.monitor.comp_data_port.connect(scb.chi_comp_dat_imp);

    // Connect UCIe Monitor to Scoreboard
    ucie_agt.monitor.tx_hdr_port.connect(scb.ucie_tx_hdr_imp);
    ucie_agt.monitor.tx_data_port.connect(scb.ucie_tx_dat_imp);
    ucie_agt.monitor.rx_hdr_port.connect(scb.ucie_rx_hdr_imp);
    ucie_agt.monitor.rx_data_port.connect(scb.ucie_rx_dat_imp);
  endfunction

endclass
