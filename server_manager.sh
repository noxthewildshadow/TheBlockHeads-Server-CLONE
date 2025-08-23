#!/bin/bash

# Configuration
SERVER_BINARY="./blockheads_server171"
DEFAULT_PORT=12153
SCREEN_SERVER="blockheads_server"
SCREEN_BOT="blockheads_bot"
ECONOMY_FILE="economy_data.json"

show_usage() {
    echo "================================================================"
    echo "              THE BLOCKHEADS SERVER MANAGER"
    echo "================================================================"
    echo "Usage: $0 [command]"
    echo ""
    echo "Available commands:"
    echo "  start [WORLD_NAME] [PORT] - Start server and bot"
    echo "  stop                      - Stop server and bot"
    echo "  status                    - Show server status"
    echo "  help                      - Show this help"
    echo ""
    echo "Examples:"
    echo "  $0 start MyWorld 12153"
    echo "  $0 start MyWorld        (uses default port 12153)"
    echo "  $0 stop"
    echo "  $0 status"
    echo ""
    echo "Note: First create a world manually with:"
    echo "  ./blockheads_server171 -n"
    echo ""
    echo "After creating the world, press CTRL+C to exit"
    echo "and then start the server with the start command."
    echo "================================================================"
}

is_port_in_use() {
    lsof -Pi ":$1" -sTCP:LISTEN -t >/dev/null
}

free_port() {
    local port="$1"
    echo "Freeing port $port..."
    local pids=$(lsof -ti ":$port")
    [ -n "$pids" ] && kill -9 $pids 2>/dev/null
    killall screen 2>/dev/null || true
    sleep 2
    ! is_port_in_use "$port"
}

check_world_exists() {
    local world_id="$1"
    local saves_dir="$HOME/GNUstep/Library/ApplicationSupport/TheBlockheads/saves"
    [ -d "$saves_dir/$world_id" ] || {
        echo "ERROR: World '$world_id' does not exist in: $saves_dir/"
        echo ""
        echo "To create a world, run: ./blockheads_server171 -n"
        echo "After creating the world, press CTRL+C to exit"
        echo "and then start the server with: $0 start $world_id $port"
        return 1
    }
    return 0
}

