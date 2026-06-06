// Base UVM Test for the CHI-to-UCIe bridge

class base_test extends uvm_test;
  `uvm_component_utils(base_test)

  chi_ucie_env env;

  function new(string name = "base_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    env = chi_ucie_env::type_id::create("env", this);
  endfunction

  virtual function void end_of_elaboration_phase(uvm_phase phase);
    super.end_of_elaboration_phase(phase);
    this.print();
  endfunction

  virtual task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    `uvm_info("TEST", "Starting base_test run_phase", UVM_LOW)
    #1000ns;
    `uvm_info("TEST", "base_test completed", UVM_LOW)
    phase.drop_objection(this);
  endtask

endclass
