#!/bin/bash
# tthermal guard prototype: keep the CPU package under a max temperature by steering
# the Intel RAPL power limits (MMIO domain).
#
#   burst limit (PL2)     feed-forward from headroom: cool CPU = full burst,
#                         close to max = no burst. Recomputed every 0.5 s.
#   sustained limit (PL1) slow integrator that settles long loads just under max.
#
# Never raises a limit above the factory value. Factory limits are restored on
# exit (also Ctrl+C); a reboot restores them as well.
#
# Usage: sudo ./guard.sh <max-temp-C>          guard until Ctrl+C
#        sudo ./guard.sh <max-temp-C> --test   cool down, 90 s full load, 40 s idle, summary
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "run with sudo" >&2; exit 1; }
max_c=${1:?usage: guard.sh <max-temp-C> [--test]}
[[ $max_c =~ ^[0-9]+$ ]] && (( max_c >= 65 && max_c <= 95 )) || { echo "max temp must be 65-95" >&2; exit 1; }
test_mode=${2:-}

mmio=/sys/class/powercap/intel-rapl-mmio:0
pl1_file=$mmio/constraint_0_power_limit_uw
pl2_file=$mmio/constraint_1_power_limit_uw

pkg=""
for z in /sys/class/thermal/thermal_zone*; do
  [[ $(<"$z/type") == x86_pkg_temp ]] && pkg=$z/temp && break
done
[[ -n $pkg ]] || { echo "no x86_pkg_temp sensor" >&2; exit 1; }

factory_pl1=$(( $(<"$pl1_file") / 1000 ))
factory_pl2=$(( $(<"$pl2_file") / 1000 ))
floor_mw=6000
burst_from_mc=5000
burst_full_mc=30000
target_mc=$(( (max_c - 2) * 1000 ))
max_mc=$(( max_c * 1000 ))

pl1=$factory_pl1
pl2=$factory_pl2
written_pl1=0
written_pl2=0
pids=()
here=$(cd "$(dirname "$0")" && pwd)
log=$here/guard-$(date +%F-%H%M).csv

restore() {
  for p in "${pids[@]}"; do kill "$p" 2>/dev/null || true; done
  echo $(( factory_pl1 * 1000 )) >"$pl1_file"
  echo $(( factory_pl2 * 1000 )) >"$pl2_file"
  [[ -n ${SUDO_USER:-} && -f $log ]] && chown "$SUDO_USER:" "$log"
  echo "restored factory limits: PL1 $((factory_pl1 / 1000)) W, PL2 $((factory_pl2 / 1000)) W"
}
trap restore EXIT
trap 'exit 130' INT TERM

clamp() { local v=$1 lo=$2 hi=$3; (( v < lo )) && v=$lo; (( v > hi )) && v=$hi; echo "$v"; }

write_limits() {
  if (( pl1 - written_pl1 > 250 || written_pl1 - pl1 > 250 )); then
    echo $(( pl1 * 1000 )) >"$pl1_file"; written_pl1=$pl1
  fi
  if (( pl2 - written_pl2 > 250 || written_pl2 - pl2 > 250 )); then
    echo $(( pl2 * 1000 )) >"$pl2_file"; written_pl2=$pl2
  fi
}

# One control step (called every 0.5 s). Sets global t_mc, pl1, pl2.
step() {
  t_mc=$(<"$pkg")
  # Sustained: 0.3 W per second per °C away from target.
  pl1=$(( pl1 + (target_mc - t_mc) * 150 / 1000 ))
  (( t_mc >= max_mc )) && pl1=$(( pl1 - 1000 ))
  pl1=$(clamp "$pl1" "$floor_mw" "$factory_pl1")
  # Burst: linear from PL1 (headroom <= 5 °C) to factory PL2 (headroom >= 30 °C).
  local h=$(( max_mc - t_mc ))
  if (( h <= burst_from_mc )); then
    pl2=$pl1
  else
    pl2=$(( pl1 + (h - burst_from_mc) * (factory_pl2 - pl1) / (burst_full_mc - burst_from_mc) ))
  fi
  pl2=$(clamp "$pl2" "$pl1" "$factory_pl2")
  write_limits
}

sample() {
  local phase=$1 sec=$2 mhz
  mhz=$(awk '/MHz/{s+=$4;n++} END{printf "%d", s/n}' /proc/cpuinfo)
  echo "$phase,$sec,$((t_mc / 1000)),$mhz,$((pl1 / 1000)).$(( (pl1 % 1000) / 100 )),$((pl2 / 1000)).$(( (pl2 % 1000) / 100 ))" >>"$log"
}

echo "phase,sec,temp_c,avg_mhz,pl1_w,pl2_w" >"$log"
echo "guarding at max ${max_c} °C (factory PL1 $((factory_pl1 / 1000)) W / PL2 $((factory_pl2 / 1000)) W) — log: $log"

if [[ $test_mode != --test ]]; then
  i=0
  while :; do
    step
    (( i % 2 == 0 )) && sample run $(( i / 2 ))
    (( i % 10 == 0 )) && printf '\r%3d °C  PL1 %2d.%d W  PL2 %2d.%d W ' $((t_mc / 1000)) $((pl1 / 1000)) $(( (pl1 % 1000) / 100 )) $((pl2 / 1000)) $(( (pl2 % 1000) / 100 ))
    i=$(( i + 1 ))
    sleep 0.5
  done
fi

pp=(net.hadess.PowerProfiles /net/hadess/PowerProfiles net.hadess.PowerProfiles)
orig_profile=$(busctl get-property "${pp[@]}" ActiveProfile | awk '{gsub(/"/,"",$2); print $2}')
trap 'busctl set-property "${pp[@]}" ActiveProfile s "$orig_profile" || true; echo "restored profile: $orig_profile"; restore' EXIT
busctl set-property "${pp[@]}" ActiveProfile s balanced
echo "profile: balanced (was $orig_profile)"

echo "cooling down to <55 °C (now $(( $(<"$pkg") / 1000 )) °C, up to 180 s)"
for _ in $(seq 360); do step; (( t_mc < 55000 )) && break; sleep 0.5; done
start_c=$(( t_mc / 1000 ))

echo "full load 90 s (start $start_c °C)"
for _ in $(seq "$(nproc)"); do ( while :; do :; done ) & pids+=($!); done
for i in $(seq 180); do step; (( i % 2 == 0 )) && sample load $(( i / 2 )); sleep 0.5; done
for p in "${pids[@]}"; do kill "$p" 2>/dev/null || true; done
pids=()

echo "idle 40 s"
for i in $(seq 80); do step; (( i % 2 == 0 )) && sample idle $(( i / 2 )); sleep 0.5; done

echo
awk -F, -v max="$max_c" -v start="$start_c" 'NR>1 && $1=="load" {
  if ($3>peak) peak=$3
  if ($3>max) over++
  if ($2<=10) { bm+=$4; bn++ }
  if ($2>70) { st+=$3; sm+=$4; sp+=$5; sn++ }
} END {
  printf "max %d °C · start %d °C\n", max, start
  printf "peak under load      %d °C\n", peak
  printf "seconds above max    %d\n", over+0
  printf "burst speed 0-10 s   %d MHz\n", bm/bn
  printf "settled (70-90 s)    %.1f °C @ %d MHz, PL1 %.1f W\n", st/sn, sm/sn, sp/sn
}' "$log"
echo "csv: $log"
