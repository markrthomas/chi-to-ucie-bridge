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
from cocotb.triggers import RisingEdge, ClockCycles

# ---- CHI REQ flit field map (mirrors chi_ucie_bridge_defs.vh) ----
CHI_REQ_SIZE_LSB = 6
CHI_REQ_ADDR_LSB = 9
CHI_REQ_OPCODE_LSB = 57
CHI_REQ_TXNID_LSB = 64
CHI_REQ_SRCID_LSB = 72
CHI_REQ_TGTID_LSB = 79
CHI_REQ_QOS_LSB   = 86

CHI_REQ_READNOSNP = 0x04
CHI_REQ_WRITENOSNPFULL = 0x1D

# ---- CHI DAT flit field map ----
CHI_DAT_DATA_LSB = 0
CHI_DAT_BE_LSB = 512
CHI_DAT_POISON_LSB = 576
CHI_DAT_DATAID_LSB = 577   # 4-bit field after POISON
CHI_DAT_RESPERR_LSB = 581
CHI_DAT_TXNID_LSB = 586
CHI_DAT_OPCODE_LSB = 594
CHI_DAT_COMPDATA = 0x4
CHI_DAT_NCBWRDATA = 0x3
CHI_RESPERR_OK = 0x0
CHI_RESPERR_DERR = 0x2

# Sideband message codes (mirrors chi_ucie_bridge_defs.vh §5.3)
SB_MSG_LINK_ACTIVE = 0xA0
SB_MSG_PARAM_REQ   = 0xB0
SB_MSG_PARAM_ACK   = 0xB1
SB_MSG_PM_L1_REQ   = 0xD0
SB_MSG_PM_L1_ACK   = 0xD1
SB_MSG_PM_L1_EXIT  = 0xD2

# ---- CHI RSP flit field map ----
CHI_RSP_TXNID_LSB = 6
CHI_RSP_OPCODE_LSB = 14
CHI_RSP_COMP = 0x4

# ---- UCIe 128-bit header field positions (bit offsets within the header) ----
UCIE_KIND_LSB = 124
UCIE_CODE_LSB = 120
UCIE_TAG_LSB  = 112
UCIE_ATTR_LSB = 104
UCIE_ADDR_LSB = 32   # addr[79:32] — LSB stays 32, width is now 48 bits
UCIE_HDR_MASK = (1 << 128) - 1

UCIE_PKT_KIND_AD_REQ = 0x8
UCIE_PKT_KIND_AD_CPL = 0x9
UCIE_PKT_KIND_MEM_CPL = 0xA
UCIE_MSG_MEM_RD = 0x3
UCIE_MSG_MEM_WR = 0x4
UCIE_MSG_MEM_WR_DATA = 0x6
UCIE_CPL_SC = 0x1

MASK512 = (1 << 512) - 1


def field(value, lsb, width):
    return (int(value) >> lsb) & ((1 << width) - 1)


def make_chi_read(txnid, addr, srcid=0x12, size=0x6, qos=0):
    flit = 0
    flit |= (CHI_REQ_READNOSNP & 0x7F) << CHI_REQ_OPCODE_LSB
    flit |= (addr & ((1 << 48) - 1)) << CHI_REQ_ADDR_LSB
    flit |= (txnid & 0xFF) << CHI_REQ_TXNID_LSB
    flit |= (srcid & 0x7F) << CHI_REQ_SRCID_LSB
    flit |= (size & 0x7) << CHI_REQ_SIZE_LSB
    flit |= (qos & 0xF) << CHI_REQ_QOS_LSB
    return flit


def make_chi_write_req(txnid, addr, srcid=0x34, size=0x6, qos=0):
    flit = 0
    flit |= (CHI_REQ_WRITENOSNPFULL & 0x7F) << CHI_REQ_OPCODE_LSB
    flit |= (addr & ((1 << 48) - 1)) << CHI_REQ_ADDR_LSB
    flit |= (txnid & 0xFF) << CHI_REQ_TXNID_LSB
    flit |= (srcid & 0x7F) << CHI_REQ_SRCID_LSB
    flit |= (size & 0x7) << CHI_REQ_SIZE_LSB
    flit |= (qos & 0xF) << CHI_REQ_QOS_LSB
    return flit


def make_chi_write_data(txnid, data):
    flit = 0
    flit |= (data & MASK512) << CHI_DAT_DATA_LSB
    flit |= ((1 << 64) - 1) << CHI_DAT_BE_LSB
    flit |= (txnid & 0xFF) << CHI_DAT_TXNID_LSB
    flit |= (CHI_DAT_NCBWRDATA & 0xF) << CHI_DAT_OPCODE_LSB
    return flit


def pack_ucie_hdr(kind, code, tag, addr48=0, length=0, src_id=0, attr=0, flit_seq=0):
    # Layout: [127:124]=kind [123:120]=code [119:112]=tag [111:104]=attr
    #         [103:96]=length [95:88]=src_id [87:80]=flit_seq [79:32]=addr
    #         [31:16]=reserved [15:0]=crc16
    raw = ((kind     & 0xF)              << 124) \
        | ((code     & 0xF)              << 120) \
        | ((tag      & 0xFF)             << 112) \
        | ((attr     & 0xFF)             << 104) \
        | ((length   & 0xFF)             << 96)  \
        | ((src_id   & 0xFF)             << 88)  \
        | ((flit_seq & 0xFF)             << 80)  \
        | ((addr48   & 0xFFFF_FFFF_FFFF) << 32)
    crc = 0
    for sh in (16, 32, 48, 64, 80, 96, 112):
        crc ^= (raw >> sh) & 0xFFFF
    return raw | (crc & 0xFFFF)


def pack_mem_cpl_burst(tag, data, poison=0, size=6, addr48=0x0000_0000_0040):
    """Returns header + data flits for a MEM_CPL read completion.

    size=4 → 1 data beat (16B), size=5 → 2 beats (32B), size=6 → 4 beats (64B).
    addr48 is placed in the UCIe header address field; addr[4] (bit 36 of header)
    distinguishes split-completion halves (0=lower, 1=upper).
    """
    length = 1 << size          # byte count
    num_beats = max(1, length >> 4)  # 128-bit data beats
    hdr = pack_ucie_hdr(UCIE_PKT_KIND_MEM_CPL, UCIE_CPL_SC, tag,
                        addr48, length & 0xFF, 0x55, (poison << 7), 0)
    flits = [hdr]
    for i in range(num_beats):
        flits.append((data >> (128 * i)) & ((1 << 128) - 1))
    return flits


def pack_mem_cpl_burst_badcrc(tag, data):
    """A MEM_CPL burst whose header flit (beat 0) CRC field is corrupted."""
    flits = pack_mem_cpl_burst(tag, data)
    flits[0] ^= 0xFFFF  # flip header[15:0] (the crc16)
    return flits


def data_for(addr16):
    """Deterministic 512-bit read/write payload derived from the address."""
    word = ((addr16 & 0xFFFF) << 16) | 0xDA7A
    d = 0
    for i in range(16):
        d |= word << (32 * i)
    return d & MASK512


