#!/bin/bash
# Remove the tthermal root helper. Factory power limits are restored when it stops.
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "tthermal uninstall: run with sudo" >&2; exit 1; }

systemctl disable --now tthermal.service 2>/dev/null || true
rm -f /etc/systemd/system/tthermal.service /usr/local/lib/tthermal/tthermald /etc/tthermal.conf /etc/modprobe.d/tthermal.conf
rmdir /usr/local/lib/tthermal 2>/dev/null || true
rm -rf /var/lib/tthermal /run/tthermal
systemctl daemon-reload
if command -v limine-mkinitcpio >/dev/null; then limine-mkinitcpio >/dev/null; else mkinitcpio -P >/dev/null; fi
echo "tthermal helper removed (fan control off after the next reboot)"
