// Structured field definitions for the CHI <-> UCIe bridge.
//
// Phase 4.2: 128-bit UCIe adapter header with full 48-bit address, 16-bit XOR
// integrity field, and 8-bit flit sequence counter.
//
// Header layout (128 bits):
//   [127:124] kind (4b)      packet type
//   [123:120] code (4b)      opcode / status
//   [119:112] tag  (8b)      local tag
//   [111:104] attr (8b)      MemAttr / Order / misc attributes
//   [103:96]  length (8b)    transfer size
//   [95:88]   src_id (8b)    requester node ID
//   [87:80]   flit_seq (8b)  TX flit sequence counter (wraps at 256)
//   [79:32]   addr (48b)     full 48-bit address
//   [31:16]   reserved (16b)
//   [15:0]    crc16 (16b)    XOR of slices [127:16] — 16-bit integrity field
//
// Data packet layout (§4.3: multi-beat):
// A data burst (e.g. CHI WriteData or ReadData) spans UCIE_DATA_BEATS+1 flits
// on the data channel (ucie_tx_data / ucie_rx_data):
//   Beat 0:    128-bit adapter header (kind=AD_REQ/MEM_CPL, code=WR_DATA/RD_DATA)
//   Beat 1..4: 128-bit data payload flits (pure data)
// Total 512 bits of data over 4 beats. Poison is carried in the Beat 0 header.

`ifndef CHI_UCIE_BRIDGE_DEFS_VH
`define CHI_UCIE_BRIDGE_DEFS_VH

// ---- Global widths ----
localparam integer DATA_W          = 512;
localparam integer BE_W            = DATA_W/8;
localparam integer CHI_UCIE_ADDR_W = 48;
localparam integer TXNID_W         = 8;
localparam integer NODEID_W        = 7;
localparam integer QOS_W           = 4;
localparam integer UCIE_HDR_W      = 128;
localparam integer UCIE_DATA_W     = UCIE_HDR_W;   // §4.3: single flit width; data spans UCIE_DATA_BEATS flits
localparam integer UCIE_DATA_BEATS = 4;             // data beats per write/read-cpl burst (4 × 128b = 512b)

// ---- CHI opcode model ----
localparam [6:0] CHI_REQ_READNOSNP       = 7'h04;
localparam [6:0] CHI_REQ_READONCE        = 7'h03;
localparam [6:0] CHI_REQ_WRITENOSNPFULL  = 7'h1D;
localparam [6:0] CHI_REQ_WRITENOSNPPTL   = 7'h1C;
localparam [6:0] CHI_REQ_WRITEUNIQUEFULL = 7'h19;

localparam [3:0] CHI_RSP_COMP            = 4'h4;
localparam [3:0] CHI_RSP_DBIDRESP        = 4'h3;
localparam [3:0] CHI_DAT_COMPDATA        = 4'h4;
localparam [3:0] CHI_DAT_NCBWRDATA       = 4'h3;

localparam [1:0] CHI_RESPERR_OK          = 2'b00;
localparam [1:0] CHI_RESPERR_DERR        = 2'b10;
localparam [1:0] CHI_RESPERR_NDERR       = 2'b11;
localparam [2:0] CHI_CACHE_I             = 3'b000;

// ---- CHI REQ flit field map ----
localparam integer CHI_REQ_ORDER_W   = 2;
localparam integer CHI_REQ_MEMATTR_W = 4;
localparam integer CHI_REQ_SIZE_W    = 3;
localparam integer CHI_REQ_ADDR_W    = CHI_UCIE_ADDR_W;
localparam integer CHI_REQ_OPCODE_W  = 7;
localparam integer CHI_REQ_TXNID_W   = TXNID_W;
localparam integer CHI_REQ_SRCID_W   = NODEID_W;
localparam integer CHI_REQ_TGTID_W   = NODEID_W;
localparam integer CHI_REQ_QOS_W     = QOS_W;

