"""cocotb tests for chi_to_ucie_bridge.

- test_read_translates: a directed connectivity smoke.
- test_random_traffic: a randomized, self-checking scoreboard run with
  backpressure on every handshake and out-of-order UCIe completions. The
  far-side UCIe model never sees the original CHI TxnID (the bridge hides it
  behind a local tag), so the scoreboard correlates completions purely by the
  restored TxnID, which validates the transaction table end to end.
"""

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ReadOnly, ClockCycles

# ---- CHI REQ flit field map (mirrors chi_ucie_bridge_defs.vh) ----
CHI_REQ_SIZE_LSB = 6
CHI_REQ_ADDR_LSB = 9
CHI_REQ_OPCODE_LSB = 57
CHI_REQ_TXNID_LSB = 64
CHI_REQ_SRCID_LSB = 72

CHI_REQ_READNOSNP = 0x04
CHI_REQ_WRITENOSNPFULL = 0x1D

# ---- CHI DAT flit field map ----
CHI_DAT_DATA_LSB = 0
CHI_DAT_BE_LSB = 512
CHI_DAT_RESPERR_LSB = 581
CHI_DAT_TXNID_LSB = 586
CHI_DAT_OPCODE_LSB = 594
CHI_DAT_COMPDATA = 0x4
CHI_DAT_NCBWRDATA = 0x3
CHI_RESPERR_OK = 0x0
CHI_RESPERR_DERR = 0x2

# ---- CHI RSP flit field map ----
CHI_RSP_TXNID_LSB = 6
CHI_RSP_OPCODE_LSB = 14
CHI_RSP_COMP = 0x4

# ---- UCIe header field positions ----
UCIE_KIND_LSB = 60
UCIE_CODE_LSB = 56
UCIE_TAG_LSB = 48
UCIE_ADDR_LSB = 32

UCIE_PKT_KIND_AD_REQ = 0x8
UCIE_PKT_KIND_AD_CPL = 0x9
UCIE_PKT_KIND_MEM_CPL = 0xA
UCIE_MSG_MEM_RD = 0x3
UCIE_MSG_MEM_WR = 0x4
UCIE_MSG_MEM_WR_DATA = 0x6
UCIE_CPL_SC = 0x1

# ---- UCIe data packet positions ----
UCIE_DATA_POISON_LSB = 512
UCIE_DATA_HDR_LSB = 513

MASK512 = (1 << 512) - 1


def field(value, lsb, width):
    return (int(value) >> lsb) & ((1 << width) - 1)


def make_chi_read(txnid, addr, srcid=0x12, size=0x6):
    flit = 0
    flit |= (CHI_REQ_READNOSNP & 0x7F) << CHI_REQ_OPCODE_LSB
    flit |= (addr & ((1 << 48) - 1)) << CHI_REQ_ADDR_LSB
    flit |= (txnid & 0xFF) << CHI_REQ_TXNID_LSB
    flit |= (srcid & 0x7F) << CHI_REQ_SRCID_LSB
    flit |= (size & 0x7) << CHI_REQ_SIZE_LSB
    return flit


def make_chi_write_req(txnid, addr, srcid=0x34, size=0x6):
    flit = 0
    flit |= (CHI_REQ_WRITENOSNPFULL & 0x7F) << CHI_REQ_OPCODE_LSB
    flit |= (addr & ((1 << 48) - 1)) << CHI_REQ_ADDR_LSB
    flit |= (txnid & 0xFF) << CHI_REQ_TXNID_LSB
    flit |= (srcid & 0x7F) << CHI_REQ_SRCID_LSB
    flit |= (size & 0x7) << CHI_REQ_SIZE_LSB
    return flit


def make_chi_write_data(txnid, data):
    flit = 0
    flit |= (data & MASK512) << CHI_DAT_DATA_LSB
    flit |= ((1 << 64) - 1) << CHI_DAT_BE_LSB
    flit |= (txnid & 0xFF) << CHI_DAT_TXNID_LSB
    flit |= (CHI_DAT_NCBWRDATA & 0xF) << CHI_DAT_OPCODE_LSB
    return flit