async def reset_and_open(dut):
    dut.rst_n.value = 0
    dut.phy_init_done.value = 0
    dut.link_error.value = 0
    dut.sb_tx_ready.value = 1
    dut.sb_rx_valid.value = 0
    dut.sb_rx_data.value = 0
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
    dut.ucie_rx_hdr_crdt.value = 0
    dut.ucie_rx_dat_crdt.value = 0

    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    cocotb.start_soon(Clock(dut.ucie_clk, 6, units="ns").start())

    await ClockCycles(dut.clk, 8)
    dut.rst_n.value = 1
    dut.phy_init_done.value = 1
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
    cov_qos = CoverGroup("qos_class", ["lo", "hi"])   # lo=QoS<8, hi=QoS>=8

    inuse = set()                 # TxnIDs currently outstanding (must be unique)
    tag_info = {}                 # local tag -> dict(is_write, addr16)
    pend_adcpl = []               # local tags awaiting AD_CPL (write completion)
    pend_memcpl = []              # (local tag, data) awaiting MEM_CPL (read completion)
    pend_hdr_crdts = [0]          # TX header credits to return to bridge
    pend_dat_crdts = [0]          # TX data credits to return to bridge
    exp_qos_by_addr = {}          # addr16 -> expected UCIe attr[3:0] (= CHI QoS)

    N = 80
    MAX_INFLIGHT = 12

    def rdy():
        return 1 if random.random() < 0.7 else 0

    # ---- UCIe TX header consumer: capture issued local tag + request kind ----
    async def tx_hdr_consumer():
        while state["running"]:
            dut.ucie_tx_hdr_ready.value = rdy()
            await RisingEdge(dut.ucie_clk)
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
                # QoS check (§5.4): attr[3:0] must match the CHI QoS field issued.
                qos_got = field(hdr, UCIE_ATTR_LSB, 4)
                cov_qos.hit("hi" if qos_got >= 8 else "lo")
                exp_qos = exp_qos_by_addr.get(addr16)
                if exp_qos is not None and qos_got != exp_qos:
                    sb.errors.append(
                        f"QoS mismatch addr16={addr16:#06x}: "
                        f"got attr[3:0]={qos_got} expected {exp_qos}"
                    )

    UCIE_LEN_LSB = 96  # length field in data-burst beat-0 header

    # ---- UCIe TX data consumer: check write-data burst by local tag ----
    # §6.1: beat count is derived from the length field in the burst's beat-0 header.
    async def tx_data_consumer():
        beat_ctr = 0
        tag = 0
        accum = 0
        last_beat = 4  # default until overridden from beat-0 header
        while state["running"]:
            dut.ucie_tx_data_ready.value = rdy()
            await RisingEdge(dut.ucie_clk)
            if dut.ucie_tx_data_ready.value == 1 and dut.ucie_tx_data_valid.value == 1:
                val = int(dut.ucie_tx_data.value)
                if beat_ctr == 0:
                    tag = field(val, UCIE_TAG_LSB, 8)
                    length = field(val, UCIE_LEN_LSB, 8)
                    last_beat = max(1, length >> 4)  # num 128-bit data beats
                    accum = 0
                else:
                    accum |= (val << (128 * (beat_ctr - 1)))

                if beat_ctr == last_beat:
                    info = tag_info.get(tag)
                    exp_mask = (1 << (128 * last_beat)) - 1
                    if info is None:
                        sb.errors.append(f"write data for unknown tag {tag}")
                    elif (accum & exp_mask) != (data_for(info["addr16"]) & exp_mask):
                        sb.errors.append(f"write data payload mismatch tag {tag}")
                    else:
                        pend_adcpl.append(tag)
                    beat_ctr = 0
                else:
                    beat_ctr += 1

    # ---- UCIe RX header driver: return AD_CPL (write completions), out of order ----
    async def rx_hdr_driver():
        while state["running"]:
            chosen = None
            if pend_adcpl and random.random() < 0.6:
                chosen = random.choice(pend_adcpl)
                dut.ucie_rx_hdr.value = pack_ucie_hdr(
                    UCIE_PKT_KIND_AD_CPL, UCIE_CPL_SC, chosen, 0, 0, 0x55, 0, 0)
                dut.ucie_rx_hdr_valid.value = 1
            else:
                dut.ucie_rx_hdr_valid.value = 0
            
            await RisingEdge(dut.ucie_clk)
            if chosen is not None and dut.ucie_rx_hdr_ready.value == 1:
                pend_adcpl.remove(chosen)
                pend_hdr_crdts[0] += 1  # write consumed 1 hdr credit
                pend_dat_crdts[0] += 1  # write consumed 1 dat credit

    # ---- UCIe RX data driver: return MEM_CPL (read completions), out of order ----
    async def rx_data_driver():
        while state["running"]:
            chosen = None
            if pend_memcpl and random.random() < 0.6:
                chosen = random.choice(pend_memcpl)
                flits = pack_mem_cpl_burst(chosen[0], chosen[1])
                for flit in flits:
                    dut.ucie_rx_data.value = flit
                    dut.ucie_rx_data_valid.value = 1
                    while True:
                        await RisingEdge(dut.ucie_clk)
                        if dut.ucie_rx_data_ready.value == 1:
                            break
                dut.ucie_rx_data_valid.value = 0
                pend_memcpl.remove(chosen)
                pend_hdr_crdts[0] += 1  # read burst consumed 1 hdr credit
            else:
                dut.ucie_rx_data_valid.value = 0
                await RisingEdge(dut.ucie_clk)

    # ---- Credit returners: pulse ucie_rx_hdr/dat_crdt when credits are due ----
    async def hdr_crdt_returner():
        while state["running"]:
            if pend_hdr_crdts[0] > 0:
                pend_hdr_crdts[0] -= 1
                dut.ucie_rx_hdr_crdt.value = 1
            else:
                dut.ucie_rx_hdr_crdt.value = 0
            await RisingEdge(dut.ucie_clk)

    async def dat_crdt_returner():
        while state["running"]:
            if pend_dat_crdts[0] > 0:
                pend_dat_crdts[0] -= 1
                dut.ucie_rx_dat_crdt.value = 1
            else:
                dut.ucie_rx_dat_crdt.value = 0
            await RisingEdge(dut.ucie_clk)

    # ---- CHI RSP sink: write completions ----
    async def chi_rsp_sink():
        while state["running"]:
            dut.chi_rsp_ready.value = rdy()
            await RisingEdge(dut.clk)
            if dut.chi_rsp_ready.value == 1 and dut.chi_rsp_valid.value == 1:
                rsp = int(dut.chi_rsp_data.value)
                assert field(rsp, CHI_RSP_OPCODE_LSB, 4) == CHI_RSP_COMP
                txnid = field(rsp, CHI_RSP_TXNID_LSB, 8)
                sb.complete_write(txnid)
                cov_cpl.hit("comp")
                inuse.discard(txnid)

    # ---- CHI CompData sink: read completions ----
    async def chi_comp_sink():
        while state["running"]:
            dut.chi_comp_data_ready.value = rdy()
            await RisingEdge(dut.clk)
            if dut.chi_comp_data_ready.value == 1 and dut.chi_comp_data_valid.value == 1:
                dat = int(dut.chi_comp_data.value)
                assert field(dat, CHI_DAT_OPCODE_LSB, 4) == CHI_DAT_COMPDATA
                txnid = field(dat, CHI_DAT_TXNID_LSB, 8)
                data = (dat >> CHI_DAT_DATA_LSB) & MASK512
                sb.complete_read(txnid, data)
                cov_cpl.hit("compdata")
                inuse.discard(txnid)

    for c in (tx_hdr_consumer, tx_data_consumer, rx_hdr_driver, rx_data_driver,
              chi_rsp_sink, chi_comp_sink, hdr_crdt_returner, dat_crdt_returner):
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
        qos = random.randint(0, 15)
        exp_qos_by_addr[addr & 0xFFFF] = qos

        if is_write:
            dut.chi_req_data.value = make_chi_write_req(txnid, addr, qos=qos)
            dut.chi_wr_data.value = make_chi_write_data(txnid, data_for(addr & 0xFFFF))
            dut.chi_req_valid.value = 1
            dut.chi_wr_data_valid.value = 1
        else:
            dut.chi_req_data.value = make_chi_read(txnid, addr, qos=qos)
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
    assert not cov_qos.uncovered(), f"uncovered QoS bins: {cov_qos.uncovered()}"
    dut._log.info(f"random traffic OK: {sb.reads_done} reads, {sb.writes_done} writes, "
                  f"crc_err_cnt={int(dut.crc_err_cnt.value)}; "
                  f"coverage {cov_op.report()} {cov_cpl.report()} {cov_qos.report()}")


