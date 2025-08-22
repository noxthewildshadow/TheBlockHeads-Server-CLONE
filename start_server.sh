#!/bin/bash
# start_server.sh - minimal starter for Blockheads server + bot
set -euo pipefail

SERVER_BINARY="./blockheads_server171"
DEFAULT_PORT=12153
SCREEN_SERVER="blockheads_server"
SCREEN_BOT="blockheads_bot"

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
    return 0
  fi
  [ -x "./bot_server.sh" ] || return 1
  screen -dmS "$SCREEN_BOT" bash -lc "exec ./bot_server.sh '$log_file'"
  sleep 1
  return 0
}

start_server() {
  local world_name="$1"
  local port="${2:-$DEFAULT_PORT}"

  SV_BIN=$(find_server_binary)
  [ -n "$SV_BIN" ] || { echo "server binary not found" >&2; return 1; }

  if is_port_in_use "$port"; then
    echo "port $port in use" >&2
    return 1
  fi

  WORLD_DIR=$(find_world_dir "$world_name")
  [ -n "$WORLD_DIR" ] || { echo "world not found: $world_name" >&2; return 1; }

  LOG_DIR="$WORLD_DIR"
  LOG_FILE="$LOG_DIR/console.log"
  mkdir -p "$LOG_DIR"
  : > "$LOG_FILE"
  chmod a+w "$LOG_FILE" 2>/dev/null || true

  echo "$world_name" > world_id.txt

  screen -dmS "$SCREEN_SERVER" bash -lc "exec \"$SV_BIN\" -o \"$world_name\" -p $port 2>&1 | tee -a \"$LOG_FILE\""

  local tries=0
  while [ $tries -lt 12 ]; do
    screen -list | grep -q "$SCREEN_SERVER" && break
    sleep 1
    tries=$((tries+1))
  done
  if ! screen -list | grep -q "$SCREEN_SERVER"; then
    echo "failed to start screen session" >&2
    return 1
  fi

  start_bot "$LOG_FILE" || true
  printf 'started\n'
  return 0
}

stop_server() {
  screen -list | grep -q "$SCREEN_BOT" && screen -S "$SCREEN_BOT" -X quit || true
  screen -list | grep -q "$SCREEN_SERVER" && screen -S "$SCREEN_SERVER" -X quit || true
  pkill -f "$SERVER_BINARY" 2>/dev/null || true
}

show_status() {
  screen -list | grep -q "$SCREEN_SERVER" && echo "server: running" || echo "server: stopped"
  screen -list | grep -q "$SCREEN_BOT" && echo "bot: running" || echo "bot: stopped"
  [ -f world_id.txt ] && echo "world: $(cat world_id.txt)"
}

case "${1:-}" in
  start)
    if [ -z "${2:-}" ]; then
      echo "Usage: $0 start WORLD_NAME [PORT]" >&2
      exit 1
    fi
    start_server "$2" "$3"
    ;;
  stop)
    stop_server
    ;;
  status)
    show_status
    ;;
  *)
    echo "Usage: $0 start WORLD_NAME [PORT] | stop | status" >&2
    ;;
esac
