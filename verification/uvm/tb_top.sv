// Top-level module for UVM testbench

`timescale 1ns/1ps
`include "chi_ucie_bridge_defs.vh"

module tb_top;
  import uvm_pkg::*;
  import chi_ucie_uvm_pkg::*;

  logic clk;
  logic ucie_clk;
  logic rst_n;

  // Clock generation
  initial begin
    clk = 0;
    forever #5ns clk = ~clk; // 100 MHz
  end

  initial begin
    ucie_clk = 0;
    forever #3ns ucie_clk = ~ucie_clk; // 166 MHz
  end

  // Reset generation
  initial begin
    rst_n = 0;
    #50ns rst_n = 1;
  end

  // Interfaces
  chi_if  chi_vif (clk, rst_n);
  ucie_if ucie_vif (ucie_clk, rst_n);

  // DUT instantiation
  chi_to_ucie_bridge #(
    .FIFO_DEPTH(8),
    .TX_HDR_CREDITS(8),
    .TX_DAT_CREDITS(8),
    .MAX_OUTSTANDING(32)
  ) dut (
    .clk(clk),
    .ucie_clk(ucie_clk),
    .rst_n(rst_n),
    .chi_req_valid(chi_vif.req_valid),
    .chi_req_data(chi_vif.req_data),
    .chi_req_ready(chi_vif.req_ready),
    .chi_wr_data_valid(chi_vif.wr_data_valid),
    .chi_wr_data(chi_vif.wr_data),
    .chi_wr_data_ready(chi_vif.wr_data_ready),
    .chi_rsp_valid(chi_vif.rsp_valid),
    .chi_rsp_data(chi_vif.rsp_data),
    .chi_rsp_ready(chi_vif.rsp_ready),
    .chi_comp_data_valid(chi_vif.comp_data_valid),
    .chi_comp_data(chi_vif.comp_data),
    .chi_comp_data_ready(chi_vif.comp_data_ready),
    .ucie_tx_hdr_valid(ucie_vif.tx_hdr_valid),
    .ucie_tx_hdr(ucie_vif.tx_hdr),
    .ucie_tx_hdr_ready(ucie_vif.tx_hdr_ready),
    .ucie_tx_data_valid(ucie_vif.tx_data_valid),
    .ucie_tx_data(ucie_vif.tx_data),
    .ucie_tx_data_ready(ucie_vif.tx_data_ready),
    .ucie_rx_hdr_valid(ucie_vif.rx_hdr_valid),
    .ucie_rx_hdr(ucie_vif.rx_hdr),
    .ucie_rx_hdr_ready(ucie_vif.rx_hdr_ready),
    .ucie_rx_data_valid(ucie_vif.rx_data_valid),
    .ucie_rx_data(ucie_vif.rx_data),
    .ucie_rx_data_ready(ucie_vif.rx_data_ready),
    .ucie_rx_hdr_crdt(ucie_vif.rx_hdr_crdt),
    .ucie_rx_dat_crdt(ucie_vif.rx_dat_crdt),
    .ucie_tx_hdr_crdt(ucie_vif.tx_hdr_crdt),
    .ucie_tx_dat_crdt(ucie_vif.tx_dat_crdt),
    .phy_init_done(ucie_vif.phy_init_done),
    .link_error(ucie_vif.link_error),
    .retrain_req(ucie_vif.retrain_req),
    .link_state(ucie_vif.link_state),
    .sb_tx_valid(ucie_vif.sb_tx_valid),
    .sb_tx_data(ucie_vif.sb_tx_data),
    .sb_tx_ready(ucie_vif.sb_tx_ready),
    .sb_rx_valid(ucie_vif.sb_rx_valid),
    .sb_rx_data(ucie_vif.sb_rx_data),
    .sb_rx_ready(ucie_vif.sb_rx_ready),
    .pm_l1_active(ucie_vif.pm_l1_active),
    .err_inj_en(1'b0),
    .drain_done(),
    .crc_err_cnt(),
    .tag_err_cnt(),
    .drain_cnt(),
    .qos_hi_cnt()
  );

  initial begin
    // Set virtual interfaces in config_db
    uvm_config_db#(virtual chi_if.driver)::set(null, "uvm_test_top.env.chi_agt.driver", "vif", chi_vif.driver);
    uvm_config_db#(virtual chi_if.monitor)::set(null, "uvm_test_top.env.chi_agt.monitor", "vif", chi_vif.monitor);
    uvm_config_db#(virtual ucie_if.driver)::set(null, "uvm_test_top.env.ucie_agt.driver", "vif", ucie_vif.driver);
    uvm_config_db#(virtual ucie_if.monitor)::set(null, "uvm_test_top.env.ucie_agt.monitor", "vif", ucie_vif.monitor);
    
    // Start simulation
    run_test();
  end

endmodule
