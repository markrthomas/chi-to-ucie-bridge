// CHI Sequencer

class chi_sequencer extends uvm_sequencer #(chi_item);
  `uvm_component_utils(chi_sequencer)

  function new(string name = "chi_sequencer", uvm_component parent = null);
    super.new(name, parent);
  endfunction

endclass
