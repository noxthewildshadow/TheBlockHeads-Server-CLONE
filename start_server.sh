#!/usr/bin/env bash
# start_server.sh - manage The Blockheads server + bot with screen
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER_BINARY="${SERVER_BINARY:-$SCRIPT_DIR/blockheads_server171}"
DEFAULT_PORT=12153
SCREEN_SERVER="${SCREEN_SERVER:-blockheads_server}"
SCREEN_BOT="${SCREEN_BOT:-blockheads_bot}"
SAVES_DIR="${HOME}/GNUstep/Library/ApplicationSupport/TheBlockheads/saves"
WORLD_ID_FILE="$SCRIPT_DIR/world_id.txt"

show_usage() {
    cat <<EOF
Usage: $0 start [WORLD_NAME] [PORT]
  start WORLD_NAME PORT - Start server and bot with specified world and port
  stop                  - Stop server and bot
  status                - Show server and bot status
  help                  - Show this help

Note: First create a world manually with:
  $SERVER_BINARY -n
  (Press Ctrl+C after world creation)
EOF
}

is_port_in_use() {
    local port="$1"
    if lsof -Pi ":$port" -sTCP:LISTEN -t >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

free_port() {
    local port="$1"
    echo "Attempting to free port $port..."
    local pids
    pids="$(lsof -ti ":$port" 2>/dev/null || true)"
    if [ -n "$pids" ]; then
        echo "Found processes using port $port: $pids"
        kill $pids 2>/dev/null || true
        sleep 2
        pids="$(lsof -ti ":$port" 2>/dev/null || true)"
        if [ -n "$pids" ]; then
            echo "Forcing kill of PIDs: $pids"
            kill -9 $pids 2>/dev/null || true
            sleep 1
        fi
    fi
    if is_port_in_use "$port"; then
        echo "ERROR: Could not free port $port"
        return 1
    fi
    echo "Port $port freed successfully"
    return 0
}

check_world_exists() {
    local world_name="$1"
    local world_dir="$SAVES_DIR/$world_name"
    if [ ! -d "$world_dir" ]; then
        echo "Error: World '$world_name' does not exist at: $world_dir"
        echo "First create a world with: $SERVER_BINARY -n"
        return 1
    fi
    return 0
}

start_server() {
    local world_name="$1"
    local port="${2:-$DEFAULT_PORT}"

    if [ ! -x "$SERVER_BINARY" ]; then
        echo "ERROR: Server binary not found or not executable: $SERVER_BINARY"
        return 1
    fi

    if is_port_in_use "$port"; then
        echo "Port $port appears in use."
        if ! free_port "$port"; then
            echo "Cannot start server. Port $port is not available."
            return 1
        fi
    fi

    if screen -list | grep -q "\.${SCREEN_SERVER}[[:space:]]"; then
        echo "Stopping existing screen server session..."
        screen -S "$SCREEN_SERVER" -X quit || true
        sleep 1
    fi
    if screen -list | grep -q "\.${SCREEN_BOT}[[:space:]]"; then
        echo "Stopping existing screen bot session..."
        screen -S "$SCREEN_BOT" -X quit || true
        sleep 1
    fi

    if ! check_world_exists "$world_name"; then
        return 1
    fi

    local log_dir="$SAVES_DIR/$world_name"
    local log_file="$log_dir/console.log"
    mkdir -p "$log_dir"

    echo "Starting server with world: $world_name, port: $port"
    printf '%s' "$world_name" > "$WORLD_ID_FILE"

    screen -dmS "$SCREEN_SERVER" bash -lc "
        while true; do
            echo \"[$(date '+%Y-%m-%d %H:%M:%S')] Starting server...\" | tee -a '$log_file'
            if \"$SERVER_BINARY\" -o '$world_name' -p $port 2>&1 | tee -a '$log_file'; then
                echo \"[$(date '+%Y-%m-%d %H:%M:%S')] Server closed normally.\" | tee -a '$log_file'
                break
            else
                exit_code=\$?
                echo \"[$(date '+%Y-%m-%d %H:%M:%S')] Server failed with code: \$exit_code\" | tee -a '$log_file'
            fi
            echo \"[$(date '+%Y-%m-%d %H:%M:%S')] Restarting in 5 seconds...\" | tee -a '$log_file'
            sleep 5
        done
    "

    local wait_time=0
    while [ ! -f "$log_file" ] && [ $wait_time -lt 15 ]; do
        sleep 1
        ((wait_time++))
    done

    if [ ! -f "$log_file" ]; then
        echo "ERROR: Could not create log file. Server may not have started."
        return 1
    fi

    if grep -E "Failed to start server|port.*already in use" "$log_file" -m 1 >/dev/null 2>&1; then
        echo "ERROR: Server log indicates a start problem. Check $log_file"
        return 1
    fi

    start_bot "$log_file"

    echo "Server started successfully."
    echo "To view console: screen -r $SCREEN_SERVER"
    echo "To view bot: screen -r $SCREEN_BOT"
    echo ""
    echo "IMPORTANT: To connect from The Blockheads game:"
    echo "1. Make sure port $port is open on your firewall/router"
    echo "2. Use your server's IP address and port $port"
}

start_bot() {
    local log_file="$1"
    if screen -list | grep -q "\.${SCREEN_BOT}[[:space:]]"; then
        echo "Bot is already running."
        return 0
    fi
    echo "Waiting briefly for server to be ready..."
    sleep 3
    local bot_script="$SCRIPT_DIR/bot_server.sh"
    if [ ! -x "$bot_script" ]; then
        echo "ERROR: Bot script not found or not executable: $bot_script"
        return 1
    fi
    screen -dmS "$SCREEN_BOT" bash -lc "
        echo 'Starting server bot...'
        cd '$SCRIPT_DIR' || exit 1
        ./bot_server.sh '$log_file'
    "
    echo "Bot started successfully (screen session: $SCREEN_BOT)."
}

stop_server() {
    if screen -list | grep -q "\.${SCREEN_SERVER}[[:space:]]"; then
        screen -S "$SCREEN_SERVER" -X quit || true
        echo "Server stopped."
    else
        echo "Server was not running."
    fi

    if screen -list | grep -q "\.${SCREEN_BOT}[[:space:]]"; then
        screen -S "$SCREEN_BOT" -X quit || true
        echo "Bot stopped."
    else
        echo "Bot was not running."
    fi

    pkill -f "$(basename "$SERVER_BINARY")" 2>/dev/null || true
}

show_status() {
    echo "=== THE BLOCKHEADS SERVER STATUS ==="
    if screen -list | grep -q "\.${SCREEN_SERVER}[[:space:]]"; then
        echo "Server: RUNNING"
    else
        echo "Server: STOPPED"
    fi
    if screen -list | grep -q "\.${SCREEN_BOT}[[:space:]]"; then
        echo "Bot: RUNNING"
    else
        echo "Bot: STOPPED"
    fi
    if [ -f "$WORLD_ID_FILE" ]; then
        WORLD_NAME="$(cat "$WORLD_ID_FILE")"
        echo "Current world: $WORLD_NAME"
    fi
    echo "===================================="
}

case "${1:-help}" in
    start)
        if [ -z "${2:-}" ]; then
            echo "Error: You must specify WORLD_NAME"
            show_usage
            exit 1
        fi
        start_server "$2" "${3:-}"
        ;;
    stop)
        stop_server
        ;;
    status)
        show_status
        ;;
    help|*)
        show_usage
        ;;
esac