def pack_ucie_hdr(kind, code, tag, addr16=0, length=0, src_id=0, attr=0):
    raw = ((kind & 0xF) << 60) | ((code & 0xF) << 56) | ((tag & 0xFF) << 48) \
        | ((addr16 & 0xFFFF) << 32) | ((length & 0xFF) << 24) \
        | ((src_id & 0xFF) << 16) | ((attr & 0xFF) << 8)
    csum = 0
    for sh in (56, 48, 40, 32, 24, 16, 8):
        csum ^= (raw >> sh) & 0xFF
    return raw | (csum & 0xFF)


def pack_mem_cpl_data(tag, data):
    hdr = pack_ucie_hdr(UCIE_PKT_KIND_MEM_CPL, UCIE_CPL_SC, tag, 0x0040, 0x40, 0x55, 0x00)
    return (hdr << UCIE_DATA_HDR_LSB) | ((data & MASK512) << 0)


def pack_mem_cpl_data_badcrc(tag, data):
    """A MEM_CPL packet whose embedded header checksum byte is corrupted."""
    pkt = pack_mem_cpl_data(tag, data)
    return pkt ^ (0xFF << UCIE_DATA_HDR_LSB)  # flip header[7:0] (the checksum)


def data_for(addr16):
    """Deterministic 512-bit read/write payload derived from the address."""
    word = ((addr16 & 0xFFFF) << 16) | 0xDA7A
    d = 0
    for i in range(16):
        d |= word << (32 * i)
    return d & MASK512


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


class CoverGroup:
    """Minimal functional-coverage model: named bins with a hit count and a
    goal that every bin is exercised at least once."""

    def __init__(self, name, bins):
        self.name = name
        self.counts = {b: 0 for b in bins}

    def hit(self, b):
        self.counts[b] = self.counts.get(b, 0) + 1

    def uncovered(self):
        return [b for b, c in self.counts.items() if c == 0]

    def report(self):
        return f"{self.name}{{" + ", ".join(f"{b}={c}" for b, c in self.counts.items()) + "}"


class Scoreboard:
    def __init__(self):
        self.outstanding = {}   # txnid -> dict(is_write, addr16, data)
        self.errors = []
        self.reads_done = 0
        self.writes_done = 0

    def expect(self, txnid, is_write, addr16):
        self.outstanding[txnid] = dict(is_write=is_write, addr16=addr16,
                                       data=data_for(addr16))

    def complete_write(self, txnid):
        exp = self.outstanding.pop(txnid, None)
        if exp is None:
            self.errors.append(f"Comp for unknown/!outstanding TxnID 0x{txnid:02x}")
        elif not exp["is_write"]:
            self.errors.append(f"Comp (RSP) returned for read TxnID 0x{txnid:02x}")
        else:
            self.writes_done += 1

    def complete_read(self, txnid, data):
        exp = self.outstanding.pop(txnid, None)
        if exp is None:
            self.errors.append(f"CompData for unknown/!outstanding TxnID 0x{txnid:02x}")
        elif exp["is_write"]:
            self.errors.append(f"CompData returned for write TxnID 0x{txnid:02x}")
        elif data != exp["data"]:
            self.errors.append(
                f"read data mismatch TxnID 0x{txnid:02x}: "
                f"got 0x{data:0128x} exp 0x{exp['data']:0128x}")
        else:
            self.reads_done += 1


