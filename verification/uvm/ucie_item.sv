// UVM Sequence Item for UCIe transactions.

class ucie_item extends uvm_sequence_item;
  `uvm_object_utils(ucie_item)

  // Header Fields
  rand ucie_pkt_kind_e    kind;
  rand logic [3:0]        code;  // ucie_msg_code_e for requests; ucie_cpl_status_e for completions
  rand logic [7:0]        tag;
  rand logic [ADDR_W-1:0] addr;
  rand logic [7:0]        length;
  rand logic [7:0]        src_id;
  rand logic [7:0]        attr;
  rand logic [7:0]        flit_seq;

  // Data Payload (for multi-beat bursts)
  rand logic [DATA_W-1:0] data;
  rand logic              is_burst;

  // Constraints
  constraint c_burst_kind {
    (kind == UCIE_PKT_KIND_AD_REQ && code == UCIE_MSG_MEM_WR_DATA) ||
    (kind == UCIE_PKT_KIND_MEM_CPL) -> is_burst == 1;
  }

  function new(string name = "ucie_item");
    super.new(name);
  endfunction

  // XOR CRC16 over slices [127:16] with CRC field zeroed
  local function logic [15:0] crc16(logic [127:0] h);
    return h[127:112] ^ h[111:96] ^ h[95:80] ^ h[79:64] ^
           h[63:48]   ^ h[47:32]  ^ h[31:16];
  endfunction

  // Pack header into 128-bit flit (CRC16 computed and inserted)
  function logic [UCIE_HDR_W-1:0] pack_hdr();
    logic [UCIE_HDR_W-1:0] hdr = '0;
    hdr[127:124] = kind;
    hdr[123:120] = code;
    hdr[119:112] = tag;
    hdr[111:104] = attr;
    hdr[103:96]  = length;
    hdr[95:88]   = src_id;
    hdr[87:80]   = flit_seq;
    hdr[79:32]   = addr;
    hdr[15:0]    = crc16(hdr);   // [31:16] reserved = 0, so CRC covers all meaningful fields
    return hdr;
  endfunction

  // Pack data into 4 flits
  function void pack_data_beats(output logic [UCIE_HDR_W-1:0] beats[4]);
    for (int i=0; i<4; i++) begin
      beats[i] = data[i*128 +: 128];
    end
  endfunction

  // Unpack header from 128-bit flit
  function void unpack_hdr(logic [UCIE_HDR_W-1:0] hdr);
    kind     = ucie_pkt_kind_e'(hdr[127:124]);
    code     = hdr[123:120];
    tag      = hdr[119:112];
    attr     = hdr[111:104];
    length   = hdr[103:96];
    src_id   = hdr[95:88];
    flit_seq = hdr[87:80];
    addr     = hdr[79:32];
  endfunction

  // Unpack data from 4 flits
  function void unpack_data_beats(logic [UCIE_HDR_W-1:0] beats[4]);
    for (int i=0; i<4; i++) begin
      data[i*128 +: 128] = beats[i];
    end
  endfunction

endclass
