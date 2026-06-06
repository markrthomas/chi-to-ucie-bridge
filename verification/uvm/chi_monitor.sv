// CHI Monitor

class chi_monitor extends uvm_monitor;
  `uvm_component_utils(chi_monitor)

  virtual chi_if.monitor vif;

  // Analysis ports for each channel
  uvm_analysis_port #(chi_item) req_port;
  uvm_analysis_port #(chi_item) wr_data_port;
  uvm_analysis_port #(chi_item) rsp_port;
  uvm_analysis_port #(chi_item) comp_data_port;

  function new(string name = "chi_monitor", uvm_component parent = null);
    super.new(name, parent);
    req_port       = new("req_port", this);
    wr_data_port   = new("wr_data_port", this);
    rsp_port       = new("rsp_port", this);
    comp_data_port = new("comp_data_port", this);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual chi_if.monitor)::get(this, "", "vif", vif)) begin
      `uvm_fatal("CHI_MON", "Could not get virtual interface")
    end
  endfunction

  virtual task run_phase(uvm_phase phase);
    fork
      collect_reqs();
      collect_wr_data();
      collect_rsps();
      collect_comp_data();
    join
  endtask

  local task collect_reqs();
    forever begin
      @(vif.mon_cb);
      if (vif.mon_cb.req_valid && vif.mon_cb.req_ready) begin
        chi_item item = chi_item::type_id::create("req_item");
        item.unpack_flit(vif.mon_cb.req_data, chi_item::REQ);
        req_port.write(item);
      end
    end
  endtask

  local task collect_wr_data();
    forever begin
      @(vif.mon_cb);
      if (vif.mon_cb.wr_data_valid && vif.mon_cb.wr_data_ready) begin
        chi_item item = chi_item::type_id::create("wr_data_item");
        item.unpack_flit(vif.mon_cb.wr_data, chi_item::DAT);
        wr_data_port.write(item);
      end
    end
  endtask

  local task collect_rsps();
    forever begin
      @(vif.mon_cb);
      if (vif.mon_cb.rsp_valid && vif.mon_cb.rsp_ready) begin
        chi_item item = chi_item::type_id::create("rsp_item");
        item.unpack_flit(vif.mon_cb.rsp_data, chi_item::RSP);
        rsp_port.write(item);
      end
    end
  endtask

  local task collect_comp_data();
    forever begin
      @(vif.mon_cb);
      if (vif.mon_cb.comp_data_valid && vif.mon_cb.comp_data_ready) begin
        chi_item item = chi_item::type_id::create("comp_data_item");
        item.unpack_flit(vif.mon_cb.comp_data, chi_item::DAT);
        comp_data_port.write(item);
      end
    end
  endtask

endclass