@cocotb.test(timeout_time=2, timeout_unit="ms")
async def test_random_errors(dut):
    """Randomized read stream with corrupted-checksum completions."""
    random.seed(0x5EED5)
    await reset_and_open(dut)

    dut.ucie_tx_data_ready.value = 1
    dut.ucie_rx_hdr_valid.value = 0
    dut.chi_rsp_ready.value = 1

    st = dict(running=True, n_corrupt=0, derr=0, ok=0, done=0, errors=[])
    inuse = set()
    expected = {}                 # txnid -> expected data
    pend = []                     # (tag, data, corrupt)
    pend_hdr_crdts = [0]          # TX header credits to return to bridge
    cov_csum = CoverGroup("rx_checksum", ["good", "bad"])
    cov_resp = CoverGroup("read_resperr", ["ok", "derr"])

    N = 80
    MAX_INFLIGHT = 12

    def rdy():
        return 1 if random.random() < 0.7 else 0

    async def tx_hdr_consumer():
        while st["running"]:
            dut.ucie_tx_hdr_ready.value = rdy()
            await RisingEdge(dut.ucie_clk)
            if dut.ucie_tx_hdr_ready.value == 1 and dut.ucie_tx_hdr_valid.value == 1:
                hdr = int(dut.ucie_tx_hdr.value)
                tag = field(hdr, UCIE_TAG_LSB, 8)
                addr16 = field(hdr, UCIE_ADDR_LSB, 16)
                corrupt = random.random() < 0.3
                if corrupt:
                    st["n_corrupt"] += 1
                cov_csum.hit("bad" if corrupt else "good")
                pend.append((tag, data_for(addr16), corrupt))

    async def rx_data_driver():
        while st["running"]:
            chosen = None
            if pend and random.random() < 0.6:
                chosen = random.choice(pend)
                tag, data, corrupt = chosen
                flits = pack_mem_cpl_burst_badcrc(tag, data) if corrupt \
                    else pack_mem_cpl_burst(tag, data)
                for flit in flits:
                    dut.ucie_rx_data.value = flit
                    dut.ucie_rx_data_valid.value = 1
                    while True:
                        await RisingEdge(dut.ucie_clk)
                        if dut.ucie_rx_data_ready.value == 1:
                            break
                dut.ucie_rx_data_valid.value = 0
                pend.remove(chosen)
                pend_hdr_crdts[0] += 1
            else:
                dut.ucie_rx_data_valid.value = 0
                await RisingEdge(dut.ucie_clk)

    async def hdr_crdt_returner():
        while st["running"]:
            if pend_hdr_crdts[0] > 0:
                pend_hdr_crdts[0] -= 1
                dut.ucie_rx_hdr_crdt.value = 1
            else:
                dut.ucie_rx_hdr_crdt.value = 0
            await RisingEdge(dut.ucie_clk)

    async def chi_comp_sink():
        while st["running"]:
            dut.chi_comp_data_ready.value = rdy()
            await RisingEdge(dut.clk)
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

    for c in (tx_hdr_consumer, rx_data_driver, hdr_crdt_returner, chi_comp_sink):
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


@cocotb.test(timeout_time=2, timeout_unit="ms")
async def test_phy_error(dut):
    """Link-error injection: ACTIVE -> ERR_DRAIN -> RETRAIN -> ACTIVE cycle.

    Exercises phy_link_ctrl S_ERR_DRAIN and S_RETRAIN states and the
    corresponding sideband LINK_ERROR / RETRAIN_REQ / LINK_ACTIVE branches in
    chi_to_ucie_bridge, closing the coverage gaps on those lines.
    """
    await reset_and_open(dut)

    dut.ucie_tx_hdr_ready.value  = 1
    dut.ucie_tx_data_ready.value = 1

    # Issue N reads so the bridge is briefly active with outstanding transactions.
    N         = 4
    addr_base = 0xB000_0000_0000
    for i in range(N):
        dut.chi_req_data.value  = make_chi_read(0x20 + i, addr_base + i * 64)
        dut.chi_req_valid.value = 1
        accepted = False
        for _ in range(100):
            await RisingEdge(dut.clk)
            if dut.chi_req_ready.value == 1:
                accepted = True
                break
        assert accepted, f"read {i} not accepted by chi_req_ready"
    dut.chi_req_valid.value = 0

    # Allow the async-FIFO CDC to drain the req_fifo into the UCIe TX datapath.
    # ucie_tx_hdr_ready=1, so all N headers fire in N ucie_clk cycles (~24 ns).
    # 40 ucie_clk cycles is a safe margin.
    await ClockCycles(dut.ucie_clk, 40)

    # Inject link error.  All FIFOs are now empty (req_fifo drained via hdr_fire;
    # rdat/rsp FIFOs have no completions), so drain_done is asserted immediately
    # and the phy_link_ctrl cycles through ERR_DRAIN → RETRAIN in ~3 clk cycles.
    PLC_ACTIVE  = 1
    PLC_ERR_DRN = 2
    PLC_RETRAIN = 3

    await RisingEdge(dut.clk)
    dut.link_error.value = 1

    for _ in range(20):
        await RisingEdge(dut.clk)
        if int(dut.link_state.value) == PLC_ERR_DRN:
            break
    assert int(dut.link_state.value) == PLC_ERR_DRN, \
        f"expected ERR_DRAIN (2), got link_state={int(dut.link_state.value)}"

    for _ in range(20):
        await RisingEdge(dut.clk)
        if int(dut.link_state.value) == PLC_RETRAIN:
            break
    assert int(dut.link_state.value) == PLC_RETRAIN, \
        f"expected RETRAIN (3), got link_state={int(dut.link_state.value)}"
    assert int(dut.retrain_req.value) == 1, "retrain_req not asserted in RETRAIN state"

    # Clear error; phy_init_done is still 1 from reset_and_open → ACTIVE recovery.
    await RisingEdge(dut.clk)
    dut.link_error.value = 0

    for _ in range(20):
        await RisingEdge(dut.clk)
        if int(dut.link_state.value) == PLC_ACTIVE:
            break
    assert int(dut.link_state.value) == PLC_ACTIVE, \
        f"expected ACTIVE (1), got link_state={int(dut.link_state.value)}"

    # Confirm the bridge reopens for new requests (reset_drain back to S_UP).
    await ClockCycles(dut.clk, 8)
    dut.chi_req_data.value  = make_chi_read(0xAA, addr_base + N * 64)
    dut.chi_req_valid.value = 1
    recovered = False
    for _ in range(100):
        await RisingEdge(dut.clk)
        if dut.chi_req_ready.value == 1:
            recovered = True
            break
    dut.chi_req_valid.value = 0
    assert recovered, "bridge did not reopen after PHY error recovery"

    dut._log.info(
        "phy_error OK: ACTIVE→ERR_DRAIN→RETRAIN→ACTIVE verified; bridge reopened"
    )


