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

  // Immediate credit return: UCIe peer returns one credit per accepted flit.
  // Simultaneous consume+ret leaves the credit counter unchanged (always available).
  wire        ucie_rx_hdr_crdt = ucie_tx_hdr_valid && ucie_tx_hdr_ready;
  wire        ucie_rx_dat_crdt = ucie_tx_data_valid && ucie_tx_data_ready;
  wire        ucie_tx_hdr_crdt;
  wire        ucie_tx_dat_crdt;

  reg         phy_init_done;
  reg         link_error;
  wire        retrain_req;
  wire [1:0]  link_state;
  wire        sb_tx_valid;
  wire [7:0]  sb_tx_data;
  reg         sb_tx_ready;
  reg         sb_rx_valid;
  reg  [7:0]  sb_rx_data;
  wire        sb_rx_ready;
  wire        pm_l1_active;
  wire [15:0] qos_hi_cnt;
  reg         err_inj_en;
  wire        drain_done;
  wire [15:0] crc_err_cnt;
  wire [15:0] tag_err_cnt;
  wire [15:0] drain_cnt;

  // Local tags the bridge assigns at UCIe header issue (captured by the tb).
  reg [7:0] rd_tag;
  reg [7:0] wr_tag;
  reg [7:0] tag_a;
  reg [7:0] tag_b;

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
    .ucie_rx_hdr_crdt(ucie_rx_hdr_crdt),
    .ucie_rx_dat_crdt(ucie_rx_dat_crdt),
    .ucie_tx_hdr_crdt(ucie_tx_hdr_crdt),
    .ucie_tx_dat_crdt(ucie_tx_dat_crdt),
    .phy_init_done(phy_init_done),
    .link_error(link_error),
    .retrain_req(retrain_req),
    .link_state(link_state),
    .sb_tx_valid(sb_tx_valid),
    .sb_tx_data(sb_tx_data),
    .sb_tx_ready(sb_tx_ready),
    .sb_rx_valid(sb_rx_valid),
    .sb_rx_data(sb_rx_data),
    .sb_rx_ready(sb_rx_ready),
    .pm_l1_active(pm_l1_active),
    .err_inj_en(err_inj_en),
    .qos_hi_cnt(qos_hi_cnt),
    .drain_done(drain_done),
    .crc_err_cnt(crc_err_cnt),
    .tag_err_cnt(tag_err_cnt),
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
      phy_init_done = 1'b0;
      link_error    = 1'b0;
      sb_tx_ready   = 1'b1;
      sb_rx_valid   = 1'b0;
      sb_rx_data    = 8'h00;
      err_inj_en = 1'b0;
      repeat (8) @(posedge clk);
      rst_n = 1'b1;
      phy_init_done = 1'b1;
      repeat (8) @(posedge clk);
      repeat (4) @(posedge ucie_clk);
    end
  endtask

  task automatic send_chi_read;
    input [7:0]  txnid;
    input [47:0] addr;
    input [2:0]  size;
    begin
      @(posedge clk);
      chi_req_data = {CHI_REQ_W{1'b0}};
      chi_req_data[CHI_REQ_OPCODE_LSB +: CHI_REQ_OPCODE_W] = CHI_REQ_READNOSNP;
      chi_req_data[CHI_REQ_ADDR_LSB +: CHI_REQ_ADDR_W] = addr;
      chi_req_data[CHI_REQ_TXNID_LSB +: CHI_REQ_TXNID_W] = txnid;
      chi_req_data[CHI_REQ_SRCID_LSB +: CHI_REQ_SRCID_W] = 7'h12;
      chi_req_data[CHI_REQ_SIZE_LSB +: CHI_REQ_SIZE_W] = size;
      chi_req_valid = 1'b1;
      while (!chi_req_ready) @(posedge clk);
      @(posedge clk);
      chi_req_valid = 1'b0;
    end
  endtask

  task automatic send_chi_write;
    input [7:0]   txnid;
    input [47:0]  addr;
    input [511:0] data;
    input [2:0]   size;
    begin
      @(posedge clk);
      chi_req_data = {CHI_REQ_W{1'b0}};
      chi_req_data[CHI_REQ_OPCODE_LSB +: CHI_REQ_OPCODE_W] = CHI_REQ_WRITENOSNPFULL;
      chi_req_data[CHI_REQ_ADDR_LSB +: CHI_REQ_ADDR_W] = addr;
      chi_req_data[CHI_REQ_TXNID_LSB +: CHI_REQ_TXNID_W] = txnid;
      chi_req_data[CHI_REQ_SRCID_LSB +: CHI_REQ_SRCID_W] = 7'h34;
      chi_req_data[CHI_REQ_SIZE_LSB +: CHI_REQ_SIZE_W] = size;
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

  // §6.1: variable-beat MEM_CPL completion driver.
  // size=4 → 1 data beat (16B), size=5 → 2 beats (32B), size=6 → 4 beats (64B).
  task automatic drive_rx_burst;
    input [7:0]   tag;
    input [511:0] data;
    input [2:0]   size;
    integer i, num_beats;
    reg [UCIE_HDR_W-1:0] hdr;
    begin
      case (size)
        3'd4:    num_beats = 1;
        3'd5:    num_beats = 2;
        default: num_beats = 4;  // size=6
      endcase
      hdr = pack_ucie_hdr(UCIE_PKT_KIND_MEM_CPL, UCIE_CPL_SC, tag,
                          48'h0000_0000_0040, (8'h01 << size), 8'h55, 8'h00, 8'h00);
      ucie_rx_data = hdr;
      ucie_rx_data_valid = 1'b1;
      while (!ucie_rx_data_ready) @(posedge ucie_clk);
      @(posedge ucie_clk); #1;
      for (i = 0; i < num_beats; i = i + 1) begin
        ucie_rx_data = data[i*128 +: 128];
        ucie_rx_data_valid = 1'b1;
        while (!ucie_rx_data_ready) @(posedge ucie_clk);
        @(posedge ucie_clk); #1;
      end
      ucie_rx_data_valid = 1'b0;
    end
  endtask

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
    send_chi_read(8'h3c, 48'hBEEF_CAFE_1234, 3'h6);
    wait (ucie_tx_hdr_valid);
    if (ucie_tx_hdr[UCIE_KIND_MSB:UCIE_KIND_LSB] !== UCIE_PKT_KIND_AD_REQ) begin
      $display("FAIL: expected UCIe AD_REQ"); $finish(1);
    end
    if (ucie_tx_hdr[UCIE_CODE_MSB:UCIE_CODE_LSB] !== UCIE_MSG_MEM_RD) begin
      $display("FAIL: expected UCIe MEM_RD"); $finish(1);
    end
    if (ucie_tx_hdr[UCIE_ADDR_MSB:UCIE_ADDR_LSB] !== 48'hBEEF_CAFE_1234) begin
      $display("FAIL: read address mismatch"); $finish(1);
    end
    // Phase 2: the bridge issues a bridge-local tag, not the CHI TxnID. Capture
    // it so the completion can be replayed against the same tag.
    rd_tag = ucie_tx_hdr[UCIE_TAG_MSB:UCIE_TAG_LSB];
    @(posedge ucie_clk);

    $display("INFO: CHI write -> UCIe AD_REQ + DATA multi-beat smoke");
    ucie_tx_data_ready = 1'b1;
    send_chi_write(8'hd2, 48'hDEAD_BEEF_5678,
                   512'h12345678_9ABCDEF0_FEDCBA98_76543210_11223344_55667788_99AABBCC_DDEEFF00, 3'h6);
    wait (ucie_tx_hdr_valid);
    if (ucie_tx_hdr[UCIE_CODE_MSB:UCIE_CODE_LSB] !== UCIE_MSG_MEM_WR) begin
      $display("FAIL: expected UCIe MEM_WR"); $finish(1);
    end
    wr_tag = ucie_tx_hdr[UCIE_TAG_MSB:UCIE_TAG_LSB];
    if (wr_tag === rd_tag) begin
      $display("FAIL: write reused the outstanding read's local tag"); $finish(1);
    end
    
    // Beat 0: Header
    wait (ucie_tx_data_valid);
    #1;
    if (ucie_tx_data[UCIE_KIND_MSB:UCIE_KIND_LSB] !== UCIE_PKT_KIND_AD_REQ) begin
      $display("FAIL: expected UCIe write data header (AD_REQ)"); $finish(1);
    end
    if (ucie_tx_data[UCIE_CODE_MSB:UCIE_CODE_LSB] !== UCIE_MSG_MEM_WR_DATA) begin
      $display("FAIL: expected UCIe write data opcode (WR_DATA)"); $finish(1);
    end
    if (ucie_tx_data[UCIE_TAG_MSB:UCIE_TAG_LSB] !== wr_tag) begin
      $display("FAIL: write data tag mismatch in beat 0"); $finish(1);
    end
    @(posedge ucie_clk);

    // Beats 1..4: Data
    begin : check_tx_data
      integer i;
      reg [511:0] exp_data;
      exp_data = 512'h12345678_9ABCDEF0_FEDCBA98_76543210_11223344_55667788_99AABBCC_DDEEFF00;
      for (i = 0; i < 4; i = i + 1) begin
        #1;
        if (ucie_tx_data !== exp_data[i*128 +: 128]) begin
          $display("FAIL: TX data payload mismatch in beat %0d (got %h exp %h)", i+1, ucie_tx_data, exp_data[i*128 +: 128]); $finish(1);
        end
        @(posedge ucie_clk);
      end
    end

    $display("INFO: UCIe AD_CPL -> CHI RSP smoke (TxnID restored from table)");
    chi_rsp_ready = 1'b1;
    @(posedge ucie_clk);
    ucie_rx_hdr = pack_ucie_hdr(UCIE_PKT_KIND_AD_CPL, UCIE_CPL_SC, wr_tag,
                               48'h0000_0000_0000, 8'h00, 8'h55, 8'h00, 8'h00);
    ucie_rx_hdr_valid = 1'b1;
    while (!ucie_rx_hdr_ready) @(posedge ucie_clk);
    @(posedge ucie_clk);
    ucie_rx_hdr_valid = 1'b0;
    wait (chi_rsp_valid);
    if (chi_rsp_data[CHI_RSP_OPCODE_LSB +: CHI_RSP_OPCODE_W] !== CHI_RSP_COMP) begin
      $display("FAIL: expected CHI Comp"); $finish(1);
    end
    if (chi_rsp_data[CHI_RSP_TXNID_LSB +: CHI_RSP_TXNID_W] !== 8'hd2) begin
      $display("FAIL: CHI response TxnID not restored to 0xd2"); $finish(1);
    end
    @(posedge clk);

    $display("INFO: UCIe MEM_CPL data multi-beat -> CHI CompData smoke");
    chi_comp_data_ready = 1'b1;
    drive_rx_burst(rd_tag, 512'hFEEDFACE_CAFEBABE_DEADC0DE_00000001, 3'h6);
    wait (chi_comp_data_valid);
    if (chi_comp_data[CHI_DAT_OPCODE_LSB +: CHI_DAT_OPCODE_W] !== CHI_DAT_COMPDATA) begin
      $display("FAIL: expected CHI CompData"); $finish(1);
    end
    if (chi_comp_data[CHI_DAT_TXNID_LSB +: CHI_DAT_TXNID_W] !== 8'h3c) begin
      $display("FAIL: CHI data TxnID not restored to 0x3c"); $finish(1);
    end
    if (chi_comp_data[CHI_DAT_DATA_LSB +: 64] !== 64'hDEADC0DE_00000001) begin
      $display("FAIL: CHI data payload mismatch"); $finish(1);
    end
    @(posedge clk);

    $display("INFO: two reads reusing CHI TxnID -> distinct local tags");
    // Issue two reads with the same CHI TxnID while both stay outstanding.
    send_chi_read(8'h77, 48'h0000_0000_AA00, 3'h6);
    wait (ucie_tx_hdr_valid);
    tag_a = ucie_tx_hdr[UCIE_TAG_MSB:UCIE_TAG_LSB];
    @(posedge ucie_clk);
    send_chi_read(8'h77, 48'h0000_0000_BB00, 3'h6);
    wait (ucie_tx_hdr_valid);
    tag_b = ucie_tx_hdr[UCIE_TAG_MSB:UCIE_TAG_LSB];
    @(posedge ucie_clk);
    if (tag_a === tag_b) begin
      $display("FAIL: duplicate CHI TxnID got the same local tag"); $finish(1);
    end
    // Complete both and confirm each restores TxnID 0x77.
    drive_rx_burst(tag_a, 512'h0000_0000_0000_00A0, 3'h6);
    wait (chi_comp_data_valid);
    if (chi_comp_data[CHI_DAT_TXNID_LSB +: CHI_DAT_TXNID_W] !== 8'h77) begin
      $display("FAIL: first reused-TxnID completion not restored to 0x77"); $finish(1);
    end
    @(posedge clk);
    drive_rx_burst(tag_b, 512'h0000_0000_0000_00B0, 3'h6);
    wait (chi_comp_data_valid && (chi_comp_data[CHI_DAT_DATA_LSB +: 8] === 8'hB0));
    if (chi_comp_data[CHI_DAT_TXNID_LSB +: CHI_DAT_TXNID_W] !== 8'h77) begin
      $display("FAIL: second reused-TxnID completion not restored to 0x77"); $finish(1);
    end
    @(posedge clk);

    if (tag_err_cnt !== 16'h0000) begin
      $display("FAIL: unexpected tag_err_cnt=%0d", tag_err_cnt); $finish(1);
    end

    $display("INFO: QoS field routing - QoS=0xF carried into UCIe attr[3:0]");
    begin : qos_check
      reg [15:0] cnt_before;
      cnt_before = qos_hi_cnt;
      // Build a read with QoS=0xF in the CHI REQ flit.
      chi_req_data = {CHI_REQ_W{1'b0}};
      chi_req_data[CHI_REQ_OPCODE_LSB +: CHI_REQ_OPCODE_W] = CHI_REQ_READNOSNP;
      chi_req_data[CHI_REQ_ADDR_LSB   +: CHI_REQ_ADDR_W]   = 48'hC0CA_C0CA_F00D;
      chi_req_data[CHI_REQ_TXNID_LSB  +: CHI_REQ_TXNID_W]  = 8'hFE;
      chi_req_data[CHI_REQ_SRCID_LSB  +: CHI_REQ_SRCID_W]  = 7'h12;
      chi_req_data[CHI_REQ_SIZE_LSB   +: CHI_REQ_SIZE_W]   = 3'h6;
      chi_req_data[CHI_REQ_QOS_LSB    +: CHI_REQ_QOS_W]    = 4'hF;
      chi_req_valid = 1'b1;
      while (!chi_req_ready) @(posedge clk);
      @(posedge clk);
      chi_req_valid = 1'b0;
      wait (ucie_tx_hdr_valid);
      #1;
      if (ucie_tx_hdr[UCIE_ATTR_LSB +: 4] !== 4'hF) begin
        $display("FAIL: QoS not routed to attr[3:0] (got %h)", ucie_tx_hdr[UCIE_ATTR_LSB +: 4]);
        $finish(1);
      end
      @(posedge ucie_clk); #1;  // let non-blocking assignments settle
      if (qos_hi_cnt !== cnt_before + 16'h1) begin
        $display("FAIL: qos_hi_cnt not incremented (was %0d now %0d)", cnt_before, qos_hi_cnt);
        $finish(1);
      end
    end

    $display("INFO: §6.1 size=5 (32B) write -> 2-beat UCIe data burst");
    begin : subcl_write
      reg [7:0]   w5_tag;
      reg [511:0] w5_data;
      reg [7:0]   len_field;
      integer     b;
      w5_data = 512'hAABBCCDD_EEFF0011_22334455_66778899_A0B0C0D0_E0F00010_20304050_60708090;
      send_chi_write(8'hA5, 48'hAA_BB_CC_DD_EE_FF, w5_data, 3'h5);
      wait (ucie_tx_hdr_valid);
      #1;
      if (ucie_tx_hdr[UCIE_CODE_MSB:UCIE_CODE_LSB] !== UCIE_MSG_MEM_WR) begin
        $display("FAIL: size=5 write: expected MEM_WR header"); $finish(1);
      end
      w5_tag = ucie_tx_hdr[UCIE_TAG_MSB:UCIE_TAG_LSB];
      @(posedge ucie_clk);
      // Beat 0: data-burst header — verify length=0x20 (32 bytes)
      wait (ucie_tx_data_valid);
      #1;
      len_field = ucie_tx_data[UCIE_LEN_MSB:UCIE_LEN_LSB];
      if (len_field !== 8'h20) begin
        $display("FAIL: size=5 write: data-burst header length 0x%02h (exp 0x20)", len_field);
        $finish(1);
      end
      if (ucie_tx_data[UCIE_TAG_MSB:UCIE_TAG_LSB] !== w5_tag) begin
        $display("FAIL: size=5 write: data-burst tag mismatch"); $finish(1);
      end
      @(posedge ucie_clk);
      // Beat 1: first 128 bits
      #1;
      if (ucie_tx_data !== w5_data[127:0]) begin
        $display("FAIL: size=5 write: beat-1 payload mismatch"); $finish(1);
      end
      @(posedge ucie_clk);
      // Beat 2: second 128 bits (last beat — no beat 3 or 4)
      #1;
      if (ucie_tx_data !== w5_data[255:128]) begin
        $display("FAIL: size=5 write: beat-2 payload mismatch"); $finish(1);
      end
      @(posedge ucie_clk);
      // Confirm beat 3 does NOT arrive (ucie_tx_data_valid must drop or point to next req)
      #1;
      if (ucie_tx_data_valid) begin
        $display("FAIL: size=5 write: extra data beat after beat 2"); $finish(1);
      end
      // Send AD_CPL completion and check CHI RSP
      @(posedge ucie_clk);
      ucie_rx_hdr = pack_ucie_hdr(UCIE_PKT_KIND_AD_CPL, UCIE_CPL_SC, w5_tag,
                                  48'h0, 8'h00, 8'h55, 8'h00, 8'h00);
      ucie_rx_hdr_valid = 1'b1;
      while (!ucie_rx_hdr_ready) @(posedge ucie_clk);
      @(posedge ucie_clk);
      ucie_rx_hdr_valid = 1'b0;
      wait (chi_rsp_valid);
      if (chi_rsp_data[CHI_RSP_TXNID_LSB +: CHI_RSP_TXNID_W] !== 8'hA5) begin
        $display("FAIL: size=5 write: CHI RSP TxnID not restored to 0xA5"); $finish(1);
      end
      @(posedge clk);
    end

    $display("INFO: §6.1 size=5 (32B) read -> 2-beat MEM_CPL completion");
    begin : subcl_read
      reg [7:0]   r5_tag;
      reg [511:0] r5_data;
      r5_data = {256'h0,
                 256'hFEDCBA98_76543210_0F0E0D0C_0B0A0908_07060504_03020100_AABBCCDD_EEFF1122};
      chi_req_data = {CHI_REQ_W{1'b0}};
      chi_req_data[CHI_REQ_OPCODE_LSB +: CHI_REQ_OPCODE_W] = CHI_REQ_READNOSNP;
      chi_req_data[CHI_REQ_ADDR_LSB   +: CHI_REQ_ADDR_W]   = 48'hFF_EE_DD_CC_BB_AA;
      chi_req_data[CHI_REQ_TXNID_LSB  +: CHI_REQ_TXNID_W]  = 8'hB5;
      chi_req_data[CHI_REQ_SRCID_LSB  +: CHI_REQ_SRCID_W]  = 7'h12;
      chi_req_data[CHI_REQ_SIZE_LSB   +: CHI_REQ_SIZE_W]   = 3'h5;
      chi_req_valid = 1'b1;
      while (!chi_req_ready) @(posedge clk);
      @(posedge clk);
      chi_req_valid = 1'b0;
      wait (ucie_tx_hdr_valid);
      r5_tag = ucie_tx_hdr[UCIE_TAG_MSB:UCIE_TAG_LSB];
      @(posedge ucie_clk);
      drive_rx_burst(r5_tag, r5_data, 3'h5);
      wait (chi_comp_data_valid);
      if (chi_comp_data[CHI_DAT_TXNID_LSB +: CHI_DAT_TXNID_W] !== 8'hB5) begin
        $display("FAIL: size=5 read: CHI CompData TxnID mismatch"); $finish(1);
      end
      if (chi_comp_data[CHI_DAT_DATA_LSB +: 256] !== r5_data[255:0]) begin
        $display("FAIL: size=5 read: 32B data payload mismatch"); $finish(1);
      end
      if (chi_comp_data[CHI_DAT_DATA_LSB+256 +: 256] !== 256'h0) begin
        $display("FAIL: size=5 read: upper 256 bits not zero-extended"); $finish(1);
      end
      @(posedge clk);
    end

    $display("PASS CHI-to-UCIe bridge directed smoke");
    $finish(0);
  end

endmodule
