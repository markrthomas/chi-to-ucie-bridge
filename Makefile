# Root Makefile - chi-to-ucie-bridge

VERILATOR ?= verilator
SBY       ?= sby

VERILATOR_ROOT := $(shell v=$$(command -v verilator 2>/dev/null); [ -n "$$v" ] && realpath "$$(dirname "$$v")/../share/verilator")
VERILATOR_INC  := $(VERILATOR_ROOT)/include
VERILATOR_CPP  := $(VERILATOR_INC)/verilated.cpp $(VERILATOR_INC)/verilated_cov.cpp \
                  $(VERILATOR_INC)/verilated_threads.cpp

# RTL source list (synthesizable bridge, in elaboration order).
BRIDGE_SRCS := \
	src/async_fifo.v \
	src/cdc_sync.v \
	src/reset_sync.v \
	src/reset_drain.v \
	src/credit_counter.v \
	src/credit_pulse_sync.v \
	src/txn_table.v \
	src/phy_link_ctrl.v \
	src/sb_msg_handler.v \
	src/chi_to_ucie_bridge.v

# Bound concurrent SVA properties, enabled under Verilator's assertion engine.
SVA_SRC  := src/chi_to_ucie_bridge_sva.sv
SVA_ARGS := --assert +define+BRIDGE_SVA
COV_DIR  := sim/obj_dir_cov
COCOTB_COV := verification/cocotb/coverage.dat

.PHONY: help lint sim cocotb test check regress stress vcd gtkwave waves wave vlt-vcd vlt-gtkwave coverage coverage-all coverage-report coverage-html formal synth ci clean

help:
	@echo "chi-to-ucie-bridge - common targets"
	@echo "(cross-repo target vocabulary: see DV_STANDARDS.md)"
	@echo ""
	@echo "  make lint      - Verilator --lint-only on RTL"
	@echo "  make sim       - Icarus directed simulation"
	@echo "  make stress    - directed simulation stress alias"
	@echo "  make cocotb    - cocotb regression (verification/cocotb; SIM=icarus|verilator)"
	@echo "  make test      - alias for make cocotb"
	@echo "  make check     - light local gate: lint + sim"
	@echo "  make vcd       - Icarus sim dumping verification/directed/build/waves.vcd"
	@echo "  make gtkwave   - make vcd, then open the Icarus VCD with the curated waves.gtkw layout"
	@echo "  make waves     - cocotb test_random_traffic, fresh random seed (SEED=n replays) -> FST"
	@echo "  make wave      - make waves, then open it in GTKWave (layout, zoomed to fit)"
	@echo "  make vlt-vcd   - Verilator --trace harness dumping sim/obj_dir_vcd/waves.vcd"
	@echo "  make vlt-gtkwave - make vlt-vcd, then open the Verilator VCD"
	@echo "  make regress   - lint + sim"
	@echo "  make coverage          - Verilator coverage + SVA (--assert) run -> sim/coverage.info"
	@echo "  make coverage-all      - merge directed + cocotb coverage -> sim/coverage_merged.info"
	@echo "  make coverage-report   - text summary + annotated sources (sim/annotated_merged/)"
	@echo "  make coverage-html     - HTML report in sim/coverage_html/ (requires genhtml)"
	@echo "  make formal    - SymbiYosys smoke targets"
	@echo "  make synth     - Yosys synthesis smoke"
	@echo "  make clean     - remove generated artifacts"

lint:
	$(MAKE) -C verification/directed lint

sim:
	$(MAKE) -C verification/directed sim

stress:
	$(MAKE) -C verification/directed stress

cocotb:
	$(MAKE) -C verification/cocotb

test: cocotb

check: lint sim
	@echo "[CHECK] lint + sim PASSED"

vcd:
	$(MAKE) -C verification/directed vcd

gtkwave:
	$(MAKE) -C verification/directed gtkwave

