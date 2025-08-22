#!/bin/bash
# start_server.sh - Verbose and robust starter for Blockheads server + bot
set -euo pipefail

SERVER_BINARY="./blockheads_server171"
DEFAULT_PORT=12153
SCREEN_SERVER="blockheads_server"
SCREEN_BOT="blockheads_bot"

echo "start_server.sh: inicio"

find_server_binary() {
  if [ -x "$SERVER_BINARY" ]; then
    echo "$SERVER_BINARY"
    return 0
  fi
  find . -maxdepth 3 -type f -executable -iname "*blockheads*" 2>/dev/null | head -n1 || true
}

find_world_dir() {
  local world="$1"
  local try

  try="$HOME/GNUstep/Library/ApplicationSupport/TheBlockheads/saves/$world"
  [ -d "$try" ] && { printf '%s' "$try"; return 0; }

  try="./saves/$world"
  [ -d "$try" ] && { printf '%s' "$try"; return 0; }

  try="./$world"
  [ -d "$try" ] && { printf '%s' "$try"; return 0; }

  find . -type d -name "$world" 2>/dev/null | head -n1 || true
}

is_port_in_use() {
  local port="$1"
  if command -v lsof >/dev/null 2>&1 && lsof -Pi ":$port" -sTCP:LISTEN -t >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

start_bot() {
  local log_file="$1"
  if screen -list | grep -q "$SCREEN_BOT"; then
    echo "Bot: ya en ejecución"
    return 0
  fi
  [ -x "./bot_server.sh" ] || { echo "ERROR: bot_server.sh faltante o no ejecutable"; return 1; }
  screen -dmS "$SCREEN_BOT" bash -lc "exec ./bot_server.sh '$log_file'"
  echo "Bot: arrancado (screen: $SCREEN_BOT)"
  return 0
}

start_server() {
  local world_name="$1"
  local port="${2:-$DEFAULT_PORT}"

  echo "Buscando binario del servidor..."
  SV_BIN=$(find_server_binary)
  if [ -z "$SV_BIN" ]; then
    echo "ERROR: No se encontró el binario del servidor (~./blockheads_server171)."
    return 1
  fi
  echo "Binario: $SV_BIN"

  if is_port_in_use "$port"; then
    echo "ERROR: puerto $port en uso."
    return 1
  fi

  WORLD_DIR=$(find_world_dir "$world_name")
  if [ -z "$WORLD_DIR" ]; then
    echo "ERROR: Mundo no encontrado: $world_name"
    echo "Crea el mundo manualmente con: $SV_BIN -n"
    return 1
  fi
  echo "Mundo encontrado en: $WORLD_DIR"

  LOG_DIR="$WORLD_DIR"
  LOG_FILE="$LOG_DIR/console.log"
  mkdir -p "$LOG_DIR"
  : > "$LOG_FILE"
  chmod a+w "$LOG_FILE" 2>/dev/null || true
  echo "Log file: $LOG_FILE (creado/asegurado)"

  echo "Iniciando servidor en screen ($SCREEN_SERVER)..."
  screen -dmS "$SCREEN_SERVER" bash -lc "exec \"$SV_BIN\" -o \"$world_name\" -p $port 2>&1 | tee -a \"$LOG_FILE\""
  sleep 1

  local tries=0
  while [ $tries -lt 12 ]; do
    if screen -list | grep -q "$SCREEN_SERVER"; then
      echo "Screen session activa."
      break
    fi
    sleep 1
    tries=$((tries+1))
  done
  if ! screen -list | grep -q "$SCREEN_SERVER"; then
    echo "ERROR: no se pudo crear la session screen para el servidor."
    return 1
  fi

  echo "Servidor arrancado. Iniciando bot..."
  start_bot "$LOG_FILE" || true
  echo "Proceso de inicio finalizado."
  return 0
}

stop_server() {
  echo "Deteniendo bot y servidor (si existen)..."
  screen -list | grep -q "$SCREEN_BOT" && screen -S "$SCREEN_BOT" -X quit || true
  screen -list | grep -q "$SCREEN_SERVER" && screen -S "$SCREEN_SERVER" -X quit || true
  pkill -f "$SERVER_BINARY" 2>/dev/null || true
  echo "Detención completada."
}

show_status() {
  echo "Estado:"
  screen -list | grep -q "$SCREEN_SERVER" && echo "  server: running" || echo "  server: stopped"
  screen -list | grep -q "$SCREEN_BOT" && echo "  bot: running" || echo "  bot: stopped"
  [ -f world_id.txt ] && echo "  world: $(cat world_id.txt)"
}

case "${1:-}" in
  start)
    if [ -z "${2:-}" ]; then
      echo "Usage: $0 start WORLD_NAME [PORT]" >&2
      exit 1
    fi
    start_server "$2" "$3"
    ;;
  stop) stop_server ;;
  status) show_status ;;
  *) echo "Usage: $0 start WORLD_NAME [PORT] | stop | status" >&2 ;;
esac
