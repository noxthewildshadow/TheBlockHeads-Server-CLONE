#!/usr/bin/env bash
set -euo pipefail

SCREEN_SERVER="blockheads_server"
SCREEN_BOT="blockheads_bot"
SERVICE_USER="blockheads"

echo "Deteniendo Blockheads server (screen sessions) de forma segura..."

if screen -list | grep -q "$SCREEN_BOT"; then
  screen -S "$SCREEN_BOT" -X quit || true
  echo "Bot screen detenido."
fi
if screen -list | grep -q "$SCREEN_SERVER"; then
  screen -S "$SCREEN_SERVER" -X quit || true
  echo "Server screen detenido."
fi

# pkill solo procesos ejecutados por el usuario blockheads que coincidan con binary
pkill -u "$SERVICE_USER" -f "blockheads_server171" || true

echo "Limpieza completada."
