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
  wire [BE_W-1:0]        ucie_tx_data_be;

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
  wire [15:0] qos_lo_stall_cnt;

  // §9: Snoop channels
  wire                 chi_snp_valid;
  wire [CHI_SNP_W-1:0] chi_snp_data;
  reg                  chi_snp_ready;
  reg                  chi_snp_rsp_valid;
  reg [CHI_SNPRSP_W-1:0] chi_snp_rsp_data;
  wire                 chi_snp_rsp_ready;
  reg                  chi_snp_rsp_dat_valid;
  reg [CHI_DAT_W-1:0]  chi_snp_rsp_dat_data;
  wire                 chi_snp_rsp_dat_ready;

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
    .FIFO_DEPTH(FIFO_DEPTH),
    .QOS_THROTTLE_WM(6)   // §10: low enough to test with the 4 carry-over outstanding + 2 new hi-QoS
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
    .ucie_tx_data_be(ucie_tx_data_be),
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
    .qos_lo_stall_cnt(qos_lo_stall_cnt),
    .chi_snp_valid(chi_snp_valid),
    .chi_snp_data(chi_snp_data),
    .chi_snp_ready(chi_snp_ready),
    .chi_snp_rsp_valid(chi_snp_rsp_valid),
    .chi_snp_rsp_data(chi_snp_rsp_data),
    .chi_snp_rsp_ready(chi_snp_rsp_ready),
    .chi_snp_rsp_dat_valid(chi_snp_rsp_dat_valid),
    .chi_snp_rsp_dat_data(chi_snp_rsp_dat_data),
    .chi_snp_rsp_dat_ready(chi_snp_rsp_dat_ready),
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
      chi_snp_ready         = 1'b1;
      chi_snp_rsp_valid     = 1'b0;
      chi_snp_rsp_data      = {CHI_SNPRSP_W{1'b0}};
      chi_snp_rsp_dat_valid = 1'b0;
      chi_snp_rsp_dat_data  = {CHI_DAT_W{1'b0}};
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

  // §7.2: two-phase write. Drives the request alone, consumes the DBIDResp to
  // learn the allocated DBID, then drives WriteData tagged with that DBID.
  // Wraps the request opcode + BE so both full and partial writes share it.
  task automatic send_chi_write_op;
    input [6:0]   opcode;
    input [7:0]   txnid;
    input [47:0]  addr;
    input [511:0] data;
    input [63:0]  be;
    input [2:0]   size;
    reg [CHI_RSP_DBID_W-1:0] dbid;
    reg saved_rsp_ready;
    begin
      // Phase 1: request only (no WriteData yet).
      @(posedge clk);
      chi_req_data = {CHI_REQ_W{1'b0}};
      chi_req_data[CHI_REQ_OPCODE_LSB +: CHI_REQ_OPCODE_W] = opcode;
      chi_req_data[CHI_REQ_ADDR_LSB   +: CHI_REQ_ADDR_W]   = addr;
      chi_req_data[CHI_REQ_TXNID_LSB  +: CHI_REQ_TXNID_W]  = txnid;
      chi_req_data[CHI_REQ_SRCID_LSB  +: CHI_REQ_SRCID_W]  = 7'h34;
      chi_req_data[CHI_REQ_SIZE_LSB   +: CHI_REQ_SIZE_W]   = size;
      chi_req_valid = 1'b1;
      while (!chi_req_ready) @(posedge clk);
      @(posedge clk);
      chi_req_valid = 1'b0;

      // Consume the DBIDResp deterministically: hold the RSP channel closed so the
      // DBIDResp (highest arbiter priority) waits at the head, capture it, then
      // pulse ready once to pop only it. Restore the caller's ready afterward so
      // the TB's persistent-ready convention for completions is preserved.
      saved_rsp_ready = chi_rsp_ready;
      chi_rsp_ready = 1'b0;
      @(posedge clk);
      while (!(chi_rsp_valid &&
               chi_rsp_data[CHI_RSP_OPCODE_LSB +: CHI_RSP_OPCODE_W] == CHI_RSP_DBIDRESP))
        @(posedge clk);
      dbid = chi_rsp_data[CHI_RSP_DBID_LSB +: CHI_RSP_DBID_W];
      if (chi_rsp_data[CHI_RSP_TXNID_LSB +: CHI_RSP_TXNID_W] !== txnid) begin
        $display("FAIL: §7.2: DBIDResp TxnID mismatch (got %h exp %h)",
                 chi_rsp_data[CHI_RSP_TXNID_LSB +: CHI_RSP_TXNID_W], txnid); $finish(1);
      end
      chi_rsp_ready = 1'b1;
      @(posedge clk);
      chi_rsp_ready = saved_rsp_ready;

      // Phase 2: WriteData tagged with the DBID (echoed in the DAT TxnID field).
      @(posedge clk);
      chi_wr_data = {CHI_DAT_W{1'b0}};
      chi_wr_data[CHI_DAT_OPCODE_LSB  +: CHI_DAT_OPCODE_W] = CHI_DAT_NCBWRDATA;
      chi_wr_data[CHI_DAT_TXNID_LSB   +: CHI_DAT_TXNID_W]  = {{(TXNID_W-CHI_RSP_DBID_W){1'b0}}, dbid};
      chi_wr_data[CHI_DAT_BE_LSB      +: CHI_DAT_BE_W]     = be;
      chi_wr_data[CHI_DAT_DATA_LSB    +: CHI_DAT_DATA_W]   = data;
      chi_wr_data_valid = 1'b1;
      while (!chi_wr_data_ready) @(posedge clk);
      @(posedge clk);
      chi_wr_data_valid = 1'b0;
    end
  endtask

  task automatic send_chi_write;
    input [7:0]   txnid;
    input [47:0]  addr;
    input [511:0] data;
    input [2:0]   size;
    begin
      send_chi_write_op(CHI_REQ_WRITENOSNPFULL, txnid, addr, data, {BE_W{1'b1}}, size);
    end
  endtask

  // §6.2: partial-write helper — uses WRITENOSNPPTL with caller-supplied BE mask.
  task automatic send_chi_partial_write;
    input [7:0]   txnid;
    input [47:0]  addr;
    input [511:0] data;
    input [63:0]  be;
    input [2:0]   size;
    begin
      send_chi_write_op(CHI_REQ_WRITENOSNPPTL, txnid, addr, data, be, size);
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

  // §6.3: split-completion driver.  Sends two 32-byte MEM_CPL bursts for the
  // same local tag: first with addr[4]=0 (lower half, DataID=0), second with
  // addr[4]=1 (upper half, DataID=2).  data[255:0] = lower, data[511:256] = upper.
  task automatic drive_rx_split;
    input [7:0]   tag;
    input [511:0] data;
    reg [UCIE_HDR_W-1:0] hdr;
    integer i;
    begin
      // Lower half: addr[4]=0, length=0x20, 2 data beats
      hdr = pack_ucie_hdr(UCIE_PKT_KIND_MEM_CPL, UCIE_CPL_SC, tag,
                          48'h0000_0000_0000, 8'h20, 8'h55, 8'h00, 8'h00);
      ucie_rx_data = hdr;
      ucie_rx_data_valid = 1'b1;
      while (!ucie_rx_data_ready) @(posedge ucie_clk);
      @(posedge ucie_clk); #1;
      for (i = 0; i < 2; i = i + 1) begin
        ucie_rx_data = data[i*128 +: 128];
        ucie_rx_data_valid = 1'b1;
        while (!ucie_rx_data_ready) @(posedge ucie_clk);
        @(posedge ucie_clk); #1;
      end
      ucie_rx_data_valid = 1'b0;
      // Upper half: addr[4]=1 (addr=0x10), length=0x20, 2 data beats
      hdr = pack_ucie_hdr(UCIE_PKT_KIND_MEM_CPL, UCIE_CPL_SC, tag,
                          48'h0000_0000_0010, 8'h20, 8'h55, 8'h00, 8'h00);
      ucie_rx_data = hdr;
      ucie_rx_data_valid = 1'b1;
      while (!ucie_rx_data_ready) @(posedge ucie_clk);
      @(posedge ucie_clk); #1;
      for (i = 0; i < 2; i = i + 1) begin
        ucie_rx_data = data[256 + i*128 +: 128];
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

    $display("INFO: §6.2 WRITENOSNPPTL BE forwarding (BE=64'h0000_FFFF_FFFF_FFFF, size=5)");
    begin : subcl_be
      reg [7:0]   be_tag;
      reg [63:0]  exp_be;
      reg [511:0] be_data;
      exp_be  = 64'h0000_FFFF_FFFF_FFFF;
      be_data = 512'hA0B1C2D3_E4F50617_28394A5B_6C7D8E9F_1A2B3C4D_5E6F7081_92A3B4C5_D6E7F809;
      send_chi_partial_write(8'hC3, 48'h1234_5678_9ABC, be_data, exp_be, 3'h5);
      wait (ucie_tx_hdr_valid);
      #1;
      if (ucie_tx_hdr[UCIE_CODE_MSB:UCIE_CODE_LSB] !== UCIE_MSG_MEM_WR) begin
        $display("FAIL: §6.2: expected MEM_WR header"); $finish(1);
      end
      be_tag = ucie_tx_hdr[UCIE_TAG_MSB:UCIE_TAG_LSB];
      @(posedge ucie_clk);
      // Beat 0: data-burst header — ucie_tx_data_be must carry the CHI_DAT_BE
      wait (ucie_tx_data_valid);
      #1;
      if (ucie_tx_data_be !== exp_be) begin
        $display("FAIL: §6.2: ucie_tx_data_be=%h exp %h", ucie_tx_data_be, exp_be); $finish(1);
      end
      @(posedge ucie_clk);
      // Beat 1: first 128 bits
      #1;
      if (ucie_tx_data !== be_data[127:0]) begin
        $display("FAIL: §6.2: beat-1 data mismatch"); $finish(1);
      end
      @(posedge ucie_clk);
      // Beat 2: second 128 bits (last for size=5)
      #1;
      if (ucie_tx_data !== be_data[255:128]) begin
        $display("FAIL: §6.2: beat-2 data mismatch"); $finish(1);
      end
      @(posedge ucie_clk);
      // AD_CPL → CHI RSP Comp with TxnID restored
      ucie_rx_hdr = pack_ucie_hdr(UCIE_PKT_KIND_AD_CPL, UCIE_CPL_SC, be_tag,
                                  48'h0, 8'h00, 8'h55, 8'h00, 8'h00);
      ucie_rx_hdr_valid = 1'b1;
      while (!ucie_rx_hdr_ready) @(posedge ucie_clk);
      @(posedge ucie_clk);
      ucie_rx_hdr_valid = 1'b0;
      wait (chi_rsp_valid);
      if (chi_rsp_data[CHI_RSP_TXNID_LSB +: CHI_RSP_TXNID_W] !== 8'hC3) begin
        $display("FAIL: §6.2: CHI RSP TxnID not restored to 0xC3"); $finish(1);
      end
      @(posedge clk);
    end

    $display("INFO: §6.3 split read-completion: two 32-byte MEM_CPLs -> two CHI CompData");
    begin : subcl_split
      reg [7:0]   split_tag;
      reg [511:0] split_data;
      // Lower half: data[255:0], upper half: data[511:256] — both non-zero and distinct.
      split_data = {
        256'hDEAD_BEEF_CAFE_BABE_1234_5678_9ABC_DEF0_F0E1_D2C3_B4A5_9687_7869_5A4B_3C2D_1E0F,
        256'hAABB_CCDD_EEFF_0011_2233_4455_6677_8899_A0B0_C0D0_E0F0_0010_2030_4050_6070_8090
      };
      send_chi_read(8'hD5, 48'h5555_AAAA_0000, 3'h6);
      wait (ucie_tx_hdr_valid);
      split_tag = ucie_tx_hdr[UCIE_TAG_MSB:UCIE_TAG_LSB];
      @(posedge ucie_clk);
      drive_rx_split(split_tag, split_data);
      // First CompData: DataID=0, split_data[255:0] at CHI DATA[255:0]
      wait (chi_comp_data_valid);
      if (chi_comp_data[CHI_DAT_TXNID_LSB +: CHI_DAT_TXNID_W] !== 8'hD5) begin
        $display("FAIL: §6.3: first CompData TxnID mismatch"); $finish(1);
      end
      if (chi_comp_data[CHI_DAT_DATAID_LSB +: CHI_DAT_DATAID_W] !== 4'h0) begin
        $display("FAIL: §6.3: first CompData DataID not 0 (got %h)", chi_comp_data[CHI_DAT_DATAID_LSB +: CHI_DAT_DATAID_W]); $finish(1);
      end
      if (chi_comp_data[CHI_DAT_DATA_LSB +: 256] !== split_data[255:0]) begin
        $display("FAIL: §6.3: first CompData lower 256 bits mismatch"); $finish(1);
      end
      @(posedge clk);
      // Second CompData: DataID=2, split_data[511:256] at CHI DATA[511:256]; lower 256 must be zero
      wait (chi_comp_data_valid && chi_comp_data[CHI_DAT_DATAID_LSB +: CHI_DAT_DATAID_W] === 4'h2);
      if (chi_comp_data[CHI_DAT_TXNID_LSB +: CHI_DAT_TXNID_W] !== 8'hD5) begin
        $display("FAIL: §6.3: second CompData TxnID mismatch"); $finish(1);
      end
      if (chi_comp_data[CHI_DAT_DATA_LSB +: 256] !== 256'h0) begin
        $display("FAIL: §6.3: second CompData lower 256 bits not zero (DataID=2 placement bug)"); $finish(1);
      end
      if (chi_comp_data[CHI_DAT_DATA_LSB+256 +: 256] !== split_data[511:256]) begin
        $display("FAIL: §6.3: second CompData upper 256 bits mismatch"); $finish(1);
      end
      @(posedge clk);
    end

    $display("INFO: §6.4 TX header flit_seq monotonically increasing (burst treated as single unit)");
    begin : subcl_seq
      reg [7:0] seq_a, seq_b, seq_wr;
      // Two consecutive reads: each req header should increment flit_seq by 1.
      send_chi_read(8'hE1, 48'h1000_0000_0000, 3'h6);
      wait (ucie_tx_hdr_valid);
      seq_a = ucie_tx_hdr[UCIE_SEQ_MSB:UCIE_SEQ_LSB];
      @(posedge ucie_clk);
      send_chi_read(8'hE2, 48'h2000_0000_0000, 3'h6);
      wait (ucie_tx_hdr_valid);
      seq_b = ucie_tx_hdr[UCIE_SEQ_MSB:UCIE_SEQ_LSB];
      @(posedge ucie_clk);
      if (seq_b !== seq_a + 8'h1) begin
        $display("FAIL: §6.4: read B flit_seq not seq_A+1 (got %h exp %h)",
                 seq_b, seq_a + 8'h1); $finish(1);
      end
      // Write: req header gets seq_B+1; data burst header (beat 0) gets seq_B+2.
      send_chi_write(8'hE3, 48'h3000_0000_0000, 512'hCC, 3'h6);
      wait (ucie_tx_hdr_valid);
      seq_wr = ucie_tx_hdr[UCIE_SEQ_MSB:UCIE_SEQ_LSB];
      if (seq_wr !== seq_b + 8'h1) begin
        $display("FAIL: §6.4: write req header flit_seq not seq_B+1 (got %h exp %h)",
                 seq_wr, seq_b + 8'h1); $finish(1);
      end
      @(posedge ucie_clk);
      wait (ucie_tx_data_valid);
      #1;
      if (ucie_tx_data[UCIE_SEQ_MSB:UCIE_SEQ_LSB] !== seq_wr + 8'h1) begin
        $display("FAIL: §6.4: write burst header flit_seq not seq_WR+1 (got %h exp %h)",
                 ucie_tx_data[UCIE_SEQ_MSB:UCIE_SEQ_LSB], seq_wr + 8'h1); $finish(1);
      end
      @(posedge ucie_clk);
    end

    $display("INFO: §7.1 unsupported opcode -> CHI Comp with RespErr=NDERR (no deadlock)");
    begin : bad_op
      chi_rsp_ready = 1'b1;
      @(posedge clk);
      chi_req_data = {CHI_REQ_W{1'b0}};
      chi_req_data[CHI_REQ_OPCODE_LSB +: CHI_REQ_OPCODE_W] = 7'h50;  // not read/write
      chi_req_data[CHI_REQ_TXNID_LSB  +: CHI_REQ_TXNID_W]  = 8'hBA;
      chi_req_data[CHI_REQ_SRCID_LSB  +: CHI_REQ_SRCID_W]  = 7'h5A;
      chi_req_valid = 1'b1;
      // Must be accepted within a bounded time (the Phase-1 bug stalled forever).
      fork : accept_watchdog
        begin
          while (!chi_req_ready) @(posedge clk);
          disable accept_watchdog;
        end
        begin
          repeat (64) @(posedge clk);
          $display("FAIL: §7.1: unsupported opcode never accepted (request-channel deadlock)");
          $finish(1);
        end
      join
      @(posedge clk);
      chi_req_valid = 1'b0;
      // No UCIe header must be issued for a rejected request.
      if (ucie_tx_hdr_valid) begin
        $display("FAIL: §7.1: rejected opcode issued a UCIe header"); $finish(1);
      end
      wait (chi_rsp_valid);
      if (chi_rsp_data[CHI_RSP_OPCODE_LSB +: CHI_RSP_OPCODE_W] !== CHI_RSP_COMP) begin
        $display("FAIL: §7.1: expected CHI Comp for rejected opcode"); $finish(1);
      end
      if (chi_rsp_data[CHI_RSP_RESPERR_LSB +: CHI_RSP_RESPERR_W] !== CHI_RESPERR_NDERR) begin
        $display("FAIL: §7.1: rejected opcode RespErr not NDERR (got %h)",
                 chi_rsp_data[CHI_RSP_RESPERR_LSB +: CHI_RSP_RESPERR_W]); $finish(1);
      end
      if (chi_rsp_data[CHI_RSP_TXNID_LSB +: CHI_RSP_TXNID_W] !== 8'hBA) begin
        $display("FAIL: §7.1: rejected opcode TxnID not echoed (got %h)",
                 chi_rsp_data[CHI_RSP_TXNID_LSB +: CHI_RSP_TXNID_W]); $finish(1);
      end
      if (chi_rsp_data[CHI_RSP_SRCID_LSB +: CHI_RSP_SRCID_W] !== 7'h5A) begin
        $display("FAIL: §7.1: rejected opcode SrcID not echoed"); $finish(1);
      end
      @(posedge clk);
      chi_rsp_ready = 1'b0;
    end

    $display("INFO: §8 CMO opcodes -> UCIE_PKT_KIND_CMO header + CHI Comp on AD_CPL return");
    begin : cmo_ops
      reg [7:0] cmo_tag;
      // Test all four CMO opcodes in sequence.  Each produces a header-only UCIe
      // packet; no write data follows.  The far side returns AD_CPL → CHI Comp.
      integer cmo_i;
      reg [6:0] cmo_opcodes [0:3];
      reg [7:0] cmo_txnids  [0:3];
      begin
        cmo_opcodes[0] = CHI_REQ_CLEANSHARED;
        cmo_opcodes[1] = CHI_REQ_CLEANSHAREDPERSIST;
        cmo_opcodes[2] = CHI_REQ_CLEANINVALID;
        cmo_opcodes[3] = CHI_REQ_MAKEINVALID;
        cmo_txnids[0]  = 8'hC0;
        cmo_txnids[1]  = 8'hC1;
        cmo_txnids[2]  = 8'hC2;
        cmo_txnids[3]  = 8'hC3;
        chi_rsp_ready = 1'b1;
        for (cmo_i = 0; cmo_i < 4; cmo_i = cmo_i + 1) begin
          @(posedge clk);
          chi_req_data = {CHI_REQ_W{1'b0}};
          chi_req_data[CHI_REQ_OPCODE_LSB +: CHI_REQ_OPCODE_W] = cmo_opcodes[cmo_i];
          chi_req_data[CHI_REQ_TXNID_LSB  +: CHI_REQ_TXNID_W]  = cmo_txnids[cmo_i];
          chi_req_data[CHI_REQ_SRCID_LSB  +: CHI_REQ_SRCID_W]  = 7'h1C;
          chi_req_data[CHI_REQ_SIZE_LSB   +: CHI_REQ_SIZE_W]   = 3'h6;
          chi_req_data[CHI_REQ_ADDR_LSB   +: CHI_REQ_ADDR_W]   = 48'hA000_0000_0040 * (cmo_i + 1);
          chi_req_valid = 1'b1;
          while (!chi_req_ready) @(posedge clk);
          @(posedge clk);
          chi_req_valid = 1'b0;
          // UCIe header must be kind=CMO and code=opcode[3:0].
          wait (ucie_tx_hdr_valid);
          if (ucie_tx_hdr[UCIE_KIND_MSB:UCIE_KIND_LSB] !== UCIE_PKT_KIND_CMO) begin
            $display("FAIL: §8: CMO 0x%02x: UCIe kind 0x%x != CMO",
                     cmo_opcodes[cmo_i],
                     ucie_tx_hdr[UCIE_KIND_MSB:UCIE_KIND_LSB]); $finish(1);
          end
          if (ucie_tx_hdr[UCIE_CODE_MSB:UCIE_CODE_LSB] !== cmo_opcodes[cmo_i][3:0]) begin
            $display("FAIL: §8: CMO 0x%02x: UCIe code 0x%x != opcode[3:0]",
                     cmo_opcodes[cmo_i],
                     ucie_tx_hdr[UCIE_CODE_MSB:UCIE_CODE_LSB]); $finish(1);
          end
          cmo_tag = ucie_tx_hdr[UCIE_TAG_MSB:UCIE_TAG_LSB];
          @(posedge ucie_clk);
          // Far side returns AD_CPL; bridge must emit CHI Comp with RespErr=OK.
          ucie_rx_hdr = pack_ucie_hdr(UCIE_PKT_KIND_AD_CPL, UCIE_CPL_SC, cmo_tag,
                                      48'h0, 8'h00, 8'h55, 8'h00, 8'h00);
          ucie_rx_hdr_valid = 1'b1;
          while (!ucie_rx_hdr_ready) @(posedge ucie_clk);
          @(posedge ucie_clk);
          ucie_rx_hdr_valid = 1'b0;
          while (!(chi_rsp_valid &&
                   chi_rsp_data[CHI_RSP_OPCODE_LSB +: CHI_RSP_OPCODE_W] == CHI_RSP_COMP))
            @(posedge clk);
          if (chi_rsp_data[CHI_RSP_RESPERR_LSB +: CHI_RSP_RESPERR_W] !== CHI_RESPERR_OK) begin
            $display("FAIL: §8: CMO 0x%02x Comp RespErr not OK", cmo_opcodes[cmo_i]);
            $finish(1);
          end
          if (chi_rsp_data[CHI_RSP_TXNID_LSB +: CHI_RSP_TXNID_W] !== cmo_txnids[cmo_i]) begin
            $display("FAIL: §8: CMO 0x%02x TxnID not echoed", cmo_opcodes[cmo_i]);
            $finish(1);
          end
          @(posedge clk);
        end
        chi_rsp_ready = 1'b0;
      end
    end

    $display("INFO: §7.2 DBID write handshake: DBIDResp precedes WriteData; no early UCIe issue");
    begin : dbid_hs
      reg [CHI_RSP_DBID_W-1:0] hs_dbid;
      reg [7:0] hs_tag;
      // Phase 1: write request only (no WriteData).
      chi_rsp_ready = 1'b0;
      @(posedge clk);
      chi_req_data = {CHI_REQ_W{1'b0}};
      chi_req_data[CHI_REQ_OPCODE_LSB +: CHI_REQ_OPCODE_W] = CHI_REQ_WRITENOSNPFULL;
      chi_req_data[CHI_REQ_ADDR_LSB   +: CHI_REQ_ADDR_W]   = 48'h7777_8888_9999;
      chi_req_data[CHI_REQ_TXNID_LSB  +: CHI_REQ_TXNID_W]  = 8'h9E;
      chi_req_data[CHI_REQ_SRCID_LSB  +: CHI_REQ_SRCID_W]  = 7'h2B;
      chi_req_data[CHI_REQ_SIZE_LSB   +: CHI_REQ_SIZE_W]   = 3'h6;
      chi_req_valid = 1'b1;
      while (!chi_req_ready) @(posedge clk);
      @(posedge clk);
      chi_req_valid = 1'b0;
      // A DBIDResp must appear, and no UCIe header may issue yet (no WriteData).
      while (!(chi_rsp_valid &&
               chi_rsp_data[CHI_RSP_OPCODE_LSB +: CHI_RSP_OPCODE_W] == CHI_RSP_DBIDRESP))
        @(posedge clk);
      hs_dbid = chi_rsp_data[CHI_RSP_DBID_LSB +: CHI_RSP_DBID_W];
      if (chi_rsp_data[CHI_RSP_TXNID_LSB +: CHI_RSP_TXNID_W] !== 8'h9E) begin
        $display("FAIL: §7.2: DBIDResp TxnID mismatch (got %h)",
                 chi_rsp_data[CHI_RSP_TXNID_LSB +: CHI_RSP_TXNID_W]); $finish(1);
      end
      if (ucie_tx_hdr_valid) begin
        $display("FAIL: §7.2: UCIe header issued before WriteData was sent"); $finish(1);
      end
      chi_rsp_ready = 1'b1;   // pop the DBIDResp
      @(posedge clk);
      chi_rsp_ready = 1'b0;
      // Phase 2: WriteData tagged with the DBID. Stall the UCIe header so the
      // post-data issue is observable rather than firing in a single cycle.
      ucie_tx_hdr_ready = 1'b0;
      @(posedge clk);
      chi_wr_data = {CHI_DAT_W{1'b0}};
      chi_wr_data[CHI_DAT_OPCODE_LSB +: CHI_DAT_OPCODE_W] = CHI_DAT_NCBWRDATA;
      chi_wr_data[CHI_DAT_TXNID_LSB  +: CHI_DAT_TXNID_W]  = {{(TXNID_W-CHI_RSP_DBID_W){1'b0}}, hs_dbid};
      chi_wr_data[CHI_DAT_BE_LSB     +: CHI_DAT_BE_W]     = {BE_W{1'b1}};
      chi_wr_data[CHI_DAT_DATA_LSB   +: CHI_DAT_DATA_W]   = 512'hFEED_FACE_0000_0001;
      chi_wr_data_valid = 1'b1;
      while (!chi_wr_data_ready) @(posedge clk);
      @(posedge clk);
      chi_wr_data_valid = 1'b0;
      // The UCIe write header must now appear (stalled), carrying MEM_WR.
      wait (ucie_tx_hdr_valid);
      if (ucie_tx_hdr[UCIE_CODE_MSB:UCIE_CODE_LSB] !== UCIE_MSG_MEM_WR) begin
        $display("FAIL: §7.2: expected MEM_WR header after WriteData"); $finish(1);
      end
      hs_tag = ucie_tx_hdr[UCIE_TAG_MSB:UCIE_TAG_LSB];
      ucie_tx_hdr_ready = 1'b1;   // release header + data burst
      @(posedge ucie_clk);
      wait (ucie_tx_data_valid);
      repeat (6) @(posedge ucie_clk);
      // Complete via AD_CPL; the Comp must restore the original TxnID 0x9E.
      chi_rsp_ready = 1'b1;
      ucie_rx_hdr = pack_ucie_hdr(UCIE_PKT_KIND_AD_CPL, UCIE_CPL_SC, hs_tag,
                                  48'h0, 8'h00, 8'h55, 8'h00, 8'h00);
      ucie_rx_hdr_valid = 1'b1;
      while (!ucie_rx_hdr_ready) @(posedge ucie_clk);
      @(posedge ucie_clk);
      ucie_rx_hdr_valid = 1'b0;
      while (!(chi_rsp_valid &&
               chi_rsp_data[CHI_RSP_OPCODE_LSB +: CHI_RSP_OPCODE_W] == CHI_RSP_COMP))
        @(posedge clk);
      if (chi_rsp_data[CHI_RSP_TXNID_LSB +: CHI_RSP_TXNID_W] !== 8'h9E) begin
        $display("FAIL: §7.2: write Comp TxnID not restored to 0x9E"); $finish(1);
      end
      @(posedge clk);
      chi_rsp_ready = 1'b0;
    end

    $display("INFO: §10 QoS watermark throttle: low-QoS stalled at WM=6");
    begin : qos_throttle
      // At this point 4 carry-over outstanding txns (from §6.4) keep outstanding=4.
      // QOS_THROTTLE_WM=6 in the DUT. Issue 2 hi-QoS reads to reach 4+2=6=WM.
      reg [7:0]  hi_tag1;
      reg [7:0]  hi_tag2;
      reg [15:0] stall_before;

      // Hi-QoS read 1 (QoS=0xF, bypasses throttle): outstanding → 5
      @(posedge clk);
      chi_req_data = {CHI_REQ_W{1'b0}};
      chi_req_data[CHI_REQ_OPCODE_LSB +: CHI_REQ_OPCODE_W] = CHI_REQ_READNOSNP;
      chi_req_data[CHI_REQ_ADDR_LSB   +: CHI_REQ_ADDR_W]   = 48'h1234_0000_0001;
      chi_req_data[CHI_REQ_TXNID_LSB  +: CHI_REQ_TXNID_W]  = 8'hF1;
      chi_req_data[CHI_REQ_SRCID_LSB  +: CHI_REQ_SRCID_W]  = 7'h01;
      chi_req_data[CHI_REQ_SIZE_LSB   +: CHI_REQ_SIZE_W]   = 3'h6;
      chi_req_data[CHI_REQ_QOS_LSB    +: CHI_REQ_QOS_W]    = 4'hF;
      chi_req_valid = 1'b1;
      while (!chi_req_ready) @(posedge clk);
      @(posedge clk);
      chi_req_valid = 1'b0;
      wait (ucie_tx_hdr_valid);
      hi_tag1 = ucie_tx_hdr[UCIE_TAG_MSB:UCIE_TAG_LSB];
      @(posedge ucie_clk);

      // Hi-QoS read 2: outstanding → 6 = WM
      @(posedge clk);
      chi_req_data[CHI_REQ_TXNID_LSB  +: CHI_REQ_TXNID_W]  = 8'hF2;
      chi_req_data[CHI_REQ_ADDR_LSB   +: CHI_REQ_ADDR_W]   = 48'h1234_0000_0002;
      chi_req_valid = 1'b1;
      while (!chi_req_ready) @(posedge clk);
      @(posedge clk);
      chi_req_valid = 1'b0;
      wait (ucie_tx_hdr_valid);
      hi_tag2 = ucie_tx_hdr[UCIE_TAG_MSB:UCIE_TAG_LSB];
      @(posedge ucie_clk);

      // Wait for CDC (outstanding_above_wm=1 propagates to clk domain after ~2 clk edges).
      repeat (6) @(posedge clk);

      // Drive a lo-QoS read: must be stalled (chi_req_ready=0).
      stall_before = qos_lo_stall_cnt;
      @(posedge clk);
      chi_req_data = {CHI_REQ_W{1'b0}};
      chi_req_data[CHI_REQ_OPCODE_LSB +: CHI_REQ_OPCODE_W] = CHI_REQ_READNOSNP;
      chi_req_data[CHI_REQ_ADDR_LSB   +: CHI_REQ_ADDR_W]   = 48'h5678_0000_0001;
      chi_req_data[CHI_REQ_TXNID_LSB  +: CHI_REQ_TXNID_W]  = 8'h10;
      chi_req_data[CHI_REQ_SRCID_LSB  +: CHI_REQ_SRCID_W]  = 7'h12;
      chi_req_data[CHI_REQ_SIZE_LSB   +: CHI_REQ_SIZE_W]   = 3'h6;
      chi_req_data[CHI_REQ_QOS_LSB    +: CHI_REQ_QOS_W]    = 4'h0;
      chi_req_valid = 1'b1;
      #1;
      if (chi_req_ready) begin
        $display("FAIL: §10: lo-QoS request not stalled when outstanding >= WM"); $finish(1);
      end
      repeat (2) @(posedge clk); #1;
      if (chi_req_ready) begin
        $display("FAIL: §10: lo-QoS request not stalled (2nd check)"); $finish(1);
      end
      chi_req_valid = 1'b0;

      // stall counter must have incremented.
      repeat (2) @(posedge clk);
      if (qos_lo_stall_cnt <= stall_before) begin
        $display("FAIL: §10: qos_lo_stall_cnt did not increment (was %0d, now %0d)",
                 stall_before, qos_lo_stall_cnt); $finish(1);
      end

      // Complete both hi-QoS reads (MEM_CPL bursts) → outstanding drops to 4 < WM.
      drive_rx_burst(hi_tag1, 512'h0, 3'h6);
      drive_rx_burst(hi_tag2, 512'h0, 3'h6);

      // Wait for CDC to clear (outstanding_above_wm_clk → 0).
      repeat (6) @(posedge clk);

      // lo-QoS read must now be accepted.
      @(posedge clk);
      chi_req_data[CHI_REQ_QOS_LSB +: CHI_REQ_QOS_W] = 4'h0;
      chi_req_valid = 1'b1;
      fork : lo_qos_unblock
        begin
          while (!chi_req_ready) @(posedge clk);
          disable lo_qos_unblock;
        end
        begin
          repeat (32) @(posedge clk);
          $display("FAIL: §10: lo-QoS never unblocked after outstanding < WM");
          $finish(1);
        end
      join
      @(posedge clk);
      chi_req_valid = 1'b0;
    end

    $display("INFO: §9 snoop opcodes: UCIe SNP → chi_snp; SnpResp/SnpRespData → UCIe SNP_RSP");
    begin : snoop_ops
      reg [7:0]   snp_tag;
      reg [47:0]  snp_addr;
      reg [7:0]   snp_txnid;
      reg [7:0]   snp_rsp_tag;
      reg [511:0] dirty_data;
      reg [UCIE_HDR_W-1:0] snp_ucie_hdr;
      reg [7:0]   tx_kind;
      integer     b;

      snp_addr    = 48'hABCD_0000_1000;
      snp_txnid   = 8'h42;
      dirty_data  = 512'hDEADC0DE_CAFEBABE_12345678_9ABCDEF0_FEDCBA98_76543210_11223344_55667788;

      // ---- Sub-test A: header-only SnpResp ----
      // 1. Inject UCIe SNP packet on the rx header channel.
      @(posedge ucie_clk);
      snp_ucie_hdr = pack_ucie_hdr(
        UCIE_PKT_KIND_SNP,  // kind=D
        4'h7,               // code = SNP opcode lower 4 bits (SnpUnique opcode[3:0])
        snp_txnid,          // tag = HN TxnID
        snp_addr,           // addr
        8'h40,              // length
        8'h2A,              // src_id = HN SrcID
        8'h00,              // attr[1:0] = DoNotGoToSD:RetToSrc = 0
        8'h00               // flit_seq
      );
      ucie_rx_hdr = snp_ucie_hdr;
      ucie_rx_hdr_valid = 1'b1;
      while (!ucie_rx_hdr_ready) @(posedge ucie_clk);
      @(posedge ucie_clk);
      ucie_rx_hdr_valid = 1'b0;

      // 2. CHI master sees chi_snp_valid with correct fields.
      wait (chi_snp_valid);
      #1;
      if (chi_snp_data[CHI_SNP_TXNID_LSB +: CHI_SNP_TXNID_W] !== snp_txnid) begin
        $display("FAIL: §9A: chi_snp TxnID mismatch (got %h exp %h)",
                 chi_snp_data[CHI_SNP_TXNID_LSB +: CHI_SNP_TXNID_W], snp_txnid); $finish(1);
      end
      if (chi_snp_data[CHI_SNP_ADDR_LSB +: CHI_SNP_ADDR_W] !== snp_addr) begin
        $display("FAIL: §9A: chi_snp addr mismatch (got %h exp %h)",
                 chi_snp_data[CHI_SNP_ADDR_LSB +: CHI_SNP_ADDR_W], snp_addr); $finish(1);
      end
      if (chi_snp_data[CHI_SNP_SRCID_LSB +: CHI_SNP_SRCID_W] !== 7'h2A) begin
        $display("FAIL: §9A: chi_snp SrcID mismatch"); $finish(1);
      end

      // 3. CHI master drives SnpResp (no dirty data, resp=I=0).
      @(posedge clk);
      chi_snp_rsp_data = {CHI_SNPRSP_W{1'b0}};
      chi_snp_rsp_data[CHI_SNPRSP_RESP_LSB   +: CHI_SNPRSP_RESP_W]   = 3'b000; // I
      chi_snp_rsp_data[CHI_SNPRSP_TXNID_LSB  +: CHI_SNPRSP_TXNID_W]  = snp_txnid;
      chi_snp_rsp_data[CHI_SNPRSP_OPCODE_LSB +: CHI_SNPRSP_OPCODE_W] = CHI_SNPRSP_OP;
      chi_snp_rsp_data[CHI_SNPRSP_SRCID_LSB  +: CHI_SNPRSP_SRCID_W]  = 7'h10;
      chi_snp_rsp_valid = 1'b1;
      while (!chi_snp_rsp_ready) @(posedge clk);
      @(posedge clk);
      chi_snp_rsp_valid = 1'b0;

      // 4. Bridge must emit a UCIe SNP_RSP header (kind=B, has_dat=0, resp=I=0).
      wait (ucie_tx_hdr_valid);
      #1;
      tx_kind = ucie_tx_hdr[UCIE_KIND_MSB:UCIE_KIND_LSB];
      if (tx_kind !== UCIE_PKT_KIND_SNP_RSP) begin
        $display("FAIL: §9A: expected UCIe SNP_RSP header (got kind=%h)", tx_kind); $finish(1);
      end
      if (ucie_tx_hdr[UCIE_CODE_MSB:UCIE_CODE_LSB] !== 4'h0) begin  // has_dat=0, resp=I=0
        $display("FAIL: §9A: SNP_RSP code mismatch (got %h exp 0h0)",
                 ucie_tx_hdr[UCIE_CODE_MSB:UCIE_CODE_LSB]); $finish(1);
      end
      if (ucie_tx_hdr[UCIE_TAG_MSB:UCIE_TAG_LSB] !== snp_txnid) begin
        $display("FAIL: §9A: SNP_RSP tag (HN TxnID) mismatch"); $finish(1);
      end
      // Data channel must stay idle (no dirty burst).
      @(posedge ucie_clk); #1;
      if (ucie_tx_data_valid) begin
        $display("FAIL: §9A: unexpected data beat after header-only SnpResp"); $finish(1);
      end
      @(posedge ucie_clk);

      // ---- Sub-test B: SnpRespData (dirty writeback) ----
      // Inject a second SNP snoop.
      snp_txnid = 8'h7F;
      @(posedge ucie_clk);
      snp_ucie_hdr = pack_ucie_hdr(
        UCIE_PKT_KIND_SNP, 4'h1,          // SnpClean opcode[3:0]=1
        snp_txnid, snp_addr, 8'h40, 8'h2A, 8'h00, 8'h00
      );
      ucie_rx_hdr = snp_ucie_hdr;
      ucie_rx_hdr_valid = 1'b1;
      while (!ucie_rx_hdr_ready) @(posedge ucie_clk);
      @(posedge ucie_clk);
      ucie_rx_hdr_valid = 1'b0;

      // Wait for chi_snp_valid with new txnid.
      wait (chi_snp_valid && chi_snp_data[CHI_SNP_TXNID_LSB +: CHI_SNP_TXNID_W] === snp_txnid);

      // CHI master drives SnpRespData (resp=UD=3=3'b011, with dirty line).
      @(posedge clk);
      chi_snp_rsp_dat_data = {CHI_DAT_W{1'b0}};
      chi_snp_rsp_dat_data[CHI_DAT_DATA_LSB   +: CHI_DAT_DATA_W]   = dirty_data;
      chi_snp_rsp_dat_data[CHI_DAT_RESP_LSB   +: 3]                = 3'b011; // UD
      chi_snp_rsp_dat_data[CHI_DAT_TXNID_LSB  +: CHI_DAT_TXNID_W]  = snp_txnid;
      chi_snp_rsp_dat_data[CHI_DAT_OPCODE_LSB +: CHI_DAT_OPCODE_W] = 4'h1;  // SnpRespData
      chi_snp_rsp_dat_valid = 1'b1;
      while (!chi_snp_rsp_dat_ready) @(posedge clk);
      @(posedge clk);
      chi_snp_rsp_dat_valid = 1'b0;

      // Bridge must emit UCIe SNP_RSP header with has_dat=1, resp=UD=3.
      wait (ucie_tx_hdr_valid);
      #1;
      if (ucie_tx_hdr[UCIE_KIND_MSB:UCIE_KIND_LSB] !== UCIE_PKT_KIND_SNP_RSP) begin
        $display("FAIL: §9B: expected SNP_RSP header"); $finish(1);
      end
      if (ucie_tx_hdr[UCIE_CODE_MSB:UCIE_CODE_LSB] !== 4'hB) begin  // has_dat=1, resp=UD(3'b011)=3
        $display("FAIL: §9B: SNP_RSP code mismatch (got %h exp 0xB)",
                 ucie_tx_hdr[UCIE_CODE_MSB:UCIE_CODE_LSB]); $finish(1);
      end
      if (ucie_tx_hdr[UCIE_TAG_MSB:UCIE_TAG_LSB] !== snp_txnid) begin
        $display("FAIL: §9B: SNP_RSP tag mismatch"); $finish(1);
      end
      @(posedge ucie_clk);

      // Data burst: beat 0 = data-burst header, beats 1-4 = dirty line.
      wait (ucie_tx_data_valid); #1;
      if (ucie_tx_data[UCIE_KIND_MSB:UCIE_KIND_LSB] !== UCIE_PKT_KIND_SNP_RSP) begin
        $display("FAIL: §9B: data beat 0 kind mismatch"); $finish(1);
      end
      @(posedge ucie_clk);
      for (b = 0; b < 4; b = b + 1) begin
        #1;
        if (ucie_tx_data !== dirty_data[b*128 +: 128]) begin
          $display("FAIL: §9B: dirty data beat %0d mismatch (got %h exp %h)",
                   b+1, ucie_tx_data, dirty_data[b*128 +: 128]); $finish(1);
        end
        @(posedge ucie_clk);
      end
    end

    $display("PASS CHI-to-UCIe bridge directed smoke");
    $finish(0);
  end

endmodule
