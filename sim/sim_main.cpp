// Verilator trace harness for chi_to_ucie_bridge.
//
// The directed SystemVerilog testbench owns protocol self-checking. This C++
// harness provides the root `make vlt-vcd` flow used by sibling RTL repos and
// captures reset, link-up, idle CDC, and basic ready/valid activity.

#include "Vchi_to_ucie_bridge.h"
#include "verilated.h"
#include "verilated_cov.h"
#if VM_TRACE
#include "verilated_vcd_c.h"
#endif

#include <cstdint>
#include <cstdio>
#include <cstring>

static void zero_wide(uint32_t* words, int nwords) {
    for (int i = 0; i < nwords; ++i) words[i] = 0;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vchi_to_ucie_bridge* dut = new Vchi_to_ucie_bridge;

#if VM_TRACE
    Verilated::traceEverOn(true);
    VerilatedVcdC* tfp = new VerilatedVcdC;
    dut->trace(tfp, 99);
    const char* vcd_path = "waves.vcd";
    for (int i = 1; i < argc; ++i) {
        if (!strncmp(argv[i], "+vcd=", 5)) vcd_path = argv[i] + 5;
    }
    tfp->open(vcd_path);
#endif

    dut->clk = 0;
    dut->ucie_clk = 0;
    dut->rst_n = 0;
    dut->chi_req_valid = 0;
    zero_wide(dut->chi_req_data.data(), 3);     // CHI_REQ_W=82b → 3 words
    dut->chi_wr_data_valid = 0;
    zero_wide(dut->chi_wr_data.data(), 19);     // CHI_DAT_W=598b → 19 words
    dut->chi_rsp_ready = 1;
    dut->chi_comp_data_ready = 1;
    dut->ucie_tx_hdr_ready = 1;
    dut->ucie_tx_data_ready = 1;
    dut->ucie_rx_hdr_valid = 0;
    zero_wide(dut->ucie_rx_hdr.data(), 4);      // UCIE_HDR_W=128b → 4 words
    dut->ucie_rx_data_valid = 0;
    zero_wide(dut->ucie_rx_data.data(), 4);     // UCIE_DATA_W=128b → 4 words
    dut->ucie_rx_hdr_crdt = 0;
    dut->ucie_rx_dat_crdt = 0;
    dut->phy_init_done = 0;
    dut->link_error = 0;
    dut->sb_tx_ready = 1;
    dut->sb_rx_valid = 0;
    dut->sb_rx_data = 0;
    dut->err_inj_en = 0;
    dut->eval();

    const int CLK_H = 5;
    const int UCIE_H = 3;
    const uint64_t T_END = 2000;

    uint64_t clk_cycles = 0;
    uint64_t ucie_cycles = 0;
    int prev_clk = 0;
    int prev_ucie_clk = 0;

    for (uint64_t t = 1; t < T_END && !Verilated::gotFinish(); ++t) {
        int clk = static_cast<int>((t / CLK_H) & 1);
        int ucie_clk = static_cast<int>((t / UCIE_H) & 1);
        int clk_rise = clk && !prev_clk;
        int ucie_rise = ucie_clk && !prev_ucie_clk;

        dut->clk = clk;
        dut->ucie_clk = ucie_clk;

        if (clk_cycles >= 8) dut->rst_n = 1;
        if (clk_cycles >= 16) dut->phy_init_done = 1;
        if (clk_cycles >= 80 && clk_cycles < 100) dut->ucie_tx_hdr_ready = 0;
        else dut->ucie_tx_hdr_ready = 1;
        if (clk_cycles >= 120 && clk_cycles < 132) dut->phy_init_done = 0;
        if (clk_cycles >= 132) dut->phy_init_done = 1;

        dut->eval();

#if VM_TRACE
        tfp->dump(t);
#endif

        if (clk_rise) ++clk_cycles;
        if (ucie_rise) ++ucie_cycles;
        prev_clk = clk;
        prev_ucie_clk = ucie_clk;
    }

    dut->final();
#if VM_TRACE
    tfp->close();
    delete tfp;
    std::printf("[sim_vcd] VCD written to %s\n", vcd_path);
#endif
    VerilatedCov::write("coverage.dat");
    std::printf("[sim_vcd] done: %llu clk cycles, %llu ucie_clk cycles\n",
                static_cast<unsigned long long>(clk_cycles),
                static_cast<unsigned long long>(ucie_cycles));
    delete dut;
    return 0;
}
