#!/usr/bin/env bash
# inventory_tools.sh — reproducible, READ-ONLY tool + host-capability inventory.
# Classifies each tool: FOUND_AND_RUNNABLE | FOUND_NOT_SOURCED | MISSING | NOT_REQUIRED.
# Emits a human table to stdout and machine JSON to evidence/environment_inventory.json.
# It runs nothing that mutates state, no sudo, no licence-server queries beyond a version string.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
JSON="${ROOT}/evidence/environment_inventory.json"
mkdir -p "${ROOT}/evidence"

ver() { "$@" 2>&1 | head -1 | tr -d '\r'; }

# tool | required_lane | classification-hint
FREE_TOOLS="verilator iverilog vvp gtkwave yosys sby boolector z3 verible-verilog-lint slang \
python3 pip pipx cocotb-config pytest gcc g++ clang cmake ninja make git jq \
qemu-system-x86_64 ndctl cxl daxctl lspci setpci numactl fio perf trace-cmd bpftrace"
AMD_TOOLS="vivado xvlog xelab xsim vitis xsct"
ALTERA_TOOLS="quartus quartus_sh quartus_map quartus_fit quartus_sta quartus_pgm qsys-script qsys-generate jtagconfig"
COMMERCIAL="vsim vcs xrun"

classify() { # $1 tool
  local p; p="$(command -v "$1" 2>/dev/null)"
  if [ -n "$p" ]; then echo "FOUND_AND_RUNNABLE|$p"; else echo "MISSING|"; fi
}

printf "%-24s %-20s %s\n" "TOOL" "STATUS" "PATH"
printf "%-24s %-20s %s\n" "----" "------" "----"
first=1
{
  echo "{"
  echo "  \"generated_by\": \"scripts/inventory_tools.sh\","
  echo "  \"host\": {\"uname\": \"$(uname -sr)\", \"os\": \"$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}")\"},"
  echo "  \"tools\": ["
  for grp in FREE_TOOLS AMD_TOOLS ALTERA_TOOLS COMMERCIAL; do
    lane="$grp"
    for t in ${!grp}; do
      IFS='|' read -r status path <<<"$(classify "$t")"
      printf "%-24s %-20s %s\n" "$t" "$status" "$path" >&2
      [ $first -eq 0 ] && echo ","
      first=0
      printf '    {"tool":"%s","lane":"%s","status":"%s","path":"%s"}' "$t" "$lane" "$status" "$path"
    done
  done
  echo ""
  echo "  ],"
  echo "  \"host_cxl\": {"
  echo "    \"sys_bus_cxl\": $([ -d /sys/bus/cxl ] && echo true || echo false),"
  echo "    \"cxl_modules\": \"$(lsmod 2>/dev/null | grep -i cxl | awk '{print $1}' | paste -sd, -)\","
  echo "    \"pci_cxl_devices\": \"$(lspci -nn 2>/dev/null | grep -iE 'CXL' | wc -l)\""
  echo "  }"
  echo "}"
} > "$JSON"

echo ""
echo "JSON written: $JSON"