# waves / wave: one random test end to end. cocotb test_random_traffic (random
# R/W with backpressure and out-of-order UCIe completions, scoreboarded) under
# Icarus with a fresh random TEST_SEED each run (printed; SEED=<n> replays; the
# plain cocotb regression keeps its fixed seeds), FST via cocotb WAVES=1, then
# GTKWave with verification/cocotb/waves.gtkw zoomed to fit. cocotb only
# compiles its dump module into a fresh sim_build, so that is wiped first.
COCOTB_DIR := verification/cocotb
WAVE_TEST  ?= test_random_traffic
WAVE_FST   := $(COCOTB_DIR)/sim_build/chi_to_ucie_bridge.fst
WAVE_SEED  := $(or $(SEED),$(shell echo $$(( $$(od -An -N4 -tu4 /dev/urandom) % 2147483646 + 1 ))))
waves:
	@echo "[WAVE] $(WAVE_TEST) with random seed: SEED=$(WAVE_SEED)"
	rm -rf $(COCOTB_DIR)/sim_build
	TEST_SEED=$(WAVE_SEED) $(MAKE) -C $(COCOTB_DIR) WAVES=1 TESTCASE=$(WAVE_TEST)
	@if grep -q "<failure" $(COCOTB_DIR)/results.xml; then \
		echo "[WAVE] *** TEST FAILED (SEED=$(WAVE_SEED)) — see $(WAVE_FST) ***"; \
	else echo "[WAVE] PASS (SEED=$(WAVE_SEED)) — $(WAVE_FST)"; fi

wave: waves
	@if command -v gtkwave >/dev/null 2>&1; then \
		echo "[WAVE] opening $(WAVE_FST) with $(COCOTB_DIR)/waves.gtkw"; \
		exec gtkwave -S $(COCOTB_DIR)/zoom_full.tcl $(WAVE_FST) $(COCOTB_DIR)/waves.gtkw; \
	else \
		echo "[WAVE] gtkwave not on PATH — dump is at $(WAVE_FST) (layout: $(COCOTB_DIR)/waves.gtkw)"; \
	fi

VCD_DIR := sim/obj_dir_vcd
VLT_VCD := $(VCD_DIR)/waves.vcd
vlt-vcd:
	@set -e; \
	command -v $(VERILATOR) >/dev/null 2>&1 || { echo "[VLT-VCD] verilator not on PATH; skipping"; exit 0; }; \
	rm -rf $(VCD_DIR); \
	$(VERILATOR) --trace --coverage -cc $(BRIDGE_SRCS) --top-module chi_to_ucie_bridge \
		--Mdir $(VCD_DIR) -Isrc -Wno-DECLFILENAME -Wno-WIDTH -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-fatal; \
	$(MAKE) -C $(VCD_DIR) -f Vchi_to_ucie_bridge.mk; \
	g++ -DVM_TRACE=1 -DVM_COVERAGE=1 -o $(VCD_DIR)/sim_vcd \
		sim/sim_main.cpp $(VCD_DIR)/Vchi_to_ucie_bridge__ALL.a \
		-I$(VCD_DIR) -I$(VERILATOR_INC) -I$(VERILATOR_INC)/vltstd \
		$(VERILATOR_CPP) $(VERILATOR_INC)/verilated_vcd_c.cpp -pthread -lm; \
	( cd $(VCD_DIR) && ./sim_vcd +vcd=waves.vcd ); \
	echo "[VLT-VCD] $(VLT_VCD) written"

vlt-gtkwave: vlt-vcd
	gtkwave $(VLT_VCD)

regress: lint sim
	@echo "[REGRESS] lint + directed sim PASSED"

