// Sideband management message handler (§5.3).
//
// Handles the bridge's sideband TX/RX interface.  Three independent message
// flows are managed:
//
//   Link-state TX (§4.4): sends LINK_ERROR / RETRAIN_REQ / LINK_ACTIVE on
//   each phy_link_ctrl state transition.
//
//   PARAM exchange: responds to PHY PARAM_REQ with a 2-byte sequence:
//   SB_MSG_PARAM_ACK (0xB1) followed by MAX_OUTSTANDING[7:0].
//
//   PM-L1 flow: on PM_L1_REQ, asserts pm_l1_active (which the bridge top gates
//   chi_req_ready with).  Once drain_done, sends PM_L1_ACK.  Clears on PM_L1_EXIT.
//
// TX priority: PM_L1_ACK > link-state messages > PARAM_ACK > PARAM value byte.
// This ensures the PHY's power-sequencing gate (PM_L1_ACK) is not delayed by
// informational traffic.
//
// All logic in the clk domain.

`include "chi_ucie_bridge_defs.vh"

module sb_msg_handler #(
  parameter integer MAX_OUTSTANDING = 32
) (
  input  wire       clk,
  input  wire       rst_n,

  // Link-state input from phy_link_ctrl (PLC_* encoding).
  input  wire [1:0] link_state,

  // drain_done from reset_drain: all async FIFOs empty while draining.
  input  wire       drain_done,

  // Sideband TX.
  output wire       sb_tx_valid,
  output wire [7:0] sb_tx_data,
  input  wire       sb_tx_ready,

  // Sideband RX (bridge always accepts).
  input  wire       sb_rx_valid,
  input  wire [7:0] sb_rx_data,
  output wire       sb_rx_ready,

  // Power-management L1 gate: high from PM_L1_REQ until PM_L1_EXIT.
  output wire       pm_l1_active
);

  // ---- Link-state encoding ----
  localparam [1:0] PLC_WAIT    = 2'b00;
  localparam [1:0] PLC_ACTIVE  = 2'b01;
  localparam [1:0] PLC_ERR_DRN = 2'b10;
  localparam [1:0] PLC_RETRAIN = 2'b11;

  // ---- PM-L1 state machine ----
  localparam [1:0] PM_IDLE     = 2'b00;  // pm_l1_active = 0
  localparam [1:0] PM_DRAINING = 2'b01;  // waiting for drain_done
  localparam [1:0] PM_ACK_PEND = 2'b10;  // queued PM_L1_ACK to send
  localparam [1:0] PM_L1       = 2'b11;  // PHY in L1; waiting for PM_L1_EXIT

  reg [1:0] pm_state;
  reg [1:0] link_state_q;

  // ---- Link-state message pending ----
  reg       ls_pending;
  reg [7:0] ls_msg_r;

  // ---- PARAM_ACK pending (2-byte: opcode then value) ----
  reg param_pend;
  reg param_phase;   // 0 = send SB_MSG_PARAM_ACK opcode, 1 = send value byte

  // ---- TX arbitration ----
  wire pm_ack_pend = (pm_state == PM_ACK_PEND);
  wire param_opcode_pend = param_pend && !param_phase;
  wire param_value_pend  = param_pend &&  param_phase;

  wire tx_valid_w =
      pm_ack_pend       |
      ls_pending        |
      param_opcode_pend |
      param_value_pend;

  wire [7:0] tx_data_w =
      pm_ack_pend       ? SB_MSG_PM_L1_ACK                           :
      ls_pending        ? ls_msg_r                                    :
      param_opcode_pend ? SB_MSG_PARAM_ACK                           :
                          MAX_OUTSTANDING[7:0];

  wire sb_tx_fire = tx_valid_w & sb_tx_ready;

  assign sb_tx_valid  = tx_valid_w;
  assign sb_tx_data   = tx_data_w;
  assign sb_rx_ready  = 1'b1;
  assign pm_l1_active = (pm_state != PM_IDLE);

  // ---- RX message decode ----
  wire rx_fire      = sb_rx_valid;   // sb_rx_ready is always 1
  wire rx_pm_l1_req  = rx_fire && (sb_rx_data == SB_MSG_PM_L1_REQ);
  wire rx_pm_l1_exit = rx_fire && (sb_rx_data == SB_MSG_PM_L1_EXIT);
  wire rx_param_req  = rx_fire && (sb_rx_data == SB_MSG_PARAM_REQ);

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pm_state     <= PM_IDLE;
      link_state_q <= PLC_WAIT;
      ls_pending   <= 1'b0;
      ls_msg_r     <= 8'h00;
      param_pend   <= 1'b0;
      param_phase  <= 1'b0;
    end else begin
      link_state_q <= link_state;

      // ---- PM-L1 state machine ----
      case (pm_state)
        PM_IDLE:     if (rx_pm_l1_req)                       pm_state <= PM_DRAINING;
        PM_DRAINING: if (drain_done)                         pm_state <= PM_ACK_PEND;
        PM_ACK_PEND: if (sb_tx_fire && pm_ack_pend)         pm_state <= PM_L1;
        PM_L1:       if (rx_pm_l1_exit)                     pm_state <= PM_IDLE;
        default:                                             pm_state <= PM_IDLE;
      endcase

      // ---- Link-state TX (edge-detect on link_state) ----
      if (link_state == PLC_ERR_DRN && link_state_q != PLC_ERR_DRN) begin
        ls_pending <= 1'b1; ls_msg_r <= SB_MSG_LINK_ERROR;
      end else if (link_state == PLC_RETRAIN && link_state_q != PLC_RETRAIN) begin
        ls_pending <= 1'b1; ls_msg_r <= SB_MSG_RETRAIN_REQ;
      end else if (link_state == PLC_ACTIVE && link_state_q != PLC_ACTIVE) begin
        ls_pending <= 1'b1; ls_msg_r <= SB_MSG_LINK_ACTIVE;
      end else if (sb_tx_fire && ls_pending && !pm_ack_pend) begin
        ls_pending <= 1'b0;
      end

      // ---- PARAM_ACK (2-byte: opcode then value) ----
      if (rx_param_req) begin
        param_pend  <= 1'b1;
        param_phase <= 1'b0;   // restart from opcode phase even if mid-sequence
      end else if (sb_tx_fire && param_pend && !pm_ack_pend && !ls_pending) begin
        if (!param_phase) begin
          param_phase <= 1'b1;   // opcode sent; queue value byte
        end else begin
          param_pend  <= 1'b0;
          param_phase <= 1'b0;
        end
      end
    end
  end

`ifdef FORMAL
  initial assume (!rst_n);

  always @(posedge clk) begin
    if (rst_n) begin
      // pm_l1_active exactly tracks pm_state != PM_IDLE.
      assert (pm_l1_active == (pm_state != PM_IDLE));
      // PM_ACK_PEND is only entered from PM_DRAINING.
      if (pm_state == PM_ACK_PEND && $past(pm_state) != PM_ACK_PEND)
        assert ($past(pm_state) == PM_DRAINING);
      // PM_DRAINING is only entered from PM_IDLE.
      if (pm_state == PM_DRAINING && $past(pm_state) != PM_DRAINING)
        assert ($past(pm_state) == PM_IDLE);
      // Reachability.
      cover (pm_l1_active);
      cover (pm_state == PM_ACK_PEND);
      cover (pm_state == PM_L1);
      cover (sb_tx_valid && sb_tx_data == SB_MSG_PM_L1_ACK);
      cover (sb_tx_valid && sb_tx_data == SB_MSG_PARAM_ACK);
    end
  end

  // PARAM_ACK opcode always precedes value byte, unless PHY retried PARAM_REQ
  // in the same cycle the opcode was being transmitted (rx_param_req resets phase).
  always @(posedge clk) begin
    if (rst_n && $past(rst_n)) begin
      if ($past(sb_tx_fire && param_pend && !pm_ack_pend && !ls_pending && !param_phase)
          && !$past(rx_param_req))
        assert (param_phase);
    end
  end

  // PM_L1_ACK (transition ACK_PEND→L1) fires exactly when drain_done was true
  // in PM_DRAINING.  Encode: can only enter PM_ACK_PEND after seeing drain_done.
  always @(posedge clk) begin
    if (rst_n && $past(rst_n)) begin
      if (pm_state == PM_ACK_PEND && $past(pm_state) == PM_DRAINING)
        assert ($past(drain_done));
    end
  end
`endif

endmodule
