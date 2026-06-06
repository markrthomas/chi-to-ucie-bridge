// UCIe Monitor

class ucie_monitor extends uvm_monitor;
  `uvm_component_utils(ucie_monitor)

  virtual ucie_if.monitor vif;

  // Analysis ports
  uvm_analysis_port #(ucie_item) tx_hdr_port;
  uvm_analysis_port #(ucie_item) tx_data_port;
  uvm_analysis_port #(ucie_item) rx_hdr_port;
  uvm_analysis_port #(ucie_item) rx_data_port;

  function new(string name = "ucie_monitor", uvm_component parent = null);
    super.new(name, parent);
    tx_hdr_port  = new("tx_hdr_port", this);
    tx_data_port = new("tx_data_port", this);
    rx_hdr_port  = new("rx_hdr_port", this);
    rx_data_port = new("rx_data_port", this);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual ucie_if.monitor)::get(this, "", "vif", vif)) begin
      `uvm_fatal("UCIE_MON", "Could not get virtual interface")
    end
  endfunction

  virtual task run_phase(uvm_phase phase);
    fork
      monitor_tx_hdr();
      monitor_tx_data();
      monitor_rx_hdr();
      monitor_rx_data();
    join
  endtask

  local task monitor_tx_hdr();
    forever begin
      @(vif.mon_cb);
      if (vif.mon_cb.tx_hdr_valid && vif.mon_cb.tx_hdr_ready) begin
        ucie_item item = ucie_item::type_id::create("tx_hdr_item");
        item.unpack_hdr(vif.mon_cb.tx_hdr);
        tx_hdr_port.write(item);
      end
    end
  endtask

  local task monitor_tx_data();
    logic [UCIE_HDR_W-1:0] beats[4];
    forever begin
      @(vif.mon_cb);
      if (vif.mon_cb.tx_data_valid && vif.mon_cb.tx_data_ready) begin
        ucie_item item = ucie_item::type_id::create("tx_data_item");
        // Reconstruct burst: Beat 0 is header
        item.unpack_hdr(vif.mon_cb.tx_data);
        item.is_burst = 1;
        // Beats 1..4: Data
        for (int i=0; i<4; i++) begin
          do begin
            @(vif.mon_cb);
          end while (!(vif.mon_cb.tx_data_valid && vif.mon_cb.tx_data_ready));
          beats[i] = vif.mon_cb.tx_data;
        end
        item.unpack_data_beats(beats);
        tx_data_port.write(item);
      end
    end
  endtask

  local task monitor_rx_hdr();
    forever begin
      @(vif.mon_cb);
      if (vif.mon_cb.rx_hdr_valid && vif.mon_cb.rx_hdr_ready) begin
        ucie_item item = ucie_item::type_id::create("rx_hdr_item");
        item.unpack_hdr(vif.mon_cb.rx_hdr);
        rx_hdr_port.write(item);
      end
    end
  endtask

  local task monitor_rx_data();
    logic [UCIE_HDR_W-1:0] beats[4];
    forever begin
      @(vif.mon_cb);
      if (vif.mon_cb.rx_data_valid && vif.mon_cb.rx_data_ready) begin
        ucie_item item = ucie_item::type_id::create("rx_data_item");
        // Reconstruct burst: Beat 0 is header
        item.unpack_hdr(vif.mon_cb.rx_data);
        item.is_burst = 1;
        // Beats 1..4: Data
        for (int i=0; i<4; i++) begin
          do begin
            @(vif.mon_cb);
          end while (!(vif.mon_cb.rx_data_valid && vif.mon_cb.rx_data_ready));
          beats[i] = vif.mon_cb.rx_data;
        end
        item.unpack_data_beats(beats);
        rx_data_port.write(item);
      end
    end
  endtask

endclass
