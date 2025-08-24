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

    # Start server with proper error handling - FIXED COMMAND
    # Usamos un approach diferente para iniciar el servidor
    if ! screen -dmS "$SCREEN_SERVER" bash -c "
        cd '$PWD'
        echo 'Starting The Blockheads server...'
        # Ejecutar el servidor en bucle con reinicio automático
        while true; do
            echo \"[\$(date '+%Y-%m-%d %H:%M:%S')] Starting server with world: $world_id on port: $port\"
            if ./blockheads_server171 -o '$world_id' -p $port 2>&1 | tee -a '$log_file'; then
                echo \"[\$(date '+%Y-%m-%d %H:%M:%S')] Server closed normally\"
            else
                exit_code=\$?
                echo \"[\$(date '+%Y-%m-%d %H:%M:%S')] Server failed with code: \$exit_code\"
                # Si el error es por puerto en uso, no reintentar
                if tail -n 5 '$log_file' | grep -q \"port.*already in use\"; then
                    echo \"[\$(date '+%Y-%m-%d %H:%M:%S')] ERROR: Port already in use. Will not retry.\"
                    break
                fi
            fi
            echo \"[\$(date '+%Y-%m-%d %H:%M:%S')] Restarting in 5 seconds...\"
            sleep 5
        done
    "; then
        echo -e "${RED}ERROR: Failed to start server screen session${NC}"
        return 1
    fi

    # Wait for server to start
    echo -e "${CYAN}Waiting for server to start...${NC}"
    
    # Esperar a que el archivo de log se cree
    local wait_time=0
    while [ ! -f "$log_file" ] && [ $wait_time -lt 30 ]; do
        sleep 1
        ((wait_time++))
        echo -e "${YELLOW}Waiting for server log... ($wait_time/30)${NC}"
    done

    if [ ! -f "$log_file" ]; then
        echo -e "${RED}ERROR: Could not create log file. Server may not have started.${NC}"
        echo -e "${YELLOW}Check if the server binary has execution permissions: chmod +x $SERVER_BINARY${NC}"
        return 1
    fi

    # Wait for server to be ready - MEJOR DETECCIÓN
    echo -e "${CYAN}Waiting for server to be ready...${NC}"
    local server_ready=false
    for i in {1..60}; do
        # Verificar diferentes mensajes de éxito
        if grep -q "World load complete\|Server started\|Ready for connections\|using seed:\|save delay:" "$log_file"; then
            server_ready=true
            break
        fi
        
        # Verificar si hay errores
        if grep -q "ERROR\|Error\|error\|failed\|Failed" "$log_file"; then
            echo -e "${RED}Server startup failed. Check $log_file for details.${NC}"
            return 1
        fi
        
        # Verificar si el proceso del servidor sigue ejecutándose
        if ! screen_session_exists "$SCREEN_SERVER"; then
            echo -e "${RED}Server process died. Check $log_file for errors.${NC}"
            return 1
        fi
        
        sleep 1
        echo -e "${YELLOW}Waiting for server to be ready... ($i/60)${NC}"
    done

    if [ "$server_ready" = false ]; then
        echo -e "${YELLOW}WARNING: Server did not show complete startup messages, but continuing...${NC}"
        echo -e "${YELLOW}This is normal for some server versions. Checking if server process is running...${NC}"
        
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
    fi
    
    if screen_session_exists "$SCREEN_BOT"; then
        bot_started=1
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