localparam integer CHI_REQ_ORDER_LSB   = 0;
localparam integer CHI_REQ_MEMATTR_LSB = CHI_REQ_ORDER_LSB   + CHI_REQ_ORDER_W;
localparam integer CHI_REQ_SIZE_LSB    = CHI_REQ_MEMATTR_LSB + CHI_REQ_MEMATTR_W;
localparam integer CHI_REQ_ADDR_LSB    = CHI_REQ_SIZE_LSB    + CHI_REQ_SIZE_W;
localparam integer CHI_REQ_OPCODE_LSB  = CHI_REQ_ADDR_LSB    + CHI_REQ_ADDR_W;
localparam integer CHI_REQ_TXNID_LSB   = CHI_REQ_OPCODE_LSB  + CHI_REQ_OPCODE_W;
localparam integer CHI_REQ_SRCID_LSB   = CHI_REQ_TXNID_LSB   + CHI_REQ_TXNID_W;
localparam integer CHI_REQ_TGTID_LSB   = CHI_REQ_SRCID_LSB   + CHI_REQ_SRCID_W;
localparam integer CHI_REQ_QOS_LSB     = CHI_REQ_TGTID_LSB   + CHI_REQ_TGTID_W;
localparam integer CHI_REQ_W           = CHI_REQ_QOS_LSB     + CHI_REQ_QOS_W;

// ---- CHI RSP flit field map ----
localparam integer CHI_RSP_RESPERR_W = 2;
localparam integer CHI_RSP_DBID_W    = 4;
localparam integer CHI_RSP_TXNID_W   = TXNID_W;
localparam integer CHI_RSP_OPCODE_W  = 4;
localparam integer CHI_RSP_SRCID_W   = NODEID_W;

localparam integer CHI_RSP_RESPERR_LSB = 0;
localparam integer CHI_RSP_DBID_LSB    = CHI_RSP_RESPERR_LSB + CHI_RSP_RESPERR_W;
localparam integer CHI_RSP_TXNID_LSB   = CHI_RSP_DBID_LSB    + CHI_RSP_DBID_W;
localparam integer CHI_RSP_OPCODE_LSB  = CHI_RSP_TXNID_LSB   + CHI_RSP_TXNID_W;
localparam integer CHI_RSP_SRCID_LSB   = CHI_RSP_OPCODE_LSB  + CHI_RSP_OPCODE_W;
localparam integer CHI_RSP_W           = CHI_RSP_SRCID_LSB   + CHI_RSP_SRCID_W;

// ---- CHI DAT flit field map ----
localparam integer CHI_DAT_DATA_W    = DATA_W;
localparam integer CHI_DAT_BE_W      = BE_W;
localparam integer CHI_DAT_POISON_W  = 1;
localparam integer CHI_DAT_DATAID_W  = 4;
localparam integer CHI_DAT_RESPERR_W = 2;
localparam integer CHI_DAT_RESP_W    = 3;
localparam integer CHI_DAT_TXNID_W   = TXNID_W;
localparam integer CHI_DAT_OPCODE_W  = 4;

localparam integer CHI_DAT_DATA_LSB    = 0;
localparam integer CHI_DAT_BE_LSB      = CHI_DAT_DATA_LSB    + CHI_DAT_DATA_W;
localparam integer CHI_DAT_POISON_LSB  = CHI_DAT_BE_LSB      + CHI_DAT_BE_W;
localparam integer CHI_DAT_DATAID_LSB  = CHI_DAT_POISON_LSB  + CHI_DAT_POISON_W;
localparam integer CHI_DAT_RESPERR_LSB = CHI_DAT_DATAID_LSB  + CHI_DAT_DATAID_W;
localparam integer CHI_DAT_RESP_LSB    = CHI_DAT_RESPERR_LSB + CHI_DAT_RESPERR_W;
localparam integer CHI_DAT_TXNID_LSB   = CHI_DAT_RESP_LSB    + CHI_DAT_RESP_W;
localparam integer CHI_DAT_OPCODE_LSB  = CHI_DAT_TXNID_LSB   + CHI_DAT_TXNID_W;
localparam integer CHI_DAT_W           = CHI_DAT_OPCODE_LSB  + CHI_DAT_OPCODE_W;

// ---- UCIe adapter packet kinds and codes ----
localparam [3:0] UCIE_PKT_KIND_AD_REQ  = 4'h8;
localparam [3:0] UCIE_PKT_KIND_AD_CPL  = 4'h9;
localparam [3:0] UCIE_PKT_KIND_MEM_CPL = 4'ha;
localparam [3:0] UCIE_PKT_KIND_ERROR   = 4'he;

