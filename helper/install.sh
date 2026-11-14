#!/bin/bash
# Install the tthermal root helper. Run with sudo (terminal) or pkexec (panel button).
set -euo pipefail

fail() { echo "tthermal install: $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || fail "run with sudo"

user=${SUDO_USER:-}
[[ -z $user && -n ${PKEXEC_UID:-} ]] && user=$(id -nu "$PKEXEC_UID")
[[ -n $user && $user != root ]] || fail "could not tell which user to install for"

[[ -d /sys/class/powercap/intel-rapl-mmio:0 ]] || fail "needs an Intel CPU with RAPL MMIO power limits"
grep -qx x86_pkg_temp /sys/class/thermal/thermal_zone*/type || fail "no x86_pkg_temp sensor"

here=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)

install -Dm755 "$here/tthermald" /usr/local/lib/tthermal/tthermald
install -Dm644 "$here/tthermal.service" /etc/systemd/system/tthermal.service
[[ -e /etc/tthermal.conf ]] || install -Dm644 "$here/tthermal.conf" /etc/tthermal.conf
install -d -m755 -o "$user" -g "$(id -gn "$user")" /var/lib/tthermal

# ThinkPad fan control: the driver only accepts fan commands with
# fan_control=1, which takes effect at the next boot.
# thinkpad_acpi usually loads from the initramfs, so the option only reaches it
# after the initramfs is rebuilt.
reboot_note=""
if [[ -e /proc/acpi/ibm/fan ]]; then
  modprobe_conf=/etc/modprobe.d/tthermal.conf
  option="options thinkpad_acpi fan_control=1"
  if [[ $(cat "$modprobe_conf" 2>/dev/null) != "$option" ]]; then
    echo "$option" >"$modprobe_conf"
    echo "rebuilding initramfs for fan control…"
    if command -v limine-mkinitcpio >/dev/null; then
      limine-mkinitcpio >/dev/null
    else
      mkinitcpio -P >/dev/null
    fi
  fi
  [[ $(</sys/module/thinkpad_acpi/parameters/fan_control) == Y ]] || reboot_note=" — reboot once to enable fan control"
fi

systemctl daemon-reload
systemctl enable tthermal.service >/dev/null
systemctl restart tthermal.service
echo "tthermal helper installed for $user$reboot_note"
