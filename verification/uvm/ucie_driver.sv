// UCIe Driver

class ucie_driver extends uvm_driver #(ucie_item);
  `uvm_component_utils(ucie_driver)

  virtual ucie_if.driver vif;

  function new(string name = "ucie_driver", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual ucie_if.driver)::get(this, "", "vif", vif)) begin
      `uvm_fatal("UCIE_DRV", "Could not get virtual interface")
    end
  endfunction

  virtual task run_phase(uvm_phase phase);
    reset_signals();
    fork
      backpressure_handler();
      item_handler();
    join
  endtask

  local task reset_signals();
    wait (vif.rst_n === 1'b0);
    vif.drv_cb.rx_hdr_valid  <= 1'b0;
    vif.drv_cb.rx_hdr        <= '0;
    vif.drv_cb.rx_data_valid <= 1'b0;
    vif.drv_cb.rx_data       <= '0;
    vif.drv_cb.rx_hdr_crdt   <= 1'b0;
    vif.drv_cb.rx_dat_crdt   <= 1'b0;
    vif.drv_cb.tx_hdr_ready  <= 1'b1;
    vif.drv_cb.tx_data_ready <= 1'b1;
    vif.drv_cb.link_up       <= 1'b0;
    wait (vif.rst_n === 1'b1);
    vif.drv_cb.link_up       <= 1'b1;
  endtask

  local task backpressure_handler();
    forever begin
      @(vif.drv_cb);
      // Randomly toggle ready signals
      vif.drv_cb.tx_hdr_ready  <= ($urandom_range(0, 99) < 80);
      vif.drv_cb.tx_data_ready <= ($urandom_range(0, 99) < 80);
    end
  endtask

  local task item_handler();
    forever begin
      seq_item_port.get_next_item(req);
      drive_item(req);
      seq_item_port.item_done();
    end
  endtask

  local task drive_item(ucie_item item);
    // Simple driver: only supports RX bursts for now (UCIe -> Bridge)
    if (item.is_burst) begin
      drive_rx_burst(item);
    end else begin
      drive_rx_hdr(item);
    end
  endtask

  // Return TX buffer credits after driving completions.
  // AD_CPL (write cpl): bridge consumed 1 hdr credit + 1 dat credit to send this write.
  // MEM_CPL (read cpl): bridge consumed 1 hdr credit to send the read request.
  local task return_credits(ucie_item item);
    @(vif.drv_cb);
    vif.drv_cb.rx_hdr_crdt <= 1'b1;
    if (item.kind == UCIE_PKT_KIND_AD_CPL)
      vif.drv_cb.rx_dat_crdt <= 1'b1;
    @(vif.drv_cb);
    vif.drv_cb.rx_hdr_crdt <= 1'b0;
    vif.drv_cb.rx_dat_crdt <= 1'b0;
  endtask

  local task drive_rx_hdr(ucie_item item);
    vif.drv_cb.rx_hdr       <= item.pack_hdr();
    vif.drv_cb.rx_hdr_valid <= 1'b1;
    do begin
      @(vif.drv_cb);
    end while (!vif.drv_cb.rx_hdr_ready);
    vif.drv_cb.rx_hdr_valid <= 1'b0;
    return_credits(item);
  endtask

  local task drive_rx_burst(ucie_item item);
    logic [UCIE_HDR_W-1:0] beats[4];
    item.pack_data_beats(beats);

    // Beat 0: Header flit (with CRC)
    vif.drv_cb.rx_data       <= item.pack_hdr();
    vif.drv_cb.rx_data_valid <= 1'b1;
    do begin
      @(vif.drv_cb);
    end while (!vif.drv_cb.rx_data_ready);

    // Beats 1..4: Raw 128-bit data chunks
    for (int i=0; i<4; i++) begin
      vif.drv_cb.rx_data <= beats[i];
      do begin
        @(vif.drv_cb);
      end while (!vif.drv_cb.rx_data_ready);
    end
    vif.drv_cb.rx_data_valid <= 1'b0;
    return_credits(item);
  endtask

endclass
