// UCIe Sequencer

class ucie_sequencer extends uvm_sequencer #(ucie_item);
  `uvm_component_utils(ucie_sequencer)

  function new(string name = "ucie_sequencer", uvm_component parent = null);
    super.new(name, parent);
  endfunction

endclass
