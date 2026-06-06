// UVM Test that runs a mix of reads and writes

class read_write_test extends base_test;
  `uvm_component_utils(read_write_test)

  function new(string name = "read_write_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual task run_phase(uvm_phase phase);
    chi_read_write_seq  chi_seq;
    ucie_completion_seq ucie_seq;

    phase.raise_objection(this);
    
    chi_seq  = chi_read_write_seq::type_id::create("chi_seq");
    ucie_seq = ucie_completion_seq::type_id::create("ucie_seq");

    `uvm_info("TEST", "Starting Read/Write test stimulus", UVM_LOW)

    fork
      chi_seq.start(env.chi_agt.sequencer);
      ucie_seq.start(env.ucie_agt.sequencer);
    join_any

    #500ns; // Allow some time for final completions
    phase.drop_objection(this);
  endtask

endclass
