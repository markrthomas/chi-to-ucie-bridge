// Structured field definitions for the CHI <-> UCIe bridge.
//
// Compact-model note: CHI uses packed REQ/RSP/DAT flits with explicit fields.
// UCIe is modeled at the adapter boundary as a 64-bit header plus optional
// 512-bit payload packet. This is an RTL bring-up model, not a bit-exact CHI or
// UCIe wire protocol implementation.

`ifndef CHI_UCIE_BRIDGE_DEFS_VH
`define CHI_UCIE_BRIDGE_DEFS_VH

// ---- Global widths ----
localparam integer DATA_W          = 512;
localparam integer BE_W            = DATA_W/8;
localparam integer CHI_UCIE_ADDR_W = 48;
localparam integer TXNID_W         = 8;
localparam integer NODEID_W        = 7;
localparam integer QOS_W           = 4;
localparam integer UCIE_HDR_W      = 64;
localparam integer UCIE_DATA_W     = UCIE_HDR_W + DATA_W + 1;

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

localparam integer UCIE_KIND_MSB       = 63;
localparam integer UCIE_KIND_LSB       = 60;
localparam integer UCIE_CODE_MSB       = 59;
localparam integer UCIE_CODE_LSB       = 56;
localparam integer UCIE_TAG_MSB        = 55;
localparam integer UCIE_TAG_LSB        = 48;
localparam integer UCIE_ADDR_MSB       = 47;
localparam integer UCIE_ADDR_LSB       = 32;
localparam integer UCIE_LEN_MSB        = 31;
localparam integer UCIE_LEN_LSB        = 24;
localparam integer UCIE_ID_MSB         = 23;
localparam integer UCIE_ID_LSB         = 16;
localparam integer UCIE_ATTR_MSB       = 15;
localparam integer UCIE_ATTR_LSB       = 8;
localparam integer UCIE_CSUM_MSB       = 7;
localparam integer UCIE_CSUM_LSB       = 0;

localparam integer UCIE_DATA_PAYLOAD_LSB = 0;
localparam integer UCIE_DATA_POISON_LSB  = UCIE_DATA_PAYLOAD_LSB + DATA_W;
localparam integer UCIE_DATA_HDR_LSB     = UCIE_DATA_POISON_LSB + 1;

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

function automatic [7:0] ucie_checksum;
  input [63:0] pkt;
  begin
    ucie_checksum = pkt[63:56] ^ pkt[55:48] ^ pkt[47:40] ^ pkt[39:32] ^
                    pkt[31:24] ^ pkt[23:16] ^ pkt[15:8];
  end
endfunction

function automatic [63:0] pack_ucie_hdr;
  input [3:0]  kind;
  input [3:0]  code;
  input [7:0]  tag;
  input [15:0] addr_or_count;
  input [7:0]  length;
  input [7:0]  src_id;
  input [7:0]  attr;
  reg [63:0] raw;
  begin
    raw = {kind, code, tag, addr_or_count, length, src_id, attr, 8'h00};
    raw[UCIE_CSUM_MSB:UCIE_CSUM_LSB] = ucie_checksum(raw);
    pack_ucie_hdr = raw;
  end
endfunction

function automatic ucie_hdr_checksum_ok;
  input [63:0] pkt;
  reg [63:0] raw;
  begin
    raw = pkt;
    raw[UCIE_CSUM_MSB:UCIE_CSUM_LSB] = 8'h00;
    ucie_hdr_checksum_ok = (pkt[UCIE_CSUM_MSB:UCIE_CSUM_LSB] == ucie_checksum(raw));
  end
endfunction

`endif
