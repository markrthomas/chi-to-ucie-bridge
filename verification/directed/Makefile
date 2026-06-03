# Run from this directory: make
# Requires: iverilog, vvp. Optional: gtkwave for waveform viewing.

BUILD_DIR := build
SRC_DIR   := ../../src
VCD       := $(BUILD_DIR)/waves.vcd

SOURCES := $(SRC_DIR)/async_fifo.v \
           $(SRC_DIR)/cdc_sync.v \
           $(SRC_DIR)/reset_sync.v \
           $(SRC_DIR)/reset_drain.v \
           $(SRC_DIR)/credit_counter.v \
           $(SRC_DIR)/credit_pulse_sync.v \
           $(SRC_DIR)/chi_to_ucie_bridge.v \
           $(SRC_DIR)/chi_to_ucie_bridge_chk.v \
           $(SRC_DIR)/tb_chi_to_ucie_bridge.v
OUT := $(BUILD_DIR)/tb.out

.PHONY: all run sim compile stress vcd gtkwave lint clean

all: run

compile: $(OUT)

run sim: compile
	vvp $(OUT)

stress: compile
	vvp $(OUT) +stress

vcd: compile
	vvp $(OUT) +vcd

gtkwave: vcd
	gtkwave $(VCD)

$(OUT): $(SOURCES) | $(BUILD_DIR)
	iverilog -g2005-sv -I$(SRC_DIR) -o $@ $(SOURCES)

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

lint:
	cd ../.. && verilator -Isrc --lint-only -Wall -top-module chi_to_ucie_bridge \
		src/async_fifo.v src/cdc_sync.v src/reset_sync.v src/reset_drain.v \
		src/credit_counter.v src/credit_pulse_sync.v src/chi_to_ucie_bridge.v \
		-Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-fatal

clean:
	rm -rf $(BUILD_DIR)
