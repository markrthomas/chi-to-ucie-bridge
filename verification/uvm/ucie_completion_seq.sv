// UCIe responder sequence — drives reactive completions back to the bridge.
// Pops completion descriptors from cpl_mbox (filled by chi_ucie_scoreboard
// on each observed UCIe TX_HDR) and drives the appropriate UCIe RX transaction.

class ucie_completion_seq extends uvm_sequence #(ucie_item);
  `uvm_object_utils(ucie_completion_seq)

  mailbox #(ucie_item) cpl_mbox;

  function new(string name = "ucie_completion_seq");
    super.new(name);
  endfunction

  virtual task body();
    if (!uvm_config_db#(mailbox#(ucie_item))::get(m_sequencer, "", "cpl_mbox", cpl_mbox))
      `uvm_fatal("UCIE_CPL_SEQ", "Could not get cpl_mbox from config_db")

    forever begin
      ucie_item pending;
      cpl_mbox.get(pending);   // blocks until the scoreboard queues a completion
      // Small delay so the TX_HDR handshake has fully settled before we respond
      #20ns;
      `uvm_create(req)
      req.kind     = pending.kind;
      req.code     = pending.code;
      req.tag      = pending.tag;
      req.data     = pending.data;
      req.is_burst = pending.is_burst;
      `uvm_send(req)
    end
  endtask

endclass
