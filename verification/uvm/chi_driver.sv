// CHI Driver

class chi_driver extends uvm_driver #(chi_item);
  `uvm_component_utils(chi_driver)

  virtual chi_if.driver vif;

  function new(string name = "chi_driver", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual chi_if.driver)::get(this, "", "vif", vif)) begin
      `uvm_fatal("CHI_DRV", "Could not get virtual interface")
    end
  endfunction

  virtual task run_phase(uvm_phase phase);
    reset_signals();
    forever begin
      seq_item_port.get_next_item(req);
      drive_item(req);
      seq_item_port.item_done();
    end
  endtask

  local task reset_signals();
    wait (vif.rst_n === 1'b0);
    vif.drv_cb.req_valid     <= 1'b0;
    vif.drv_cb.req_data      <= '0;
    vif.drv_cb.wr_data_valid <= 1'b0;
    vif.drv_cb.wr_data       <= '0;
    vif.drv_cb.rsp_ready     <= 1'b1; // Default ready to accept
    vif.drv_cb.comp_data_ready <= 1'b1;
    wait (vif.rst_n === 1'b1);
  endtask

  local task drive_item(chi_item item);
    case (item.item_type)
      chi_item::REQ: drive_req(item);
      chi_item::DAT: drive_wr_data(item);
      default: `uvm_error("CHI_DRV", $sformatf("Unsupported item type: %s", item.item_type.name()))
    endcase
  endtask

  local function logic is_write_opcode(chi_item item);
    return (item.req_opcode == CHI_REQ_WRITENOSNPFULL  ||
            item.req_opcode == CHI_REQ_WRITENOSNPPTL   ||
            item.req_opcode == CHI_REQ_WRITEUNIQUEFULL);
  endfunction

  local task drive_req(chi_item item);
    vif.drv_cb.req_data  <= item.pack_flit();
    vif.drv_cb.req_valid <= 1'b1;
    if (is_write_opcode(item)) begin
      // Bridge requires REQ and WR_DATA valid simultaneously for writes.
      // The write item carries both REQ and DAT fields; build the DAT flit inline.
      chi_item dat = chi_item::type_id::create("dat_flit");
      dat.item_type  = chi_item::DAT;
      dat.dat_opcode = item.dat_opcode;
      dat.data       = item.data;
      dat.be         = item.be;
      dat.txnid      = item.txnid;
      vif.drv_cb.wr_data       <= dat.pack_flit();
      vif.drv_cb.wr_data_valid <= 1'b1;
      do begin
        @(vif.drv_cb);
      end while (!vif.drv_cb.req_ready || !vif.drv_cb.wr_data_ready);
      vif.drv_cb.req_valid     <= 1'b0;
      vif.drv_cb.wr_data_valid <= 1'b0;
    end else begin
      do begin
        @(vif.drv_cb);
      end while (!vif.drv_cb.req_ready);
      vif.drv_cb.req_valid <= 1'b0;
    end
  endtask

  local task drive_wr_data(chi_item item);
    vif.drv_cb.wr_data       <= item.pack_flit();
    vif.drv_cb.wr_data_valid <= 1'b1;
    do begin
      @(vif.drv_cb);
    end while (!vif.drv_cb.wr_data_ready);
    vif.drv_cb.wr_data_valid <= 1'b0;
  endtask

endclass
