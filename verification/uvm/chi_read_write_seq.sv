// Sequence that issues a mix of CHI reads and writes

class chi_read_write_seq extends chi_base_seq;
  `uvm_object_utils(chi_read_write_seq)

  rand int num_txns = 20;

  function new(string name = "chi_read_write_seq");
    super.new(name);
  endfunction

  virtual task body();
    bit [ADDR_W-1:0] addr;
    bit [TXNID_W-1:0] txnid;
    bit [DATA_W-1:0] data;

    `uvm_info("CHI_SEQ", $sformatf("Starting mix of %0d transactions", num_txns), UVM_LOW)

    for (int i = 0; i < num_txns; i++) begin
      addr  = $urandom_range(0, 32'hFFFF_FFFF);
      txnid = i; // Simple sequential TxnID
      data  = {$urandom, $urandom, $urandom, $urandom}; // 512-bit pseudo-random

      if ($urandom_range(0, 1)) begin
        send_read(addr, txnid);
      end else begin
        send_write(addr, txnid, data);
      end
      
      #20ns; // Small gap between transactions
    end
  endtask

endclass
