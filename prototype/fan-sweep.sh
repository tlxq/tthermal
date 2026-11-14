#!/bin/bash
# Measure rpm for every ThinkPad fan level (needs thinkpad_acpi fan_control=1).
# Pauses tthermal, holds each level 15 s, then hands the fan back to the
# firmware and restarts tthermal. Listen as it goes to judge the noise.
# Usage: sudo ./fan-sweep.sh
set -uo pipefail
[[ $EUID -eq 0 ]] || { echo "run with sudo" >&2; exit 1; }
fan=/proc/acpi/ibm/fan
[[ $(</sys/module/thinkpad_acpi/parameters/fan_control) == Y ]] || { echo "fan control not enabled (reboot after install.sh)" >&2; exit 1; }

restore() { echo "level auto" >"$fan"; systemctl start tthermal; echo "fan back on auto, tthermal running"; }
trap restore EXIT
systemctl stop tthermal
echo "watchdog 60" >"$fan"

printf '%-6s %s\n' level rpm
for level in 0 1 2 3 4 5 6 7; do
  echo "level $level" >"$fan"
  sleep 12
  rpm=0
  for _ in 1 2 3; do rpm=$(( rpm + $(awk '/^speed:/{print $2}' "$fan") )); sleep 1; done
  printf '%-6s %d   (%d °C)\n' "$level" $(( rpm / 3 )) $(( $(</sys/class/thermal/thermal_zone6/temp) / 1000 ))
done