async def _send_rx_data_burst(dut, flits):
    """Helper: drive a burst of ucie_rx_data flits, waiting for ready each beat."""
    for flit in flits:
        dut.ucie_rx_data.value = flit
        dut.ucie_rx_data_valid.value = 1
        for _ in range(50):
            await RisingEdge(dut.ucie_clk)
            if dut.ucie_rx_data_ready.value == 1:
                break
        else:
            raise AssertionError("ucie_rx_data_ready never asserted")
    dut.ucie_rx_data_valid.value = 0


async def _send_rx_hdr(dut, hdr, timeout=20):
    """Helper: drive one UCIe RX header and wait for it to be accepted."""
    dut.ucie_rx_hdr.value = hdr
    dut.ucie_rx_hdr_valid.value = 1
    for _ in range(timeout):
        await RisingEdge(dut.ucie_clk)
        if dut.ucie_rx_hdr_ready.value == 1:
            dut.ucie_rx_hdr_valid.value = 0
            return
    raise AssertionError("ucie_rx_hdr_ready never asserted")


@cocotb.test(timeout_time=500, timeout_unit="us")
async def test_sideband_pm_l1(dut):
    """PM L1 flow: PM_IDLE→PM_DRAINING→PM_ACK_PEND→PM_L1→PM_IDLE.

    Covers sb_msg_handler PM state machine, pm_l1_active, rx_pm_l1_req,
    rx_pm_l1_exit, and the pm_ack_pend mux path in tx_data_w.
    drain_done is gated by reset_drain state; we lower phy_init_done to enter
    S_DRAIN so drain_done asserts (all FIFOs empty → all_empty=1).
    """
    await reset_and_open(dut)
    dut.ucie_tx_hdr_ready.value = 1
    dut.sb_tx_ready.value = 1

    # Step 1: send PM_L1_REQ → pm_l1_active asserts.
    await RisingEdge(dut.clk)
    dut.sb_rx_valid.value = 1
    dut.sb_rx_data.value = SB_MSG_PM_L1_REQ
    await RisingEdge(dut.clk)
    dut.sb_rx_valid.value = 0

    for _ in range(10):
        await RisingEdge(dut.clk)
        if dut.pm_l1_active.value == 1:
            break
    assert dut.pm_l1_active.value == 1, "pm_l1_active did not assert after PM_L1_REQ"

    # Step 2: lower phy_init_done → phy_link_ctrl ACTIVE→WAIT_PHY → reset_drain
    # S_UP→S_DRAIN; with all FIFOs empty, drain_done=1 immediately.
    # PM_DRAINING then transitions to PM_ACK_PEND on the next clk edge.
    dut.phy_init_done.value = 0
    for _ in range(20):
        await RisingEdge(dut.clk)
        if dut.sb_tx_valid.value == 1 and int(dut.sb_tx_data.value) == SB_MSG_PM_L1_ACK:
            break
    assert dut.sb_tx_valid.value == 1, "PM_L1_ACK (sb_tx_valid) not asserted"
    assert int(dut.sb_tx_data.value) == SB_MSG_PM_L1_ACK, \
        f"Expected PM_L1_ACK=0x{SB_MSG_PM_L1_ACK:02X}, got 0x{int(dut.sb_tx_data.value):02X}"

    # Allow ACK to fire (sb_tx_ready=1); bridge enters PM_L1.
    await RisingEdge(dut.clk)

    # Step 3: send PM_L1_EXIT → pm_l1_active deasserts.
    dut.sb_rx_valid.value = 1
    dut.sb_rx_data.value = SB_MSG_PM_L1_EXIT
    await RisingEdge(dut.clk)
    dut.sb_rx_valid.value = 0

    for _ in range(10):
        await RisingEdge(dut.clk)
        if dut.pm_l1_active.value == 0:
            break
    assert dut.pm_l1_active.value == 0, "pm_l1_active did not clear after PM_L1_EXIT"

    # Step 4: bring link back up so the bridge re-opens.
    dut.phy_init_done.value = 1
    for _ in range(30):
        await RisingEdge(dut.clk)
        if dut.chi_req_ready.value == 1:
            break

    dut._log.info("PM L1 flow: PM_IDLE→PM_DRAINING→PM_ACK_PEND→PM_L1→PM_IDLE verified")


@cocotb.test(timeout_time=500, timeout_unit="us")
async def test_sideband_param(dut):
    """PARAM exchange: PARAM_REQ → PARAM_ACK opcode → MAX_OUTSTANDING value byte.

    Covers param_pend, param_phase, param_opcode_pend, param_value_pend,
    and the SB_MSG_PARAM_ACK mux path in tx_data_w.
    """
    await reset_and_open(dut)
    dut.sb_tx_ready.value = 1

    # Wait for the post-reset LINK_ACTIVE sideband message to flush.
    for _ in range(20):
        await RisingEdge(dut.clk)
        if dut.sb_tx_valid.value == 0:
            break

    # Send PARAM_REQ.
    await RisingEdge(dut.clk)
    dut.sb_rx_valid.value = 1
    dut.sb_rx_data.value = SB_MSG_PARAM_REQ
    await RisingEdge(dut.clk)
    dut.sb_rx_valid.value = 0

    # Collect the two-byte PARAM_ACK response: opcode (0xB1) then MAX_OUTSTANDING.
    # With sb_tx_ready=1 both bytes fire on consecutive cycles, so we capture
    # them in a single pass to avoid missing the value byte.
    param_bytes = []
    for _ in range(20):
        await RisingEdge(dut.clk)
        if dut.sb_tx_valid.value == 1 and dut.sb_tx_ready.value == 1:
            param_bytes.append(int(dut.sb_tx_data.value))
            if len(param_bytes) == 2:
                break

    assert len(param_bytes) == 2, \
        f"Expected 2 PARAM_ACK bytes, captured {len(param_bytes)}: {[hex(b) for b in param_bytes]}"
    assert param_bytes[0] == SB_MSG_PARAM_ACK, \
        f"First byte: expected 0x{SB_MSG_PARAM_ACK:02X}, got 0x{param_bytes[0]:02X}"
    assert param_bytes[1] == 32, \
        f"Second byte (MAX_OUTSTANDING): expected 32, got {param_bytes[1]}"

    dut._log.info("PARAM exchange: PARAM_REQ → PARAM_ACK(0xB1) + 32 verified")


