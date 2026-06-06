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

  // Status
  logic               link_up;

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
    output link_up;
  endclocking

  // Monitor clocking block
  clocking mon_cb @(posedge clk);
    default input #1ns output #1ns;
    input tx_hdr_valid, tx_hdr, tx_hdr_ready;
    input tx_data_valid, tx_data, tx_data_ready;
    input rx_hdr_valid, rx_hdr, rx_hdr_ready;
    input rx_data_valid, rx_data, rx_data_ready;
    input rx_hdr_crdt, rx_dat_crdt, tx_hdr_crdt, tx_dat_crdt;
    input link_up;
  endclocking

  modport driver (clocking drv_cb, input clk, rst_n);
  modport monitor (clocking mon_cb, input clk, rst_n);

endinterface
