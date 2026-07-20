// CHI <-> UCIe bridge.
//
// Phase 2: outstanding transaction tracking. Requests are issued to UCIe with a
// bridge-local tag (allocated from txn_table) rather than the CHI TxnID; the
// original CHI identity is restored from the table when the completion returns.
// Retains the Phase 1 dual-clock async FIFOs, compact UCIe adapter packet model,
// and link readiness gating.
//
// Phase 4.3: multi-beat data support. 512-bit data bursts are split into 4 beats
// of 128-bit data, preceded by a 128-bit header flit (5 beats total).
//
// Phase 4.4: PHY/link-training integration hooks. phy_link_ctrl manages the
// link-state FSM (WAIT_PHY -> ACTIVE -> ERR_DRAIN -> RETRAIN) and drives the
// internal link_up into reset_drain. A minimal sideband TX/RX interface allows
// the PHY block to exchange management messages with the bridge.

`include "chi_ucie_bridge_defs.vh"

module chi_to_ucie_bridge #(
  parameter integer FIFO_DEPTH      = 8,
  parameter integer TX_HDR_CREDITS  = 8,
  parameter integer TX_DAT_CREDITS  = 8,
  parameter integer MAX_OUTSTANDING = 32,
  parameter integer QOS_THROTTLE_WM = MAX_OUTSTANDING / 2
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
  output wire [BE_W-1:0]          ucie_tx_data_be,  // §6.2: write BE, valid on beat 0 only

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

  // PHY integration hooks (§4.4)
  input  wire                     phy_init_done,
  input  wire                     link_error,
  output wire                     retrain_req,
  output wire [1:0]               link_state,

  // Sideband interface (§4.4 / §5.3)
  output wire                     sb_tx_valid,
  output wire [7:0]               sb_tx_data,
  input  wire                     sb_tx_ready,
  input  wire                     sb_rx_valid,
  input  wire [7:0]               sb_rx_data,
  output wire                     sb_rx_ready,

  // Power-management L1 gate (§5.3): high from PM_L1_REQ until PM_L1_EXIT.
  output wire                     pm_l1_active,

  input  wire                     err_inj_en,
  output wire                     drain_done,
  output reg  [15:0]              crc_err_cnt,
  output reg  [15:0]              tag_err_cnt,
  output reg  [15:0]              drain_cnt,
  // QoS observability (§5.4): counts UCIe headers issued with CHI QoS >= 8.
  output reg  [15:0]              qos_hi_cnt,
  // §10: counts cycles a low-QoS request is held off by the watermark.
  output reg  [15:0]              qos_lo_stall_cnt,

  // §9: CHI Snoop channel (bridge → CHI master)
  output wire                     chi_snp_valid,
  output wire [CHI_SNP_W-1:0]    chi_snp_data,
  input  wire                     chi_snp_ready,

  // §9: CHI SnpResp channel (CHI master → bridge, header-only)
  input  wire                     chi_snp_rsp_valid,
  input  wire [CHI_SNPRSP_W-1:0] chi_snp_rsp_data,
  output wire                     chi_snp_rsp_ready,

  // §9: CHI SnpRespData channel (CHI master → bridge, with dirty line)
  input  wire                     chi_snp_rsp_dat_valid,
  input  wire [CHI_DAT_W-1:0]    chi_snp_rsp_dat_data,
  output wire                     chi_snp_rsp_dat_ready
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

  // Synchronise phy_init_done into the clk domain for phy_link_ctrl.
  // link_error is assumed to originate in the clk domain from the system
  // link-training block; add a sync stage here if the PHY is on a separate clock.
  wire link_up_clk;
  cdc_sync #(.STAGES(2)) u_link_up_cdc (
    .clk(clk), .rst_n(clk_rst_n), .d(phy_init_done), .q(link_up_clk)
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

  // §9: Snoop FIFO wires (declared early for Icarus compatibility)
  wire snp_rx_w_full;
  wire snp_rx_r_empty;
  wire [CHI_SNP_W-1:0]      snp_rx_r_data;

  wire snp_rsp_w_full;
  wire snp_rsp_r_empty;
  wire [CHI_SNPRSP_W:0]     snp_rsp_r_data;  // [CHI_SNPRSP_W] = has_dat flag

  wire snp_dat_w_full;
  wire snp_dat_r_empty;
  wire [CHI_DAT_W-1:0]      snp_dat_r_data;

  // §9: CDCs for snp_rsp and snp_dat read-side empties (ucie_clk → clk) for all_empty
  wire snp_rsp_r_empty_clk;
  wire snp_dat_r_empty_clk;

  // Internal control pulses (declared early for Icarus compatibility)
  wire hdr_fire;
  wire data_fire;
  wire rx_hdr_fire = ucie_rx_hdr_valid && ucie_rx_hdr_ready;
  wire rx_dat_fire = ucie_rx_data_valid && ucie_rx_data_ready;

  // §10: QoS watermark CDC (declared early; driven after txn_table below)
  wire outstanding_above_wm;      // ucie_clk domain
  wire outstanding_above_wm_clk;  // clk domain (2-flop CDC)

  // §9: TX presenting state machine (replaces held_v/held_tag/held_seq)
  reg        tx_presenting;
  reg        tx_is_snp_rsp;
  reg  [LTAG_W-1:0] tx_held_tag;
  reg  [7:0]        tx_held_seq;
  wire req_hdr_fire     = hdr_fire && !tx_is_snp_rsp;
  wire snp_rsp_hdr_fire = hdr_fire &&  tx_is_snp_rsp;

  // §9: Snoop data tag queue (sdq) — tracks pending snp_rsp with dirty data
  reg [TXNID_W-1:0] sdq_mem [0:MAX_OUTSTANDING-1];
  reg [WQ_AW:0]     sdq_wptr;
  reg [WQ_AW:0]     sdq_rptr;
  wire sdq_empty = (sdq_wptr == sdq_rptr);
  wire [TXNID_W-1:0] sdq_front_txnid = sdq_mem[sdq_rptr[WQ_AW-1:0]];

  // §9: TX data mux — snoop dirty data takes priority over write data.
  // snp_dat_last/snp_dat_fire/sdq_pop are assigned after tx_dat_beat_ctr and data_fire
  // are in scope (Icarus no-forward-reference rule).
  wire tx_dat_is_snp;
  wire snp_dat_last;
  wire snp_dat_fire;
  wire sdq_pop;
  assign tx_dat_is_snp = !sdq_empty;

  // Multi-beat burst counters (§4.3 / §6.1)
  reg [2:0] tx_dat_beat_ctr;
  // wq_front_last_beat and tx_dat_last are assigned near the wq declarations below
  // (after wq_front_size is defined) to satisfy Icarus's no-forward-reference rule.
  wire [2:0] wq_front_last_beat;
  wire       tx_dat_last;
  reg  [2:0] rx_dat_beat_ctr;
  reg  [2:0] rx_burst_beats;  // latched from beat-0 MEM_CPL header length[6:4]
  wire rx_dat_last = (rx_dat_beat_ctr != 3'd0) && (rx_dat_beat_ctr == rx_burst_beats);

  // §6.3: rx_hdr_latch and split-completion signals declared early so they are
  // visible in the txn_table port-connection expression (Icarus forward-ref rule).
  reg [UCIE_HDR_W-1:0] rx_hdr_latch;
  wire       rx_cpl_is_split  = (rx_hdr_latch[UCIE_LEN_MSB:UCIE_LEN_LSB] == 8'h20);
  wire       rx_cpl_upper     = rx_hdr_latch[UCIE_ADDR_LSB + 4];
  wire [3:0] rx_cpl_dataid    = rx_cpl_is_split ? {2'b00, rx_cpl_upper, 1'b0} : 4'h0;
  // b_is_large forward-declared here (driven by txn_table output below) so it is
  // in scope for rx_cpl_frees_tbl, which is itself used in the txn_table port list.
  wire       b_is_large;
  // Free the table entry when: standalone (not a 32B half), the upper half of a
  // split, or a 32B completion for a txn that did not expect a split (size=5 read).
  wire       rx_cpl_frees_tbl = !rx_cpl_is_split || rx_cpl_upper || !b_is_large;

  // Flit sequence counter.
  // §6.4 choice: treat each data burst as a single sequenced unit using the beat-0
  // header flit_seq; raw data beats 1–4 carry no sequence number.  Only TX header
  // flits (UCIe request headers and write/read-data burst headers at beat 0) consume
  // sequence numbers, so consecutive TX headers always differ by exactly 1 (mod 256).
  reg [7:0] flit_seq_ctr;
  always @(posedge ucie_clk or negedge ucie_rst_n) begin
    if (!ucie_rst_n)
      flit_seq_ctr <= 8'h00;
    else
      flit_seq_ctr <= flit_seq_ctr + {7'h0, hdr_fire}
                                   + {7'h0, data_fire && tx_dat_beat_ctr == 3'd0};
  end
  // When a request header and data burst header co-fire, the burst header gets seq+1.
  wire [7:0] dat_flit_seq = flit_seq_ctr + {7'h0, hdr_fire};

  wire req_r_empty_clk;
  wire wdat_r_empty_clk;
  cdc_sync #(.STAGES(2)) u_req_empty_cdc (
    .clk(clk), .rst_n(clk_rst_n), .d(req_r_empty), .q(req_r_empty_clk)
  );
  cdc_sync #(.STAGES(2)) u_wdat_empty_cdc (
    .clk(clk), .rst_n(clk_rst_n), .d(wdat_r_empty), .q(wdat_r_empty_clk)
  );

  wire all_empty = req_r_empty_clk && wdat_r_empty_clk && rsp_r_empty && rdat_r_empty
               && snp_rx_r_empty && snp_rsp_r_empty_clk && snp_dat_r_empty_clk;

  // PHY link controller: translates phy_init_done / link_error into the
  // reset_drain link_up signal, and sequences the error-recovery retrain flow.
  // Operates in the clk domain alongside reset_drain.
  wire link_up_internal;
  phy_link_ctrl u_phy_ctrl (
    .clk(clk), .rst_n(clk_rst_n),
    .phy_init_done(link_up_clk),  // CDC-synchronised PHY ready
    .link_error(link_error),
    .drain_done(drain_done),
    .link_up(link_up_internal),
    .retrain_req(retrain_req),
    .link_state(link_state)
  );

  wire bridge_open;
  reset_drain u_reset_drain (
    .clk(clk),
    .rst_n(clk_rst_n),
    .link_up(link_up_internal),
    .all_empty(all_empty),
    .open(bridge_open),
    .drain_done(drain_done)
  );

  // Sideband management handler: link-state TX, PARAM exchange, and PM-L1 flow.
  sb_msg_handler #(.MAX_OUTSTANDING(MAX_OUTSTANDING)) u_sb_handler (
    .clk(clk), .rst_n(clk_rst_n),
    .link_state(link_state), .drain_done(drain_done),
    .sb_tx_valid(sb_tx_valid), .sb_tx_data(sb_tx_data), .sb_tx_ready(sb_tx_ready),
    .sb_rx_valid(sb_rx_valid), .sb_rx_data(sb_rx_data), .sb_rx_ready(sb_rx_ready),
    .pm_l1_active(pm_l1_active)
  );

  wire bridge_open_ucie;
  cdc_sync #(.STAGES(2)) u_open_cdc (
    .clk(ucie_clk), .rst_n(ucie_rst_n), .d(bridge_open), .q(bridge_open_ucie)
  );

  // ---------------------------------------------------------------------------
  // CHI host-domain enqueue
  // ---------------------------------------------------------------------------
  wire chi_req_is_write  = is_chi_write(chi_req_data[CHI_REQ_OPCODE_LSB +: CHI_REQ_OPCODE_W]);
  wire chi_req_is_read   = is_chi_read(chi_req_data[CHI_REQ_OPCODE_LSB +: CHI_REQ_OPCODE_W]);
  wire chi_req_is_cmo    = is_chi_cmo(chi_req_data[CHI_REQ_OPCODE_LSB +: CHI_REQ_OPCODE_W]);
  wire req_supported     = chi_req_is_write || chi_req_is_read || chi_req_is_cmo;
  wire chi_req_is_qos_hi = chi_req_data[CHI_REQ_QOS_LSB +: CHI_REQ_QOS_W] >= 4'd8;  // §10
  wire throttle_lo       = outstanding_above_wm_clk && !chi_req_is_qos_hi;             // §10

  // §7.1: an unsupported opcode is accepted and answered with a CHI RSP carrying
  // RespErr (NDERR) via a local clk-domain error-response FIFO, instead of the
  // Phase-1 behaviour of stalling chi_req_ready forever (a request-channel
  // deadlock). A compliant write master never sends WriteData for a rejected
  // request (it would wait for a DBIDResp we never issue), so the data channel
  // cannot deadlock either.
  wire chi_req_is_err = !req_supported;   // opcode-based; accept gated on valid below
  wire err_rsp_w_full;

  // §7.2: real CHI write handshake using a CHI-domain (clk) DBID pool. A write
  // request is accepted on its own (no data), allocated a DBID, and answered with
  // a DBIDResp. The master then sends WriteData tagged with that DBID; the bridge
  // matches it, replays the stored request into the pipeline, and frees the DBID.
  // This replaces the Phase-1 shortcut of requiring request+data in the same
  // cycle and pushing write data straight through the FIFOs.
  localparam integer WBUF    = FIFO_DEPTH;
  localparam integer WBUF_AW = $clog2(WBUF);
  reg  [WBUF-1:0]      dbid_valid;
  reg  [CHI_REQ_W-1:0] wpend_req [0:WBUF-1];
  wire                 dbid_pool_full = &dbid_valid;
  wire                 dbid_rsp_w_full;

  // Lowest free DBID (priority encoder over the free-list).
  integer di;
  reg [WBUF_AW-1:0] dbid_alloc;
  always @(*) begin
    dbid_alloc = {WBUF_AW{1'b0}};
    for (di = WBUF-1; di >= 0; di = di - 1)
      if (!dbid_valid[di]) dbid_alloc = di[WBUF_AW-1:0];
  end

  // Capacity-based readies. Intentionally independent of chi_req_valid /
  // chi_wr_data_valid (AXI-style): a valid-dependent ready races with procedural
  // "while(!ready) @(posedge clk); @(posedge clk);" drivers in the same delta and
  // double-enqueues. The accept pulses below gate each ready on its valid.
  wire cap_open = bridge_open && !pm_l1_active;
  // WriteData carries its DBID in the DAT TxnID field; match it to a live entry.
  wire [WBUF_AW-1:0] wr_dbid    = chi_wr_data[CHI_DAT_TXNID_LSB +: WBUF_AW];
  wire               wr_dat_hit = dbid_valid[wr_dbid];

  wire rd_req_ready  = chi_req_is_read  && cap_open && !req_w_full  && !throttle_lo;
  wire wr_req_ready  = chi_req_is_write && cap_open && !dbid_pool_full && !dbid_rsp_w_full && !throttle_lo;
  wire err_req_ready = chi_req_is_err   && cap_open && !err_rsp_w_full;
  wire cmo_req_ready = chi_req_is_cmo   && cap_open && !req_w_full   && !throttle_lo;  // §8
  wire wr_dat_ready  = wr_dat_hit       && cap_open && !req_w_full && !wdat_w_full;

  assign chi_req_ready     = rd_req_ready || wr_req_ready || err_req_ready || cmo_req_ready;
  assign chi_wr_data_ready = wr_dat_ready;

  wire rd_req_accept  = chi_req_valid     && rd_req_ready;   // read: single-phase enqueue
  wire wr_req_accept  = chi_req_valid     && wr_req_ready;   // write phase 1: alloc DBID
  wire err_rsp_accept = chi_req_valid     && err_req_ready;  // §7.1 reject
  wire cmo_req_accept = chi_req_valid     && cmo_req_ready;  // §8 CMO: single-phase enqueue
  wire wr_dat_accept  = chi_wr_data_valid && wr_dat_ready;   // write phase 2: enqueue

  // req_fifo enqueue: reads/CMOs push their request now; writes push the *stored*
  // request when their WriteData arrives (so header and data enter together).
  wire                 req_w_en   = rd_req_accept || wr_dat_accept || cmo_req_accept;
  wire [CHI_REQ_W-1:0] req_w_data = wr_dat_accept ? wpend_req[wr_dbid] : chi_req_data;
  wire                 wdat_w_en  = wr_dat_accept;
  wire                 err_rsp_w_en  = err_rsp_accept;
  wire                 dbid_rsp_w_en = wr_req_accept;

  always @(posedge clk or negedge clk_rst_n) begin
    if (!clk_rst_n) begin
      dbid_valid <= {WBUF{1'b0}};
    end else begin
      // Alloc and free target different slots (alloc picks a free one, free a
      // valid one), so same-cycle alloc+free never conflict.
      if (wr_req_accept) dbid_valid[dbid_alloc] <= 1'b1;
      if (wr_dat_accept) dbid_valid[wr_dbid]    <= 1'b0;
    end
  end
  always @(posedge clk) begin
    if (wr_req_accept) wpend_req[dbid_alloc] <= chi_req_data;
  end

  async_fifo #(.WIDTH(CHI_REQ_W), .DEPTH(FIFO_DEPTH)) u_req_fifo (
    .w_clk(clk), .w_rst_n(clk_rst_n), .w_en(req_w_en), .w_data(req_w_data), .w_full(req_w_full),
    .r_clk(ucie_clk), .r_rst_n(ucie_rst_n), .r_en(req_hdr_fire),
    .r_data(req_r_data), .r_empty(req_r_empty)
  );

  async_fifo #(.WIDTH(CHI_DAT_W), .DEPTH(FIFO_DEPTH)) u_wdat_fifo (
    .w_clk(clk), .w_rst_n(clk_rst_n), .w_en(wdat_w_en), .w_data(chi_wr_data), .w_full(wdat_w_full),
    .r_clk(ucie_clk), .r_rst_n(ucie_rst_n), .r_en(data_fire && tx_dat_last && !tx_dat_is_snp),
    .r_data(wdat_r_data), .r_empty(wdat_r_empty)
  );

  // ---------------------------------------------------------------------------
  // Transaction table (ucie_clk domain)
  // ---------------------------------------------------------------------------
  wire                req_head_is_write = is_chi_write(req_r_data[CHI_REQ_OPCODE_LSB +: CHI_REQ_OPCODE_W]);
  wire                req_head_is_cmo   = is_chi_cmo(req_r_data[CHI_REQ_OPCODE_LSB +: CHI_REQ_OPCODE_W]);
  wire [LTAG_W-1:0]   free_tag;
  wire                tbl_full;
  wire                tbl_tag_err;

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
    .consume(data_fire && tx_dat_beat_ctr == 3'd0), .ret(ucie_rx_dat_crdt),
    .available(dat_crdt_avail)
  );

  always @(posedge ucie_clk or negedge ucie_rst_n) begin
    if (!ucie_rst_n)
      tx_dat_beat_ctr <= 3'd0;
    else if (data_fire)
      tx_dat_beat_ctr <= tx_dat_last ? 3'd0 : tx_dat_beat_ctr + 3'd1;
  end

  always @(posedge ucie_clk or negedge ucie_rst_n) begin
    if (!ucie_rst_n) begin
      rx_dat_beat_ctr <= 3'd0;
      rx_burst_beats  <= 3'd4;  // default to 4-beat (64B) until overridden
    end else begin
      if (rx_dat_fire) begin
        rx_dat_beat_ctr <= rx_dat_last ? 3'd0 : rx_dat_beat_ctr + 3'd1;
        // Latch burst length from the beat-0 MEM_CPL header: length[6:4] = num_data_beats.
        // length=0x10→1 beat, 0x20→2 beats, 0x40→4 beats.
        if (rx_dat_beat_ctr == 3'd0)
          rx_burst_beats <= ucie_rx_data[UCIE_LEN_LSB+4 +: 3];
      end
    end
  end

  assign ucie_tx_hdr_crdt = rx_hdr_fire;
  assign ucie_tx_dat_crdt = rx_dat_fire && rx_dat_last;

  wire [LTAG_W-1:0] rx_hdr_tag = ucie_rx_hdr[UCIE_TAG_LSB +: LTAG_W];

  reg [LTAG_W-1:0] rx_dat_tag_latched;
  always @(posedge ucie_clk) begin
    if (rx_dat_fire && rx_dat_beat_ctr == 3'd0)
      rx_dat_tag_latched <= ucie_rx_data[UCIE_TAG_LSB +: LTAG_W];
  end
  wire [LTAG_W-1:0] rx_dat_tag = (rx_dat_beat_ctr == 3'd0) ?
                                 ucie_rx_data[UCIE_TAG_LSB +: LTAG_W] :
                                 rx_dat_tag_latched;

  // §9: TX presenting state machine — locks in the source and tag/seq for the
  // duration of each header handshake, supporting both req (CHI→UCIe) and
  // snp_rsp (SnpResp/SnpRespData) sources on the same UCIe TX header channel.
  wire any_tx_src = bridge_open_ucie &&
      (!snp_rsp_r_empty || (!req_r_empty && !tbl_full));

  always @(posedge ucie_clk or negedge ucie_rst_n) begin
    if (!ucie_rst_n) begin
      tx_presenting <= 1'b0;
      tx_is_snp_rsp <= 1'b0;
      tx_held_tag   <= {LTAG_W{1'b0}};
      tx_held_seq   <= 8'h00;
    end else if (tx_presenting && (hdr_fire || !bridge_open_ucie)) begin
      tx_presenting <= 1'b0;
    end else if (!tx_presenting && any_tx_src) begin
      tx_presenting  <= 1'b1;
      tx_is_snp_rsp  <= !snp_rsp_r_empty;
      tx_held_tag    <= free_tag;
      tx_held_seq    <= flit_seq_ctr;
    end
  end

  wire [TXNID_W-1:0] a_txnid;
  wire [NODEID_W-1:0] a_srcid;
  wire                a_is_write;
  wire                a_valid;
  wire [TXNID_W-1:0] b_txnid;
  wire [NODEID_W-1:0] b_srcid;
  wire                b_is_write;
  wire                b_valid;
  // b_is_large declared earlier in the §6.3 block (Icarus forward-ref rule).
  wire [LTAG_W:0]    outstanding;

  txn_table #(
    .N(MAX_OUTSTANDING), .TID_W(TXNID_W), .SID_W(NODEID_W), .LTAG_W(LTAG_W)
  ) u_txn_table (
    .clk(ucie_clk), .rst_n(ucie_rst_n),
    .alloc_en(req_hdr_fire),
    .alloc_idx(tx_held_tag),
    .alloc_txnid(req_r_data[CHI_REQ_TXNID_LSB +: TXNID_W]),
    .alloc_srcid(req_r_data[CHI_REQ_SRCID_LSB +: CHI_REQ_SRCID_W]),
    .alloc_is_write(req_head_is_write),
    .alloc_is_large(!req_head_is_write && !req_head_is_cmo &&
                    (req_r_data[CHI_REQ_SIZE_LSB +: CHI_REQ_SIZE_W] >= 3'd6)),
    .free_tag(free_tag),
    .full(tbl_full),
    .a_lookup_tag(rx_hdr_tag), .a_free_en(rx_hdr_fire),
    .a_txnid(a_txnid), .a_srcid(a_srcid), .a_is_write(a_is_write), .a_valid(a_valid),
    .b_lookup_tag(rx_dat_tag), .b_free_en(rx_dat_fire && rx_dat_last && rx_cpl_frees_tbl),
    .b_txnid(b_txnid), .b_srcid(b_srcid), .b_is_write(b_is_write), .b_valid(b_valid),
    .b_is_large(b_is_large),
    .outstanding(outstanding), .tag_err(tbl_tag_err)
  );

  // §10: compare outstanding count against watermark in ucie_clk domain; CDC to clk.
  assign outstanding_above_wm = (outstanding >= QOS_THROTTLE_WM[LTAG_W:0]);
  cdc_sync #(.STAGES(2)) u_qos_wm_cdc (
    .clk(clk), .rst_n(clk_rst_n), .d(outstanding_above_wm), .q(outstanding_above_wm_clk)
  );

  // §9: CDC of snp_rsp / snp_dat read-side empties (ucie_clk → clk) for all_empty.
  cdc_sync #(.STAGES(2)) u_snp_rsp_empty_cdc (
    .clk(clk), .rst_n(clk_rst_n), .d(snp_rsp_r_empty), .q(snp_rsp_r_empty_clk)
  );
  cdc_sync #(.STAGES(2)) u_snp_dat_empty_cdc (
    .clk(clk), .rst_n(clk_rst_n), .d(snp_dat_r_empty), .q(snp_dat_r_empty_clk)
  );

  // ---------------------------------------------------------------------------
  // Write-data tag side-queue: carries each write's local tag from header issue
  // to data issue and enforces header-before-data ordering on the independent
  // ready paths.
  // ---------------------------------------------------------------------------
  reg [LTAG_W+2:0] wtag_mem [0:MAX_OUTSTANDING-1];  // §6.1: {size[2:0], tag[LTAG_W-1:0]}
  reg [WQ_AW:0]    wq_wptr;
  reg [WQ_AW:0]    wq_rptr;
  wire wq_empty = (wq_wptr == wq_rptr);
  wire [LTAG_W-1:0] wq_front      = wtag_mem[wq_rptr[WQ_AW-1:0]][LTAG_W-1:0];
  wire [2:0]         wq_front_size = wtag_mem[wq_rptr[WQ_AW-1:0]][LTAG_W+2:LTAG_W];

  // §6.1: last data-beat index from CHI size.
  // size=0..4 (≤16B) → 1 beat, size=5 (32B) → 2 beats, size=6 (64B) → 4 beats.
  function automatic [2:0] size_to_last_beat;
    input [2:0] size;
    begin
      if (size >= 3'd6) size_to_last_beat = 3'd4;
      else if (size >= 3'd5) size_to_last_beat = 3'd2;
      else size_to_last_beat = 3'd1;
    end
  endfunction
  assign wq_front_last_beat = size_to_last_beat(wq_front_size);
  assign tx_dat_last        = tx_dat_is_snp ? snp_dat_last
                                            : (tx_dat_beat_ctr == wq_front_last_beat);

  wire wq_push = req_hdr_fire && req_head_is_write;
  wire wq_pop  = data_fire && tx_dat_last && !tx_dat_is_snp;

  always @(posedge ucie_clk or negedge ucie_rst_n) begin
    if (!ucie_rst_n) begin
      wq_wptr <= {(WQ_AW+1){1'b0}};
      wq_rptr <= {(WQ_AW+1){1'b0}};
    end else begin
      if (wq_push) begin
        wtag_mem[wq_wptr[WQ_AW-1:0]] <= {req_r_data[CHI_REQ_SIZE_LSB +: CHI_REQ_SIZE_W], tx_held_tag};
        wq_wptr <= wq_wptr + 1'b1;
      end
      if (wq_pop) wq_rptr <= wq_rptr + 1'b1;
    end
  end

  reg  [7:0] held_dat_seq;
  reg        held_dat_v;
  wire [7:0] present_dat_seq = held_dat_v ? held_dat_seq : dat_flit_seq;

  always @(posedge ucie_clk or negedge ucie_rst_n) begin
    if (!ucie_rst_n) begin
      held_dat_v   <= 1'b0;
      held_dat_seq <= 8'h00;
    end else if (data_fire && tx_dat_last) begin
      held_dat_v   <= 1'b0;
    end else if (ucie_tx_data_valid && !ucie_tx_data_ready) begin
      if (!held_dat_v) begin
        held_dat_seq <= present_dat_seq;
        held_dat_v   <= 1'b1;
      end
    end else if (!ucie_tx_data_valid) begin
      held_dat_v   <= 1'b0;
    end
  end

  // ---------------------------------------------------------------------------
  // RX data accumulation (§4.3)
  // ---------------------------------------------------------------------------
  reg [511:0] rx_dat_accum;
  reg         rx_dat_poison_latched;
  // rx_hdr_latch declared early (see §6.3 block near top) for Icarus compatibility.

  always @(posedge ucie_clk) begin
    if (rx_dat_fire) begin
      if (rx_dat_beat_ctr == 3'd0) begin
        rx_dat_poison_latched <= ucie_rx_data[UCIE_ATTR_LSB + 7];
        rx_hdr_latch          <= ucie_rx_data;
      end else begin
        case (rx_dat_beat_ctr)
          3'd1: rx_dat_accum[0   +: 128] <= ucie_rx_data;
          3'd2: rx_dat_accum[128 +: 128] <= ucie_rx_data;
          3'd3: rx_dat_accum[256 +: 128] <= ucie_rx_data;
          3'd4: rx_dat_accum[384 +: 128] <= ucie_rx_data;
          default: ;
        endcase
      end
    end
  end

  // Combinational full 512-bit data for the last beat; zero-extended for shorter bursts.
  reg [511:0] rx_dat_full;
  always @(*) begin
    case (rx_burst_beats)
      3'd1:    rx_dat_full = {384'h0, ucie_rx_data};                          // 1 data beat
      3'd2:    rx_dat_full = {256'h0, ucie_rx_data, rx_dat_accum[127:0]};    // 2 data beats
      default: rx_dat_full = {ucie_rx_data, rx_dat_accum[383:0]};            // 4 data beats
    endcase
  end

  reg [TXNID_W-1:0] rx_dat_txnid_latched;
  reg               rx_dat_valid_latched;
  always @(posedge ucie_clk) begin
    if (rx_dat_fire && rx_dat_beat_ctr == 3'd0) begin
      rx_dat_txnid_latched <= b_txnid;
      rx_dat_valid_latched <= b_valid;
    end
  end


  // ---------------------------------------------------------------------------
  // CHI -> UCIe translation (TX)
  // ---------------------------------------------------------------------------
  function automatic [UCIE_HDR_W-1:0] translate_chi_req_to_ucie;
    input [CHI_REQ_W-1:0] chi_req;
    input [7:0]           local_tag;
    input [7:0]           flit_seq;
    reg [3:0] kind;
    reg [3:0] code;
    reg [7:0] attr;
    begin
      // §8: CMO → UCIE_PKT_KIND_CMO; code carries the lower 4 bits of the CHI
      // opcode (CleanShared=0x8, CleanInvalid=0x9, MakeInvalid=0xD,
      // CleanSharedPersist=0x1). No data burst follows; far side returns AD_CPL.
      if (is_chi_cmo(chi_req[CHI_REQ_OPCODE_LSB +: CHI_REQ_OPCODE_W])) begin
        kind = UCIE_PKT_KIND_CMO;
        code = chi_req[CHI_REQ_OPCODE_LSB +: 4];
      end else begin
        kind = UCIE_PKT_KIND_AD_REQ;
        code = is_chi_write(chi_req[CHI_REQ_OPCODE_LSB +: CHI_REQ_OPCODE_W]) ?
               UCIE_MSG_MEM_WR : UCIE_MSG_MEM_RD;
      end
      attr = {2'b00,
              chi_req[CHI_REQ_ORDER_LSB +: CHI_REQ_ORDER_W],
              chi_req[CHI_REQ_QOS_LSB +: CHI_REQ_QOS_W]};  // §5.4: attr[3:0] = QoS
      translate_chi_req_to_ucie = pack_ucie_hdr(
        kind,
        code,
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
    input [2:0]           beat;
    input [2:0]           size;   // §6.1: CHI size field; drives length = 1 << size
    reg [UCIE_HDR_W-1:0] hdr;
    begin
      if (beat == 3'd0) begin
        hdr = pack_ucie_hdr(
          UCIE_PKT_KIND_AD_REQ,
          UCIE_MSG_MEM_WR_DATA,
          local_tag,
          48'h0000_0000_0000,
          (8'h01 << size),   // §6.1: byte count = 2^size
          8'h00,
          {dat[CHI_DAT_POISON_LSB], 7'b0},
          flit_seq
        );
        translate_chi_data_to_ucie = hdr;
      end else begin
        case (beat)
          3'd1: translate_chi_data_to_ucie = dat[0   +: 128];
          3'd2: translate_chi_data_to_ucie = dat[128 +: 128];
          3'd3: translate_chi_data_to_ucie = dat[256 +: 128];
          3'd4: translate_chi_data_to_ucie = dat[384 +: 128];
          default: translate_chi_data_to_ucie = 128'h0;
        endcase
      end
    end
  endfunction

  assign ucie_tx_hdr_valid = bridge_open_ucie && tx_presenting && hdr_crdt_avail;
  assign ucie_tx_hdr = tx_is_snp_rsp ?
      translate_snp_rsp_to_ucie(snp_rsp_r_data[CHI_SNPRSP_W-1:0],
                                 snp_rsp_r_data[CHI_SNPRSP_W], tx_held_seq) :
      translate_chi_req_to_ucie(req_r_data, {{(8-LTAG_W){1'b0}}, tx_held_tag}, tx_held_seq);
  assign hdr_fire = ucie_tx_hdr_valid && ucie_tx_hdr_ready;

  // QoS high-priority counter: increments when a header fires with QoS >= 8.
  // Resets on link tear-down (bridge_open_ucie deasserted).
  always @(posedge ucie_clk or negedge ucie_rst_n) begin
    if (!ucie_rst_n)
      qos_hi_cnt <= 16'h0;
    else if (!bridge_open_ucie)
      qos_hi_cnt <= 16'h0;
    else if (req_hdr_fire && req_r_data[CHI_REQ_QOS_LSB +: CHI_REQ_QOS_W] >= 4'd8)
      qos_hi_cnt <= qos_hi_cnt + 1'b1;
  end

  // §10: low-QoS stall counter: counts clk cycles where a valid low-QoS request
  // is held off by the outstanding watermark.
  always @(posedge clk or negedge clk_rst_n) begin
    if (!clk_rst_n)
      qos_lo_stall_cnt <= 16'h0;
    else if (!bridge_open)
      qos_lo_stall_cnt <= 16'h0;
    else if (throttle_lo && chi_req_valid)
      qos_lo_stall_cnt <= qos_lo_stall_cnt + 1'b1;
  end

  assign ucie_tx_data_valid = bridge_open_ucie && dat_crdt_avail &&
      (tx_dat_is_snp ? !snp_dat_r_empty
                     : (!wdat_r_empty && !wq_empty));
  assign ucie_tx_data = tx_dat_is_snp ?
      translate_snp_dat_to_ucie(snp_dat_r_data, sdq_front_txnid, present_dat_seq, tx_dat_beat_ctr) :
      translate_chi_data_to_ucie(wdat_r_data, {{(8-LTAG_W){1'b0}}, wq_front},
                                 present_dat_seq, tx_dat_beat_ctr, wq_front_size);
  assign ucie_tx_data_be = (tx_dat_beat_ctr == 3'd0 && !tx_dat_is_snp) ?
      wdat_r_data[CHI_DAT_BE_LSB +: BE_W] : {BE_W{1'b1}};
  assign data_fire     = ucie_tx_data_valid && ucie_tx_data_ready;
  assign snp_dat_last  = (tx_dat_beat_ctr == 3'd4);
  assign snp_dat_fire  = data_fire && tx_dat_is_snp;
  assign sdq_pop       = snp_dat_fire && snp_dat_last;

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

  // §7.1: build a CHI Comp response carrying RespErr=NDERR for a request the
  // bridge cannot translate. Identity (TxnID/SrcID) is taken straight from the
  // rejected request so it routes back to the originating requester.
  function automatic [CHI_RSP_W-1:0] make_err_rsp;
    input [CHI_REQ_W-1:0] chi_req;
    reg [CHI_RSP_W-1:0] rsp;
    begin
      rsp = {CHI_RSP_W{1'b0}};
      rsp[CHI_RSP_RESPERR_LSB +: CHI_RSP_RESPERR_W] = CHI_RESPERR_NDERR;
      rsp[CHI_RSP_DBID_LSB +: CHI_RSP_DBID_W]       = chi_req[CHI_REQ_TXNID_LSB +: CHI_RSP_DBID_W];
      rsp[CHI_RSP_TXNID_LSB +: CHI_RSP_TXNID_W]     = chi_req[CHI_REQ_TXNID_LSB +: TXNID_W];
      rsp[CHI_RSP_OPCODE_LSB +: CHI_RSP_OPCODE_W]   = CHI_RSP_COMP;
      rsp[CHI_RSP_SRCID_LSB +: CHI_RSP_SRCID_W]     = chi_req[CHI_REQ_SRCID_LSB +: CHI_REQ_SRCID_W];
      make_err_rsp = rsp;
    end
  endfunction

  // §7.2: build the DBIDResp for an accepted write request. Carries the allocated
  // DBID (which the master must echo in its WriteData TxnID) plus the original
  // CHI identity so it routes back to the requester.
  function automatic [CHI_RSP_W-1:0] make_dbid_rsp;
    input [CHI_REQ_W-1:0]  chi_req;
    input [WBUF_AW-1:0]    dbid;
    reg [CHI_RSP_W-1:0] rsp;
    begin
      rsp = {CHI_RSP_W{1'b0}};
      rsp[CHI_RSP_RESPERR_LSB +: CHI_RSP_RESPERR_W] = CHI_RESPERR_OK;
      rsp[CHI_RSP_DBID_LSB +: CHI_RSP_DBID_W]       = {{(CHI_RSP_DBID_W-WBUF_AW){1'b0}}, dbid};
      rsp[CHI_RSP_TXNID_LSB +: CHI_RSP_TXNID_W]     = chi_req[CHI_REQ_TXNID_LSB +: TXNID_W];
      rsp[CHI_RSP_OPCODE_LSB +: CHI_RSP_OPCODE_W]   = CHI_RSP_DBIDRESP;
      rsp[CHI_RSP_SRCID_LSB +: CHI_RSP_SRCID_W]     = chi_req[CHI_REQ_SRCID_LSB +: CHI_REQ_SRCID_W];
      make_dbid_rsp = rsp;
    end
  endfunction

  function automatic [CHI_DAT_W-1:0] translate_ucie_data_to_chi;
    input [UCIE_HDR_W-1:0] hdr;
    input [511:0]          data;
    input                  poison;
    input [TXNID_W-1:0]    r_txnid;
    input                  r_valid;
    input [3:0]            dataid;  // §6.3: DataID for split-completion positioning
    reg [CHI_DAT_W-1:0] dat;
    reg ok;
    begin
      ok = ucie_hdr_crc16_ok(hdr) && r_valid &&
           (hdr[UCIE_KIND_MSB:UCIE_KIND_LSB] == UCIE_PKT_KIND_MEM_CPL) &&
           (hdr[UCIE_CODE_MSB:UCIE_CODE_LSB] == UCIE_CPL_SC);
      dat = {CHI_DAT_W{1'b0}};
      // DataID=2 (upper half): shift the 256 accumulated bits into [511:256].
      // DataID=0 (lower half or full 64B): pass data through unchanged.
      if (dataid[1])
        dat[CHI_DAT_DATA_LSB +: CHI_DAT_DATA_W] = {data[255:0], 256'h0};
      else
        dat[CHI_DAT_DATA_LSB +: CHI_DAT_DATA_W] = data;
      dat[CHI_DAT_BE_LSB +: CHI_DAT_BE_W]           = {BE_W{1'b1}};
      dat[CHI_DAT_POISON_LSB +: CHI_DAT_POISON_W]   = poison;
      dat[CHI_DAT_DATAID_LSB +: CHI_DAT_DATAID_W]   = dataid;
      dat[CHI_DAT_RESPERR_LSB +: CHI_DAT_RESPERR_W] = ok ? CHI_RESPERR_OK : CHI_RESPERR_DERR;
      dat[CHI_DAT_RESP_LSB +: CHI_DAT_RESP_W]       = CHI_CACHE_I;
      dat[CHI_DAT_TXNID_LSB +: CHI_DAT_TXNID_W]     = r_txnid;
      dat[CHI_DAT_OPCODE_LSB +: CHI_DAT_OPCODE_W]   = CHI_DAT_COMPDATA;
      translate_ucie_data_to_chi = dat;
    end
  endfunction

  // §9: RX header routing — SNP packets go to snp_rx_fifo; everything else to rsp_fifo.
  wire rx_hdr_is_snp = (ucie_rx_hdr[UCIE_KIND_MSB:UCIE_KIND_LSB] == UCIE_PKT_KIND_SNP);
  assign ucie_rx_hdr_ready = bridge_open_ucie &&
      (rx_hdr_is_snp ? !snp_rx_w_full : !rsp_w_full);
  // Accept non-last beats unconditionally (they don't write the FIFO);
  // gate the last beat on FIFO space.  rx_dat_last is 0 at beat 0.
  assign ucie_rx_data_ready = bridge_open_ucie && (!rdat_w_full || !rx_dat_last);

  wire rx_hdr_bad = rx_hdr_fire && !ucie_hdr_crc16_ok(ucie_rx_hdr);
  wire rx_dat_bad = rx_dat_fire && (rx_dat_beat_ctr == 3'd0) && !ucie_hdr_crc16_ok(ucie_rx_data);

  // §7.1/§7.2: local clk-domain response FIFOs. Both the DBIDResp (write phase 1)
  // and the NDERR error response live entirely in the CHI clock domain, so no CDC
  // is needed for them.
  wire [CHI_RSP_W-1:0] err_rsp_r_data;
  wire                 err_rsp_r_empty;
  wire [CHI_RSP_W-1:0] dbid_rsp_r_data;
  wire                 dbid_rsp_r_empty;

  // Arbitrate three RSP sources: DBIDResp first (starving the write master of its
  // token would deadlock), then far-side completions, then error responses.
  //
  // A pure combinatorial mux violates the CHI valid/stable property: u_dbid_rsp_fifo
  // uses both ports on clk but still has a 2-cycle gray-code sync latency, so
  // dbid_rsp_r_empty can fall (new entry visible) while we are presenting a
  // lower-priority rsp_r_data with chi_rsp_ready=0.  The registered state machine
  // below latches the winner once per presentation and holds it until accepted.
  wire any_rsp_avail = !dbid_rsp_r_empty || !rsp_r_empty || !err_rsp_r_empty;
  reg  [CHI_RSP_W-1:0] rsp_held_data;
  reg                   rsp_presenting;
  reg                   rsp_src_dbid;   // 1 → pop u_dbid_rsp_fifo on accept
  reg                   rsp_src_err;    // 1 → pop u_err_rsp_fifo; 0 → pop u_rsp_fifo
  always @(posedge clk or negedge clk_rst_n) begin
    if (!clk_rst_n) begin
      rsp_presenting <= 1'b0;
      rsp_src_dbid   <= 1'b0;
      rsp_src_err    <= 1'b0;
      rsp_held_data  <= {CHI_RSP_W{1'b0}};
    end else if (rsp_presenting && chi_rsp_ready) begin
      rsp_presenting <= 1'b0;
    end else if (!rsp_presenting && any_rsp_avail) begin
      rsp_presenting <= 1'b1;
      rsp_src_dbid   <= !dbid_rsp_r_empty;
      rsp_src_err    <= dbid_rsp_r_empty && rsp_r_empty;
      rsp_held_data  <= !dbid_rsp_r_empty ? dbid_rsp_r_data :
                        !rsp_r_empty      ? rsp_r_data : err_rsp_r_data;
    end
  end
  assign chi_rsp_valid = rsp_presenting;
  assign chi_rsp_data  = rsp_held_data;
  wire dbid_rsp_pop = rsp_presenting && chi_rsp_ready &&  rsp_src_dbid;
  wire rsp_pop      = rsp_presenting && chi_rsp_ready && !rsp_src_dbid && !rsp_src_err;
  wire err_rsp_pop  = rsp_presenting && chi_rsp_ready && !rsp_src_dbid &&  rsp_src_err;

  async_fifo #(.WIDTH(CHI_RSP_W), .DEPTH(FIFO_DEPTH)) u_rsp_fifo (
    .w_clk(ucie_clk), .w_rst_n(ucie_rst_n), .w_en(rx_hdr_fire && !rx_hdr_is_snp),
    .w_data(translate_ucie_hdr_to_chi_rsp(ucie_rx_hdr, a_txnid, a_srcid, a_valid)), .w_full(rsp_w_full),
    .r_clk(clk), .r_rst_n(clk_rst_n), .r_en(rsp_pop),
    .r_data(rsp_r_data), .r_empty(rsp_r_empty)
  );

  async_fifo #(.WIDTH(CHI_RSP_W), .DEPTH(FIFO_DEPTH)) u_dbid_rsp_fifo (
    .w_clk(clk), .w_rst_n(clk_rst_n), .w_en(dbid_rsp_w_en),
    .w_data(make_dbid_rsp(chi_req_data, dbid_alloc)), .w_full(dbid_rsp_w_full),
    .r_clk(clk), .r_rst_n(clk_rst_n), .r_en(dbid_rsp_pop),
    .r_data(dbid_rsp_r_data), .r_empty(dbid_rsp_r_empty)
  );

  async_fifo #(.WIDTH(CHI_RSP_W), .DEPTH(FIFO_DEPTH)) u_err_rsp_fifo (
    .w_clk(clk), .w_rst_n(clk_rst_n), .w_en(err_rsp_w_en),
    .w_data(make_err_rsp(chi_req_data)), .w_full(err_rsp_w_full),
    .r_clk(clk), .r_rst_n(clk_rst_n), .r_en(err_rsp_pop),
    .r_data(err_rsp_r_data), .r_empty(err_rsp_r_empty)
  );

  async_fifo #(.WIDTH(CHI_DAT_W), .DEPTH(FIFO_DEPTH)) u_rdat_fifo (
    .w_clk(ucie_clk), .w_rst_n(ucie_rst_n), .w_en(rx_dat_fire && rx_dat_last),
    .w_data(translate_ucie_data_to_chi(rx_hdr_latch, rx_dat_full, rx_dat_poison_latched, rx_dat_txnid_latched, rx_dat_valid_latched, rx_cpl_dataid)), .w_full(rdat_w_full),
    .r_clk(clk), .r_rst_n(clk_rst_n), .r_en(chi_comp_data_valid && chi_comp_data_ready),
    .r_data(rdat_r_data), .r_empty(rdat_r_empty)
  );

  assign chi_comp_data_valid = !rdat_r_empty;
  assign chi_comp_data = rdat_r_data;

  // ---------------------------------------------------------------------------
  // §9: Snoop FIFOs, SDQ, and CHI SNP output
  // ---------------------------------------------------------------------------

  // u_snp_rx_fifo: incoming UCIe SNP → CHI SNP flit (ucie_clk write, clk read)
  async_fifo #(.WIDTH(CHI_SNP_W), .DEPTH(FIFO_DEPTH)) u_snp_rx_fifo (
    .w_clk(ucie_clk), .w_rst_n(ucie_rst_n),
    .w_en(rx_hdr_fire && rx_hdr_is_snp),
    .w_data(translate_ucie_snp_to_chi_snp(ucie_rx_hdr)),
    .w_full(snp_rx_w_full),
    .r_clk(clk), .r_rst_n(clk_rst_n),
    .r_en(chi_snp_valid && chi_snp_ready),
    .r_data(snp_rx_r_data), .r_empty(snp_rx_r_empty)
  );
  assign chi_snp_valid = !snp_rx_r_empty;
  assign chi_snp_data  = snp_rx_r_data;

  // u_snp_rsp_fifo: CHI SnpResp/SnpRespData → UCIe SNP_RSP header (clk write, ucie_clk read)
  // Width = CHI_SNPRSP_W + 1 where bit[CHI_SNPRSP_W] is has_dat flag.
  wire snp_rsp_w_en  = (chi_snp_rsp_valid && chi_snp_rsp_ready);
  wire snp_rsp_dat_accept = (chi_snp_rsp_dat_valid && chi_snp_rsp_dat_ready);

  // Build the stored snp_rsp word from either channel.
  // SnpResp (no data): {1'b0, rsp_data}
  // SnpRespData (with data): extract resp/txnid/srcid from the DAT flit, set has_dat=1.
  wire [CHI_SNPRSP_W-1:0] snp_rsp_from_dat;
  assign snp_rsp_from_dat[CHI_SNPRSP_RESP_LSB   +: CHI_SNPRSP_RESP_W]   =
      chi_snp_rsp_dat_data[CHI_DAT_RESP_LSB +: CHI_SNPRSP_RESP_W];
  assign snp_rsp_from_dat[CHI_SNPRSP_TXNID_LSB  +: CHI_SNPRSP_TXNID_W]  =
      chi_snp_rsp_dat_data[CHI_DAT_TXNID_LSB +: CHI_SNPRSP_TXNID_W];
  assign snp_rsp_from_dat[CHI_SNPRSP_OPCODE_LSB +: CHI_SNPRSP_OPCODE_W] = CHI_SNPRSP_OP;
  assign snp_rsp_from_dat[CHI_SNPRSP_SRCID_LSB  +: CHI_SNPRSP_SRCID_W]  = {NODEID_W{1'b0}};

  wire [CHI_SNPRSP_W:0] snp_rsp_w_data_norm = {1'b0, chi_snp_rsp_data};
  wire [CHI_SNPRSP_W:0] snp_rsp_w_data_dat  = {1'b1, snp_rsp_from_dat};

  // Push to snp_rsp_fifo from either source; dat-path takes priority on same cycle.
  wire snp_rsp_fifo_push    = snp_rsp_dat_accept || snp_rsp_w_en;
  wire [CHI_SNPRSP_W:0] snp_rsp_fifo_wdata = snp_rsp_dat_accept ? snp_rsp_w_data_dat
                                                                  : snp_rsp_w_data_norm;

  assign chi_snp_rsp_ready     = cap_open && !snp_rsp_w_full && !snp_rsp_dat_accept;
  assign chi_snp_rsp_dat_ready = cap_open && !snp_rsp_w_full && !snp_dat_w_full;

  async_fifo #(.WIDTH(CHI_SNPRSP_W+1), .DEPTH(FIFO_DEPTH)) u_snp_rsp_fifo (
    .w_clk(clk), .w_rst_n(clk_rst_n),
    .w_en(snp_rsp_fifo_push),
    .w_data(snp_rsp_fifo_wdata),
    .w_full(snp_rsp_w_full),
    .r_clk(ucie_clk), .r_rst_n(ucie_rst_n),
    .r_en(snp_rsp_hdr_fire),
    .r_data(snp_rsp_r_data), .r_empty(snp_rsp_r_empty)
  );

  // u_snp_dat_fifo: dirty writeback data (clk write, ucie_clk read)
  async_fifo #(.WIDTH(CHI_DAT_W), .DEPTH(FIFO_DEPTH)) u_snp_dat_fifo (
    .w_clk(clk), .w_rst_n(clk_rst_n),
    .w_en(snp_rsp_dat_accept),
    .w_data(chi_snp_rsp_dat_data),
    .w_full(snp_dat_w_full),
    .r_clk(ucie_clk), .r_rst_n(ucie_rst_n),
    .r_en(snp_dat_fire && snp_dat_last),
    .r_data(snp_dat_r_data), .r_empty(snp_dat_r_empty)
  );

  // Snoop data tag queue: push snp_txnid when a has_dat SNP_RSP header fires;
  // pop when the last dirty data beat fires.
  always @(posedge ucie_clk or negedge ucie_rst_n) begin
    if (!ucie_rst_n) begin
      sdq_wptr <= {(WQ_AW+1){1'b0}};
      sdq_rptr <= {(WQ_AW+1){1'b0}};
    end else begin
      if (snp_rsp_hdr_fire && snp_rsp_r_data[CHI_SNPRSP_W]) begin
        sdq_mem[sdq_wptr[WQ_AW-1:0]] <= snp_rsp_r_data[CHI_SNPRSP_TXNID_LSB +: TXNID_W];
        sdq_wptr <= sdq_wptr + 1'b1;
      end
      if (sdq_pop) sdq_rptr <= sdq_rptr + 1'b1;
    end
  end

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
      if (tx_dat_beat_ctr == 0)
        assert (ucie_hdr_crc16_ok(ucie_tx_data));
      assert (!ucie_tx_data_valid || !wq_empty || !sdq_empty);
      // §6.1: data beat counter must not exceed the burst's last beat index.
      if (ucie_tx_data_valid)
        assert (tx_dat_beat_ctr <= wq_front_last_beat);
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

  // §6.4: flit_seq monotonicity.
  // (a) When a request header and a burst header co-fire in the same cycle,
  //     the burst header carries seq = req-header seq + 1.
  // (b) Back-to-back request headers with no intervening burst header and no
  //     stalling on the later header differ by exactly 1 (mod 256).
  always @(posedge ucie_clk) begin
    if (ucie_rst_n) begin
      if (hdr_fire && data_fire && tx_dat_beat_ctr == 3'd0)
        assert (ucie_tx_data[UCIE_SEQ_MSB:UCIE_SEQ_LSB] ==
                ucie_tx_hdr[UCIE_SEQ_MSB:UCIE_SEQ_LSB] + 8'h1);
    end
  end
  always @(posedge ucie_clk) begin
    if (ucie_rst_n && f_ucie_past_valid) begin
      if ($past(hdr_fire) && hdr_fire && !tx_is_snp_rsp &&
          !$past(data_fire && (tx_dat_beat_ctr == 3'd0)))
        assert (ucie_tx_hdr[UCIE_SEQ_MSB:UCIE_SEQ_LSB] ==
                $past(ucie_tx_hdr[UCIE_SEQ_MSB:UCIE_SEQ_LSB]) + 8'h1);
    end
  end
`endif

endmodule