@cocotb.test(timeout_time=1, timeout_unit="ms")
async def test_split_completion(dut):
    """§6.3 split completion: a 64B read returns as two 32B UCIe MEM_CPLs.

    Covers rx_cpl_is_split, rx_cpl_upper, rx_cpl_frees_tbl, DataID=2 data
    placement in translate_ucie_data_to_chi (line with {data[255:0], 256'h0}).
    Lower half: addr[4]=0 → DataID=0; upper half: addr[4]=1 (addr=0x10) → DataID=2.
    """
    await reset_and_open(dut)
    dut.ucie_tx_hdr_ready.value = 1
    dut.chi_comp_data_ready.value = 1

    # Issue a size=6 (64B) read; alloc_is_large=1 for this entry.
    txnid = 0x55
    dut.chi_req_data.value = make_chi_read(txnid, 0x4000_0000_0000, size=0x6)
    dut.chi_req_valid.value = 1
    for _ in range(100):
        await RisingEdge(dut.clk)
        if dut.chi_req_ready.value == 1:
            dut.chi_req_valid.value = 0
            break
    else:
        assert False, "chi_req_ready never asserted"

    # Capture local tag from UCIe TX header.
    local_tag = None
    for _ in range(80):
        await RisingEdge(dut.ucie_clk)
        if dut.ucie_tx_hdr_valid.value == 1:
            local_tag = field(int(dut.ucie_tx_hdr.value), UCIE_TAG_LSB, 8)
            break
    assert local_tag is not None, "no UCIe TX header issued for size=6 read"

    dut.ucie_rx_hdr_crdt.value = 1
    await RisingEdge(dut.ucie_clk)
    dut.ucie_rx_hdr_crdt.value = 0

    # 256-bit payloads for each half.
    LOWER = 0xAABB_CCDD_EEFF_0011_2233_4455_6677_8899_A0B0_C0D0_E0F0_0010_2030_4050_6070_8090
    UPPER = 0xDEAD_BEEF_CAFE_BABE_1234_5678_9ABC_DEF0_F0E1_D2C3_B4A5_9687_7869_5A4B_3C2D_1E0F

    # Lower half: length=0x20 (32B, 2 beats), addr[4]=0.
    await _send_rx_data_burst(dut, pack_mem_cpl_burst(
        local_tag, LOWER, size=5, addr48=0x0000_0000_0000))

    # Upper half: length=0x20, addr[4]=1 (addr=0x10 sets header bit 36).
    await _send_rx_data_burst(dut, pack_mem_cpl_burst(
        local_tag, UPPER, size=5, addr48=0x0000_0000_0010))

    MASK256 = (1 << 256) - 1

    # First CHI CompData: DataID=0, data[255:0] = LOWER.
    for _ in range(100):
        await RisingEdge(dut.clk)
        if dut.chi_comp_data_valid.value == 1:
            break
    assert dut.chi_comp_data_valid.value == 1, "no first CHI CompData (lower split)"
    dat0 = int(dut.chi_comp_data.value)
    assert field(dat0, CHI_DAT_TXNID_LSB, 8) == txnid, "TxnID mismatch (lower)"
    assert field(dat0, CHI_DAT_DATAID_LSB, 4) == 0, \
        f"Expected DataID=0, got {field(dat0, CHI_DAT_DATAID_LSB, 4)}"
    got_lower = (dat0 >> CHI_DAT_DATA_LSB) & MASK256
    assert got_lower == LOWER & MASK256, \
        f"Lower data mismatch: 0x{got_lower:064x} != 0x{LOWER & MASK256:064x}"
    await RisingEdge(dut.clk)

    # Second CHI CompData: DataID=2, data[511:256]=UPPER, data[255:0]=0.
    for _ in range(100):
        await RisingEdge(dut.clk)
        if dut.chi_comp_data_valid.value == 1:
            break
    assert dut.chi_comp_data_valid.value == 1, "no second CHI CompData (upper split)"
    dat2 = int(dut.chi_comp_data.value)
    assert field(dat2, CHI_DAT_TXNID_LSB, 8) == txnid, "TxnID mismatch (upper)"
    assert field(dat2, CHI_DAT_DATAID_LSB, 4) == 2, \
        f"Expected DataID=2, got {field(dat2, CHI_DAT_DATAID_LSB, 4)}"
    lower256 = (dat2 >> CHI_DAT_DATA_LSB) & MASK256
    upper256 = (dat2 >> (CHI_DAT_DATA_LSB + 256)) & MASK256
    assert lower256 == 0, "Lower 256b of DataID=2 flit must be zero"
    assert upper256 == UPPER & MASK256, \
        f"Upper data mismatch: 0x{upper256:064x} != 0x{UPPER & MASK256:064x}"

    dut._log.info("split completion: DataID=0 (lower) + DataID=2 (upper) verified")


@cocotb.test(timeout_time=2, timeout_unit="ms")
async def test_txn_table_full(dut):
    """Fill all 32 txn_table slots; verify ucie_tx_hdr_valid is gated by tbl_full.

    Covers the tbl_full wire in the bridge and the full flag in txn_table.
    Credits are returned after each header to prevent TX-credit starvation
    (TX_HDR_CREDITS=8 < MAX_OUTSTANDING=32).
    """
    await reset_and_open(dut)
    dut.ucie_tx_hdr_ready.value = 1
    dut.chi_comp_data_ready.value = 1

    N = 32  # MAX_OUTSTANDING
    state = dict(headers=0, running=True)

    async def hdr_crdt_returner():
        while state["running"]:
            await RisingEdge(dut.ucie_clk)
            if dut.ucie_tx_hdr_valid.value == 1 and dut.ucie_tx_hdr_ready.value == 1:
                state["headers"] += 1
                dut.ucie_rx_hdr_crdt.value = 1
            else:
                dut.ucie_rx_hdr_crdt.value = 0

    cocotb.start_soon(hdr_crdt_returner())

    for i in range(N):
        dut.chi_req_data.value = make_chi_read(i & 0xFF, 0x3000_0000_0000 + i * 64)
        dut.chi_req_valid.value = 1
        for _ in range(300):
            await RisingEdge(dut.clk)
            if dut.chi_req_ready.value == 1:
                dut.chi_req_valid.value = 0
                break
        else:
            assert False, f"read {i} not accepted within timeout"

    # Wait for all N headers to be observed.
    for _ in range(2000):
        await RisingEdge(dut.ucie_clk)
        if state["headers"] >= N:
            break
    state["running"] = False
    assert state["headers"] >= N, f"only {state['headers']}/{N} UCIe headers observed"

    # Provide one extra credit so credit exhaustion cannot explain silence.
    dut.ucie_rx_hdr_crdt.value = 1
    await RisingEdge(dut.ucie_clk)
    dut.ucie_rx_hdr_crdt.value = 0
    await ClockCycles(dut.ucie_clk, 4)

    # One more read: must not produce a UCIe header (txn_table full).
    dut.chi_req_data.value = make_chi_read(0xFF, 0x9999_0000_0000)
    dut.chi_req_valid.value = 1
    for _ in range(20):
        await RisingEdge(dut.ucie_clk)
        assert dut.ucie_tx_hdr_valid.value == 0, \
            "ucie_tx_hdr_valid asserted with all txn_table slots occupied (tbl_full not gating)"
    dut.chi_req_valid.value = 0

    dut._log.info(f"txn_table full: {N}/{N} slots occupied, tbl_full gate verified")


