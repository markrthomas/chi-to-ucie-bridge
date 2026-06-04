`timescale 1ns / 1ps

`include "chi_ucie_bridge_defs.vh"

module tb_chi_to_ucie_bridge;

  localparam integer FIFO_DEPTH = 8;

  reg clk;
  reg ucie_clk;
  reg rst_n;

  reg                  chi_req_valid;
  reg [CHI_REQ_W-1:0]  chi_req_data;
  wire                 chi_req_ready;

  reg                  chi_wr_data_valid;
  reg [CHI_DAT_W-1:0]  chi_wr_data;
  wire                 chi_wr_data_ready;

  wire                 chi_rsp_valid;
  wire [CHI_RSP_W-1:0] chi_rsp_data;
  reg                  chi_rsp_ready;

  wire                 chi_comp_data_valid;
  wire [CHI_DAT_W-1:0] chi_comp_data;
  reg                  chi_comp_data_ready;

  wire                  ucie_tx_hdr_valid;
  wire [UCIE_HDR_W-1:0] ucie_tx_hdr;
  reg                   ucie_tx_hdr_ready;

  wire                   ucie_tx_data_valid;
  wire [UCIE_DATA_W-1:0] ucie_tx_data;
  reg                    ucie_tx_data_ready;

  reg                   ucie_rx_hdr_valid;
  reg [UCIE_HDR_W-1:0]  ucie_rx_hdr;
  wire                  ucie_rx_hdr_ready;

  reg                    ucie_rx_data_valid;
  reg [UCIE_DATA_W-1:0]  ucie_rx_data;
  wire                   ucie_rx_data_ready;

  reg         link_up;
  reg         err_inj_en;
  wire        drain_done;
  wire [15:0] crc_err_cnt;
  wire [15:0] drain_cnt;

  chi_to_ucie_bridge #(
    .FIFO_DEPTH(FIFO_DEPTH)
  ) dut (
    .clk(clk),
    .ucie_clk(ucie_clk),
    .rst_n(rst_n),
    .chi_req_valid(chi_req_valid),
    .chi_req_data(chi_req_data),
    .chi_req_ready(chi_req_ready),
    .chi_wr_data_valid(chi_wr_data_valid),
    .chi_wr_data(chi_wr_data),
    .chi_wr_data_ready(chi_wr_data_ready),
    .chi_rsp_valid(chi_rsp_valid),
    .chi_rsp_data(chi_rsp_data),
    .chi_rsp_ready(chi_rsp_ready),
    .chi_comp_data_valid(chi_comp_data_valid),
    .chi_comp_data(chi_comp_data),
    .chi_comp_data_ready(chi_comp_data_ready),
    .ucie_tx_hdr_valid(ucie_tx_hdr_valid),
    .ucie_tx_hdr(ucie_tx_hdr),
    .ucie_tx_hdr_ready(ucie_tx_hdr_ready),
    .ucie_tx_data_valid(ucie_tx_data_valid),
    .ucie_tx_data(ucie_tx_data),
    .ucie_tx_data_ready(ucie_tx_data_ready),
    .ucie_rx_hdr_valid(ucie_rx_hdr_valid),
    .ucie_rx_hdr(ucie_rx_hdr),
    .ucie_rx_hdr_ready(ucie_rx_hdr_ready),
    .ucie_rx_data_valid(ucie_rx_data_valid),
    .ucie_rx_data(ucie_rx_data),
    .ucie_rx_data_ready(ucie_rx_data_ready),
    .link_up(link_up),
    .err_inj_en(err_inj_en),
    .drain_done(drain_done),
    .crc_err_cnt(crc_err_cnt),
    .drain_cnt(drain_cnt)
  );

  chi_to_ucie_bridge_chk u_chk (
    .clk(ucie_clk),
    .rst_n(rst_n),
    .chi_req_valid(1'b0),
    .chi_req_ready(1'b0),
    .chi_req_data({CHI_REQ_W{1'b0}}),
    .ucie_tx_hdr_valid(ucie_tx_hdr_valid),
    .ucie_tx_hdr_ready(ucie_tx_hdr_ready),
    .ucie_tx_hdr(ucie_tx_hdr)
  );

  always #5 clk = ~clk;
  always #3 ucie_clk = ~ucie_clk;

  task automatic reset_tb;
    begin
      rst_n = 1'b0;
      chi_req_valid = 1'b0;
      chi_req_data = {CHI_REQ_W{1'b0}};
      chi_wr_data_valid = 1'b0;
      chi_wr_data = {CHI_DAT_W{1'b0}};
      chi_rsp_ready = 1'b0;
      chi_comp_data_ready = 1'b0;
      ucie_tx_hdr_ready = 1'b0;
      ucie_tx_data_ready = 1'b0;
      ucie_rx_hdr_valid = 1'b0;
      ucie_rx_hdr = {UCIE_HDR_W{1'b0}};
      ucie_rx_data_valid = 1'b0;
      ucie_rx_data = {UCIE_DATA_W{1'b0}};
      link_up = 1'b0;
      err_inj_en = 1'b0;
      repeat (8) @(posedge clk);
      rst_n = 1'b1;
      link_up = 1'b1;
      repeat (8) @(posedge clk);
      repeat (4) @(posedge ucie_clk);
    end
  endtask

  task automatic send_chi_read;
    input [7:0] txnid;
    input [47:0] addr;
    begin
      @(posedge clk);
      chi_req_data = {CHI_REQ_W{1'b0}};
      chi_req_data[CHI_REQ_OPCODE_LSB +: CHI_REQ_OPCODE_W] = CHI_REQ_READNOSNP;
      chi_req_data[CHI_REQ_ADDR_LSB +: CHI_REQ_ADDR_W] = addr;
      chi_req_data[CHI_REQ_TXNID_LSB +: CHI_REQ_TXNID_W] = txnid;
      chi_req_data[CHI_REQ_SRCID_LSB +: CHI_REQ_SRCID_W] = 7'h12;
      chi_req_data[CHI_REQ_SIZE_LSB +: CHI_REQ_SIZE_W] = 3'h6;
      chi_req_valid = 1'b1;
      while (!chi_req_ready) @(posedge clk);
      @(posedge clk);
      chi_req_valid = 1'b0;
    end
  endtask

  task automatic send_chi_write;
    input [7:0] txnid;
    input [47:0] addr;
    input [511:0] data;
    begin
      @(posedge clk);
      chi_req_data = {CHI_REQ_W{1'b0}};
      chi_req_data[CHI_REQ_OPCODE_LSB +: CHI_REQ_OPCODE_W] = CHI_REQ_WRITENOSNPFULL;
      chi_req_data[CHI_REQ_ADDR_LSB +: CHI_REQ_ADDR_W] = addr;
      chi_req_data[CHI_REQ_TXNID_LSB +: CHI_REQ_TXNID_W] = txnid;
      chi_req_data[CHI_REQ_SRCID_LSB +: CHI_REQ_SRCID_W] = 7'h34;
      chi_req_data[CHI_REQ_SIZE_LSB +: CHI_REQ_SIZE_W] = 3'h6;
      chi_wr_data = {CHI_DAT_W{1'b0}};
      chi_wr_data[CHI_DAT_OPCODE_LSB +: CHI_DAT_OPCODE_W] = CHI_DAT_NCBWRDATA;
      chi_wr_data[CHI_DAT_TXNID_LSB +: CHI_DAT_TXNID_W] = txnid;
      chi_wr_data[CHI_DAT_BE_LSB +: CHI_DAT_BE_W] = {BE_W{1'b1}};
      chi_wr_data[CHI_DAT_DATA_LSB +: CHI_DAT_DATA_W] = data;
      chi_req_valid = 1'b1;
      chi_wr_data_valid = 1'b1;
      while (!chi_req_ready) @(posedge clk);
      @(posedge clk);
      chi_req_valid = 1'b0;
      chi_wr_data_valid = 1'b0;
    end
  endtask

  function automatic [UCIE_DATA_W-1:0] pack_rx_data;
    input [7:0] tag;
    input [511:0] data;
    reg [63:0] hdr;
    begin
      hdr = pack_ucie_hdr(UCIE_PKT_KIND_MEM_CPL, UCIE_CPL_SC, tag, 16'h0040, 8'h40, 8'h55, 8'h00);
      pack_rx_data = {hdr, 1'b0, data};
    end
  endfunction

  initial begin
    clk = 1'b0;
    ucie_clk = 1'b0;

    if ($test$plusargs("vcd")) begin
      $dumpfile("build/waves.vcd");
      $dumpvars(0, tb_chi_to_ucie_bridge);
    end

    reset_tb();

    $display("INFO: CHI read -> UCIe AD_REQ smoke");
    ucie_tx_hdr_ready = 1'b1;
    send_chi_read(8'h3c, 48'hBEEF_CAFE_1234);
    wait (ucie_tx_hdr_valid);
    if (ucie_tx_hdr[UCIE_KIND_MSB:UCIE_KIND_LSB] !== UCIE_PKT_KIND_AD_REQ) begin
      $display("FAIL: expected UCIe AD_REQ"); $finish(1);
    end
    if (ucie_tx_hdr[UCIE_CODE_MSB:UCIE_CODE_LSB] !== UCIE_MSG_MEM_RD) begin
      $display("FAIL: expected UCIe MEM_RD"); $finish(1);
    end
    if (ucie_tx_hdr[UCIE_TAG_MSB:UCIE_TAG_LSB] !== 8'h3c) begin
      $display("FAIL: read tag mismatch"); $finish(1);
    end
    if (ucie_tx_hdr[UCIE_ADDR_MSB:UCIE_ADDR_LSB] !== 16'h1234) begin
      $display("FAIL: read address low16 mismatch"); $finish(1);
    end
    @(posedge ucie_clk);

    $display("INFO: CHI write -> UCIe AD_REQ + DATA smoke");
    ucie_tx_data_ready = 1'b1;
    send_chi_write(8'hd2, 48'hDEAD_BEEF_5678,
                   512'h12345678_9ABCDEF0_FEDCBA98_76543210_11223344_55667788_99AABBCC_DDEEFF00);
    wait (ucie_tx_hdr_valid);
    if (ucie_tx_hdr[UCIE_CODE_MSB:UCIE_CODE_LSB] !== UCIE_MSG_MEM_WR) begin
      $display("FAIL: expected UCIe MEM_WR"); $finish(1);
    end
    wait (ucie_tx_data_valid);
    if (ucie_tx_data[UCIE_DATA_HDR_LSB + UCIE_CODE_LSB +: 4] !== UCIE_MSG_MEM_WR_DATA) begin
      $display("FAIL: expected UCIe write data packet"); $finish(1);
    end
    if (ucie_tx_data[UCIE_DATA_PAYLOAD_LSB +: 512] !==
        512'h12345678_9ABCDEF0_FEDCBA98_76543210_11223344_55667788_99AABBCC_DDEEFF00) begin
      $display("FAIL: write data payload mismatch"); $finish(1);
    end
    @(posedge ucie_clk);

    $display("INFO: UCIe AD_CPL -> CHI RSP smoke");
    chi_rsp_ready = 1'b1;
    @(posedge ucie_clk);
    ucie_rx_hdr = pack_ucie_hdr(UCIE_PKT_KIND_AD_CPL, UCIE_CPL_SC, 8'hd2, 16'h0000, 8'h00, 8'h55, 8'h00);
    ucie_rx_hdr_valid = 1'b1;
    while (!ucie_rx_hdr_ready) @(posedge ucie_clk);
    @(posedge ucie_clk);
    ucie_rx_hdr_valid = 1'b0;
    wait (chi_rsp_valid);
    if (chi_rsp_data[CHI_RSP_OPCODE_LSB +: CHI_RSP_OPCODE_W] !== CHI_RSP_COMP) begin
      $display("FAIL: expected CHI Comp"); $finish(1);
    end
    if (chi_rsp_data[CHI_RSP_TXNID_LSB +: CHI_RSP_TXNID_W] !== 8'hd2) begin
      $display("FAIL: CHI response TxnID mismatch"); $finish(1);
    end
    @(posedge clk);

    $display("INFO: UCIe MEM_CPL data -> CHI CompData smoke");
    chi_comp_data_ready = 1'b1;
    @(posedge ucie_clk);
    ucie_rx_data = pack_rx_data(8'h3c, 512'hFEEDFACE_CAFEBABE_DEADC0DE_00000001);
    ucie_rx_data_valid = 1'b1;
    while (!ucie_rx_data_ready) @(posedge ucie_clk);
    @(posedge ucie_clk);
    ucie_rx_data_valid = 1'b0;
    wait (chi_comp_data_valid);
    if (chi_comp_data[CHI_DAT_OPCODE_LSB +: CHI_DAT_OPCODE_W] !== CHI_DAT_COMPDATA) begin
      $display("FAIL: expected CHI CompData"); $finish(1);
    end
    if (chi_comp_data[CHI_DAT_TXNID_LSB +: CHI_DAT_TXNID_W] !== 8'h3c) begin
      $display("FAIL: CHI data TxnID mismatch"); $finish(1);
    end
    if (chi_comp_data[CHI_DAT_DATA_LSB +: 64] !== 64'hDEADC0DE_00000001) begin
      $display("FAIL: CHI data payload mismatch"); $finish(1);
    end

    $display("PASS CHI-to-UCIe bridge directed smoke");
    $finish(0);
  end

endmodule
