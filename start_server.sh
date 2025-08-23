#!/bin/bash
set -e

# Lightweight server controller for TheBlockheads
# Usage: ./start_server.sh start WORLD_NAME [PORT]

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
    echo "  $SERVER_BINARY -n"
    echo "  (Press Ctrl+C after world creation)"
}

is_port_in_use() {
    local port="$1"
    if lsof -Pi :"$port" -sTCP:LISTEN -t >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

free_port() {
    local port="$1"
    echo "Attempting to free port $port..."
    local pids
    pids=$(lsof -ti :"$port" 2>/dev/null || true)
    if [ -n "$pids" ]; then
        echo "Found processes using port $port: $pids"
        kill -9 $pids 2>/dev/null || true
        sleep 2
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
    local saves_dir="$HOME/GNUstep/Library/ApplicationSupport/TheBlockheads/saves"
    local world_dir="$saves_dir/$world_name"
    if [ ! -d "$world_dir" ]; then
        echo "Error: World '$world_name' does not exist." >&2
        echo "First create a world with: $SERVER_BINARY -n" >&2
        return 1
    fi
    return 0
}

start_server() {
    local world_name="$1"
    local port="${2:-$DEFAULT_PORT}"

    if [ ! -x "$SERVER_BINARY" ]; then
        echo "ERROR: Server binary not found or not executable: $SERVER_BINARY" >&2
        return 1
    fi

    if is_port_in_use "$port"; then
        echo "Port $port is in use. Attempting to free it..."
        if ! free_port "$port"; then
            echo "Cannot start server. Port $port is not available." >&2
            return 1
        fi
    fi

    # Stop existing screen session if present
    if screen -list | grep -q "$SCREEN_SERVER"; then
        echo "An existing server screen session was found. Stopping it first..."
        screen -S "$SCREEN_SERVER" -X quit || true
        sleep 1
    fi

    if ! check_world_exists "$world_name"; then
        return 1
    fi

    local log_dir="$HOME/GNUstep/Library/ApplicationSupport/TheBlockheads/saves/$world_name"
    local log_file="$log_dir/console.log"
    mkdir -p "$log_dir"

    echo "Starting server with world: $world_name, port: $port"
    echo "$world_name" > world_id.txt

    # Start server inside a detached screen; log to console.log
    screen -dmS "$SCREEN_SERVER" bash -c "
        while true; do
            echo \"[$(date '+%Y-%m-%d %H:%M:%S')] Starting server...\";
            $SERVER_BINARY -o '$world_name' -p $port 2>&1 | tee -a '$log_file';
            exit_code=\$?;
            echo \"[$(date '+%Y-%m-%d %H:%M:%S')] Server exited with code: \$exit_code\";
            if [ \$exit_code -eq 1 ] && tail -n 5 '$log_file' | grep -qi \"port.*already in use\"; then
                echo \"[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: Port already in use. Will not retry.\";
                break;
            fi
            echo \"[$(date '+%Y-%m-%d %H:%M:%S')] Restarting in 5 seconds...\";
            sleep 5;
        done
    "

    echo "Waiting for server to create log file..."
    local wait_time=0
    while [ ! -f "$log_file" ] && [ $wait_time -lt 30 ]; do
        sleep 1
        ((wait_time++))
    done

    if [ ! -f "$log_file" ]; then
        echo "ERROR: Could not create log file. Server may not have started." >&2
        return 1
    fi

    # Quick sanity check for obvious errors
    if grep -q -i "Failed to start server\|port.*already in use" "$log_file" 2>/dev/null; then
        echo "ERROR: Server reported a start failure. Check $log_file" >&2
        return 1
    fi

    start_bot "$log_file"

    echo "Server started successfully."
    echo "To view console: screen -r $SCREEN_SERVER"
    echo "To view bot: screen -r $SCREEN_BOT"
}

start_bot() {
    local log_file="$1"
    if screen -list | grep -q "$SCREEN_BOT"; then
        echo "Bot is already running."
        return 0
    fi
    echo "Waiting for server to be ready..."
    sleep 5
    screen -dmS "$SCREEN_BOT" bash -c "echo 'Starting server bot...'; ./bot_server.sh '$log_file'"
    echo "Bot started successfully."
}

stop_server() {
    if screen -list | grep -q "$SCREEN_SERVER"; then
        screen -S "$SCREEN_SERVER" -X quit || true
        echo "Server stopped."
    else
        echo "Server was not running."
    fi

    if screen -list | grep -q "$SCREEN_BOT"; then
        screen -S "$SCREEN_BOT" -X quit || true
        echo "Bot stopped."
    else
        echo "Bot was not running."
    fi

    pkill -f "$SERVER_BINARY" 2>/dev/null || true
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
