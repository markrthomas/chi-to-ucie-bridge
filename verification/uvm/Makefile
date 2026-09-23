# Makefile for UVM Testbench (placeholder for Xcelium/commercial simulator)

UVM_HOME ?= $(shell ncroot)/tools/uvm
INCDIRS  += +incdir+../../src
INCDIRS  += +incdir+.

# Source files
PKGS     = chi_ucie_uvm_pkg.sv
IFS      = chi_if.sv ucie_if.sv
TOP      = tb_top.sv

# Compilation & Simulation targets (placeholder for commercial tool)
# Example for Xcelium:
# xrun -64bit -uvm -sv +incdir+../../src +incdir+. $(PKGS) $(IFS) $(TOP) +UVM_TESTNAME=base_test

clean:
	rm -rf xcelium.d xrun.log xrun.history
