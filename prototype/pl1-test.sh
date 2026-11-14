#!/bin/bash
# Sustained test: does a higher sustained limit (PL1) buy real speed on a long
# all-core load, and how hot does it run? Run as root with the lid open;
# tthermal is paused for the test and started again at the end.
#
#   sudo prototype/pl1-test.sh [watts...]     default: 15 20 25
#
# Each level: cool to 50 °C, then 120 s of sha256 on every core.
# Writes prototype/pl1-<date>.csv, one row per second:
#   pl1_w,second,temp_c,pkg_w,mhz,fan_rpm,pl1_read_w
# and prints a summary per level (MB/s hashed, average watts, temps).
set -uo pipefail
(( EUID == 0 )) || { echo "run with sudo" >&2; exit 1; }

levels=("${@:-15 20 25}")
read -ra levels <<<"${levels[*]}"
seconds=120
abort_c=97
mmio=/sys/class/powercap/intel-rapl-mmio:0
pl1_file=$mmio/constraint_0_power_limit_uw
pl2_file=$mmio/constraint_1_power_limit_uw
energy=/sys/class/powercap/intel-rapl:0/energy_uj
pkg=""
for z in /sys/class/thermal/thermal_zone*; do
  [[ $(<"$z/type") == x86_pkg_temp ]] && pkg=$z/temp && break
done
fan_rpm() { awk '/^speed:/ { print $2 }' /proc/acpi/ibm/fan 2>/dev/null; }
avg_mhz() { awk '/^cpu MHz/ { s += $4; n++ } END { printf "%d", s / n }' /proc/cpuinfo; }

dir=$(dirname "$0")
out=$dir/pl1-$(date +%F-%H%M).csv
work=$(mktemp -d)
was_active=0
systemctl is-active -q tthermal && was_active=1

restore() {
  pkill -P $$ 2>/dev/null
  [[ -n ${factory_pl1:-} ]] && echo "$factory_pl1" >"$pl1_file"
  [[ -n ${factory_pl2:-} ]] && echo "$factory_pl2" >"$pl2_file"
  rm -rf "$work"
  (( was_active )) && systemctl start tthermal
  echo "tthermal back on, limits restored. Results: $out"
}

lid=$(awk '{ print $2 }' /proc/acpi/button/lid/*/state 2>/dev/null)
[[ $lid == closed ]] && echo "note: lid is closed, firmware may hold PL1 lower (seen 12 W)"

(( was_active )) && systemctl stop tthermal
factory_pl1=$(<"$pl1_file")
factory_pl2=$(<"$pl2_file")
trap 'restore; exit 1' INT TERM
echo 29000000 >"$pl2_file"

cool_down() {
  local i
  for (( i = 0; i < 240; i++ )); do
    (( $(<"$pkg") <= 50000 )) && return
    sleep 0.5
  done
}

# One worker per core, each logs a line per 64 MB hashed.
cores=$(nproc)
worker() {
  while :; do
    head -c 64M /dev/zero | sha256sum >/dev/null && echo >>"$work/$1"
  done
}

echo "pl1_w,second,temp_c,pkg_w,mhz,fan_rpm,pl1_read_w" >"$out"
for w in "${levels[@]}"; do
  echo "== PL1 $w W: cooling down"
  cool_down
  echo $(( w * 1000000 )) >"$pl1_file"
  rm -f "$work"/*
  for (( i = 0; i < cores; i++ )); do worker "$i" & done
  e0=$(<"$energy")
  for (( s = 1; s <= seconds; s++ )); do
    sleep 1
    e1=$(<"$energy")
    t=$(( $(<"$pkg") / 1000 ))
    pw=$(awk -v d=$(( e1 - e0 )) 'BEGIN { printf "%.1f", d / 1e6 }')
    (( e1 >= e0 )) || pw=""
    e0=$e1
    echo "$w,$s,$t,$pw,$(avg_mhz),$(fan_rpm),$(( $(<"$pl1_file") / 1000000 ))" >>"$out"
    (( s % 10 == 0 )) && printf '   %3d s  %d °C  %s W\n' "$s" "$t" "$pw"
    (( t >= abort_c )) && { echo "   stopped: $t °C"; break; }
  done
  (( s > seconds )) && s=$seconds
  for j in $(jobs -p); do kill "$j" 2>/dev/null; done
  wait 2>/dev/null
  chunks=$(cat "$work"/* 2>/dev/null | wc -l)
  echo "$w,done,,,,,$(( chunks * 64 / s ))" >>"$out"
done

restore
trap - INT TERM
echo
echo "Per level (last 60 s of each run):"
awk -F, '
  $2 == "done" { mbs[$1] = $7; next }
  NR > 1 && $2 > 60 { t[$1] += $3; if ($3 > p[$1]) p[$1] = $3; w[$1] += $4; m[$1] += $5; f[$1] += $6; n[$1]++ }
  END { for (k in n) printf "  PL1 %2s W:  %4d MB/s  %4.1f W  %4.0f MHz  avg %4.1f °C  peak %d °C  fan %4.0f rpm\n",
          k, mbs[k], w[k] / n[k], m[k] / n[k], t[k] / n[k], p[k], f[k] / n[k] }' "$out" | sort -k2,2n
