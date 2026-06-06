// UVM Sequence Item for CHI transactions.

class chi_item extends uvm_sequence_item;
  `uvm_object_utils(chi_item)

  typedef enum { REQ, RSP, DAT } item_type_e;

  // Type of CHI flit
  rand item_type_e item_type;

  // REQ Fields
  rand chi_req_opcode_e req_opcode;
  rand logic [ADDR_W-1:0] addr;
  rand logic [2:0]        size;
  rand logic [TXNID_W-1:0] txnid;
  rand logic [NODEID_W-1:0] srcid;
  rand logic [NODEID_W-1:0] tgtid;
  rand logic [3:0]        qos;
  rand logic [1:0]        order;
  rand logic [3:0]        memattr;

  // RSP Fields
  rand chi_rsp_opcode_e rsp_opcode;
  rand chi_resperr_e    resperr;
  rand logic [3:0]      dbid;

  // DAT Fields
  rand chi_dat_opcode_e dat_opcode;
  rand logic [DATA_W-1:0] data;
  rand logic [BE_W-1:0]   be;
  rand logic              poison;
  rand logic [3:0]        dataid;
  rand chi_resperr_e      dat_resperr;
  rand chi_cache_state_e  resp;

  // Constraints
  constraint c_default_size { size == 3'h6; } // 64-byte
  constraint c_default_srcid { srcid == 7'h12; }

  function new(string name = "chi_item");
    super.new(name);
  endfunction

  // Pack into bitstream (mirroring the flit layout)
  function logic [CHI_DAT_W-1:0] pack_flit();
    logic [CHI_DAT_W-1:0] flit = '0;
    case (item_type)
      REQ: begin
        flit[0 +: 2]   = order;
        flit[2 +: 4]   = memattr;
        flit[6 +: 3]   = size;
        flit[9 +: 48]  = addr;
        flit[57 +: 7]  = req_opcode;
        flit[64 +: 8]  = txnid;
        flit[72 +: 7]  = srcid;
        flit[79 +: 7]  = tgtid;
        flit[86 +: 4]  = qos;
      end
      RSP: begin
        flit[0 +: 2]   = resperr;
        flit[2 +: 4]   = dbid;
        flit[6 +: 8]   = txnid;
        flit[14 +: 4]  = rsp_opcode;
        flit[18 +: 7]  = srcid;
      end
      DAT: begin
        flit[0   +: 512] = data;
        flit[512 +: 64]  = be;
        flit[576 +: 1]   = poison;
        flit[577 +: 4]   = dataid;
        flit[581 +: 2]   = dat_resperr;
        flit[583 +: 3]   = resp;
        flit[586 +: 8]   = txnid;
        flit[594 +: 4]   = dat_opcode;
      end
    endcase
    return flit;
  endfunction

  // Unpack from bitstream
  function void unpack_flit(logic [CHI_DAT_W-1:0] flit, item_type_e t);
    this.item_type = t;
    case (item_type)
      REQ: begin
        order      = flit[0 +: 2];
        memattr    = flit[2 +: 4];
        size       = flit[6 +: 3];
        addr       = flit[9 +: 48];
        req_opcode = chi_req_opcode_e'(flit[57 +: 7]);
        txnid      = flit[64 +: 8];
        srcid      = flit[72 +: 7];
        tgtid      = flit[79 +: 7];
        qos        = flit[86 +: 4];
      end
      RSP: begin
        resperr    = chi_resperr_e'(flit[0 +: 2]);
        dbid       = flit[2 +: 4];
        txnid      = flit[6 +: 8];
        rsp_opcode = chi_rsp_opcode_e'(flit[14 +: 4]);
        srcid      = flit[18 +: 7];
      end
      DAT: begin
        data        = flit[0   +: 512];
        be          = flit[512 +: 64];
        poison      = flit[576 +: 1];
        dataid      = flit[577 +: 4];
        dat_resperr = chi_resperr_e'(flit[581 +: 2]);
        resp        = chi_cache_state_e'(flit[583 +: 3]);
        txnid       = flit[586 +: 8];
        dat_opcode  = chi_dat_opcode_e'(flit[594 +: 4]);
      end
    endcase
  endfunction

endclass
