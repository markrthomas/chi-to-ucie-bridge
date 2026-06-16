// PHY link-layer state controller.
//
// Translates PHY-level ready/error signals into the bridge's internal
// link_up/drain_done protocol and handles link error recovery with automatic
// retrain sequencing.  Lives in the clk domain alongside reset_drain.
//
// States:
//   S_WAIT_PHY  -- waiting for phy_init_done
//   S_ACTIVE    -- link active; drives link_up=1 into reset_drain
//   S_ERR_DRAIN -- link_error seen; link_up=0, draining outstanding txns
//   S_RETRAIN   -- drain complete; assert retrain_req until PHY re-initiates
//
// Normal bring-up:  S_WAIT_PHY -> S_ACTIVE on phy_init_done
// Normal tear-down: S_ACTIVE   -> S_WAIT_PHY on !phy_init_done (no error)
// Error recovery:   S_ACTIVE -> S_ERR_DRAIN on link_error,
//                   S_ERR_DRAIN -> S_RETRAIN on drain_done,
//                   S_RETRAIN -> S_ACTIVE on phy_init_done && !link_error

module phy_link_ctrl (
  input  wire       clk,
  input  wire       rst_n,
  input  wire       phy_init_done,
  input  wire       link_error,
  input  wire       drain_done,
  output wire       link_up,
  output wire       retrain_req,
  output wire [1:0] link_state
);

  localparam [1:0] S_WAIT_PHY  = 2'b00;
  localparam [1:0] S_ACTIVE    = 2'b01;
  localparam [1:0] S_ERR_DRAIN = 2'b10;
  localparam [1:0] S_RETRAIN   = 2'b11;

  reg [1:0] state;

  assign link_up     = (state == S_ACTIVE);
  assign retrain_req = (state == S_RETRAIN);
  assign link_state  = state;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= S_WAIT_PHY;
    end else begin
      case (state)
        S_WAIT_PHY:  if (phy_init_done && !link_error)       state <= S_ACTIVE;
        S_ACTIVE:    if (link_error)                          state <= S_ERR_DRAIN;
                     else if (!phy_init_done)                 state <= S_WAIT_PHY;
        S_ERR_DRAIN: if (drain_done)                         state <= S_RETRAIN;
        S_RETRAIN:   if (phy_init_done && !link_error)       state <= S_ACTIVE;
        default:                                              state <= S_WAIT_PHY;
      endcase
    end
  end

`ifdef FORMAL
  initial assume (!rst_n);

  always @(posedge clk) begin
    if (rst_n) begin
      // All encodings are legal (4 states use all 2-bit values).
      // link_up and retrain_req are exclusive to their respective states.
      assert (link_up     == (state == S_ACTIVE));
      assert (retrain_req == (state == S_RETRAIN));
      // link_up and retrain_req are mutually exclusive.
      assert (!(link_up && retrain_req));

      // Reachability.
      cover (state == S_ACTIVE);
      cover (state == S_ERR_DRAIN);
      cover (state == S_RETRAIN);
      // Full error-recovery cycle.
      cover (state == S_ACTIVE && $past(state) == S_RETRAIN);
    end
  end

  // When link_error arrives while active, link_up deasserts next cycle.
  always @(posedge clk) begin
    if (rst_n && $past(rst_n)) begin
      if ($past(state == S_ACTIVE) && $past(link_error))
        assert (!link_up);
    end
  end

  // retrain_req only fires after a drain has completed (S_ERR_DRAIN was visited).
  // Expressed as: S_RETRAIN cannot be entered except from S_ERR_DRAIN.
  always @(posedge clk) begin
    if (rst_n && $past(rst_n)) begin
      if (state == S_RETRAIN && $past(state) != S_RETRAIN)
        assert ($past(state) == S_ERR_DRAIN);
    end
  end
`endif

endmodule
