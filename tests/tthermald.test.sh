#!/bin/bash
# Runs helper/tthermald against fake sysfs files (no root, no real limits):
# calm at 45 °C, then 95 °C must be caught on the next tick and the fan must
# go up. Run by scripts/check.sh.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
d=$(mktemp -d)
pid=""
cleanup() { [[ -n $pid ]] && kill "$pid" 2>/dev/null; wait 2>/dev/null; rm -rf "$d"; }
trap cleanup EXIT
mkdir -p "$d/mmio" "$d/run" "$d/lib"
echo 15000000 >"$d/mmio/constraint_0_power_limit_uw"
echo 51000000 >"$d/mmio/constraint_1_power_limit_uw"
echo 45000 >"$d/temp"
printf 'speed:\t\t2550\nlevel:\t\t1\n' >"$d/fan"
echo Y >"$d/fan_param"
printf 'enabled=1\nmax=90\nfan_cap=7\nburst=1\nheartbeat=%s\n' "$EPOCHSECONDS" >"$d/lib/control"
sed -e "s|^conf=.*|conf=$d/none|" -e "s|^control=.*|control=$d/lib/control|" -e "s|^run_dir=.*|run_dir=$d/run|" \
  -e "s|^mmio=.*|mmio=$d/mmio|" -e "/^pkg=\"\"$/,/no x86_pkg_temp sensor/c pkg=$d/temp" \
  -e "s|^fan_file=/proc/acpi/ibm/fan|fan_file=$d/fan|" -e "s|^fan_param=.*|fan_param=$d/fan_param|" \
  "$here/helper/tthermald" >"$d/h"
bash "$d/h" >"$d/log" 2>&1 &
pid=$!

fail() { echo "FAIL: $*"; sed 's/^/  log: /' "$d/log"; exit 1; }
wait_for() { # wait_for <seconds> <grep pattern> <file>
  local i
  for ((i = 0; i < $1 * 10; i++)); do grep -q "$2" "$3" 2>/dev/null && return 0; sleep 0.1; done
  return 1
}

wait_for 3 '^state=guarding' "$d/run/status" || fail "no guarding status at 45 °C"
sleep 2.2 # a few calm ticks
grep -q '^temp=45$' "$d/run/status" || fail "status temp is not 45"
[[ $(<"$d/mmio/constraint_0_power_limit_uw") == 15000000 ]] || fail "PL1 moved while calm"

echo 95000 >"$d/temp"
t0=$EPOCHREALTIME
wait_for 2 '^holding: 95' "$d/log" || fail "95 °C not caught within 2 s"
ms=$(( (${EPOCHREALTIME/./} - ${t0/./}) / 1000 ))
(( ms <= 1000 )) || fail "95 °C caught after $ms ms, want one tick (500 ms)"
pl2=$(<"$d/mmio/constraint_1_power_limit_uw")
(( pl2 <= 15000000 )) || fail "burst limit $pl2 still above PL1 at 95 °C"
wait_for 6 'level [2-7]' "$d/fan" || fail "fan did not go up at 95 °C"
echo "tthermald: calm at 45 °C, 95 °C caught in $ms ms, fan up: ok"
