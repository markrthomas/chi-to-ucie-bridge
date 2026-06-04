"""Minimal cocotb connectivity smoke for chi_to_ucie_bridge.

Confirms the harness elaborates, the bridge opens after reset/link-up, and a
CHI read is translated to a UCIe AD_REQ/MEM_RD. The full randomized scoreboard
builds on this in test_bridge_random.py.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles

# ---- CHI REQ flit field map (mirrors chi_ucie_bridge_defs.vh) ----
CHI_REQ_ORDER_LSB = 0
CHI_REQ_MEMATTR_LSB = 2
CHI_REQ_SIZE_LSB = 6
CHI_REQ_ADDR_LSB = 9
CHI_REQ_OPCODE_LSB = 57
CHI_REQ_TXNID_LSB = 64
CHI_REQ_SRCID_LSB = 72

CHI_REQ_READNOSNP = 0x04
CHI_REQ_WRITENOSNPFULL = 0x1D

# ---- UCIe header field positions ----
UCIE_KIND_LSB = 60
UCIE_CODE_LSB = 56
UCIE_TAG_LSB = 48

UCIE_PKT_KIND_AD_REQ = 0x8
UCIE_MSG_MEM_RD = 0x3


def make_chi_read(txnid, addr, srcid=0x12, size=0x6):
    flit = 0
    flit |= (CHI_REQ_READNOSNP & 0x7F) << CHI_REQ_OPCODE_LSB
    flit |= (addr & ((1 << 48) - 1)) << CHI_REQ_ADDR_LSB
    flit |= (txnid & 0xFF) << CHI_REQ_TXNID_LSB
    flit |= (srcid & 0x7F) << CHI_REQ_SRCID_LSB
    flit |= (size & 0x7) << CHI_REQ_SIZE_LSB
    return flit


def field(value, lsb, width):
    return (int(value) >> lsb) & ((1 << width) - 1)


async def reset_and_open(dut):
    dut.rst_n.value = 0
    dut.link_up.value = 0
    dut.err_inj_en.value = 0
    dut.chi_req_valid.value = 0
    dut.chi_req_data.value = 0
    dut.chi_wr_data_valid.value = 0
    dut.chi_wr_data.value = 0
    dut.chi_rsp_ready.value = 1
    dut.chi_comp_data_ready.value = 1
    dut.ucie_tx_hdr_ready.value = 1
    dut.ucie_tx_data_ready.value = 1
    dut.ucie_rx_hdr_valid.value = 0
    dut.ucie_rx_hdr.value = 0
    dut.ucie_rx_data_valid.value = 0
    dut.ucie_rx_data.value = 0

    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    cocotb.start_soon(Clock(dut.ucie_clk, 6, units="ns").start())

    await ClockCycles(dut.clk, 8)
    dut.rst_n.value = 1
    dut.link_up.value = 1
    await ClockCycles(dut.clk, 16)


@cocotb.test(timeout_time=50, timeout_unit="us")
async def test_read_translates(dut):
    """A CHI read is issued to UCIe as AD_REQ / MEM_RD."""
    await reset_and_open(dut)

    await RisingEdge(dut.clk)
    dut.chi_req_data.value = make_chi_read(0x3C, 0xBEEF_CAFE_1234)
    dut.chi_req_valid.value = 1
    accepted = False
    for _ in range(100):
        await RisingEdge(dut.clk)
        if dut.chi_req_ready.value == 1:
            accepted = True
            break
    assert accepted, "chi_req_ready never asserted (bridge did not open?)"
    await RisingEdge(dut.clk)
    dut.chi_req_valid.value = 0

    for _ in range(50):
        await RisingEdge(dut.ucie_clk)
        if dut.ucie_tx_hdr_valid.value == 1:
            break
    assert dut.ucie_tx_hdr_valid.value == 1, "no UCIe header issued"

    hdr = dut.ucie_tx_hdr.value
    assert field(hdr, UCIE_KIND_LSB, 4) == UCIE_PKT_KIND_AD_REQ, "expected AD_REQ"
    assert field(hdr, UCIE_CODE_LSB, 4) == UCIE_MSG_MEM_RD, "expected MEM_RD"
    dut._log.info("read translated to UCIe AD_REQ/MEM_RD, local tag=%d"
                  % field(hdr, UCIE_TAG_LSB, 8))