localparam [3:0] UCIE_MSG_MEM_RD       = 4'h3;
localparam [3:0] UCIE_MSG_MEM_WR       = 4'h4;
localparam [3:0] UCIE_MSG_MEM_RD_DATA  = 4'h5;
localparam [3:0] UCIE_MSG_MEM_WR_DATA  = 4'h6;

localparam [3:0] UCIE_CPL_SC           = 4'h1;
localparam [3:0] UCIE_CPL_UR           = 4'h2;
localparam [3:0] UCIE_CPL_CA           = 4'h3;

// ---- UCIe sideband management message codes (§4.4) ----
localparam [7:0] SB_MSG_LINK_ACTIVE  = 8'hA0;  // bridge entered link-active state
localparam [7:0] SB_MSG_LINK_ERROR   = 8'hE1;  // bridge detected link error
localparam [7:0] SB_MSG_RETRAIN_REQ  = 8'hC2;  // bridge requesting PHY retrain

// ---- UCIe 128-bit header field positions ----
localparam integer UCIE_KIND_MSB  = 127;
localparam integer UCIE_KIND_LSB  = 124;
localparam integer UCIE_CODE_MSB  = 123;
localparam integer UCIE_CODE_LSB  = 120;
localparam integer UCIE_TAG_MSB   = 119;
localparam integer UCIE_TAG_LSB   = 112;
localparam integer UCIE_ATTR_MSB  = 111;
localparam integer UCIE_ATTR_LSB  = 104;
localparam integer UCIE_LEN_MSB   = 103;
localparam integer UCIE_LEN_LSB   = 96;
localparam integer UCIE_ID_MSB    = 95;
localparam integer UCIE_ID_LSB    = 88;
localparam integer UCIE_SEQ_MSB   = 87;
localparam integer UCIE_SEQ_LSB   = 80;
localparam integer UCIE_ADDR_MSB  = 79;
localparam integer UCIE_ADDR_LSB  = 32;
// [31:16] reserved
localparam integer UCIE_CRC_MSB   = 15;
localparam integer UCIE_CRC_LSB   = 0;

function automatic is_chi_write;
  input [6:0] opcode;
  begin
    case (opcode)
      CHI_REQ_WRITENOSNPFULL,
      CHI_REQ_WRITENOSNPPTL,
      CHI_REQ_WRITEUNIQUEFULL: is_chi_write = 1'b1;
      default:                 is_chi_write = 1'b0;
    endcase
  end
endfunction

function automatic is_chi_read;
  input [6:0] opcode;
  begin
    case (opcode)
      CHI_REQ_READNOSNP,
      CHI_REQ_READONCE: is_chi_read = 1'b1;
      default:          is_chi_read = 1'b0;
    endcase
  end
endfunction

// 16-bit XOR integrity field: XOR of seven 16-bit slices of hdr[127:16].
// Computed with crc field zeroed; placed in hdr[15:0].
function automatic [15:0] ucie_crc16;
  input [127:0] pkt;
  begin
    ucie_crc16 = pkt[127:112] ^ pkt[111:96] ^ pkt[95:80] ^ pkt[79:64] ^
                 pkt[63:48]  ^ pkt[47:32]  ^ pkt[31:16];
  end
endfunction

function automatic ucie_hdr_crc16_ok;
  input [127:0] pkt;
  reg [127:0] raw;
  begin
    raw = pkt;
    raw[UCIE_CRC_MSB:UCIE_CRC_LSB] = 16'h0000;
    ucie_hdr_crc16_ok = (pkt[UCIE_CRC_MSB:UCIE_CRC_LSB] == ucie_crc16(raw));
  end
endfunction

function automatic [UCIE_HDR_W-1:0] pack_ucie_hdr;
  input [3:0]  kind;
  input [3:0]  code;
  input [7:0]  tag;
  input [47:0] addr;
  input [7:0]  length;
  input [7:0]  src_id;
  input [7:0]  attr;
  input [7:0]  flit_seq;
  reg [127:0] raw;
  begin
    raw = {kind, code, tag, attr, length, src_id, flit_seq, addr, 16'h0000, 16'h0000};
    raw[UCIE_CRC_MSB:UCIE_CRC_LSB] = ucie_crc16(raw);
    pack_ucie_hdr = raw;
  end
endfunction

`endif
