#!/bin/bash
# start_server.sh - robust starter for blockheads server + bot
# Usage: ./start_server.sh start WORLD_NAME PORT
# Requires: screen, lsof

set -e

SERVER_BINARY="./blockheads_server171"
DEFAULT_PORT=12153
SCREEN_SERVER="blockheads_server"
SCREEN_BOT="blockheads_bot"

show_usage() {
    echo "Usage: $0 start [WORLD_NAME] [PORT]"
    echo "  start WORLD_NAME PORT - Start server and bot with specified world and port"
    echo "  stop                  - Stop server and bot"
    echo "  status                - Show server and bot status"
    echo "  help                  - Show this help"
    echo ""
    echo "Note: First create a world manually with:"
    echo "  ./blockheads_server171 -n"
    echo "  (Press Ctrl+C after world creation)"
}

is_port_in_use() {
    local port="$1"
    if lsof -Pi ":$port" -sTCP:LISTEN -t >/dev/null ; then
        return 0
    else
        return 1
    fi
}

free_port() {
    local port="$1"
    echo "Attempting to free port $port..."
    local pids
    pids=$(lsof -ti ":$port")
    if [ -n "$pids" ]; then
        echo "Found processes using port $port: $pids"
        kill -9 $pids 2>/dev/null || true
        sleep 2
    fi
    # avoid killing unrelated screens; only try to stop screen sessions named the server
    if screen -list | grep -q "$SCREEN_SERVER"; then
        screen -S "$SCREEN_SERVER" -X quit || true
    fi
    if is_port_in_use "$port"; then
        echo "ERROR: Could not free port $port"
        return 1
    else
        echo "Port $port freed successfully"
        return 0
    fi
}

check_world_exists() {
    local world_name="$1"
    local saves_dir="$HOME/GNUstep/Library/ApplicationSupport/TheBlockheads/saves"
    local world_dir="$saves_dir/$world_name"
    if [ ! -d "$world_dir" ]; then
        echo "Error: World '$world_name' does not exist."
        echo "First create a world with: ./blockheads_server171 -n"
        echo "See all options: ./blockheads_server171 -h"
        return 1
    fi
    return 0
}

start_server() {
    local world_name="$1"
    local port="${2:-$DEFAULT_PORT}"

    if is_port_in_use "$port"; then
        echo "Port $port is in use."
        if ! free_port "$port"; then
            echo "Cannot start server. Port $port is not available."
            return 1
        fi
    fi

    # stop any existing screen sessions with the same names
    if screen -list | grep -q "$SCREEN_SERVER"; then
        screen -S "$SCREEN_SERVER" -X quit || true
    fi
    if screen -list | grep -q "$SCREEN_BOT"; then
        screen -S "$SCREEN_BOT" -X quit || true
    fi
    sleep 1

    if ! check_world_exists "$world_name"; then
        return 1
    fi

    local log_dir="$HOME/GNUstep/Library/ApplicationSupport/TheBlockheads/saves/$world_name"
    local log_file="$log_dir/console.log"
    mkdir -p "$log_dir"

    echo "Starting server with world: $world_name, port: $port"
    echo "$world_name" > world_id.txt

    # create a small runner script in the log_dir to avoid quoting issues
    cat > "$log_dir/run_server.sh" <<'EOF'
#!/bin/bash
WORLD_NAME="$1"
PORT="$2"
LOG_FILE="$3"
SERVER_BIN="$4"
while true; do
  printf '[%s] Starting server...\n' "$(date '+%Y-%m-%d %H:%M:%S')"
  "$SERVER_BIN" -o "$WORLD_NAME" -p "$PORT" 2>&1 | tee -a "$LOG_FILE"
  exit_code=$?
  printf '[%s] Server closed with code: %d\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$exit_code"
  # check last lines for port in use as heuristic (not perfect)
  if tail -n 10 "$LOG_FILE" | grep -qi "port.*already in use"; then
    printf '[%s] ERROR: Port already in use. Will not retry.\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    break
  fi
  printf '[%s] Restarting in 5 seconds...\n' "$(date '+%Y-%m-%d %H:%M:%S')"
  sleep 5
done
EOF
    chmod +x "$log_dir/run_server.sh"

    # Run the runner in a detached screen
    screen -dmS "$SCREEN_SERVER" bash -c "$log_dir/run_server.sh '$world_name' $port '$log_file' '$SERVER_BINARY'"

    echo "Waiting for server to create log file..."
    local wait_time=0
    while [ ! -f "$log_file" ] && [ $wait_time -lt 15 ]; do
        sleep 1
        ((wait_time++))
    done

    if [ ! -f "$log_file" ]; then
        echo "ERROR: Could not create log file. Server may not have started."
        return 1
    fi

    if grep -q -i "Failed to start server\|port.*already in use" "$log_file"; then
        echo "ERROR: Server log indicates a problem. Check $log_file"
        return 1
    fi

    # start bot pointing to that log file
    start_bot "$log_file"

    echo "Server started successfully."
    echo "To view console: screen -r $SCREEN_SERVER"
    echo "To view bot: screen -r $SCREEN_BOT"
    echo ""
    echo "IMPORTANT: To connect from The Blockheads game:"
    echo "1. Make sure port $port is open on your firewall/router"
    echo "2. Use your server's IP address and port $port"
    echo "3. Check your network connection if you can't connect"
    return 0
}

start_bot() {
    local log_file="$1"

    if screen -list | grep -q "$SCREEN_BOT"; then
        echo "Bot is already running."
        return 0
    fi

    echo "Waiting for server to be ready..."
    sleep 5

    # start bot in screen; bot_server.sh must be executable and in cwd
    screen -dmS "$SCREEN_BOT" bash -c "exec ./bot_server.sh '$log_file'"

    echo "Bot started successfully."
}

stop_server() {
    if screen -list | grep -q "$SCREEN_SERVER"; then
        screen -S "$SCREEN_SERVER" -X quit
        echo "Server stopped."
    else
        echo "Server was not running."
    fi

    if screen -list | grep -q "$SCREEN_BOT"; then
        screen -S "$SCREEN_BOT" -X quit
        echo "Bot stopped."
    else
        echo "Bot was not running."
    fi

    pkill -f "$SERVER_BINARY" 2>/dev/null || true
    pkill -f "tail -n 0 -F" 2>/dev/null || true
}

show_status() {
    echo "=== THE BLOCKHEADS SERVER STATUS ==="
    if screen -list | grep -q "$SCREEN_SERVER"; then
        echo "Server: RUNNING"
    else
        echo "Server: STOPPED"
    fi
    if screen -list | grep -q "$SCREEN_BOT"; then
        echo "Bot: RUNNING"
    else
        echo "Bot: STOPPED"
    fi
    if [ -f "world_id.txt" ]; then
        WORLD_NAME=$(cat world_id.txt)
        echo "Current world: $WORLD_NAME"
        if screen -list | grep -q "$SCREEN_SERVER"; then
            echo "To view console: screen -r $SCREEN_SERVER"
            echo "To view bot: screen -r $SCREEN_BOT"
        fi
    fi
    echo "===================================="
}

case "$1" in
    start)
        if [ -z "$2" ]; then
            echo "Error: You must specify WORLD_NAME"
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
    help|*)
        show_usage
        ;;
esac