@cocotb.test(timeout_time=1, timeout_unit="ms")
async def test_small_completions(dut):
    """1-beat (size=4/16B) and 2-beat (size=5/32B) MEM_CPL completions.

    Covers the 3'd1 and 3'd2 branches in the rx_dat_full combinational mux
    inside chi_to_ucie_bridge.v.
    """
    await reset_and_open(dut)
    dut.ucie_tx_hdr_ready.value = 1
    dut.chi_comp_data_ready.value = 1

    async def do_small_read(txnid, size, payload):
        dut.chi_req_data.value = make_chi_read(txnid, 0x6000_0000_0000 + txnid * 64, size=size)
        dut.chi_req_valid.value = 1
        for _ in range(100):
            await RisingEdge(dut.clk)
            if dut.chi_req_ready.value == 1:
                dut.chi_req_valid.value = 0
                break
        else:
            assert False, f"read txnid={txnid} never accepted"

        local_tag = None
        for _ in range(100):
            await RisingEdge(dut.ucie_clk)
            if dut.ucie_tx_hdr_valid.value == 1:
                local_tag = field(int(dut.ucie_tx_hdr.value), UCIE_TAG_LSB, 8)
                break
        assert local_tag is not None, f"no UCIe TX header for txnid={txnid}"

        dut.ucie_rx_hdr_crdt.value = 1
        await RisingEdge(dut.ucie_clk)
        dut.ucie_rx_hdr_crdt.value = 0

        await _send_rx_data_burst(dut, pack_mem_cpl_burst(local_tag, payload, size=size))

        for _ in range(100):
            await RisingEdge(dut.clk)
            if dut.chi_comp_data_valid.value == 1:
                break
        assert dut.chi_comp_data_valid.value == 1, f"no CHI CompData for txnid={txnid}"
        dat = int(dut.chi_comp_data.value)
        assert field(dat, CHI_DAT_TXNID_LSB, 8) == txnid, \
            f"TxnID mismatch: got 0x{field(dat, CHI_DAT_TXNID_LSB, 8):02X}"
        nbytes = 1 << size
        mask = (1 << (nbytes * 8)) - 1
        got = (dat >> CHI_DAT_DATA_LSB) & mask
        assert got == payload & mask, \
            f"size={size} data mismatch: got 0x{got:x}, exp 0x{payload & mask:x}"
        await RisingEdge(dut.clk)

    await do_small_read(0xC1, 4, 0xDEAD_BEEF_CAFE_BABE_1234_5678_9ABC_DEF0)  # 1 beat
    await do_small_read(0xC2, 5, data_for(0xC002))                            # 2 beats

    dut._log.info("small completions: 1-beat (size=4) and 2-beat (size=5) verified")


@cocotb.test(timeout_time=200, timeout_unit="us")
async def test_tag_error(dut):
    """MEM_CPL with an unallocated tag increments tag_err_cnt.

    Covers the tag_err output from txn_table and the tag_err_cnt counter
    in the ucie_clk domain of chi_to_ucie_bridge.
    """
    await reset_and_open(dut)
    dut.chi_comp_data_ready.value = 1

    initial_cnt = int(dut.tag_err_cnt.value)

    # tag=0xFF → lower LTAG_W=5 bits = 0x1F (slot 31, not allocated after reset).
    await _send_rx_data_burst(dut, pack_mem_cpl_burst(0xFF, 0xDEAD_BEEF_CAFE_BABE))

    await ClockCycles(dut.ucie_clk, 8)
    new_cnt = int(dut.tag_err_cnt.value)
    assert new_cnt == initial_cnt + 1, \
        f"tag_err_cnt did not increment (before={initial_cnt}, after={new_cnt})"

    dut._log.info(f"tag error: tag_err_cnt {initial_cnt} → {new_cnt}")


@cocotb.test(timeout_time=500, timeout_unit="us")
async def test_rx_hdr_bad_crc(dut):
    """Bad-CRC AD_CPL header increments crc_err_cnt.

    Covers the rx_hdr_bad wire in chi_to_ucie_bridge (the header-channel CRC
    error path; distinct from rx_dat_bad which test_random_errors covers).
    """
    await reset_and_open(dut)
    dut.chi_rsp_ready.value = 1

    initial_crc = int(dut.crc_err_cnt.value)

    # Build a valid AD_CPL header then corrupt its CRC field.
    good_hdr = pack_ucie_hdr(UCIE_PKT_KIND_AD_CPL, UCIE_CPL_SC, 0x00)
    bad_hdr  = good_hdr ^ 0xFFFF   # flip CRC[15:0]

    dut.ucie_rx_hdr.value = bad_hdr
    dut.ucie_rx_hdr_valid.value = 1
    for _ in range(20):
        await RisingEdge(dut.ucie_clk)
        if dut.ucie_rx_hdr_ready.value == 1:
            break
    dut.ucie_rx_hdr_valid.value = 0

    await ClockCycles(dut.ucie_clk, 6)
    new_crc = int(dut.crc_err_cnt.value)
    assert new_crc == initial_crc + 1, \
        f"crc_err_cnt did not increment on bad-CRC AD_CPL (before={initial_crc}, after={new_crc})"

    dut._log.info(f"rx_hdr_bad: crc_err_cnt {initial_crc} → {new_crc}")


