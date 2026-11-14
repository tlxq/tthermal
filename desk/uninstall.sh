#!/bin/bash
# Removes the desk widget and service. The fans stay on CoolerControl's Auto curves.
set -uo pipefail
OMARCHY_SHELL_IPC_TIMEOUT=10s omarchy plugin disable com.ttdevs.tthermal || true
systemctl --user disable --now tthermal-desk.service || true
rm -f "$HOME/.config/systemd/user/tthermal-desk.service" "$HOME/.config/omarchy/plugins/com.ttdevs.tthermal"
systemctl --user daemon-reload
echo "tthermal desk removed. Fans stay on CoolerControl's Auto curves."
