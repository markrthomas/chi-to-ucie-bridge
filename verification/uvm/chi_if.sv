// CHI interface for the CHI-to-UCIe bridge.
interface chi_if (input logic clk, input logic rst_n);
  import chi_ucie_uvm_pkg::*;

  // REQ Channel
  logic               req_valid;
  logic [CHI_REQ_W-1:0] req_data; // Using param-based width for bitstream
  logic               req_ready;

  // WR_DATA Channel
  logic               wr_data_valid;
  logic [CHI_DAT_W-1:0] wr_data;
  logic               wr_data_ready;

  // RSP Channel (Output from Bridge)
  logic               rsp_valid;
  logic [CHI_RSP_W-1:0] rsp_data;
  logic               rsp_ready;

  // COMP_DATA Channel (Output from Bridge)
  logic               comp_data_valid;
  logic [CHI_DAT_W-1:0] comp_data;
  logic               comp_data_ready;

  // Driver clocking block
  clocking drv_cb @(posedge clk);
    default input #1ns output #1ns;
    output req_valid, req_data;
    input  req_ready;
    output wr_data_valid, wr_data;
    input  wr_data_ready;
    input  rsp_valid, rsp_data;
    output rsp_ready;
    input  comp_data_valid, comp_data;
    output comp_data_ready;
  endclocking

  // Monitor clocking block
  clocking mon_cb @(posedge clk);
    default input #1ns output #1ns;
    input req_valid, req_data, req_ready;
    input wr_data_valid, wr_data, wr_data_ready;
    input rsp_valid, rsp_data, rsp_ready;
    input comp_data_valid, comp_data, comp_data_ready;
  endclocking

  modport driver (clocking drv_cb, input clk, rst_n);
  modport monitor (clocking mon_cb, input clk, rst_n);

endinterface
