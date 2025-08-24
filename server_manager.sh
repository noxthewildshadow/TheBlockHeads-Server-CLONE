#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Configuration
SERVER_BINARY="./blockheads_server171"
DEFAULT_PORT=12153
SCREEN_SERVER="blockheads_server"
SCREEN_BOT="blockheads_bot"
ECONOMY_FILE="economy_data.json"
IP_RANKS_FILE="ip_ranks.txt"
SAVES_DIR="$HOME/GNUstep/Library/ApplicationSupport/TheBlockheads/saves"

# Function to check if screen session exists
screen_session_exists() {
    screen -list 2>/dev/null | grep -q "$1"
}

# Function to show usage
show_usage() {
    echo -e "${BLUE}================================================================"
    echo -e "              THE BLOCKHEADS SERVER MANAGER"
    echo -e "================================================================"
    echo -e "${NC}Usage: $0 [command]"
    echo ""
    echo -e "Available commands:"
    echo -e "  ${GREEN}start${NC} [WORLD_NAME] [PORT] - Start server and bot"
    echo -e "  ${RED}stop${NC}                      - Stop server and bot"
    echo -e "  ${CYAN}status${NC}                    - Show server status"
    echo -e "  ${YELLOW}help${NC}                      - Show this help"
    echo ""
    echo -e "Examples:"
    echo -e "  ${GREEN}$0 start MyWorld 12153${NC}"
    echo -e "  ${GREEN}$0 start MyWorld${NC}        (uses default port 12153)"
    echo -e "  ${RED}$0 stop${NC}"
    echo -e "  ${CYAN}$0 status${NC}"
    echo ""
    echo -e "${YELLOW}Note:${NC} First create a world manually with:"
    echo -e "  ${GREEN}./blockheads_server171 -n${NC}"
    echo ""
    echo -e "After creating the world, press ${YELLOW}CTRL+C${NC} to exit"
    echo -e "and then start the server with the start command."
    echo -e "${BLUE}================================================================"
}

# Function to check if port is in use
is_port_in_use() {
    lsof -Pi ":$1" -sTCP:LISTEN -t >/dev/null 2>&1
}

# Function to free a port
free_port() {
    local port="$1"
    echo -e "${YELLOW}Freeing port $port...${NC}"
    
    # Kill processes using the port
    local pids=$(lsof -ti ":$port" 2>/dev/null || true)
    if [ -n "$pids" ]; then
        kill -9 $pids 2>/dev/null || true
    fi
    
    # Quit screen sessions if they exist
    if screen_session_exists "$SCREEN_SERVER"; then
        screen -S "$SCREEN_SERVER" -X quit 2>/dev/null || true
    fi
    
    if screen_session_exists "$SCREEN_BOT"; then
        screen -S "$SCREEN_BOT" -X quit 2>/dev/null || true
    fi
    
    sleep 2
    ! is_port_in_use "$port"
}

# Function to check if world exists
check_world_exists() {
    local world_id="$1"
    
    if [ ! -d "$SAVES_DIR/$world_id" ]; then
        echo -e "${RED}ERROR: World '$world_id' does not exist in: $SAVES_DIR/${NC}"
        echo ""
        echo -e "To create a world, run: ${GREEN}./blockheads_server171 -n${NC}"
        echo -e "After creating the world, press ${YELLOW}CTRL+C${NC} to exit"
        echo -e "and then start the server with: ${GREEN}$0 start $world_id $port${NC}"
        return 1
    fi
    return 0
}

