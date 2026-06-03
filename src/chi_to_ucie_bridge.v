// CHI <-> UCIe bridge.
//
// Phase 1 baseline: dual-clock async FIFOs, compact UCIe adapter packet model,
// link readiness gating, and directed-testable CHI read/write/completion paths.

`include "chi_ucie_bridge_defs.vh"

module chi_to_ucie_bridge #(
  parameter integer FIFO_DEPTH     = 8,
  parameter integer POSTED_CREDITS = 8,
  parameter integer NP_CREDITS     = 8
) (
  input  wire                     clk,
  input  wire                     ucie_clk,
  input  wire                     rst_n,

  input  wire                     chi_req_valid,
  input  wire [CHI_REQ_W-1:0]     chi_req_data,
  output wire                     chi_req_ready,

  input  wire                     chi_wr_data_valid,
  input  wire [CHI_DAT_W-1:0]     chi_wr_data,
  output wire                     chi_wr_data_ready,

  output wire                     chi_rsp_valid,
  output wire [CHI_RSP_W-1:0]     chi_rsp_data,
  input  wire                     chi_rsp_ready,

  output wire                     chi_comp_data_valid,
  output wire [CHI_DAT_W-1:0]     chi_comp_data,
  input  wire                     chi_comp_data_ready,

  output wire                     ucie_tx_hdr_valid,
  output wire [UCIE_HDR_W-1:0]    ucie_tx_hdr,
  input  wire                     ucie_tx_hdr_ready,

  output wire                     ucie_tx_data_valid,
  output wire [UCIE_DATA_W-1:0]   ucie_tx_data,
  input  wire                     ucie_tx_data_ready,

  input  wire                     ucie_rx_hdr_valid,
  input  wire [UCIE_HDR_W-1:0]    ucie_rx_hdr,
  output wire                     ucie_rx_hdr_ready,

  input  wire                     ucie_rx_data_valid,
  input  wire [UCIE_DATA_W-1:0]   ucie_rx_data,
  output wire                     ucie_rx_data_ready,

  input  wire                     link_up,
  input  wire                     err_inj_en,
  output wire                     drain_done,
  output reg  [15:0]              crc_err_cnt,
  output reg  [15:0]              drain_cnt
);

  wire clk_rst_n;
  wire ucie_rst_n;

  reset_sync #(.STAGES(2)) u_clk_rst_sync (
    .clk(clk), .async_rst_n(rst_n), .sync_rst_n(clk_rst_n)
  );

  reset_sync #(.STAGES(2)) u_ucie_rst_sync (
    .clk(ucie_clk), .async_rst_n(rst_n), .sync_rst_n(ucie_rst_n)
  );

  wire link_up_clk;
  cdc_sync #(.STAGES(2)) u_link_up_cdc (
    .clk(clk), .rst_n(clk_rst_n), .d(link_up), .q(link_up_clk)
  );

  wire req_w_full;
  wire req_r_empty;
  wire wdat_w_full;
  wire wdat_r_empty;
  wire rsp_w_full;
  wire rsp_r_empty;
  wire rdat_w_full;
  wire rdat_r_empty;

  wire [CHI_REQ_W-1:0] req_r_data;
  wire [TXNID_W+CHI_DAT_W-1:0] wdat_r_data;
  wire [CHI_RSP_W-1:0] rsp_r_data;
  wire [CHI_DAT_W-1:0] rdat_r_data;

  wire req_r_empty_clk;
  wire wdat_r_empty_clk;
  cdc_sync #(.STAGES(2)) u_req_empty_cdc (
    .clk(clk), .rst_n(clk_rst_n), .d(req_r_empty), .q(req_r_empty_clk)
  );
  cdc_sync #(.STAGES(2)) u_wdat_empty_cdc (
    .clk(clk), .rst_n(clk_rst_n), .d(wdat_r_empty), .q(wdat_r_empty_clk)
  );

  wire all_empty = req_r_empty_clk && wdat_r_empty_clk && rsp_r_empty && rdat_r_empty;
  wire bridge_open;
  reset_drain u_reset_drain (
    .clk(clk),
    .rst_n(clk_rst_n),
    .link_up(link_up_clk),
    .all_empty(all_empty),
    .open(bridge_open),
    .drain_done(drain_done)
  );

  wire bridge_open_ucie;
  cdc_sync #(.STAGES(2)) u_open_cdc (
    .clk(ucie_clk), .rst_n(ucie_rst_n), .d(bridge_open), .q(bridge_open_ucie)
  );

  wire chi_req_is_write = is_chi_write(chi_req_data[CHI_REQ_OPCODE_LSB +: CHI_REQ_OPCODE_W]);
  wire chi_req_is_read  = is_chi_read(chi_req_data[CHI_REQ_OPCODE_LSB +: CHI_REQ_OPCODE_W]);
  wire accept_wr_data   = chi_req_is_write && chi_wr_data_valid && !wdat_w_full;
  wire req_class_space  = chi_req_is_write ? (POSTED_CREDITS > 0) : (NP_CREDITS > 0);
  wire req_supported    = chi_req_is_write || chi_req_is_read;

  assign chi_req_ready = bridge_open && req_supported && req_class_space && !req_w_full &&
                         (!chi_req_is_write || accept_wr_data);
  assign chi_wr_data_ready = bridge_open && chi_req_valid && chi_req_is_write && !req_w_full &&
                             !wdat_w_full;

  wire req_w_en = chi_req_valid && chi_req_ready;
  wire wdat_w_en = req_w_en && chi_req_is_write;
  wire [TXNID_W+CHI_DAT_W-1:0] wdat_w_data = {
    chi_req_data[CHI_REQ_TXNID_LSB +: TXNID_W], chi_wr_data
  };

  async_fifo #(.WIDTH(CHI_REQ_W), .DEPTH(FIFO_DEPTH)) u_req_fifo (
    .w_clk(clk), .w_rst_n(clk_rst_n), .w_en(req_w_en), .w_data(chi_req_data), .w_full(req_w_full),
    .r_clk(ucie_clk), .r_rst_n(ucie_rst_n), .r_en(ucie_tx_hdr_valid && ucie_tx_hdr_ready),
    .r_data(req_r_data), .r_empty(req_r_empty)
  );

  async_fifo #(.WIDTH(TXNID_W+CHI_DAT_W), .DEPTH(FIFO_DEPTH)) u_wdat_fifo (
    .w_clk(clk), .w_rst_n(clk_rst_n), .w_en(wdat_w_en), .w_data(wdat_w_data), .w_full(wdat_w_full),
    .r_clk(ucie_clk), .r_rst_n(ucie_rst_n), .r_en(ucie_tx_data_valid && ucie_tx_data_ready),
    .r_data(wdat_r_data), .r_empty(wdat_r_empty)
  );

  function automatic [UCIE_HDR_W-1:0] translate_chi_req_to_ucie;
    input [CHI_REQ_W-1:0] chi_req;
    reg [3:0] msg;
    reg [7:0] attr;
    begin
      msg = is_chi_write(chi_req[CHI_REQ_OPCODE_LSB +: CHI_REQ_OPCODE_W]) ?
            UCIE_MSG_MEM_WR : UCIE_MSG_MEM_RD;
      attr = {2'b00,
              chi_req[CHI_REQ_ORDER_LSB +: CHI_REQ_ORDER_W],
              chi_req[CHI_REQ_MEMATTR_LSB +: CHI_REQ_MEMATTR_W]};
      translate_chi_req_to_ucie = pack_ucie_hdr(
        UCIE_PKT_KIND_AD_REQ,
        msg,
        chi_req[CHI_REQ_TXNID_LSB +: TXNID_W],
        chi_req[CHI_REQ_ADDR_LSB +: 16],
        {5'b0, chi_req[CHI_REQ_SIZE_LSB +: CHI_REQ_SIZE_W]},
        {1'b0, chi_req[CHI_REQ_SRCID_LSB +: CHI_REQ_SRCID_W]},
        attr
      );
    end
  endfunction

  function automatic [UCIE_DATA_W-1:0] translate_chi_data_to_ucie;
    input [TXNID_W+CHI_DAT_W-1:0] item;
    reg [CHI_DAT_W-1:0] dat;
    reg [UCIE_HDR_W-1:0] hdr;
    begin
      dat = item[CHI_DAT_W-1:0];
      hdr = pack_ucie_hdr(
        UCIE_PKT_KIND_AD_REQ,
        UCIE_MSG_MEM_WR_DATA,
        item[CHI_DAT_W +: TXNID_W],
        16'h0000,
        8'h40,
        8'h00,
        dat[CHI_DAT_BE_LSB +: 8]
      );
      translate_chi_data_to_ucie = {
        hdr,
        dat[CHI_DAT_POISON_LSB +: CHI_DAT_POISON_W],
        dat[CHI_DAT_DATA_LSB +: CHI_DAT_DATA_W]
      };
    end
  endfunction

  assign ucie_tx_hdr_valid = bridge_open_ucie && !req_r_empty;
  assign ucie_tx_hdr = translate_chi_req_to_ucie(req_r_data);

  assign ucie_tx_data_valid = bridge_open_ucie && !wdat_r_empty;
  assign ucie_tx_data = translate_chi_data_to_ucie(wdat_r_data);

  function automatic [CHI_RSP_W-1:0] translate_ucie_hdr_to_chi_rsp;
    input [UCIE_HDR_W-1:0] hdr;
    reg [CHI_RSP_W-1:0] rsp;
    reg ok;
    begin
      ok = ucie_hdr_checksum_ok(hdr) &&
           (hdr[UCIE_KIND_MSB:UCIE_KIND_LSB] == UCIE_PKT_KIND_AD_CPL) &&
           (hdr[UCIE_CODE_MSB:UCIE_CODE_LSB] == UCIE_CPL_SC);
      rsp = {CHI_RSP_W{1'b0}};
      rsp[CHI_RSP_RESPERR_LSB +: CHI_RSP_RESPERR_W] = ok ? CHI_RESPERR_OK : CHI_RESPERR_NDERR;
      rsp[CHI_RSP_DBID_LSB +: CHI_RSP_DBID_W]       = hdr[UCIE_TAG_LSB +: CHI_RSP_DBID_W];
      rsp[CHI_RSP_TXNID_LSB +: CHI_RSP_TXNID_W]     = hdr[UCIE_TAG_LSB +: TXNID_W];
      rsp[CHI_RSP_OPCODE_LSB +: CHI_RSP_OPCODE_W]   = CHI_RSP_COMP;
      rsp[CHI_RSP_SRCID_LSB +: CHI_RSP_SRCID_W]     = hdr[UCIE_ID_LSB +: CHI_RSP_SRCID_W];
      translate_ucie_hdr_to_chi_rsp = rsp;
    end
  endfunction

  function automatic [CHI_DAT_W-1:0] translate_ucie_data_to_chi;
    input [UCIE_DATA_W-1:0] pkt;
    reg [UCIE_HDR_W-1:0] hdr;
    reg [CHI_DAT_W-1:0] dat;
    reg ok;
    begin
      hdr = pkt[UCIE_DATA_HDR_LSB +: UCIE_HDR_W];
      ok = ucie_hdr_checksum_ok(hdr) &&
           (hdr[UCIE_KIND_MSB:UCIE_KIND_LSB] == UCIE_PKT_KIND_MEM_CPL) &&
           (hdr[UCIE_CODE_MSB:UCIE_CODE_LSB] == UCIE_CPL_SC);
      dat = {CHI_DAT_W{1'b0}};
      dat[CHI_DAT_DATA_LSB +: CHI_DAT_DATA_W]       = pkt[UCIE_DATA_PAYLOAD_LSB +: DATA_W];
      dat[CHI_DAT_BE_LSB +: CHI_DAT_BE_W]           = {BE_W{1'b1}};
      dat[CHI_DAT_POISON_LSB +: CHI_DAT_POISON_W]   = pkt[UCIE_DATA_POISON_LSB];
      dat[CHI_DAT_DATAID_LSB +: CHI_DAT_DATAID_W]   = 4'h0;
      dat[CHI_DAT_RESPERR_LSB +: CHI_DAT_RESPERR_W] = ok ? CHI_RESPERR_OK : CHI_RESPERR_DERR;
      dat[CHI_DAT_RESP_LSB +: CHI_DAT_RESP_W]       = CHI_CACHE_I;
      dat[CHI_DAT_TXNID_LSB +: CHI_DAT_TXNID_W]     = hdr[UCIE_TAG_LSB +: TXNID_W];
      dat[CHI_DAT_OPCODE_LSB +: CHI_DAT_OPCODE_W]   = CHI_DAT_COMPDATA;
      translate_ucie_data_to_chi = dat;
    end
  endfunction

  assign ucie_rx_hdr_ready = bridge_open_ucie && !rsp_w_full;
  assign ucie_rx_data_ready = bridge_open_ucie && !rdat_w_full;

  wire rx_hdr_fire = ucie_rx_hdr_valid && ucie_rx_hdr_ready;
  wire rx_dat_fire = ucie_rx_data_valid && ucie_rx_data_ready;
  wire rx_hdr_bad = rx_hdr_fire && !ucie_hdr_checksum_ok(ucie_rx_hdr);
  wire rx_dat_bad = rx_dat_fire && !ucie_hdr_checksum_ok(ucie_rx_data[UCIE_DATA_HDR_LSB +: UCIE_HDR_W]);

  async_fifo #(.WIDTH(CHI_RSP_W), .DEPTH(FIFO_DEPTH)) u_rsp_fifo (
    .w_clk(ucie_clk), .w_rst_n(ucie_rst_n), .w_en(rx_hdr_fire),
    .w_data(translate_ucie_hdr_to_chi_rsp(ucie_rx_hdr)), .w_full(rsp_w_full),
    .r_clk(clk), .r_rst_n(clk_rst_n), .r_en(chi_rsp_valid && chi_rsp_ready),
    .r_data(rsp_r_data), .r_empty(rsp_r_empty)
  );

  async_fifo #(.WIDTH(CHI_DAT_W), .DEPTH(FIFO_DEPTH)) u_rdat_fifo (
    .w_clk(ucie_clk), .w_rst_n(ucie_rst_n), .w_en(rx_dat_fire),
    .w_data(translate_ucie_data_to_chi(ucie_rx_data)), .w_full(rdat_w_full),
    .r_clk(clk), .r_rst_n(clk_rst_n), .r_en(chi_comp_data_valid && chi_comp_data_ready),
    .r_data(rdat_r_data), .r_empty(rdat_r_empty)
  );

  assign chi_rsp_valid = !rsp_r_empty;
  assign chi_rsp_data = rsp_r_data;
  assign chi_comp_data_valid = !rdat_r_empty;
  assign chi_comp_data = rdat_r_data;

  always @(posedge ucie_clk or negedge ucie_rst_n) begin
    if (!ucie_rst_n) begin
      crc_err_cnt <= 16'h0000;
    end else if (err_inj_en || rx_hdr_bad || rx_dat_bad) begin
      crc_err_cnt <= crc_err_cnt + 16'h0001;
    end
  end

  always @(posedge clk or negedge clk_rst_n) begin
    if (!clk_rst_n) begin
      drain_cnt <= 16'h0000;
    end else if (!link_up_clk && !drain_done) begin
      drain_cnt <= drain_cnt + 16'h0001;
    end
  end

endmodule
