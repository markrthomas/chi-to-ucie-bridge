# Verilator UVM flow for the CHI<->UCIe bridge UVM environment
# (../ = verification/uvm; RTL in <repo>/src).
#
# Runs the *same* SystemVerilog UVM env as Xcelium (xrun) would, but under
# open-source Verilator (>= 5.050) with the Accellera UVM 2020.3.1 library
# bundled in the Verilator source tree (test_regress/t/uvm).
#
# Quick start (local lint is RAM-safe; the full --binary build belongs in CI):
#   V=~/verilator/bin/verilator ; U=~/verilator/test_regress/t/uvm
#   ( unset VERILATOR_ROOT; make -C verification/uvm/vlt lint  VERILATOR=$V UVM_HOME=$U )
#   ( unset VERILATOR_ROOT; make -C verification/uvm/vlt smoke VERILATOR=$V UVM_HOME=$U )

VERILATOR ?= verilator

UVM_HOME ?= $(error Set UVM_HOME to the bundled Verilator UVM dir, e.g. \
  ~/verilator/test_regress/t/uvm)
UVM_HDR := $(UVM_HOME)/uvm_pkg_all_v2020_3_1_dpi.svh
UVM_DPI := $(UVM_HOME)/v2020_3_1/dpi/uvm_dpi.cc

BUILD_JOBS ?= 1
UVM_TEST   ?= base_test

VFLAGS ?= --binary --timing --vpi -j $(BUILD_JOBS) --build-jobs $(BUILD_JOBS) \
          -Wno-fatal -Wno-COVERIGN -Wno-TIMESCALEMOD --CFLAGS -O0
UVM_PLUSARGS ?= +UVM_NO_RELNOTES

VLT_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
UVMROOT := $(abspath $(VLT_DIR)/..)
SRC     := $(abspath $(VLT_DIR)/../../../src)
OBJ     := $(VLT_DIR)/obj

INCS := +incdir+$(SRC) +incdir+$(UVMROOT) +incdir+$(VLT_DIR) +incdir+$(UVM_HOME)

# RTL: all src/*.v except the standalone tb_* Verilog testbench, plus the SVA.
RTL  := $(filter-out %/tb_%,$(wildcard $(SRC)/*.v)) $(SRC)/chi_to_ucie_bridge_sva.sv
# Order: RTL, interfaces, UVM package (pulls in the env via `include), TB top.
SRCS := $(RTL) $(UVMROOT)/chi_if.sv $(UVMROOT)/ucie_if.sv \
        $(UVMROOT)/chi_ucie_uvm_pkg.sv $(UVMROOT)/tb_top.sv

define build
	rm -rf $(OBJ)/tb_top
	mkdir -p $(OBJ)/tb_top
	$(VERILATOR) $(VFLAGS) --top-module tb_top --Mdir $(OBJ)/tb_top \
	  $(INCS) $(UVM_HDR) $(UVM_DPI) $(SRCS)
endef
define run
	$(OBJ)/tb_top/Vtb_top $(UVM_PLUSARGS) +UVM_TESTNAME=$(1)
endef

.PHONY: all build smoke lint clean

all: smoke

build:
	$(build)

# The TB top calls run_test() with no default, so the test is chosen here.
smoke: build
	$(call run,$(UVM_TEST))

LINTFLAGS ?= --lint-only --timing -Wno-fatal -Wno-COVERIGN -Wno-TIMESCALEMOD
lint:
	$(VERILATOR) $(LINTFLAGS) --top-module tb_top $(INCS) $(UVM_HDR) $(SRCS)

clean:
	rm -rf $(OBJ)
