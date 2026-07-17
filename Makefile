# Project 2 — PCIe Gen5 / CXL Type-3 Memory-Expansion Validation Platform
# FREE lane only in aggregate targets. `make all-free` requires no commercial
# licence and no connected board. Vivado/XSim and formal are opt-in extras.

SHELL := /bin/bash

.PHONY: help inventory vectors lint regression mutation xsim formal reports evidence all-free clean

help:
	@echo "FREE lane:"
	@echo "  make inventory   - regenerate tool/host inventory evidence"
	@echo "  make vectors     - regenerate differential vectors from the Python model"
	@echo "  make lint        - Verilator -Wall lint of project-owned RTL"
	@echo "  make regression  - lint + decoder/config/tracker sweeps (Icarus+Verilator)"
	@echo "  make mutation    - prove each protection is observable (mutation testing)"
	@echo "  make all-free    - inventory + regression + mutation (no licence / no board)"
	@echo "Opt-in extras:"
	@echo "  make xsim        - AMD XSim tri-engine cross-check (reduced golden set)"
	@echo "  make formal      - SymbiYosys bmc+induction+cover, all 3 blocks (rootless OSS CAD Suite)"
	@echo "  make evidence    - versioned JSON summaries + SHA-256 source manifest"

inventory:
	@bash scripts/inventory_tools.sh >/dev/null && echo "wrote evidence/environment_inventory.json"

vectors:
	@cd tb/models && python3 gen_vectors.py

lint:
	@verilator --lint-only -Wall -Wno-DECLFILENAME -Wno-UNUSEDPARAM \
	  -Irtl/interfaces -Irtl/core -Irtl/csr \
	  rtl/interfaces/cxl_types_pkg.sv rtl/csr/hdm_config.sv rtl/core/hdm_decoder.sv \
	  rtl/core/dpa_translator.sv rtl/core/hdm_decode_top.sv --top-module hdm_decode_top \
	  2>&1 | tee evidence/raw/lint_core.log; test $${PIPESTATUS[0]} -eq 0 && echo "lint clean"

regression:
	@bash scripts/run_hdm_regression.sh
	@bash scripts/run_tracker_sweep.sh

mutation:
	@bash scripts/run_mutation_tests.sh

xsim:
	@bash scripts/run_xsim_crosscheck.sh

formal:
	@bash scripts/run_formal.sh

reports evidence:
	@bash scripts/run_hdm_regression.sh >/dev/null 2>&1 || true
	@bash scripts/run_mutation_tests.sh 2>&1 | tee evidence/raw/sim_mutation.log >/dev/null || true
	@bash scripts/run_formal.sh >/dev/null 2>&1 || true
	@bash scripts/gen_evidence.sh
	@bash scripts/make_manifest.sh

all-free: inventory regression mutation
	@echo "==== all-free complete (FREE lane, no licence / no board) ===="

clean:
	rm -rf sim/icarus/*.vvp sim/verilator/obj_* sim/xsim/xsim.dir sim/xsim/*.log sim/xsim/*_snap*