# Function to start server
start_server() {
    local world_id="$1"
    local port="${2:-$DEFAULT_PORT}"

    # Verify server binary exists
    if [ ! -f "$SERVER_BINARY" ]; then
        echo -e "${RED}ERROR: Server binary not found: $SERVER_BINARY${NC}"
        echo -e "Run the installer first: ${GREEN}./setup.sh${NC}"
        return 1
    fi

    # Verify world exists
    if ! check_world_exists "$world_id"; then
        return 1
    fi

    # Check if port is in use
    if is_port_in_use "$port"; then
        echo -e "${YELLOW}Port $port is in use.${NC}"
        if ! free_port "$port"; then
            echo -e "${RED}ERROR: Could not free port $port${NC}"
            echo -e "Use a different port or terminate the process using it"
            return 1
        fi
    fi

    # Clean up previous sessions
    if screen_session_exists "$SCREEN_SERVER"; then
        screen -S "$SCREEN_SERVER" -X quit 2>/dev/null || true
    fi
    
    if screen_session_exists "$SCREEN_BOT"; then
        screen -S "$SCREEN_BOT" -X quit 2>/dev/null || true
    fi
    
    sleep 1

    local log_dir="$SAVES_DIR/$world_id"
    local log_file="$log_dir/console.log"
    mkdir -p "$log_dir"

    echo -e "${GREEN}Starting server - World: $world_id, Port: $port${NC}"
    echo "$world_id" > world_id.txt

    # Start server with a simpler approach
    echo -e "${YELLOW}Starting server in screen session '$SCREEN_SERVER'...${NC}"
    
    # Change to the directory and start the server
    if ! screen -dmS "$SCREEN_SERVER" bash -c "
        cd '$PWD'
        echo 'Starting The Blockheads server...'
        exec ./blockheads_server171 -o '$world_id' -p $port
    "; then
        echo -e "${RED}ERROR: Failed to start server screen session${NC}"
        return 1
    fi

    # Wait for server to start
    echo -e "${CYAN}Waiting for server to start...${NC}"
    
    # Esperar a que el proceso se inicie
    local wait_time=0
    local max_wait=30
    local server_started=false
    
    while [ $wait_time -lt $max_wait ]; do
        # Check if screen session is still running
        if ! screen_session_exists "$SCREEN_SERVER"; then
            echo -e "${RED}Server screen session ended unexpectedly${NC}"
            echo -e "${YELLOW}Check if there are errors in the server binary${NC}"
            return 1
        fi
        
        # Check if log file is being created
        if [ -f "$log_file" ]; then
            # Check for successful startup messages
            if grep -q "Server started\|Ready for connections\|World load complete" "$log_file"; then
                server_started=true
                break
            fi
            
            # Check for error messages
            if grep -q "ERROR\|Error\|Failed\|failed" "$log_file"; then
                echo -e "${RED}Server startup failed. Check $log_file for details.${NC}"
                return 1
            fi
        fi
        
        sleep 1
        ((wait_time++))
        echo -e "${YELLOW}Waiting for server to start... ($wait_time/$max_wait)${NC}"
    done

    if [ "$server_started" = false ]; then
        echo -e "${YELLOW}Server did not show startup completion messages, but may still be running${NC}"
        echo -e "${YELLOW}Checking if server process is still active...${NC}"
        
        if screen_session_exists "$SCREEN_SERVER"; then
            echo -e "${GREEN}Server screen session is active. Continuing...${NC}"
        else
            echo -e "${RED}ERROR: Server screen session not found. Server may have failed to start.${NC}"
            echo -e "${YELLOW}Check the log file for details: $log_file${NC}"
            return 1
        fi
    else
        echo -e "${GREEN}Server started successfully!${NC}"
    fi

    # Start bot
    echo -e "${CYAN}Starting server bot...${NC}"
    if ! screen -dmS "$SCREEN_BOT" bash -c "
        cd '$PWD'
        echo 'Starting server bot...'
        ./bot_server.sh '$log_file'
    "; then
        echo -e "${RED}ERROR: Failed to start bot screen session${NC}"
        return 1
    fi

    # Verify both processes started correctly
    local server_started=0
    local bot_started=0
    
    if screen_session_exists "$SCREEN_SERVER"; then
        server_started=1
        echo -e "${GREEN}Server is running in screen session: $SCREEN_SERVER${NC}"
    fi
    
    if screen_session_exists "$SCREEN_BOT"; then
        bot_started=1
        echo -e "${GREEN}Bot is running in screen session: $SCREEN_BOT${NC}"
    fi
    
    if [ "$server_started" -eq 1 ] && [ "$bot_started" -eq 1 ]; then
        echo -e "${GREEN}================================================================"
        echo -e "Server and bot started successfully!"
        echo -e "World: $world_id"
        echo -e "Port: $port"
        echo ""
        echo -e "To view server console: ${CYAN}screen -r $SCREEN_SERVER${NC}"
        echo -e "To view bot: ${CYAN}screen -r $SCREEN_BOT${NC}"
        echo ""
        echo -e "To exit console without stopping server: ${YELLOW}CTRL+A, D${NC}"
        echo -e "================================================================"
    else
        echo -e "${YELLOW}WARNING: Could not verify all screen sessions${NC}"
        echo -e "Server started: $server_started, Bot started: $bot_started"
        echo -e "Use 'screen -list' to view active sessions"
    fi
}

# Function to stop server
stop_server() {
    echo -e "${YELLOW}Stopping server and bot...${NC}"
    
    if screen_session_exists "$SCREEN_SERVER"; then
        screen -S "$SCREEN_SERVER" -X quit 2>/dev/null || true
        echo -e "${GREEN}Server stopped.${NC}"
    else
        echo -e "${YELLOW}Server was not running.${NC}"
    fi
    
    if screen_session_exists "$SCREEN_BOT"; then
        screen -S "$SCREEN_BOT" -X quit 2>/dev/null || true
        echo -e "${GREEN}Bot stopped.${NC}"
    else
        echo -e "${YELLOW}Bot was not running.${NC}"
    fi
    
    pkill -f "$SERVER_BINARY" 2>/dev/null || true
    echo -e "${GREEN}Cleanup completed.${NC}"
}

# Function to show status
show_status() {
    echo -e "${BLUE}================================================================"
    echo -e "                 THE BLOCKHEADS SERVER STATUS"
    echo -e "================================================================"
    
    # Check server
    if screen_session_exists "$SCREEN_SERVER"; then
        echo -e "Server: ${GREEN}RUNNING${NC}"
    else
        echo -e "Server: ${RED}STOPPED${NC}"
    fi
    
    # Check bot
    if screen_session_exists "$SCREEN_BOT"; then
        echo -e "Bot: ${GREEN}RUNNING${NC}"
    else
        echo -e "Bot: ${RED}STOPPED${NC}"
    fi
    
    # Show world info if exists
    if [ -f "world_id.txt" ]; then
        local WORLD_ID=$(cat world_id.txt 2>/dev/null || echo "Unknown")
        echo -e "Current world: ${CYAN}$WORLD_ID${NC}"
        
        # Show port if server is running
        if screen_session_exists "$SCREEN_SERVER"; then
            echo -e "To view console: ${CYAN}screen -r $SCREEN_SERVER${NC}"
            echo -e "To view bot: ${CYAN}screen -r $SCREEN_BOT${NC}"
        fi
    else
        echo -e "World: ${YELLOW}Not configured (run 'start' first)${NC}"
    fi
    
    echo -e "${BLUE}================================================================"
}

# Command handling
case "$1" in
    start)
        if [ -z "$2" ]; then
            echo -e "${RED}ERROR: You must specify a WORLD_NAME${NC}"
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
    help|--help|-h|"")
        show_usage
        ;;
    *)
        echo -e "${RED}ERROR: Unknown command: $1${NC}"
        show_usage
        exit 1
        ;;
esac
