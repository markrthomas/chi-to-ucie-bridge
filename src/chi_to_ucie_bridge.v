// CHI <-> UCIe bridge.
//
// Phase 2: outstanding transaction tracking. Requests are issued to UCIe with a
// bridge-local tag (allocated from txn_table) rather than the CHI TxnID; the
// original CHI identity is restored from the table when the completion returns.
// Retains the Phase 1 dual-clock async FIFOs, compact UCIe adapter packet model,
// and link readiness gating.

`include "chi_ucie_bridge_defs.vh"

module chi_to_ucie_bridge #(
  parameter integer FIFO_DEPTH      = 8,
  parameter integer TX_HDR_CREDITS  = 8,
  parameter integer TX_DAT_CREDITS  = 8,
  parameter integer MAX_OUTSTANDING = 32
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

  input  wire                     ucie_rx_hdr_crdt,
  input  wire                     ucie_rx_dat_crdt,
  output wire                     ucie_tx_hdr_crdt,
  output wire                     ucie_tx_dat_crdt,

  input  wire                     link_up,
  input  wire                     err_inj_en,
  output wire                     drain_done,
  output reg  [15:0]              crc_err_cnt,
  output reg  [15:0]              tag_err_cnt,
  output reg  [15:0]              drain_cnt
);

  localparam integer LTAG_W = $clog2(MAX_OUTSTANDING);
  localparam integer WQ_AW  = $clog2(MAX_OUTSTANDING);

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
  wire [CHI_DAT_W-1:0] wdat_r_data;
  wire [CHI_RSP_W-1:0] rsp_r_data;
  wire [CHI_DAT_W-1:0] rdat_r_data;

  // UCIe TX accept pulses (declared early; used in the FIFO read enables below).
  wire hdr_fire;
  wire data_fire;

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

  // ---------------------------------------------------------------------------
  // CHI host-domain enqueue
  // ---------------------------------------------------------------------------
  wire chi_req_is_write = is_chi_write(chi_req_data[CHI_REQ_OPCODE_LSB +: CHI_REQ_OPCODE_W]);
  wire chi_req_is_read  = is_chi_read(chi_req_data[CHI_REQ_OPCODE_LSB +: CHI_REQ_OPCODE_W]);
  wire accept_wr_data   = chi_req_is_write && chi_wr_data_valid && !wdat_w_full;
  wire req_supported    = chi_req_is_write || chi_req_is_read;

  assign chi_req_ready = bridge_open && req_supported && !req_w_full &&
                         (!chi_req_is_write || accept_wr_data);
  assign chi_wr_data_ready = bridge_open && chi_req_valid && chi_req_is_write && !req_w_full &&
                             !wdat_w_full;

  wire req_w_en = chi_req_valid && chi_req_ready;
  wire wdat_w_en = req_w_en && chi_req_is_write;
  // The write's UCIe tag comes from the side-queue at data issue, so the data
  // FIFO carries only the payload.

  async_fifo #(.WIDTH(CHI_REQ_W), .DEPTH(FIFO_DEPTH)) u_req_fifo (
    .w_clk(clk), .w_rst_n(clk_rst_n), .w_en(req_w_en), .w_data(chi_req_data), .w_full(req_w_full),
    .r_clk(ucie_clk), .r_rst_n(ucie_rst_n), .r_en(hdr_fire),
    .r_data(req_r_data), .r_empty(req_r_empty)
  );

  async_fifo #(.WIDTH(CHI_DAT_W), .DEPTH(FIFO_DEPTH)) u_wdat_fifo (
    .w_clk(clk), .w_rst_n(clk_rst_n), .w_en(wdat_w_en), .w_data(chi_wr_data), .w_full(wdat_w_full),
    .r_clk(ucie_clk), .r_rst_n(ucie_rst_n), .r_en(data_fire),
    .r_data(wdat_r_data), .r_empty(wdat_r_empty)
  );

  // ---------------------------------------------------------------------------
  // Transaction table (ucie_clk domain)
  // ---------------------------------------------------------------------------
  wire                req_head_is_write = is_chi_write(req_r_data[CHI_REQ_OPCODE_LSB +: CHI_REQ_OPCODE_W]);
  wire [LTAG_W-1:0]   free_tag;
  wire                tbl_full;
  wire                tbl_tag_err;

  // Hold the local tag stable for the whole header handshake. Without this the
  // presented tag could change mid-stall if a completion frees a lower slot,
  // violating valid/ready payload stability. Latch free_tag when a header is
  // first offered; reuse it until the header is accepted.
  reg  [LTAG_W-1:0]   held_tag;
  reg                 held_v;
  wire [LTAG_W-1:0]   present_tag = held_v ? held_tag : free_tag;

  always @(posedge ucie_clk or negedge ucie_rst_n) begin
    if (!ucie_rst_n) begin
      held_v   <= 1'b0;
      held_tag <= {LTAG_W{1'b0}};
    end else if (hdr_fire) begin
      held_v   <= 1'b0;
    end else if (ucie_tx_hdr_valid && !ucie_tx_hdr_ready) begin
      held_tag <= present_tag;
      held_v   <= 1'b1;
    end else if (!ucie_tx_hdr_valid) begin
      held_v   <= 1'b0;
    end
  end

  // ---------------------------------------------------------------------------
  // UCIe TX credit counters (ucie_clk domain)
  // ---------------------------------------------------------------------------
  wire hdr_crdt_avail;
  credit_counter #(.CREDITS(TX_HDR_CREDITS)) u_hdr_crdt (
    .clk(ucie_clk), .rst_n(ucie_rst_n),
    .consume(hdr_fire), .ret(ucie_rx_hdr_crdt),
    .available(hdr_crdt_avail)
  );

  wire dat_crdt_avail;
  credit_counter #(.CREDITS(TX_DAT_CREDITS)) u_dat_crdt (
    .clk(ucie_clk), .rst_n(ucie_rst_n),
    .consume(data_fire), .ret(ucie_rx_dat_crdt),
    .available(dat_crdt_avail)
  );

  wire rx_hdr_fire = ucie_rx_hdr_valid && ucie_rx_hdr_ready;
  wire rx_dat_fire = ucie_rx_data_valid && ucie_rx_data_ready;
  assign ucie_tx_hdr_crdt = rx_hdr_fire;
  assign ucie_tx_dat_crdt = rx_dat_fire;
  wire [LTAG_W-1:0] rx_hdr_tag = ucie_rx_hdr[UCIE_TAG_LSB +: LTAG_W];
  wire [LTAG_W-1:0] rx_dat_tag = ucie_rx_data[UCIE_DATA_HDR_LSB + UCIE_TAG_LSB +: LTAG_W];

  wire [TXNID_W-1:0] a_txnid;
  wire [NODEID_W-1:0] a_srcid;
  wire                a_is_write;
  wire                a_valid;
  wire [TXNID_W-1:0] b_txnid;
  wire [NODEID_W-1:0] b_srcid;
  wire                b_is_write;
  wire                b_valid;
  wire [LTAG_W:0]    outstanding;

  txn_table #(
    .N(MAX_OUTSTANDING), .TID_W(TXNID_W), .SID_W(NODEID_W), .LTAG_W(LTAG_W)
  ) u_txn_table (
    .clk(ucie_clk), .rst_n(ucie_rst_n),
    .alloc_en(hdr_fire),
    .alloc_idx(present_tag),
    .alloc_txnid(req_r_data[CHI_REQ_TXNID_LSB +: TXNID_W]),
    .alloc_srcid(req_r_data[CHI_REQ_SRCID_LSB +: CHI_REQ_SRCID_W]),
    .alloc_is_write(req_head_is_write),
    .free_tag(free_tag),
    .full(tbl_full),
    .a_lookup_tag(rx_hdr_tag), .a_free_en(rx_hdr_fire),
    .a_txnid(a_txnid), .a_srcid(a_srcid), .a_is_write(a_is_write), .a_valid(a_valid),
    .b_lookup_tag(rx_dat_tag), .b_free_en(rx_dat_fire),
    .b_txnid(b_txnid), .b_srcid(b_srcid), .b_is_write(b_is_write), .b_valid(b_valid),
    .outstanding(outstanding), .tag_err(tbl_tag_err)
  );

  // ---------------------------------------------------------------------------
  // Write-data tag side-queue: carries each write's local tag from header issue
  // to data issue and enforces header-before-data ordering on the independent
  // ready paths.
  // ---------------------------------------------------------------------------
  reg [LTAG_W-1:0] wtag_mem [0:MAX_OUTSTANDING-1];
  reg [WQ_AW:0]    wq_wptr;
  reg [WQ_AW:0]    wq_rptr;
  wire wq_empty = (wq_wptr == wq_rptr);
  wire [LTAG_W-1:0] wq_front = wtag_mem[wq_rptr[WQ_AW-1:0]];

  wire wq_push = hdr_fire && req_head_is_write;
  wire wq_pop  = data_fire;

  always @(posedge ucie_clk or negedge ucie_rst_n) begin
    if (!ucie_rst_n) begin
      wq_wptr <= {(WQ_AW+1){1'b0}};
      wq_rptr <= {(WQ_AW+1){1'b0}};
    end else begin
      if (wq_push) begin
        wtag_mem[wq_wptr[WQ_AW-1:0]] <= present_tag;
        wq_wptr <= wq_wptr + 1'b1;
      end
      if (wq_pop) wq_rptr <= wq_rptr + 1'b1;
    end
  end

  // ---------------------------------------------------------------------------
  // Flit sequence counter (ucie_clk domain): increments per issued TX packet.
  // Used by both hdr and data translation functions for sequencing in §4.3.
  // ---------------------------------------------------------------------------
  reg [7:0] flit_seq_ctr;
  always @(posedge ucie_clk or negedge ucie_rst_n) begin
    if (!ucie_rst_n)
      flit_seq_ctr <= 8'h00;
    else
      flit_seq_ctr <= flit_seq_ctr + {7'h0, hdr_fire} + {7'h0, data_fire};
  end
  // When header and data fire simultaneously, data gets the next sequence number.
  wire [7:0] dat_flit_seq = flit_seq_ctr + {7'h0, hdr_fire};

  // ---------------------------------------------------------------------------
  // CHI -> UCIe translation (TX)
  // ---------------------------------------------------------------------------
  function automatic [UCIE_HDR_W-1:0] translate_chi_req_to_ucie;
    input [CHI_REQ_W-1:0] chi_req;
    input [7:0]           local_tag;
    input [7:0]           flit_seq;
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
        local_tag,
        chi_req[CHI_REQ_ADDR_LSB +: 48],
        {5'b0, chi_req[CHI_REQ_SIZE_LSB +: CHI_REQ_SIZE_W]},
        {1'b0, chi_req[CHI_REQ_SRCID_LSB +: CHI_REQ_SRCID_W]},
        attr,
        flit_seq
      );
    end
  endfunction

  function automatic [UCIE_DATA_W-1:0] translate_chi_data_to_ucie;
    input [CHI_DAT_W-1:0] dat;
    input [7:0]           local_tag;
    input [7:0]           flit_seq;
    reg [UCIE_HDR_W-1:0] hdr;
    begin
      hdr = pack_ucie_hdr(
        UCIE_PKT_KIND_AD_REQ,
        UCIE_MSG_MEM_WR_DATA,
        local_tag,
        48'h0000_0000_0000,
        8'h40,
        8'h00,
        dat[CHI_DAT_BE_LSB +: 8],
        flit_seq
      );
      translate_chi_data_to_ucie = {
        hdr,
        dat[CHI_DAT_POISON_LSB +: CHI_DAT_POISON_W],
        dat[CHI_DAT_DATA_LSB +: CHI_DAT_DATA_W]
      };
    end
  endfunction

  assign ucie_tx_hdr_valid = bridge_open_ucie && !req_r_empty && !tbl_full && hdr_crdt_avail;
  assign ucie_tx_hdr = translate_chi_req_to_ucie(req_r_data, {{(8-LTAG_W){1'b0}}, present_tag},
                                                 flit_seq_ctr);
  assign hdr_fire = ucie_tx_hdr_valid && ucie_tx_hdr_ready;

  assign ucie_tx_data_valid = bridge_open_ucie && !wdat_r_empty && !wq_empty && dat_crdt_avail;
  assign ucie_tx_data = translate_chi_data_to_ucie(wdat_r_data, {{(8-LTAG_W){1'b0}}, wq_front},
                                                   dat_flit_seq);
  assign data_fire = ucie_tx_data_valid && ucie_tx_data_ready;

  // ---------------------------------------------------------------------------
  // UCIe -> CHI translation (RX); CHI identity restored from the table
  // ---------------------------------------------------------------------------
  function automatic [CHI_RSP_W-1:0] translate_ucie_hdr_to_chi_rsp;
    input [UCIE_HDR_W-1:0] hdr;
    input [TXNID_W-1:0]    r_txnid;
    input [NODEID_W-1:0]   r_srcid;
    input                  r_valid;
    reg [CHI_RSP_W-1:0] rsp;
    reg ok;
    begin
      ok = ucie_hdr_crc16_ok(hdr) && r_valid &&
           (hdr[UCIE_KIND_MSB:UCIE_KIND_LSB] == UCIE_PKT_KIND_AD_CPL) &&
           (hdr[UCIE_CODE_MSB:UCIE_CODE_LSB] == UCIE_CPL_SC);
      rsp = {CHI_RSP_W{1'b0}};
      rsp[CHI_RSP_RESPERR_LSB +: CHI_RSP_RESPERR_W] = ok ? CHI_RESPERR_OK : CHI_RESPERR_NDERR;
      rsp[CHI_RSP_DBID_LSB +: CHI_RSP_DBID_W]       = r_txnid[CHI_RSP_DBID_W-1:0];
      rsp[CHI_RSP_TXNID_LSB +: CHI_RSP_TXNID_W]     = r_txnid;
      rsp[CHI_RSP_OPCODE_LSB +: CHI_RSP_OPCODE_W]   = CHI_RSP_COMP;
      rsp[CHI_RSP_SRCID_LSB +: CHI_RSP_SRCID_W]     = r_srcid;
      translate_ucie_hdr_to_chi_rsp = rsp;
    end
  endfunction

  function automatic [CHI_DAT_W-1:0] translate_ucie_data_to_chi;
    input [UCIE_DATA_W-1:0] pkt;
    input [TXNID_W-1:0]     r_txnid;
    input                   r_valid;
    reg [UCIE_HDR_W-1:0] hdr;
    reg [CHI_DAT_W-1:0] dat;
    reg ok;
    begin
      hdr = pkt[UCIE_DATA_HDR_LSB +: UCIE_HDR_W];
      ok = ucie_hdr_crc16_ok(hdr) && r_valid &&
           (hdr[UCIE_KIND_MSB:UCIE_KIND_LSB] == UCIE_PKT_KIND_MEM_CPL) &&
           (hdr[UCIE_CODE_MSB:UCIE_CODE_LSB] == UCIE_CPL_SC);
      dat = {CHI_DAT_W{1'b0}};
      dat[CHI_DAT_DATA_LSB +: CHI_DAT_DATA_W]       = pkt[UCIE_DATA_PAYLOAD_LSB +: DATA_W];
      dat[CHI_DAT_BE_LSB +: CHI_DAT_BE_W]           = {BE_W{1'b1}};
      dat[CHI_DAT_POISON_LSB +: CHI_DAT_POISON_W]   = pkt[UCIE_DATA_POISON_LSB];
      dat[CHI_DAT_DATAID_LSB +: CHI_DAT_DATAID_W]   = 4'h0;
      dat[CHI_DAT_RESPERR_LSB +: CHI_DAT_RESPERR_W] = ok ? CHI_RESPERR_OK : CHI_RESPERR_DERR;
      dat[CHI_DAT_RESP_LSB +: CHI_DAT_RESP_W]       = CHI_CACHE_I;
      dat[CHI_DAT_TXNID_LSB +: CHI_DAT_TXNID_W]     = r_txnid;
      dat[CHI_DAT_OPCODE_LSB +: CHI_DAT_OPCODE_W]   = CHI_DAT_COMPDATA;
      translate_ucie_data_to_chi = dat;
    end
  endfunction

  assign ucie_rx_hdr_ready = bridge_open_ucie && !rsp_w_full;
  assign ucie_rx_data_ready = bridge_open_ucie && !rdat_w_full;

  wire rx_hdr_bad = rx_hdr_fire && !ucie_hdr_crc16_ok(ucie_rx_hdr);
  wire rx_dat_bad = rx_dat_fire && !ucie_hdr_crc16_ok(ucie_rx_data[UCIE_DATA_HDR_LSB +: UCIE_HDR_W]);

  async_fifo #(.WIDTH(CHI_RSP_W), .DEPTH(FIFO_DEPTH)) u_rsp_fifo (
    .w_clk(ucie_clk), .w_rst_n(ucie_rst_n), .w_en(rx_hdr_fire),
    .w_data(translate_ucie_hdr_to_chi_rsp(ucie_rx_hdr, a_txnid, a_srcid, a_valid)), .w_full(rsp_w_full),
    .r_clk(clk), .r_rst_n(clk_rst_n), .r_en(chi_rsp_valid && chi_rsp_ready),
    .r_data(rsp_r_data), .r_empty(rsp_r_empty)
  );

  async_fifo #(.WIDTH(CHI_DAT_W), .DEPTH(FIFO_DEPTH)) u_rdat_fifo (
    .w_clk(ucie_clk), .w_rst_n(ucie_rst_n), .w_en(rx_dat_fire),
    .w_data(translate_ucie_data_to_chi(ucie_rx_data, b_txnid, b_valid)), .w_full(rdat_w_full),
    .r_clk(clk), .r_rst_n(clk_rst_n), .r_en(chi_comp_data_valid && chi_comp_data_ready),
    .r_data(rdat_r_data), .r_empty(rdat_r_empty)
  );

  assign chi_rsp_valid = !rsp_r_empty;
  assign chi_rsp_data = rsp_r_data;
  assign chi_comp_data_valid = !rdat_r_empty;
  assign chi_comp_data = rdat_r_data;

  // ---------------------------------------------------------------------------
  // Error / status counters
  // ---------------------------------------------------------------------------
  always @(posedge ucie_clk or negedge ucie_rst_n) begin
    if (!ucie_rst_n) begin
      crc_err_cnt <= 16'h0000;
    end else if (err_inj_en || rx_hdr_bad || rx_dat_bad) begin
      crc_err_cnt <= crc_err_cnt + 16'h0001;
    end
  end

  always @(posedge ucie_clk or negedge ucie_rst_n) begin
    if (!ucie_rst_n) begin
      tag_err_cnt <= 16'h0000;
    end else if (tbl_tag_err) begin
      tag_err_cnt <= tag_err_cnt + 16'h0001;
    end
  end

  always @(posedge clk or negedge clk_rst_n) begin
    if (!clk_rst_n) begin
      drain_cnt <= 16'h0000;
    end else if (!link_up_clk && !drain_done) begin
      drain_cnt <= drain_cnt + 16'h0001;
    end
  end

`ifdef FORMAL
  // ---- Single-cycle TX-path invariants (ucie_clk domain) ----
  // These are CDC-independent and prove without FIFO reachability constraints.
  always @(posedge ucie_clk) begin
    if (ucie_rst_n) begin
      assert (ucie_hdr_crc16_ok(ucie_tx_hdr));
      assert (ucie_hdr_crc16_ok(ucie_tx_data[UCIE_DATA_HDR_LSB +: UCIE_HDR_W]));
      assert (!ucie_tx_data_valid || !wq_empty);
    end
  end

  // ---- Temporal handshake invariants ($past-based for yosys compatibility) ----
  // f_*_past_valid prevents $past from being evaluated before the first real
  // clock edge (where $past returns X and all conditions become false).
  reg f_ucie_past_valid;
  reg f_chi_past_valid;
  initial begin
    f_ucie_past_valid = 0;
    f_chi_past_valid  = 0;
  end
  always @(posedge ucie_clk) f_ucie_past_valid <= ucie_rst_n;
  always @(posedge clk)      f_chi_past_valid  <= clk_rst_n;

  // UCIe TX path: a stalled valid header stays valid and payload-stable until
  // either it is accepted or the link closes.  With the async-FIFO CDC assumes
  // in place, the req_fifo read-side state can no longer transition spuriously,
  // making these properties provable at depth 8.
  always @(posedge ucie_clk) begin
    if (ucie_rst_n && f_ucie_past_valid) begin
      if ($past(ucie_tx_hdr_valid) && !$past(ucie_tx_hdr_ready) &&
          $past(bridge_open_ucie) && $past(ucie_rst_n)) begin
        assert (ucie_tx_hdr_valid  || !bridge_open_ucie);
        assert ($stable(ucie_tx_hdr) || !bridge_open_ucie);
      end
    end
  end

  // CHI completion outputs (clk domain): a presented completion holds valid
  // and stable payload until the consumer accepts it.
  always @(posedge clk) begin
    if (clk_rst_n && f_chi_past_valid) begin
      if ($past(chi_rsp_valid) && !$past(chi_rsp_ready)) begin
        assert (chi_rsp_valid);
        assert ($stable(chi_rsp_data));
      end
      if ($past(chi_comp_data_valid) && !$past(chi_comp_data_ready)) begin
        assert (chi_comp_data_valid);
        assert ($stable(chi_comp_data));
      end
    end
  end
`endif

endmodule
