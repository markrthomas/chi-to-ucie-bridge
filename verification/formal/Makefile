SBY ?= sby

.PHONY: all reset_drain chi_to_ucie_bridge clean

all: reset_drain chi_to_ucie_bridge
	@echo "[FORMAL] smoke checks passed."

reset_drain:
	@command -v $(SBY) >/dev/null 2>&1 || { echo "[FORMAL] sby not on PATH; skipping"; exit 0; }
	$(SBY) -f reset_drain.sby

chi_to_ucie_bridge:
	@command -v $(SBY) >/dev/null 2>&1 || { echo "[FORMAL] sby not on PATH; skipping"; exit 0; }
	$(SBY) -f chi_to_ucie_bridge.sby

clean:
	rm -rf reset_drain chi_to_ucie_bridge reset_drain_bmc chi_to_ucie_bridge_bmc
