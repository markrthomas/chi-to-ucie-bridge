// CHI Agent

class chi_agent extends uvm_agent;
  `uvm_component_utils(chi_agent)

  chi_sequencer sequencer;
  chi_driver    driver;
  chi_monitor   monitor;

  function new(string name = "chi_agent", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    monitor = chi_monitor::type_id::create("monitor", this);
    if (get_is_active() == UVM_ACTIVE) begin
      sequencer = chi_sequencer::type_id::create("sequencer", this);
      driver    = chi_driver::type_id::create("driver", this);
    end
  endfunction

  virtual function void connect_phase(uvm_phase phase);
    if (get_is_active() == UVM_ACTIVE) begin
      driver.seq_item_port.connect(sequencer.seq_item_export);
    end
  endfunction

endclass
