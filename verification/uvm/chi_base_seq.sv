// Base sequence for CHI transactions

class chi_base_seq extends uvm_sequence #(chi_item);
  `uvm_object_utils(chi_base_seq)

  function new(string name = "chi_base_seq");
    super.new(name);
  endfunction

  task send_read(bit [ADDR_W-1:0] addr, bit [TXNID_W-1:0] txnid);
    `uvm_create(req)
    req.item_type  = chi_item::REQ;
    req.req_opcode = CHI_REQ_READNOSNP;
    req.addr       = addr;
    req.txnid      = txnid;
    `uvm_send(req)
  endtask

  task send_write(bit [ADDR_W-1:0] addr, bit [TXNID_W-1:0] txnid, bit [DATA_W-1:0] data);
    // Bridge requires REQ and WR_DATA to be valid simultaneously for writes.
    // Pack both into one item; the driver drives both channels atomically.
    `uvm_create(req)
    req.item_type  = chi_item::REQ;
    req.req_opcode = CHI_REQ_WRITENOSNPFULL;
    req.addr       = addr;
    req.txnid      = txnid;
    req.dat_opcode = CHI_DAT_NCBWRDATA;
    req.data       = data;
    req.be         = '1;
    `uvm_send(req)
  endtask

endclass
