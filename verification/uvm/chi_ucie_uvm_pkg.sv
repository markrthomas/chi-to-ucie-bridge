// Package for UVM testbench components of the CHI-to-UCIe bridge.
// Mirrored from src/chi_ucie_bridge_defs.vh but optimized for UVM/SV.

package chi_ucie_uvm_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"

  // ---- CHI Enums ----
  typedef enum logic [6:0] {
    CHI_REQ_READNOSNP       = 7'h04,
    CHI_REQ_READONCE        = 7'h03,
    CHI_REQ_WRITENOSNPFULL  = 7'h1D,
    CHI_REQ_WRITENOSNPPTL   = 7'h1C,
    CHI_REQ_WRITEUNIQUEFULL = 7'h19
  } chi_req_opcode_e;

  typedef enum logic [3:0] {
    CHI_RSP_COMP            = 4'h4,
    CHI_RSP_DBIDRESP        = 4'h3
  } chi_rsp_opcode_e;

  typedef enum logic [3:0] {
    CHI_DAT_COMPDATA        = 4'h4,
    CHI_DAT_NCBWRDATA       = 4'h3
  } chi_dat_opcode_e;

  typedef enum logic [1:0] {
    CHI_RESPERR_OK          = 2'b00,
    CHI_RESPERR_DERR        = 2'b10,
    CHI_RESPERR_NDERR       = 2'b11
  } chi_resperr_e;

  typedef enum logic [2:0] {
    CHI_CACHE_I             = 3'b000
  } chi_cache_state_e;

  // ---- UCIe Enums ----
  typedef enum logic [3:0] {
    UCIE_PKT_KIND_AD_REQ    = 4'h8,
    UCIE_PKT_KIND_AD_CPL    = 4'h9,
    UCIE_PKT_KIND_MEM_CPL   = 4'ha,
    UCIE_PKT_KIND_ERROR     = 4'he
  } ucie_pkt_kind_e;

  typedef enum logic [3:0] {
    UCIE_MSG_MEM_RD         = 4'h3,
    UCIE_MSG_MEM_WR         = 4'h4,
    UCIE_MSG_MEM_RD_DATA    = 4'h5,
    UCIE_MSG_MEM_WR_DATA    = 4'h6
  } ucie_msg_code_e;

  typedef enum logic [3:0] {
    UCIE_CPL_SC             = 4'h1,
    UCIE_CPL_UR             = 4'h2,
    UCIE_CPL_CA             = 4'h3
  } ucie_cpl_status_e;

  // ---- Widths ----
  localparam int DATA_W          = 512;
  localparam int BE_W            = 64;
  localparam int ADDR_W          = 48;
  localparam int TXNID_W         = 8;
  localparam int NODEID_W        = 7;
  localparam int UCIE_HDR_W      = 128;

  localparam int CHI_REQ_W       = 90;
  localparam int CHI_RSP_W       = 25;
  localparam int CHI_DAT_W       = 598;

  // Forward declarations for includes
  typedef class chi_item;
  typedef class ucie_item;

  // Includes for components
  `include "chi_item.sv"
  `include "ucie_item.sv"
  `include "chi_sequencer.sv"
  `include "chi_driver.sv"
  `include "chi_monitor.sv"
  `include "chi_agent.sv"
  `include "ucie_sequencer.sv"
  `include "ucie_driver.sv"
  `include "ucie_monitor.sv"
  `include "ucie_agent.sv"
  `include "chi_ucie_scoreboard.sv"
  `include "chi_ucie_env.sv"
  `include "chi_base_seq.sv"
  `include "chi_read_write_seq.sv"
  `include "ucie_completion_seq.sv"
  `include "base_test.sv"
  `include "read_write_test.sv"

endpackage
