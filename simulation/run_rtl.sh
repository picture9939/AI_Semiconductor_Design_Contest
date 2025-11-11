#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

mkdir -p waves logs

xrun -64bit -sv -timescale 1ns/1ps \
  -f filelist.f \
  +access+rwc \
  -nowarn DLCPTH -nowarn VARIST -nowarn SVBDDT \
  -l logs/xrun_rtl.log

echo "[OK] RTL sim finished. Waves: simulation/waves/rtl.vcd"
