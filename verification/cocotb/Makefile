# cocotb regression for chi_to_ucie_bridge.
#
# Requires: cocotb (with the matching VPI/VPL libs) and a simulator (iverilog or
# verilator) on PATH.
#
#   make                 # run the suite under Icarus (default)
#   make SIM=verilator    # run under Verilator (enables SVA + coverage)
#   make clean
#
# Environment note (this dev box): the oss-cad-suite shell exports VIRTUAL_ENV
# and puts a stub `python` on PATH, which misleads cocotb's interpreter
# detection and yields a Python with no stdlib. We pin cocotb to the system
# Python that actually has cocotb installed. Override COCOTB_PYTHON if needed.

COCOTB_PYTHON ?= /usr/bin/python3.10

# Derive the interpreter's home, stdlib and site-packages from COCOTB_PYTHON so
# the embedded interpreter finds `encodings` and `cocotb` regardless of the
# oss-cad-suite shell environment.
unexport VIRTUAL_ENV
export PYTHONHOME := $(shell $(COCOTB_PYTHON) -c 'import sys; print(sys.base_prefix)')
export PYTHONPATH := $(shell $(COCOTB_PYTHON) -c 'import sysconfig, site; s=sysconfig.get_path("stdlib"); print(":".join([s, s+"/lib-dynload", sysconfig.get_path("platstdlib"), sysconfig.get_path("purelib")] + site.getsitepackages() + [site.getusersitepackages()]))')

SIM           ?= icarus
TOPLEVEL_LANG ?= verilog

SRC_DIR := $(abspath ../../src)

VERILOG_SOURCES := \
	$(SRC_DIR)/async_fifo.v \
	$(SRC_DIR)/cdc_sync.v \
	$(SRC_DIR)/reset_sync.v \
	$(SRC_DIR)/reset_drain.v \
	$(SRC_DIR)/credit_counter.v \
	$(SRC_DIR)/credit_pulse_sync.v \
	$(SRC_DIR)/txn_table.v \
	$(SRC_DIR)/phy_link_ctrl.v \
	$(SRC_DIR)/sb_msg_handler.v \
	$(SRC_DIR)/chi_to_ucie_bridge.v

TOPLEVEL := chi_to_ucie_bridge
MODULE   := test_bridge

COMPILE_ARGS += -I$(SRC_DIR)

ifeq ($(SIM),verilator)
# Verilator: enable SVA assertions and coverage; the bound SVA module is added
# only here since Icarus' concurrent-assertion/bind support is limited.
VERILOG_SOURCES += $(SRC_DIR)/chi_to_ucie_bridge_sva.sv
EXTRA_ARGS += --assert --coverage
COMPILE_ARGS += +define+BRIDGE_SVA
# Pin time units so cocotb's ns-scale Timers advance (RTL has no `timescale).
COMPILE_ARGS += --timescale 1ns/1ps
COMPILE_ARGS += -Wno-DECLFILENAME -Wno-WIDTH -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM
else
COMPILE_ARGS += -g2012
endif

include $(shell cocotb-config --makefiles)/Makefile.sim
