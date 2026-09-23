# Makefile for UVM Testbench (placeholder for Xcelium/commercial simulator)

UVM_HOME ?= $(shell ncroot)/tools/uvm
INCDIRS  += +incdir+../../src
INCDIRS  += +incdir+.

# Source files
PKGS     = chi_ucie_uvm_pkg.sv
IFS      = chi_if.sv ucie_if.sv
TOP      = tb_top.sv

# Compilation & Simulation targets (placeholder for commercial tool)
# Example for Xcelium (read_write_test is the default random test; see
# verification/uvm/vlt/Makefile's UVM_TEST for the open-source Verilator flow):
# xrun -64bit -uvm -sv +incdir+../../src +incdir+. $(PKGS) $(IFS) $(TOP) +UVM_TESTNAME=read_write_test

clean:
	rm -rf xcelium.d xrun.log xrun.history
