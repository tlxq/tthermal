#!/bin/bash
# Runs desk/bin/tthermal-desk against fake sensors, nvidia-smi and CoolerControl (curl stub):
# `gaming` holds the gaming curves with the GPU idle until `auto`, a hold survives a restart,
# and the commands exit 1 when the service isn't running. Run by scripts/check.sh.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
d=$(mktemp -d)
pid=""
cleanup() { [[ -n $pid ]] && kill "$pid" 2>/dev/null; wait 2>/dev/null; rm -rf "$d"; }
trap cleanup EXIT
mkdir -p "$d/it" "$d/zen" "$d/run" "$d/bin"
echo 45000 >"$d/zen/temp1_input"
echo 1 >"$d/it/pwm1_enable"
for f in fan1 fan2 fan3 fan5; do echo 900 >"$d/it/${f}_input"; done
echo token >"$d/token"
# GPU idle: never busy enough to turn gaming on by itself
printf '#!/bin/bash\necho "40, 3, 30"\n' >"$d/bin/nvidia-smi"
# CoolerControl: the device list, and every profile PUT logged as "<channel> <profile>"
cat >"$d/bin/curl" <<STUB
#!/bin/bash
for a; do case \$a in */profile) ch=\${a%/profile}; ch=\${ch##*/settings/} ;; '{"profile_uid"'*) p=\${a#*:\"}; p=\${p%\"\}} ;; esac; done
if [[ -n \${ch:-} ]]; then echo "\$ch \$p" >>"$d/puts"; else echo '{"devices":[{"name":"it8688","uid":"u1"}]}'; fi
STUB
printf '#!/bin/bash\nexit 0\n' >"$d/bin/notify-send"
chmod +x "$d"/bin/*
export PATH="$d/bin:$PATH" XDG_RUNTIME_DIR="$d/xdg"
sed -e "s|^token_file=.*|token_file=$d/token|" -e "s|^interval_s=.*|interval_s=0.2|" \
  -e "s|^week_bin=.*|week_bin=/bin/false|" -e "s|^it=\$(hwmon_dir it8688)|it=$d/it|" \
  -e "s|^zen=\$(hwmon_dir zenpower)|zen=$d/zen|" "$here/desk/bin/tthermal-desk" >"$d/t"
cli() { bash "$d/t" "$@"; }
st() { sed -n "s/^$1=//p" "$d/xdg/tthermal/status" 2>/dev/null; }

fail() { echo "FAIL: $*"; sed 's/^/  log: /' "$d/log"; sed 's/^/  put: /' "$d/puts" 2>/dev/null; exit 1; }
wait_for() { # wait_for <seconds> <key> <value>
  local i
  for ((i = 0; i < $1 * 10; i++)); do [[ $(st "$2") == "$3" ]] && return 0; sleep 0.1; done
  return 1
}
start() { bash "$d/t" run >>"$d/log" 2>&1 & pid=$!; }
stop() { kill "$pid"; wait "$pid" 2>/dev/null || true; pid=""; }

cli gaming 2>/dev/null && fail "gaming said ok with no service running"
rm -f "$d/xdg/tthermal/hold"

start
wait_for 3 state auto || fail "never reached auto"
cli gaming || fail "gaming failed with the service running"
wait_for 3 state gaming || fail "gaming didn't hold"
[[ $(st held) == 1 ]] || fail "status doesn't say held"
grep -q '^fan2 tt-game-top$' "$d/puts" || fail "top fan never got tt-game-top"
sleep 1
[[ $(st state) == gaming ]] || fail "an idle GPU dropped the hold"

stop
start
wait_for 3 state gaming || fail "the hold didn't survive a restart"

cli auto || fail "auto failed"
wait_for 3 state auto || fail "auto didn't end the hold"
[[ $(st held) == 0 ]] || fail "status still says held"
[[ $(tail -n 1 "$d/puts") == "fan3 tt-intake" ]] || fail "auto curves not put back"
stop
grep -q 'stopped, auto curves back' "$d/log" || fail "no auto on stop"
echo "tthermal-desk: ok (hold, restart, auto)"
