// UCIe interface for the CHI-to-UCIe bridge.
interface ucie_if (input logic clk, input logic rst_n);
  import chi_ucie_uvm_pkg::*;

  // TX path (Bridge -> UCIe)
  logic               tx_hdr_valid;
  logic [UCIE_HDR_W-1:0] tx_hdr;
  logic               tx_hdr_ready;

  logic               tx_data_valid;
  logic [UCIE_HDR_W-1:0] tx_data;
  logic               tx_data_ready;

  // RX path (UCIe -> Bridge)
  logic               rx_hdr_valid;
  logic [UCIE_HDR_W-1:0] rx_hdr;
  logic               rx_hdr_ready;

  logic               rx_data_valid;
  logic [UCIE_HDR_W-1:0] rx_data;
  logic               rx_data_ready;

  // Credits
  logic               rx_hdr_crdt;
  logic               rx_dat_crdt;
  logic               tx_hdr_crdt;
  logic               tx_dat_crdt;

  // PHY hooks (§4.4)
  logic               phy_init_done;
  logic               link_error;
  logic               retrain_req;
  logic [1:0]         link_state;

  // Sideband (§4.4 / §5.3)
  logic               sb_tx_valid;
  logic [7:0]         sb_tx_data;
  logic               sb_tx_ready;
  logic               sb_rx_valid;
  logic [7:0]         sb_rx_data;
  logic               sb_rx_ready;
  logic               pm_l1_active;

  // Driver clocking block
  clocking drv_cb @(posedge clk);
    default input #1ns output #1ns;
    input  tx_hdr_valid, tx_hdr;
    output tx_hdr_ready;
    input  tx_data_valid, tx_data;
    output tx_data_ready;
    output rx_hdr_valid, rx_hdr;
    input  rx_hdr_ready;
    output rx_data_valid, rx_data;
    input  rx_data_ready;
    output rx_hdr_crdt, rx_dat_crdt;
    input  tx_hdr_crdt, tx_dat_crdt;
    output phy_init_done, link_error;
    input  retrain_req, link_state;
    output sb_tx_ready, sb_rx_valid, sb_rx_data;
    input  sb_tx_valid, sb_tx_data;
    input  pm_l1_active;
  endclocking

  // Monitor clocking block
  clocking mon_cb @(posedge clk);
    default input #1ns output #1ns;
    input tx_hdr_valid, tx_hdr, tx_hdr_ready;
    input tx_data_valid, tx_data, tx_data_ready;
    input rx_hdr_valid, rx_hdr, rx_hdr_ready;
    input rx_data_valid, rx_data, rx_data_ready;
    input rx_hdr_crdt, rx_dat_crdt, tx_hdr_crdt, tx_dat_crdt;
    input phy_init_done, link_error, retrain_req, link_state;
    input sb_tx_valid, sb_tx_data, sb_tx_ready;
    input pm_l1_active;
  endclocking

  modport driver (clocking drv_cb, input clk, rst_n);
  modport monitor (clocking mon_cb, input clk, rst_n);

endinterface
