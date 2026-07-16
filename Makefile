# Project 2 — PCIe Gen5 / CXL Type-3 Memory-Expansion Validation Platform
# FREE lane only in aggregate targets. No commercial licence or board required.
# `make all-free` never invokes Quartus, XSim, or hardware programming.

SHELL := /bin/bash
RTL_IF   := rtl/interfaces/cxl_types_pkg.sv
RUN      := scripts/run_sv_test.sh

.PHONY: help inventory lint sim unit test-unit all-free clean

help:
	@echo "Targets:"
	@echo "  make inventory   - regenerate tool/host inventory evidence"
	@echo "  make lint        - Verilator lint on project-owned RTL"
	@echo "  make unit        - run all unit testbenches (Icarus + Verilator, both must pass)"
	@echo "  make sim         - alias for unit"
	@echo "  make all-free    - inventory + lint + unit (no licence / no board)"
	@echo "  make clean       - remove sim build artifacts"

inventory:
	@bash scripts/inventory_tools.sh >/dev/null
	@echo "wrote evidence/environment_inventory.json"

# ---- Lint (project-owned RTL only) --------------------------------------
lint:
	@echo "== Verilator lint: hdm_decoder + dpa_translator =="
	@# Narrowly justified waivers:
	@#  DECLFILENAME : package name != filename by our convention (cxl_types_pkg.sv)
	@#  UNUSEDPARAM  : shared package exports DATA_W/BE_W/LINE_BYTES consumed by
	@#                 datapath modules not present in this per-module lint unit.
	verilator --lint-only -Wall -Wno-DECLFILENAME -Wno-UNUSEDPARAM -Irtl/interfaces \
	  $(RTL_IF) rtl/core/hdm_decoder.sv rtl/core/dpa_translator.sv \
	  --top-module hdm_decoder 2>&1 | tee evidence/raw/lint_core.log; \
	  test $${PIPESTATUS[0]} -eq 0

# ---- Unit tests (each must pass on BOTH engines) ------------------------
UNIT_TESTS := hdm_decode

unit test-unit:
	@rc=0; \
	for t in $(UNIT_TESTS); do \
	  bash $(RUN) tb_$$t tb_$$t $(RTL_IF) rtl/core/hdm_decoder.sv rtl/core/dpa_translator.sv tb/sv/tb_$$t.sv || rc=1; \
	done; \
	echo "==== UNIT SUITE $$( [ $$rc -eq 0 ] && echo PASS || echo FAIL ) ===="; \
	exit $$rc

sim: unit

all-free: inventory lint unit
	@echo "==== all-free complete (FREE lane only) ===="

clean:
	rm -rf sim/icarus/*.vvp sim/verilator/obj_*