@cocotb.test(timeout_time=1, timeout_unit="ms")
async def test_poison_completion(dut):
    """Poisoned MEM_CPL propagates POISON flag to CHI CompData.

    Covers rx_dat_poison_latched in chi_to_ucie_bridge.
    """
    await reset_and_open(dut)
    dut.ucie_tx_hdr_ready.value = 1
    dut.chi_comp_data_ready.value = 1

    txnid = 0xBB
    dut.chi_req_data.value = make_chi_read(txnid, 0x7000_0000_0000)
    dut.chi_req_valid.value = 1
    for _ in range(100):
        await RisingEdge(dut.clk)
        if dut.chi_req_ready.value == 1:
            dut.chi_req_valid.value = 0
            break
    else:
        assert False, "chi_req_ready never asserted"

    local_tag = None
    for _ in range(80):
        await RisingEdge(dut.ucie_clk)
        if dut.ucie_tx_hdr_valid.value == 1:
            local_tag = field(int(dut.ucie_tx_hdr.value), UCIE_TAG_LSB, 8)
            break
    assert local_tag is not None, "no UCIe TX header"

    dut.ucie_rx_hdr_crdt.value = 1
    await RisingEdge(dut.ucie_clk)
    dut.ucie_rx_hdr_crdt.value = 0

    # Return a poisoned completion (poison=1 sets attr[7] in the MEM_CPL header).
    await _send_rx_data_burst(dut, pack_mem_cpl_burst(local_tag, data_for(0x7000), poison=1))

    for _ in range(100):
        await RisingEdge(dut.clk)
        if dut.chi_comp_data_valid.value == 1:
            break
    assert dut.chi_comp_data_valid.value == 1, "no CHI CompData for poisoned completion"
    dat = int(dut.chi_comp_data.value)
    poison_bit = field(dat, CHI_DAT_POISON_LSB, 1)
    assert poison_bit == 1, f"CHI CompData POISON bit not set (got {poison_bit})"

    dut._log.info("poison completion: POISON bit propagated to CHI CompData")


@cocotb.test(timeout_time=2, timeout_unit="ms")
async def test_rdat_fifo_full(dut):
    """Fill rdat FIFO (depth=8) by stalling CHI CompData consumption.

    Covers rdat_w_full. With chi_comp_data_ready=0, 8 completions fill the FIFO.
    A 9th completion's last beat stalls (ucie_rx_data_ready=0) until we drain.
    """
    await reset_and_open(dut)
    dut.ucie_tx_hdr_ready.value = 1
    dut.chi_comp_data_ready.value = 0   # stall CHI CompData → FIFO fills

    FIFO_DEPTH = 8
    state = dict(headers=0, tags=[], running=True)

    async def hdr_consumer():
        while state["running"]:
            await RisingEdge(dut.ucie_clk)
            if dut.ucie_tx_hdr_valid.value == 1 and dut.ucie_tx_hdr_ready.value == 1:
                state["headers"] += 1
                state["tags"].append(field(int(dut.ucie_tx_hdr.value), UCIE_TAG_LSB, 8))
                dut.ucie_rx_hdr_crdt.value = 1
            else:
                dut.ucie_rx_hdr_crdt.value = 0

    cocotb.start_soon(hdr_consumer())

    # Issue FIFO_DEPTH reads and wait for their headers.
    for i in range(FIFO_DEPTH):
        dut.chi_req_data.value = make_chi_read(i & 0xFF, 0x8000_0000_0000 + i * 64)
        dut.chi_req_valid.value = 1
        for _ in range(300):
            await RisingEdge(dut.clk)
            if dut.chi_req_ready.value == 1:
                dut.chi_req_valid.value = 0
                break
        else:
            assert False, f"read {i} not accepted"

    for _ in range(2000):
        await RisingEdge(dut.ucie_clk)
        if state["headers"] >= FIFO_DEPTH:
            break
    state["running"] = False
    assert state["headers"] >= FIFO_DEPTH, \
        f"only {state['headers']}/{FIFO_DEPTH} headers seen"

    tags = state["tags"]

    # Send FIFO_DEPTH completions; each last beat writes one entry → FIFO fills.
    for tag in tags:
        await _send_rx_data_burst(dut, pack_mem_cpl_burst(tag, data_for(tag)))

    # FIFO is now full (8/8). Drive a 9th burst beat-by-beat.
    # Beats 0-3: !rx_dat_last → ucie_rx_data_ready=1 regardless of rdat_w_full.
    # Beat 4 (last): rdat_w_full=1 → ucie_rx_data_ready=0 → stall until we drain.
    extra_flits = pack_mem_cpl_burst(tags[0], data_for(0xBEEF))
    ready_deasserted = False
    for beat_idx, flit in enumerate(extra_flits):
        is_last = (beat_idx == len(extra_flits) - 1)
        dut.ucie_rx_data.value = flit
        dut.ucie_rx_data_valid.value = 1

        if is_last:
            # Sample ready before draining to check the stall condition.
            await RisingEdge(dut.ucie_clk)
            if dut.ucie_rx_data_ready.value == 0:
                ready_deasserted = True
            # Release the drain so the last beat can complete.
            dut.chi_comp_data_ready.value = 1

        # Wait for ready (with drain now open it will unblock quickly).
        for _ in range(100):
            await RisingEdge(dut.ucie_clk)
            if dut.ucie_rx_data_ready.value == 1:
                break
        else:
            assert False, f"ucie_rx_data_ready stuck at beat {beat_idx}"

    dut.ucie_rx_data_valid.value = 0
    await ClockCycles(dut.clk, 20)

    assert ready_deasserted, \
        "last beat of 9th burst was not stalled — rdat FIFO did not fill to depth 8"

    dut._log.info("rdat FIFO full: last-beat stall observed; rdat_w_full verified")


@cocotb.test(timeout_time=200, timeout_unit="us")
async def test_err_inj(dut):
    """err_inj_en asserted for one ucie_clk cycle increments crc_err_cnt.

    Covers the err_inj_en input port and the first branch of the crc_err_cnt
    always block in chi_to_ucie_bridge.
    """
    await reset_and_open(dut)

    initial_cnt = int(dut.crc_err_cnt.value)

    await RisingEdge(dut.ucie_clk)
    dut.err_inj_en.value = 1
    await RisingEdge(dut.ucie_clk)
    dut.err_inj_en.value = 0

    await ClockCycles(dut.ucie_clk, 4)
    new_cnt = int(dut.crc_err_cnt.value)
    assert new_cnt == initial_cnt + 1, \
        f"crc_err_cnt did not increment (before={initial_cnt}, after={new_cnt})"

    dut._log.info(f"err_inj: crc_err_cnt {initial_cnt} → {new_cnt}")