@cocotb.test(timeout_time=2, timeout_unit="ms")
async def test_random_traffic(dut):
    """Randomized read/write stream with backpressure and out-of-order completions."""
    random.seed(0xC0FFEE)
    await reset_and_open(dut)

    sb = Scoreboard()
    state = dict(running=True)
    cov_op = CoverGroup("tx_opcode", ["rd", "wr"])
    cov_cpl = CoverGroup("cpl_class", ["comp", "compdata"])

    inuse = set()                 # TxnIDs currently outstanding (must be unique)
    tag_info = {}                 # local tag -> dict(is_write, addr16)
    pend_adcpl = []               # local tags awaiting AD_CPL (write completion)
    pend_memcpl = []              # (local tag, data) awaiting MEM_CPL (read completion)

    N = 80
    MAX_INFLIGHT = 12

    def rdy():
        return 1 if random.random() < 0.7 else 0

    # ---- UCIe TX header consumer: capture issued local tag + request kind ----
    async def tx_hdr_consumer():
        while state["running"]:
            dut.ucie_tx_hdr_ready.value = rdy()
            await ReadOnly()
            if dut.ucie_tx_hdr_ready.value == 1 and dut.ucie_tx_hdr_valid.value == 1:
                hdr = int(dut.ucie_tx_hdr.value)
                tag = field(hdr, UCIE_TAG_LSB, 8)
                code = field(hdr, UCIE_CODE_LSB, 4)
                addr16 = field(hdr, UCIE_ADDR_LSB, 16)
                is_write = (code == UCIE_MSG_MEM_WR)
                cov_op.hit("wr" if is_write else "rd")
                tag_info[tag] = dict(is_write=is_write, addr16=addr16)
                if not is_write:
                    # Reads have no data packet; schedule the read completion now.
                    pend_memcpl.append((tag, data_for(addr16)))
            await RisingEdge(dut.ucie_clk)

    # ---- UCIe TX data consumer: check write-data payload by local tag ----
    async def tx_data_consumer():
        while state["running"]:
            dut.ucie_tx_data_ready.value = rdy()
            await ReadOnly()
            if dut.ucie_tx_data_ready.value == 1 and dut.ucie_tx_data_valid.value == 1:
                pkt = int(dut.ucie_tx_data.value)
                hdr = (pkt >> UCIE_DATA_HDR_LSB) & ((1 << 64) - 1)
                tag = field(hdr, UCIE_TAG_LSB, 8)
                payload = pkt & MASK512
                info = tag_info.get(tag)
                if info is None:
                    sb.errors.append(f"write data for unknown tag {tag}")
                elif payload != data_for(info["addr16"]):
                    sb.errors.append(f"write data payload mismatch tag {tag}")
                else:
                    # Write data received: now the far side can complete it.
                    pend_adcpl.append(tag)
            await RisingEdge(dut.ucie_clk)

    # ---- UCIe RX header driver: return AD_CPL (write completions), out of order ----
    async def rx_hdr_driver():
        while state["running"]:
            chosen = None
            if pend_adcpl and random.random() < 0.6:
                chosen = random.choice(pend_adcpl)
                dut.ucie_rx_hdr.value = pack_ucie_hdr(
                    UCIE_PKT_KIND_AD_CPL, UCIE_CPL_SC, chosen, 0, 0, 0x55, 0)
                dut.ucie_rx_hdr_valid.value = 1
            else:
                dut.ucie_rx_hdr_valid.value = 0
            await ReadOnly()
            took = chosen is not None and dut.ucie_rx_hdr_ready.value == 1
            await RisingEdge(dut.ucie_clk)
            if took:
                pend_adcpl.remove(chosen)

    # ---- UCIe RX data driver: return MEM_CPL (read completions), out of order ----
    async def rx_data_driver():
        while state["running"]:
            chosen = None
            if pend_memcpl and random.random() < 0.6:
                chosen = random.choice(pend_memcpl)
                dut.ucie_rx_data.value = pack_mem_cpl_data(chosen[0], chosen[1])
                dut.ucie_rx_data_valid.value = 1
            else:
                dut.ucie_rx_data_valid.value = 0
            await ReadOnly()
            took = chosen is not None and dut.ucie_rx_data_ready.value == 1
            await RisingEdge(dut.ucie_clk)
            if took:
                pend_memcpl.remove(chosen)

    # ---- CHI RSP sink: write completions ----
    async def chi_rsp_sink():
        while state["running"]:
            dut.chi_rsp_ready.value = rdy()
            await ReadOnly()
            if dut.chi_rsp_ready.value == 1 and dut.chi_rsp_valid.value == 1:
                rsp = int(dut.chi_rsp_data.value)
                assert field(rsp, CHI_RSP_OPCODE_LSB, 4) == CHI_RSP_COMP
                txnid = field(rsp, CHI_RSP_TXNID_LSB, 8)
                sb.complete_write(txnid)
                cov_cpl.hit("comp")
                inuse.discard(txnid)
            await RisingEdge(dut.clk)

    # ---- CHI CompData sink: read completions ----
    async def chi_comp_sink():
        while state["running"]:
            dut.chi_comp_data_ready.value = rdy()
            await ReadOnly()
            if dut.chi_comp_data_ready.value == 1 and dut.chi_comp_data_valid.value == 1:
                dat = int(dut.chi_comp_data.value)
                assert field(dat, CHI_DAT_OPCODE_LSB, 4) == CHI_DAT_COMPDATA
                txnid = field(dat, CHI_DAT_TXNID_LSB, 8)
                data = (dat >> CHI_DAT_DATA_LSB) & MASK512
                sb.complete_read(txnid, data)
                cov_cpl.hit("compdata")
                inuse.discard(txnid)
            await RisingEdge(dut.clk)

    for c in (tx_hdr_consumer, tx_data_consumer, rx_hdr_driver, rx_data_driver,
              chi_rsp_sink, chi_comp_sink):
        cocotb.start_soon(c())

    # ---- Stimulus: issue N requests with unique outstanding TxnIDs ----
    addr_ctr = 0
    for i in range(N):
        while len(inuse) >= MAX_INFLIGHT:
            await RisingEdge(dut.clk)
        # random inter-request gap
        for _ in range(random.randint(0, 3)):
            await RisingEdge(dut.clk)

        txnid = random.randint(0, 255)
        while txnid in inuse:
            txnid = random.randint(0, 255)
        addr_ctr = (addr_ctr + 1) & 0xFFFF
        addr = addr_ctr
        is_write = random.random() < 0.5

        inuse.add(txnid)
        sb.expect(txnid, is_write, addr & 0xFFFF)

        if is_write:
            dut.chi_req_data.value = make_chi_write_req(txnid, addr)
            dut.chi_wr_data.value = make_chi_write_data(txnid, data_for(addr & 0xFFFF))
            dut.chi_req_valid.value = 1
            dut.chi_wr_data_valid.value = 1
        else:
            dut.chi_req_data.value = make_chi_read(txnid, addr)
            dut.chi_req_valid.value = 1

        # hold until accepted
        while True:
            await RisingEdge(dut.clk)
            if dut.chi_req_ready.value == 1:
                break
        dut.chi_req_valid.value = 0
        dut.chi_wr_data_valid.value = 0

    # ---- Drain ----
    for _ in range(4000):
        await RisingEdge(dut.clk)
        if not inuse and not pend_adcpl and not pend_memcpl:
            break

    state["running"] = False
    await ClockCycles(dut.clk, 5)

    assert not sb.errors, "scoreboard errors:\n" + "\n".join(sb.errors[:10])
    assert not inuse, f"{len(inuse)} transactions never completed: {sorted(inuse)}"
    assert sb.reads_done + sb.writes_done == N, \
        f"completed {sb.reads_done + sb.writes_done}/{N}"
    assert int(dut.tag_err_cnt.value) == 0, f"tag_err_cnt={int(dut.tag_err_cnt.value)}"
    assert not cov_op.uncovered(), f"uncovered opcodes: {cov_op.uncovered()}"
    assert not cov_cpl.uncovered(), f"uncovered completion classes: {cov_cpl.uncovered()}"
    dut._log.info(f"random traffic OK: {sb.reads_done} reads, {sb.writes_done} writes, "
                  f"crc_err_cnt={int(dut.crc_err_cnt.value)}; "
                  f"coverage {cov_op.report()} {cov_cpl.report()}")


