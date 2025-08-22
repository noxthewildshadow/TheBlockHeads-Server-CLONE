#!/bin/bash
# start_server.sh - robust starter for Blockheads server + bot (clean & simple)
# Usage: ./start_server.sh start WORLD_NAME [PORT]
set -euo pipefail

SERVER_BINARY="./blockheads_server171"
DEFAULT_PORT=12153
SCREEN_SERVER="blockheads_server"
SCREEN_BOT="blockheads_bot"

# Try to find server binary if default missing
find_server_binary() {
  if [ -x "$SERVER_BINARY" ]; then
    echo "$SERVER_BINARY"
    return 0
  fi
  alt=$(find . -maxdepth 3 -type f -executable -iname "*blockheads*" 2>/dev/null | head -n1 || true)
  if [ -n "$alt" ]; then
    echo "$alt"
    return 0
  fi
  echo ""
  return 1
}

# Look for world save dir in common locations
find_world_dir() {
  local world="$1"
  local try

  # 1) explicit saves dir used by many servers
  try="$HOME/GNUstep/Library/ApplicationSupport/TheBlockheads/saves/$world"
  if [ -d "$try" ]; then
    echo "$try"
    return 0
  fi

  # 2) ./saves/<world>
  try="./saves/$world"
  if [ -d "$try" ]; then
    echo "$try"
    return 0
  fi

  # 3) ./ (allow world folder in cwd)
  try="./$world"
  if [ -d "$try" ]; then
    echo "$try"
    return 0
  fi

  # 4) search for folder name anywhere under cwd (last resort)
  try=$(find . -type d -name "$world" | head -n1 || true)
  if [ -n "$try" ]; then
    echo "$try"
    return 0
  fi

  echo ""
  return 1
}

show_usage() {
  cat <<EOF
Usage: $0 start WORLD_NAME [PORT]
       $0 stop
       $0 status
EOF
}

is_port_in_use() {
  local port="$1"
  if command -v lsof >/dev/null 2>&1 && lsof -Pi ":$port" -sTCP:LISTEN -t >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

start_server() {
  local world_name="$1"
  local port="${2:-$DEFAULT_PORT}"

  SV_BIN=$(find_server_binary)
  if [ -z "$SV_BIN" ]; then
    echo "Error: server binary not found. Place it as ./blockheads_server171 or in cwd."
    return 1
  fi

  if is_port_in_use "$port"; then
    echo "Port $port appears in use. Aborting."
    return 1
  fi

  # find world dir
  WORLD_DIR="$(find_world_dir "$world_name")"
  if [ -z "$WORLD_DIR" ]; then
    echo "World '$world_name' not found. Create it first with: $SV_BIN -n"
    return 1
  fi

  LOG_DIR="$WORLD_DIR"
  LOG_FILE="$LOG_DIR/console.log"
  mkdir -p "$LOG_DIR"
  # touch log file immediately so other processes can see it
  : > "$LOG_FILE"
  chmod a+w "$LOG_FILE" 2>/dev/null || true

  echo "Starting server for world: $world_name (log: $LOG_FILE)"
  echo "$world_name" > world_id.txt

  # Launch server inside a detached screen safely
  screen -dmS "$SCREEN_SERVER" bash -lc "exec \"$SV_BIN\" -o \"$world_name\" -p $port 2>&1 | tee -a \"$LOG_FILE\""

  # wait for screen session and log file to show activity
  local wait=0
  while [ $wait -lt 15 ]; do
    if screen -list | grep -q "$SCREEN_SERVER"; then
      break
    fi
    sleep 1
    wait=$((wait+1))
  done

  if ! screen -list | grep -q "$SCREEN_SERVER"; then
    echo "ERROR: screen session did not start."
    return 1
  fi

  # give server a few seconds to initialize and write to log
  wait=0
  while [ $wait -lt 15 ]; do
    if [ -s "$LOG_FILE" ] && tail -n 20 "$LOG_FILE" | grep -qiE "starting|server|listening|listening on|failed|error"; then
      break
    fi
    sleep 1
    wait=$((wait+1))
  done

  if ! [ -s "$LOG_FILE" ]; then
    echo "Warning: log file still empty after startup window. Check screen -r $SCREEN_SERVER"
  fi

  start_bot "$LOG_FILE"
  echo "Server started. Use 'screen -r $SCREEN_SERVER' to view console."
  return 0
}

start_bot() {
  local log_file="$1"
  if screen -list | grep -q "$SCREEN_BOT"; then
    echo "Bot already running."
    return 0
  fi
  # ensure bot is executable
  if [ ! -x "./bot_server.sh" ]; then
    echo "Error: bot_server.sh not executable or missing."
    return 1
  fi
  screen -dmS "$SCREEN_BOT" bash -lc "exec ./bot_server.sh '$log_file'"
  sleep 1
  if screen -list | grep -q "$SCREEN_BOT"; then
    echo "Bot started (screen: $SCREEN_BOT)."
  else
    echo "Failed to start bot."
  fi
}

stop_server() {
  if screen -list | grep -q "$SCREEN_BOT"; then
    screen -S "$SCREEN_BOT" -X quit || true
    echo "Bot stopped."
  fi
  if screen -list | grep -q "$SCREEN_SERVER"; then
    screen -S "$SCREEN_SERVER" -X quit || true
    echo "Server stopped."
  fi
  pkill -f "$SERVER_BINARY" 2>/dev/null || true
}

show_status() {
  echo "Server screen: $(screen -list | grep -Eo \"$SCREEN_SERVER[^\n]*\" || echo 'stopped')"
  echo "Bot screen:    $(screen -list | grep -Eo \"$SCREEN_BOT[^\n]*\" || echo 'stopped')"
  if [ -f world_id.txt ]; then
    echo "Current world: $(cat world_id.txt)"
  fi
}

case "${1:-}" in
  start)
    if [ -z "${2:-}" ]; then
      show_usage
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
    show_usage
    ;;
esac
