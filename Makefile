# Root Makefile - chi-to-ucie-bridge

VERILATOR ?= verilator
SBY       ?= sby

BRIDGE_SRCS := $(shell grep -vE '^[[:space:]]*(#|$$)' src/files.f)
COV_DIR := sim/obj_dir_cov

.PHONY: help lint sim regress stress vcd gtkwave coverage formal synth ci clean

help:
	@echo "chi-to-ucie-bridge - common targets"
	@echo ""
	@echo "  make lint      - Verilator --lint-only on RTL"
	@echo "  make sim       - Icarus directed simulation"
	@echo "  make stress    - directed simulation stress alias"
	@echo "  make regress   - lint + sim"
	@echo "  make coverage  - Verilator coverage stub/build"
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

regress: lint sim
	@echo "[REGRESS] lint + directed sim PASSED"

coverage:
	@command -v $(VERILATOR) >/dev/null 2>&1 || { echo "[COVERAGE] verilator not on PATH; skipping"; exit 0; }
	rm -rf $(COV_DIR)
	$(VERILATOR) --coverage -cc $(BRIDGE_SRCS) --top-module chi_to_ucie_bridge \
		--Mdir $(COV_DIR) -Isrc -Wno-DECLFILENAME -Wno-WIDTH -Wno-fatal
	$(MAKE) -C $(COV_DIR) -f Vchi_to_ucie_bridge.mk
	@echo "[COVERAGE] RTL coverage model built; add sim/sim_main.cpp for executable coverage."

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
	rm -rf $(COV_DIR) sim/coverage.info sim/synth.log