@cocotb.test(timeout_time=2, timeout_unit="ms")
async def test_random_errors(dut):
    """Randomized read stream with corrupted-checksum completions.

    The far side randomly returns MEM_CPL packets with a bad header checksum.
    The bridge must still complete each read (freeing the tag) but flag RespErr,
    and crc_err_cnt must equal the number of corrupted completions delivered.
    """
    random.seed(0x5EED5)
    await reset_and_open(dut)

    dut.ucie_tx_data_ready.value = 1
    dut.ucie_rx_hdr_valid.value = 0
    dut.chi_rsp_ready.value = 1

    st = dict(running=True, n_corrupt=0, derr=0, ok=0, done=0, errors=[])
    inuse = set()
    expected = {}                 # txnid -> expected data
    pend = []                     # (tag, data, corrupt)
    cov_csum = CoverGroup("rx_checksum", ["good", "bad"])
    cov_resp = CoverGroup("read_resperr", ["ok", "derr"])

    N = 80
    MAX_INFLIGHT = 12

    def rdy():
        return 1 if random.random() < 0.7 else 0

    async def tx_hdr_consumer():
        while st["running"]:
            dut.ucie_tx_hdr_ready.value = rdy()
            await ReadOnly()
            if dut.ucie_tx_hdr_ready.value == 1 and dut.ucie_tx_hdr_valid.value == 1:
                hdr = int(dut.ucie_tx_hdr.value)
                tag = field(hdr, UCIE_TAG_LSB, 8)
                addr16 = field(hdr, UCIE_ADDR_LSB, 16)
                corrupt = random.random() < 0.3
                if corrupt:
                    st["n_corrupt"] += 1
                cov_csum.hit("bad" if corrupt else "good")
                pend.append((tag, data_for(addr16), corrupt))
            await RisingEdge(dut.ucie_clk)

    async def rx_data_driver():
        while st["running"]:
            chosen = None
            if pend and random.random() < 0.6:
                chosen = random.choice(pend)
                tag, data, corrupt = chosen
                pkt = pack_mem_cpl_data_badcrc(tag, data) if corrupt \
                    else pack_mem_cpl_data(tag, data)
                dut.ucie_rx_data.value = pkt
                dut.ucie_rx_data_valid.value = 1
            else:
                dut.ucie_rx_data_valid.value = 0
            await ReadOnly()
            took = chosen is not None and dut.ucie_rx_data_ready.value == 1
            await RisingEdge(dut.ucie_clk)
            if took:
                pend.remove(chosen)

    async def chi_comp_sink():
        while st["running"]:
            dut.chi_comp_data_ready.value = rdy()
            await ReadOnly()
            if dut.chi_comp_data_ready.value == 1 and dut.chi_comp_data_valid.value == 1:
                dat = int(dut.chi_comp_data.value)
                txnid = field(dat, CHI_DAT_TXNID_LSB, 8)
                data = (dat >> CHI_DAT_DATA_LSB) & MASK512
                resperr = field(dat, CHI_DAT_RESPERR_LSB, 2)
                exp = expected.pop(txnid, None)
                if exp is None:
                    st["errors"].append(f"CompData for unknown TxnID 0x{txnid:02x}")
                elif data != exp:
                    st["errors"].append(f"read data mismatch TxnID 0x{txnid:02x}")
                if resperr == CHI_RESPERR_DERR:
                    st["derr"] += 1
                    cov_resp.hit("derr")
                elif resperr == CHI_RESPERR_OK:
                    st["ok"] += 1
                    cov_resp.hit("ok")
                else:
                    st["errors"].append(f"unexpected RespErr {resperr}")
                st["done"] += 1
                inuse.discard(txnid)
            await RisingEdge(dut.clk)

    for c in (tx_hdr_consumer, rx_data_driver, chi_comp_sink):
        cocotb.start_soon(c())

    addr_ctr = 0
    for i in range(N):
        while len(inuse) >= MAX_INFLIGHT:
            await RisingEdge(dut.clk)
        for _ in range(random.randint(0, 3)):
            await RisingEdge(dut.clk)
        txnid = random.randint(0, 255)
        while txnid in inuse:
            txnid = random.randint(0, 255)
        addr_ctr = (addr_ctr + 1) & 0xFFFF
        inuse.add(txnid)
        expected[txnid] = data_for(addr_ctr & 0xFFFF)
        dut.chi_req_data.value = make_chi_read(txnid, addr_ctr)
        dut.chi_req_valid.value = 1
        while True:
            await RisingEdge(dut.clk)
            if dut.chi_req_ready.value == 1:
                break
        dut.chi_req_valid.value = 0

    for _ in range(4000):
        await RisingEdge(dut.clk)
        if not inuse and not pend:
            break

    st["running"] = False
    await ClockCycles(dut.clk, 5)

    crc = int(dut.crc_err_cnt.value)
    assert not st["errors"], "errors:\n" + "\n".join(st["errors"][:10])
    assert st["done"] == N, f"completed {st['done']}/{N}"
    assert st["derr"] == st["n_corrupt"], \
        f"DERR completions {st['derr']} != corrupted {st['n_corrupt']}"
    assert st["ok"] == N - st["n_corrupt"], f"OK completions {st['ok']}"
    assert crc == st["n_corrupt"], f"crc_err_cnt {crc} != corrupted {st['n_corrupt']}"
    assert int(dut.tag_err_cnt.value) == 0, f"tag_err_cnt={int(dut.tag_err_cnt.value)}"
    assert not cov_csum.uncovered(), f"uncovered checksum bins: {cov_csum.uncovered()}"
    assert not cov_resp.uncovered(), f"uncovered resperr bins: {cov_resp.uncovered()}"
    dut._log.info(f"random errors OK: {N} reads, {st['n_corrupt']} corrupted -> "
                  f"{st['derr']} DERR, crc_err_cnt={crc}; "
                  f"coverage {cov_csum.report()} {cov_resp.report()}")