@cocotb.test(timeout_time=2, timeout_unit="ms")
async def test_wdat_fifo_full(dut):
    """Fill the write-data FIFO by stalling UCIe TX data output.

    Covers wdat_w_full: after FIFO_DEPTH=8 writes fill both the req and wdat
    FIFOs, req headers drain through UCIe TX (ucie_tx_hdr_ready=1) while
    ucie_tx_data_ready=0 keeps the wdat FIFO full.  A 9th write then sees
    chi_req_ready=0 because wdat_w_full blocks accept_wr_data even though
    the req FIFO has space.
    """
    await reset_and_open(dut)
    FIFO_DEPTH = 8

    dut.ucie_tx_hdr_ready.value  = 1   # let req headers drain freely
    dut.ucie_tx_data_ready.value = 0   # hold wdat FIFO full; no TX data beats fire
    dut.chi_rsp_ready.value      = 1
    dut.chi_comp_data_ready.value = 1

    state = dict(headers=0, running=True)

    async def hdr_crdt_returner():
        while state["running"]:
            await RisingEdge(dut.ucie_clk)
            if dut.ucie_tx_hdr_valid.value == 1 and dut.ucie_tx_hdr_ready.value == 1:
                state["headers"] += 1
                dut.ucie_rx_hdr_crdt.value = 1
            else:
                dut.ucie_rx_hdr_crdt.value = 0

    cocotb.start_soon(hdr_crdt_returner())

    # Issue FIFO_DEPTH writes; both req FIFO and wdat FIFO fill atomically.
    for i in range(FIFO_DEPTH):
        addr = 0xC000 + i * 64
        dut.chi_req_data.value      = make_chi_write_req(0x10 + i, addr)
        dut.chi_wr_data.value       = make_chi_write_data(0x10 + i, data_for(i))
        dut.chi_req_valid.value     = 1
        dut.chi_wr_data_valid.value = 1
        for _ in range(300):
            await RisingEdge(dut.clk)
            if dut.chi_req_ready.value == 1:
                dut.chi_req_valid.value     = 0
                dut.chi_wr_data_valid.value = 0
                break
        else:
            assert False, f"write {i} not accepted within timeout"

    # Wait for all FIFO_DEPTH req headers to drain through UCIe TX.
    # req FIFO drains as hdr_fire fires; wdat FIFO stays full (tx_data_ready=0).
    for _ in range(2000):
        await RisingEdge(dut.ucie_clk)
        if state["headers"] >= FIFO_DEPTH:
            break
    state["running"] = False
    assert state["headers"] >= FIFO_DEPTH, \
        f"only {state['headers']}/{FIFO_DEPTH} write TX headers observed"

    # CDC settling: req FIFO now empty, wdat FIFO still 8/8.
    await ClockCycles(dut.clk, 10)

    # 9th write must be blocked by wdat_w_full (accept_wr_data=0 blocks chi_req_ready).
    dut.chi_req_data.value      = make_chi_write_req(0x20, 0xD000)
    dut.chi_wr_data.value       = make_chi_write_data(0x20, data_for(0x20))
    dut.chi_req_valid.value     = 1
    dut.chi_wr_data_valid.value = 1
    stalled = True
    for _ in range(20):
        await RisingEdge(dut.clk)
        if dut.chi_req_ready.value == 1:
            stalled = False
            break
    assert stalled, "chi_req_ready asserted despite wdat FIFO full — wdat_w_full not blocking"
    dut.chi_req_valid.value     = 0
    dut.chi_wr_data_valid.value = 0

    # Release drain: FIFO_DEPTH bursts × 5 beats = 40 beats; initial dat_crdt=8
    # handles all 8 bursts without needing credit returns.
    dut.ucie_tx_data_ready.value = 1
    await ClockCycles(dut.ucie_clk, 200)

    dut._log.info("wdat FIFO full: chi_req_ready stall verified; wdat_w_full coverage hit")


@cocotb.test(timeout_time=2, timeout_unit="ms")
async def test_rsp_fifo_full(dut):
    """Fill the RSP FIFO (depth=8) by stalling CHI RSP consumption.

    Covers rsp_w_full: 8 AD_CPL write-completion headers from UCIe fill the
    RSP async FIFO while chi_rsp_ready=0 prevents drain.  The 9th header sees
    ucie_rx_hdr_ready=0 because rsp_w_full gates ucie_rx_hdr_ready.
    """
    await reset_and_open(dut)
    FIFO_DEPTH = 8

    dut.ucie_tx_hdr_ready.value  = 1
    dut.ucie_tx_data_ready.value = 1
    dut.chi_rsp_ready.value      = 0   # stall RSP FIFO drain
    dut.chi_comp_data_ready.value = 1

    state = dict(headers=0, tags=[], running=True)

    async def hdr_consumer():
        """Collect write TX headers and return hdr + dat credits."""
        while state["running"]:
            await RisingEdge(dut.ucie_clk)
            fired_hdr = (dut.ucie_tx_hdr_valid.value == 1
                         and dut.ucie_tx_hdr_ready.value == 1)
            fired_dat = (dut.ucie_tx_data_valid.value == 1
                         and dut.ucie_tx_data_ready.value == 1)
            dut.ucie_rx_hdr_crdt.value = 1 if fired_hdr else 0
            dut.ucie_rx_dat_crdt.value = 1 if fired_dat else 0
            if fired_hdr:
                hdr = int(dut.ucie_tx_hdr.value)
                if field(hdr, UCIE_CODE_LSB, 4) == UCIE_MSG_MEM_WR:
                    state["headers"] += 1
                    state["tags"].append(field(hdr, UCIE_TAG_LSB, 8))

    cocotb.start_soon(hdr_consumer())

    # Issue FIFO_DEPTH writes; TX headers and data drain freely.
    for i in range(FIFO_DEPTH):
        addr = 0xE000 + i * 64
        dut.chi_req_data.value      = make_chi_write_req(0x30 + i, addr)
        dut.chi_wr_data.value       = make_chi_write_data(0x30 + i, data_for(i + 8))
        dut.chi_req_valid.value     = 1
        dut.chi_wr_data_valid.value = 1
        for _ in range(300):
            await RisingEdge(dut.clk)
            if dut.chi_req_ready.value == 1:
                dut.chi_req_valid.value     = 0
                dut.chi_wr_data_valid.value = 0
                break
        else:
            assert False, f"write {i} not accepted within timeout"

    # Wait for all FIFO_DEPTH write TX headers (needed for txn_table local tags).
    for _ in range(3000):
        await RisingEdge(dut.ucie_clk)
        if state["headers"] >= FIFO_DEPTH:
            break
    state["running"] = False
    assert state["headers"] >= FIFO_DEPTH, \
        f"only {state['headers']}/{FIFO_DEPTH} write TX headers observed"

    tags = state["tags"][:FIFO_DEPTH]

    # Allow TX data bursts to drain (initial dat_crdt=8 covers all 8 bursts).
    await ClockCycles(dut.ucie_clk, 150)

    # Send FIFO_DEPTH AD_CPL headers into the RSP FIFO (chi_rsp_ready=0 → no drain).
    for tag in tags:
        hdr = pack_ucie_hdr(UCIE_PKT_KIND_AD_CPL, UCIE_CPL_SC, tag)
        await _send_rx_hdr(dut, hdr)

    # RSP FIFO now 8/8 full.  Next header must see ucie_rx_hdr_ready=0.
    dummy_hdr = pack_ucie_hdr(UCIE_PKT_KIND_AD_CPL, UCIE_CPL_SC, 0x00)
    dut.ucie_rx_hdr.value = dummy_hdr
    dut.ucie_rx_hdr_valid.value = 1
    ready_deasserted = False
    for _ in range(20):
        await RisingEdge(dut.ucie_clk)
        if dut.ucie_rx_hdr_ready.value == 0:
            ready_deasserted = True
            break
    dut.ucie_rx_hdr_valid.value = 0

    assert ready_deasserted, \
        "ucie_rx_hdr_ready did not deassert — RSP FIFO did not fill to depth 8"

    # Drain RSP FIFO.
    dut.chi_rsp_ready.value = 1
    await ClockCycles(dut.clk, 50)

    dut._log.info("RSP FIFO full: ucie_rx_hdr_ready stall verified; rsp_w_full coverage hit")
