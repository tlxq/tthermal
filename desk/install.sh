#!/bin/bash
# Desk install (no sudo): links this folder as the tthermal plugin, starts the desk service and
# puts the widget in the bar. Needs CoolerControl set up first, with your own fan profiles
# (README.md, Desk version).
# Undo: ./uninstall.sh
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
plugins=$HOME/.config/omarchy/plugins

[[ -r $HOME/.config/ttdevs/coolercontrol.token ]] || { echo "No CoolerControl token yet: make one with write access in CoolerControl and save it to ~/.config/ttdevs/coolercontrol.token." >&2; exit 1; }

ln -sfn "$here" "$plugins/com.ttdevs.tthermal"
mkdir -p "$HOME/.config/systemd/user"
ln -sf "$here/tthermal-desk.service" "$HOME/.config/systemd/user/tthermal-desk.service"
systemctl --user daemon-reload
systemctl --user enable --now tthermal-desk.service
omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
OMARCHY_SHELL_IPC_TIMEOUT=10s omarchy plugin enable com.ttdevs.tthermal
echo "tthermal desk installed: the temperature is in the bar, click it for the fans."
