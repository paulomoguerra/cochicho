#!/usr/bin/env bash
# Setup Linux: grupo `input` (hotkey evdev) + udev `/dev/uinput` (colar texto).
# Rode uma vez por máquina. Depois: saia e entre de novo na sessão gráfica.
set -euo pipefail

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "Este script é só para Linux." >&2
  exit 1
fi

USER_NAME="${SUDO_USER:-$USER}"
if [[ "$USER_NAME" == "root" ]]; then
  echo "Rode como o usuário do desktop (não root puro), ou: sudo -u SEU_USER $0" >&2
  exit 1
fi

echo "→ grupo input (+ $USER_NAME)"
sudo groupadd -f input
sudo usermod -aG input "$USER_NAME"

RULE=/etc/udev/rules.d/99-ekonami-uinput.rules
echo "→ udev $RULE"
echo 'KERNEL=="uinput", MODE="0660", GROUP="input", OPTIONS+="static_node=uinput"' | sudo tee "$RULE" >/dev/null

sudo modprobe uinput
sudo udevadm control --reload-rules
sudo udevadm trigger
# aplica já nesta boot (a regra cobre os próximos boots)
if [[ -e /dev/uinput ]]; then
  sudo chgrp input /dev/uinput
  sudo chmod 660 /dev/uinput
fi

echo
echo "OK. /dev/uinput:"
ls -l /dev/uinput
echo "grupo input: $(getent group input)"
echo
echo "Agora saia da sessão gráfica e entre de novo (ou reinicie)."
echo "Sem o relogin, o hotkey global ainda não enxerga o grupo input."