coverage:
	@set -e; \
	command -v $(VERILATOR) >/dev/null 2>&1 || { echo "[COVERAGE] verilator not on PATH; skipping"; exit 0; }; \
	rm -rf $(COV_DIR); \
	$(VERILATOR) --coverage $(SVA_ARGS) -cc $(BRIDGE_SRCS) $(SVA_SRC) --top-module chi_to_ucie_bridge \
		--Mdir $(COV_DIR) -Isrc -Wno-DECLFILENAME -Wno-WIDTH -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-fatal; \
	$(MAKE) -C $(COV_DIR) -f Vchi_to_ucie_bridge.mk; \
	g++ -DVM_TRACE=0 -DVM_COVERAGE=1 -o $(COV_DIR)/sim_cov \
		sim/sim_main.cpp $(COV_DIR)/Vchi_to_ucie_bridge__ALL.a \
		-I$(COV_DIR) -I$(VERILATOR_INC) -I$(VERILATOR_INC)/vltstd \
		$(VERILATOR_CPP) -pthread -lm; \
	( cd $(COV_DIR) && ./sim_cov ); \
	verilator_coverage --write-info sim/coverage.info $(COV_DIR)/coverage.dat; \
	echo "[COVERAGE] sim/coverage.info written from sim/sim_main.cpp execution"; \
	verilator_coverage --annotate $(COV_DIR)/annotated $(COV_DIR)/coverage.dat >/dev/null 2>&1 || true

coverage-all: coverage
	@set -e; \
	if [ ! -f $(COCOTB_COV) ]; then \
		echo "[COVERAGE-ALL] $(COCOTB_COV) not found; run 'make SIM=verilator' in verification/cocotb first"; \
		exit 1; \
	fi; \
	verilator_coverage --write-info sim/coverage_merged.info \
		$(COV_DIR)/coverage.dat $(COCOTB_COV); \
	echo "[COVERAGE-ALL] sim/coverage_merged.info written (directed + cocotb merged)"

# Normalize the merged .info (deduplicate absolute/relative SF: blocks),
# print a per-file summary, and write annotated source copies.
# Does not require genhtml.
NORM_INFO := sim/coverage_normalized.info
NORM_PY   := sim/normalize_info.py

coverage-report: coverage-all
	@set -e; \
	python3 $(NORM_PY) sim/coverage_merged.info $(NORM_INFO) \
		--summary --annotate sim/annotated_merged; \
	echo "[COVERAGE-REPORT] annotated sources in sim/annotated_merged/"

# HTML report via genhtml (lcov package).  Install with: sudo apt install lcov
coverage-html: coverage-all
	@set -e; \
	command -v genhtml >/dev/null 2>&1 || { \
		echo "[COVERAGE-HTML] genhtml not found; install with: sudo apt install lcov"; \
		exit 1; \
	}; \
	python3 $(NORM_PY) sim/coverage_merged.info $(NORM_INFO); \
	rm -rf sim/coverage_html; \
	genhtml $(NORM_INFO) --output-directory sim/coverage_html \
		--title "chi-to-ucie-bridge" --legend --num-spaces 4 \
		--prefix $(shell pwd)/src; \
	echo "[COVERAGE-HTML] report in sim/coverage_html/index.html"

formal:
	$(MAKE) -C verification/formal

synth:
	@set -e; \
	command -v yosys >/dev/null 2>&1 || { echo "[SYNTH] yosys not on PATH; skipping"; exit 0; }; \
	mkdir -p sim; \
	yosys -p "read_verilog -sv -Isrc $(BRIDGE_SRCS); synth -top chi_to_ucie_bridge; stat" > sim/synth.log 2>&1; \
	grep -E "(wires|cells|memories|processes)$$" sim/synth.log; \
	if grep -i "Latch inferred" sim/synth.log | grep -v "No latch inferred" > /dev/null; then \
		echo "[SYNTH] FAIL: inferred latches detected"; exit 1; \
	fi; \
	echo "[SYNTH] PASS: no inferred latches; see sim/synth.log"

ci: regress formal synth
	@echo "[CI] regress + formal + synth PASSED"

clean:
	$(MAKE) -C verification/directed clean
	-$(MAKE) -C verification/formal clean
	rm -rf $(COV_DIR) $(VCD_DIR) sim/coverage.info sim/coverage_merged.info sim/synth.log sim/coverage.dat
