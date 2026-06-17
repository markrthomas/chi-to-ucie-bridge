// Outstanding transaction table for the CHI <-> UCIe bridge.
//
// Phase 2: replaces the Phase 1 "CHI TxnID straight into the UCIe tag" shortcut.
// A bridge-local tag is allocated when a request header is issued to UCIe and
// freed when its completion returns; the original CHI identity is restored on
// the way back. Lives entirely in the ucie_clk domain (both allocate and free
// events occur there) so it adds no clock-domain crossing.
//
// One allocate port (at most one header issues per cycle) and two free/lookup
// ports, because the AD_CPL header channel and MEM_CPL data channel can each
// retire a transaction in the same cycle.

module txn_table #(
  parameter integer N        = 32,
  parameter integer TID_W    = 8,
  parameter integer SID_W    = 7,
  parameter integer LTAG_W   = 5   // must satisfy (1<<LTAG_W) >= N
) (
  input  wire                clk,
  input  wire                rst_n,

  // Allocate (on UCIe header issue). The caller chooses the slot (alloc_idx)
  // and holds it stable across a stalled handshake; free_tag is the suggested
  // lowest free slot to latch when a header is first presented.
  input  wire                alloc_en,
  input  wire [LTAG_W-1:0]   alloc_idx,
  input  wire [TID_W-1:0]    alloc_txnid,
  input  wire [SID_W-1:0]    alloc_srcid,
  input  wire                alloc_is_write,
  input  wire                alloc_is_large,  // §6.3: set for size>=6 reads; used to distinguish split from standalone
  output wire [LTAG_W-1:0]   free_tag,
  output wire                full,

  // Completion A: AD_CPL (request/write completion) lookup + free
  input  wire [LTAG_W-1:0]   a_lookup_tag,
  input  wire                a_free_en,
  output wire [TID_W-1:0]    a_txnid,
  output wire [SID_W-1:0]    a_srcid,
  output wire                a_is_write,
  output wire                a_valid,

  // Completion B: MEM_CPL (read-data completion) lookup + free
  input  wire [LTAG_W-1:0]   b_lookup_tag,
  input  wire                b_free_en,
  output wire [TID_W-1:0]    b_txnid,
  output wire [SID_W-1:0]    b_srcid,
  output wire                b_is_write,
  output wire                b_valid,
  output wire                b_is_large,   // §6.3: reflects alloc_is_large for the looked-up tag

  // Observability
  output reg  [LTAG_W:0]     outstanding,
  output reg                 tag_err          // pulse: free of an unallocated tag
);

  localparam integer ENTRY_W = TID_W + SID_W + 1;

  reg [N-1:0]       valid;
  reg [N-1:0]       is_large;
  reg [ENTRY_W-1:0] entry [0:N-1];

  // Lowest free index (priority encoder over the inverted valid vector).
  integer pe;
  reg [LTAG_W-1:0] free_idx;
  reg              have_free;
  always @* begin
    free_idx  = {LTAG_W{1'b0}};
    have_free = 1'b0;
    for (pe = N-1; pe >= 0; pe = pe - 1) begin
      if (!valid[pe]) begin
        free_idx  = pe[LTAG_W-1:0];
        have_free = 1'b1;
      end
    end
  end

  assign full     = !have_free;
  assign free_tag = free_idx;

  // Combinational lookups.
  wire [ENTRY_W-1:0] a_entry = entry[a_lookup_tag];
  wire [ENTRY_W-1:0] b_entry = entry[b_lookup_tag];
  assign {a_is_write, a_srcid, a_txnid} = a_entry;
  assign {b_is_write, b_srcid, b_txnid} = b_entry;
  assign a_valid    = valid[a_lookup_tag];
  assign b_valid    = valid[b_lookup_tag];
  assign b_is_large = is_large[b_lookup_tag];

  wire do_alloc = alloc_en && have_free;
  wire a_free   = a_free_en && a_valid;
  wire b_free   = b_free_en && b_valid;

  // Width-matched (LTAG_W+1) increment/decrement terms for the outstanding count.
  wire [LTAG_W:0] alloc_inc = {{LTAG_W{1'b0}}, do_alloc};
  wire [LTAG_W:0] free_dec  = {{LTAG_W{1'b0}}, a_free} + {{LTAG_W{1'b0}}, b_free};

  integer i;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      valid       <= {N{1'b0}};
      is_large    <= {N{1'b0}};
      outstanding <= {(LTAG_W+1){1'b0}};
      tag_err     <= 1'b0;
    end else begin
      for (i = 0; i < N; i = i + 1) begin
        // set wins only on a slot the caller guarantees free (valid[i]==0), so
        // set and clr never collide on the same index.
        if (do_alloc && (alloc_idx == i[LTAG_W-1:0]))
          valid[i] <= 1'b1;
        else if ((a_free && (a_lookup_tag == i[LTAG_W-1:0])) ||
                 (b_free && (b_lookup_tag == i[LTAG_W-1:0])))
          valid[i] <= 1'b0;
      end

      if (do_alloc) begin
        entry[alloc_idx]    <= {alloc_is_write, alloc_srcid, alloc_txnid};
        is_large[alloc_idx] <= alloc_is_large;
      end

      outstanding <= outstanding + alloc_inc - free_dec;

      // Free attempt against a tag that was not allocated.
      tag_err <= (a_free_en && !a_valid) || (b_free_en && !b_valid);
    end
  end

`ifdef FORMAL
  // Pin the BMC initial state to the reset state.
  initial begin
    valid       = {N{1'b0}};
    outstanding = {(LTAG_W+1){1'b0}};
  end

  // Environment assumptions for a well-behaved caller/link:
  always @(posedge clk) begin
    // The AD_CPL and MEM_CPL channels never name the same live tag in the same
    // cycle (distinct packet classes), so a transaction is never double-retired.
    if (a_free_en && b_free_en) assume (a_lookup_tag != b_lookup_tag);
    // The caller only ever allocates a slot it has been told is free (the
    // bridge latches free_tag, which it keeps reserved until issue).
    if (alloc_en) assume (!valid[alloc_idx]);
  end

  // DUT invariants.
  always @(posedge clk) begin
    if (rst_n) begin
      // The suggested free slot really is free whenever one exists.
      if (!full) assert (!valid[free_tag]);
      // The outstanding count never exceeds the table size (no over-allocation,
      // no decrement underflow given the assumptions above).
      assert (outstanding <= N[LTAG_W:0]);
    end
  end
`endif

endmodule