start_server() {
    local world_id="$1"
    local port="${2:-$DEFAULT_PORT}"

    # Verify server binary exists
    if [ ! -f "$SERVER_BINARY" ]; then
        echo "ERROR: Server binary not found: $SERVER_BINARY"
        echo "Run the installer first: ./installer.sh"
        return 1
    fi

    # Verify world exists
    if ! check_world_exists "$world_id"; then
        return 1
    fi

    # Check if port is in use
    if is_port_in_use "$port"; then
        echo "Port $port is in use."
        if ! free_port "$port"; then
            echo "ERROR: Could not free port $port"
            echo "Use a different port or terminate the process using it"
            return 1
        fi
    fi

    # Clean up previous sessions
    screen -S "$SCREEN_SERVER" -X quit 2>/dev/null || true
    screen -S "$SCREEN_BOT" -X quit 2>/dev/null || true
    sleep 1

    local log_dir="$HOME/GNUstep/Library/ApplicationSupport/TheBlockheads/saves/$world_id"
    local log_file="$log_dir/console.log"
    mkdir -p "$log_dir"

    echo "Starting server - World: $world_id, Port: $port"
    echo "$world_id" > world_id.txt

    # Start server
    screen -dmS "$SCREEN_SERVER" bash -c "
        cd '$PWD'
        echo '[\$(date \"+%Y-%m-%d %H:%M:%S\")] Starting server...'
        while true; do
            if ./blockheads_server171 -o '$world_id' -p $port 2>&1 | tee -a '$log_file'; then
                echo '[\$(date \"+%Y-%m-%d %H:%M:%S\")] Server closed normally'
            else
                exit_code=\$?
                echo '[\$(date \"+%Y-%m-%d %H:%M:%S\")] Server failed with code: \$exit_code'
                if [ \$exit_code -eq 1 ] && tail -n 5 '$log_file' | grep -q \"port.*already in use\"; then
                    echo '[\$(date \"+%Y-%m-%d %H:%M:%S\")] ERROR: Port already in use. Will not retry.'
                    break
                fi
            fi
            echo '[\$(date \"+%Y-%m-%d %H:%M:%S\")] Restarting in 5 seconds...'
            sleep 5
        done
    "

    # Wait for server to start
    echo "Waiting for server to start..."
    local wait_time=0
    while [ ! -f "$log_file" ] && [ $wait_time -lt 15 ]; do
        sleep 1
        ((wait_time++))
    done

    if [ ! -f "$log_file" ]; then
        echo "ERROR: Could not create log file. Server may not have started."
        return 1
    fi

    # Wait for server to be ready
    local server_ready=false
    for i in {1..10}; do
        if grep -q "Server started\|Ready for connections" "$log_file"; then
            server_ready=true
            break
        fi
        sleep 1
    done

    if [ "$server_ready" = false ]; then
        echo "WARNING: Server did not show complete startup messages, but continuing..."
    fi

    # Start bot
    echo "Starting server bot..."
    screen -dmS "$SCREEN_BOT" bash -c "
        cd '$PWD'
        echo 'Starting server bot...'
        ./bot_server.sh '$log_file'
    "

    # Verify both processes started correctly
    local server_started=$(screen -list | grep -c "$SCREEN_SERVER")
    local bot_started=$(screen -list | grep -c "$SCREEN_BOT")
    
    if [ "$server_started" -eq 1 ] && [ "$bot_started" -eq 1 ]; then
        echo "================================================================"
        echo "Server and bot started successfully!"
        echo "World: $world_id"
        echo "Port: $port"
        echo ""
        echo "To view server console: screen -r $SCREEN_SERVER"
        echo "To view bot: screen -r $SCREEN_BOT"
        echo ""
        echo "To exit console without stopping server: CTRL+A, D"
        echo "================================================================"
    else
        echo "WARNING: Could not verify all screen sessions"
        echo "Server started: $server_started, Bot started: $bot_started"
        echo "Use 'screen -list' to view active sessions"
    fi
}

stop_server() {
    echo "Stopping server and bot..."
    screen -S "$SCREEN_SERVER" -X quit 2>/dev/null && echo "Server stopped." || echo "Server was not running."
    screen -S "$SCREEN_BOT" -X quit 2>/dev/null && echo "Bot stopped." || echo "Bot was not running."
    pkill -f "$SERVER_BINARY" 2>/dev/null || true
    echo "Cleanup completed."
}

show_status() {
    echo "================================================================"
    echo "                 THE BLOCKHEADS SERVER STATUS"
    echo "================================================================"
    
    # Check server
    if screen -list | grep -q "$SCREEN_SERVER"; then
        echo "Server: RUNNING"
    else
        echo "Server: STOPPED"
    fi
    
    # Check bot
    if screen -list | grep -q "$SCREEN_BOT"; then
        echo "Bot: RUNNING"
    else
        echo "Bot: STOPPED"
    fi
    
    # Show world info if exists
    if [ -f "world_id.txt" ]; then
        local WORLD_ID=$(cat world_id.txt 2>/dev/null)
        echo "Current world: $WORLD_ID"
        
        # Show port if server is running
        if screen -list | grep -q "$SCREEN_SERVER"; then
            echo "To view console: screen -r $SCREEN_SERVER"
            echo "To view bot: screen -r $SCREEN_BOT"
        fi
    else
        echo "World: Not configured (run 'start' first)"
    fi
    
    echo "================================================================"
}

# Command handling
case "$1" in
    start)
        if [ -z "$2" ]; then
            echo "ERROR: You must specify a WORLD_NAME"
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
    help|--help|-h|*)
        show_usage
        ;;
esac
