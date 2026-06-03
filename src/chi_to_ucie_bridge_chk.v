`include "chi_ucie_bridge_defs.vh"

module chi_to_ucie_bridge_chk (
  input wire                  clk,
  input wire                  rst_n,
  input wire                  chi_req_valid,
  input wire                  chi_req_ready,
  input wire [CHI_REQ_W-1:0]  chi_req_data,
  input wire                  ucie_tx_hdr_valid,
  input wire                  ucie_tx_hdr_ready,
  input wire [UCIE_HDR_W-1:0] ucie_tx_hdr
);

  always @(posedge clk) begin
    if (rst_n) begin
      if (chi_req_valid && chi_req_ready) begin
        if (!is_chi_read(chi_req_data[CHI_REQ_OPCODE_LSB +: CHI_REQ_OPCODE_W]) &&
            !is_chi_write(chi_req_data[CHI_REQ_OPCODE_LSB +: CHI_REQ_OPCODE_W])) begin
          $display("FAIL: unsupported CHI opcode accepted");
          $finish(1);
        end
      end

      if (ucie_tx_hdr_valid && ucie_tx_hdr_ready) begin
        if (!ucie_hdr_checksum_ok(ucie_tx_hdr)) begin
          $display("FAIL: UCIe TX header checksum mismatch");
          $finish(1);
        end
      end
    end
  end

endmodule
