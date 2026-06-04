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
	src/chi_to_ucie_bridge.v

# Bound concurrent SVA properties, enabled under Verilator's assertion engine.
SVA_SRC  := src/chi_to_ucie_bridge_sva.sv
SVA_ARGS := --assert +define+BRIDGE_SVA
COV_DIR := sim/obj_dir_cov

.PHONY: help lint sim regress stress vcd gtkwave vlt-vcd vlt-gtkwave coverage formal synth ci clean

help:
	@echo "chi-to-ucie-bridge - common targets"
	@echo ""
	@echo "  make lint      - Verilator --lint-only on RTL"
	@echo "  make sim       - Icarus directed simulation"
	@echo "  make stress    - directed simulation stress alias"
	@echo "  make vcd       - Icarus sim dumping verification/directed/build/waves.vcd"
	@echo "  make gtkwave   - make vcd, then open the Icarus VCD"
	@echo "  make vlt-vcd   - Verilator --trace harness dumping sim/obj_dir_vcd/waves.vcd"
	@echo "  make vlt-gtkwave - make vlt-vcd, then open the Verilator VCD"
	@echo "  make regress   - lint + sim"
	@echo "  make coverage  - Verilator coverage + SVA (--assert) run -> sim/coverage.info"
	@echo "  make formal    - SymbiYosys smoke targets"
	@echo "  make synth     - Yosys synthesis smoke"
	@echo "  make clean     - remove generated artifacts"

lint:
	$(MAKE) -C verification/directed lint

sim:
	$(MAKE) -C verification/directed sim

stress:
	$(MAKE) -C verification/directed stress

vcd:
	$(MAKE) -C verification/directed vcd

gtkwave:
	$(MAKE) -C verification/directed gtkwave

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
	rm -rf $(COV_DIR) $(VCD_DIR) sim/coverage.info sim/synth.log sim/coverage.dat
