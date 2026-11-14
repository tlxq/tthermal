#!/bin/bash
# Burst test: how hot does a short all-core task get, and how long does it
# take, at different burst limits (PL2)? Run as root; tthermal is paused for the
# test and started again at the end.
#
#   sudo prototype/burst-test.sh [watts...]     default: 29 24 20 17
#
# Writes prototype/burst-<date>.csv: pl2_w,task,round,start_c,peak_c,seconds
set -uo pipefail
(( EUID == 0 )) || { echo "run with sudo" >&2; exit 1; }

levels=("${@:-29 24 20 17}")
read -ra levels <<<"${levels[*]}"
mmio=/sys/class/powercap/intel-rapl-mmio:0
pl1_file=$mmio/constraint_0_power_limit_uw
pl2_file=$mmio/constraint_1_power_limit_uw
pkg=""
for z in /sys/class/thermal/thermal_zone*; do
  [[ $(<"$z/type") == x86_pkg_temp ]] && pkg=$z/temp && break
done
out=$(dirname "$0")/burst-$(date +%F-%H%M).csv
was_active=0
systemctl is-active -q tthermal && was_active=1

restore() {
  echo "$factory_pl2" >"$pl2_file"
  echo "$factory_pl1" >"$pl1_file"
  (( was_active )) && systemctl start tthermal
  echo "tthermal back on, limits restored. Results: $out"
}

(( was_active )) && systemctl stop tthermal
factory_pl1=$(<"$pl1_file")
factory_pl2=$(<"$pl2_file")
trap 'restore; exit 1' INT TERM
echo 15000000 >"$pl1_file"

cool_down() {
  local i
  for (( i = 0; i < 120; i++ )); do
    (( $(<"$pkg") <= 50000 )) && return
    sleep 0.5
  done
}

# Runs "$@" while sampling the package temperature every 20 ms.
# Sets peak_c and secs.
measure() {
  local peak=0 t start end pid
  start=$(date +%s%N)
  "$@" &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    t=$(<"$pkg")
    (( t > peak )) && peak=$t
    sleep 0.02
  done
  end=$(date +%s%N)
  peak_c=$(( peak / 1000 ))
  secs=$(printf '%d.%03d' $(( (end - start) / 1000000000 )) $(( (end - start) / 1000000 % 1000 )))
}

# One copy per core: the logged spikes come from all cores boosting at once.
cores=$(nproc)
on_all_cores() {
  local i
  for (( i = 0; i < cores; i++ )); do
    head -c "$1" /dev/zero | sha256sum >/dev/null &
  done
  wait
}
short_task() { on_all_cores 150M; }
long_task() { on_all_cores 1200M; }

echo "pl2_w,task,round,start_c,peak_c,seconds" >"$out"
for round in 1 2 3; do
  for w in "${levels[@]}"; do
    echo $(( w * 1000000 )) >"$pl2_file"
    for task in short_task long_task; do
      cool_down
      start_c=$(( $(<"$pkg") / 1000 ))
      measure "$task"
      echo "$w,${task%_task},$round,$start_c,$peak_c,$secs" | tee -a "$out"
    done
  done
done

restore
echo
echo "Average per level (peak °C / seconds):"
awk -F, 'NR > 1 { k = $1 " W " $2; p[k] += $5; s[k] += $6; n[k]++ }
  END { for (k in p) printf "  %-12s %5.1f °C  %6.3f s\n", k, p[k] / n[k], s[k] / n[k] }' "$out" | sort -t' ' -k1,1nr -k3,3
