#!/bin/bash
set -e

# Enhanced Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
ORANGE='\033[0;33m'
PURPLE='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Function to print status messages
print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_header() {
    echo -e "${PURPLE}================================================================"
    echo -e "$1"
    echo -e "===============================================================${NC}"
}

print_step() {
    echo -e "${CYAN}[STEP]${NC} $1"
}

# Check for root privileges
if [ "$EUID" -ne 0 ]; then
    print_error "This script requires root privileges."
    print_status "Please run with: sudo $0"
    exit 1
fi

ORIGINAL_USER=${SUDO_USER:-$USER}
USER_HOME=$(getent passwd "$ORIGINAL_USER" | cut -d: -f6)

# Configuration
SERVER_URL="https://web.archive.org/web/20240309015235if_/https://majicdave.com/share/blockheads_server171.tar.gz"
TEMP_FILE="/tmp/blockheads_server171.tar.gz"
SERVER_BINARY="blockheads_server171"

print_header "THE BLOCKHEADS LINUX SERVER INSTALLER"
print_header "FOR NEW USERS: This script will install everything you need"
print_header "Please be patient as it may take several minutes"

print_step "[1/7] Installing required packages..."
print_status "Installing only essential packages for faster installation..."
{
    # Add multiverse repository if not already added
    if ! grep -q "^deb.*multiverse" /etc/apt/sources.list /etc/apt/sources.list.d/* 2>/dev/null; then
        add-apt-repository multiverse -y
    fi
    
    # Update package lists (minimal update)
    apt-get update -y
    
    # Install only essential packages (no iptables-persistent or bc)
    apt-get install -y libgnustep-base1.28 libdispatch-dev patchelf wget screen
    
} > /dev/null 2>&1

if [ $? -eq 0 ]; then
    print_success "Essential packages installed"
else
    print_error "Failed to install essential packages"
    print_status "Trying alternative approach..."
    
    # Fallback installation method
    apt-get install -y software-properties-common
    add-apt-repository multiverse -y
    apt-get update -y
    apt-get install -y libgnustep-base1.28 libdispatch-dev patchelf wget screen || {
        print_error "Still failed to install packages. Please check your internet connection."
        exit 1
    }
fi

print_step "[2/7] Downloading server archive..."
if ! wget -q --timeout=60 --tries=3 "$SERVER_URL" -O "$TEMP_FILE"; then
    print_error "Failed to download server file."
    print_status "This might be due to:"
    print_status "1. Internet connection issues"
    print_status "2. The server file is no longer available at the expected URL"
    exit 1
fi
print_success "Server archive downloaded"

print_step "[3/7] Extracting files..."
EXTRACT_DIR="/tmp/blockheads_extract_$$"
mkdir -p "$EXTRACT_DIR"

if ! tar xzf "$TEMP_FILE" -C "$EXTRACT_DIR"; then
    print_error "Failed to extract server files."
    rm -rf "$EXTRACT_DIR"
    exit 1
fi

cp -r "$EXTRACT_DIR"/* ./
rm -rf "$EXTRACT_DIR"
print_success "Files extracted successfully"

# Find server binary if it wasn't named correctly
if [ ! -f "$SERVER_BINARY" ]; then
    print_warning "$SERVER_BINARY not found. Searching for alternative binary names..."
    ALTERNATIVE_BINARY=$(find . -name "*blockheads*" -type f -executable | head -n 1)
    if [ -n "$ALTERNATIVE_BINARY" ]; then
        print_status "Found alternative binary: $ALTERNATIVE_BINARY"
        mv "$ALTERNATIVE_BINARY" "blockheads_server171"
        SERVER_BINARY="blockheads_server171"
        print_success "Renamed to: blockheads_server171"
    else
        print_error "Could not find the server binary."
        print_status "Contents of the downloaded archive:"
        tar -tzf "$TEMP_FILE" || true
        exit 1
    fi
fi

chmod +x "$SERVER_BINARY"

print_step "[4/7] Applying patchelf compatibility patches (best-effort)..."
patchelf --replace-needed libgnustep-base.so.1.24 libgnustep-base.so.1.28 "$SERVER_BINARY" || print_warning "libgnustep-base patch may have failed"
patchelf --replace-needed libobjc.so.4.6 libobjc.so.4 "$SERVER_BINARY" || true
patchelf --replace-needed libgnutls.so.26 libgnutls.so.30 "$SERVER_BINARY" || true
patchelf --replace-needed libgcrypt.so.11 libgcrypt.so.20 "$SERVER_BINARY" || true
patchelf --replace-needed libffi.so.6 libffi.so.8 "$SERVER_BINARY" || true
patchelf --replace-needed libicui18n.so.48 libicui18n.so.70 "$SERVER_BINARY" || true
patchelf --replace-needed libicuuc.so.48 libicuuc.so.70 "$SERVER_BINARY" || true
patchelf --replace-needed libicudata.so.48 libicudata.so.70 "$SERVER_BINARY" || true
patchelf --replace-needed libdispatch.so libdispatch.so.0 "$SERVER_BINARY" || true
print_success "Compatibility patches applied"

print_step "[5/7] Creating helper scripts..."
# Create server_manager.sh
cat > server_manager.sh << 'EOF'
#!/bin/bash

# Enhanced Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
ORANGE='\033[0;33m'
PURPLE='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Function to print status messages
print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_header() {
    echo -e "${PURPLE}================================================================"
    echo -e "$1"
    echo -e "===============================================================${NC}"
}

print_step() {
    echo -e "${CYAN}[STEP]${NC} $1"
}

# Configuration
SERVER_BINARY="./blockheads_server171"
DEFAULT_PORT=12153

# Function to check if screen session exists
screen_session_exists() {
    screen -list 2>/dev/null | grep -q "$1"
}

show_usage() {
    print_header "THE BLOCKHEADS SERVER MANAGER"
    print_status "Usage: $0 [command]"
    echo ""
    print_status "Available commands:"
    echo -e "  ${GREEN}start${NC} [WORLD_NAME] [PORT] - Start server, bot and anticheat"
    echo -e "  ${RED}stop${NC} [PORT]                - Stop server, bot and anticheat (specific port or all)"
    echo -e "  ${CYAN}status${NC} [PORT]              - Show server status (specific port or all)"
    echo -e "  ${YELLOW}list${NC}                     - List all running servers"
    echo -e "  ${YELLOW}help${NC}                      - Show this help"
    echo ""
    print_status "Examples:"
    echo -e "  ${GREEN}$0 start MyWorld 12153${NC}"
    echo -e "  ${GREEN}$0 start MyWorld${NC}        (uses default port 12153)"
    echo -e "  ${RED}$0 stop${NC}                   (stops all servers, bots and anticheat)"
    echo -e "  ${RED}$0 stop 12153${NC}            (stops server on port 12153)"
    echo -e "  ${CYAN}$0 status${NC}                (shows status of all servers)"
    echo -e "  ${CYAN}$0 status 12153${NC}         (shows status of server on port 12153)"
    echo -e "  ${YELLOW}$0 list${NC}                 (lists all running servers)"
    echo ""
    print_warning "Note: First create a world manually with:"
    echo -e "  ${GREEN}./blockheads_server171 -n${NC}"
    echo ""
    print_warning "After creating the world, press ${YELLOW}CTRL+C${NC} to exit"
    print_warning "and then start the server with the start command."
    print_header "END OF HELP"
}

is_port_in_use() {
    netstat -tuln | grep -q ":$1"
}

free_port() {
    local port="$1"
    print_warning "Freeing port $port..."
    local pids=$(fuser ":$port" 2>/dev/null | awk '{print $NF}')
    [ -n "$pids" ] && kill -9 $pids 2>/dev/null
    
    local screen_server="blockheads_server_$port"
    local screen_bot="blockheads_bot_$port"
    local screen_anticheat="blockheads_anticheat_$port"
    
    if screen_session_exists "$screen_server"; then
        screen -S "$screen_server" -X quit 2>/dev/null
    fi
    
    if screen_session_exists "$screen_bot"; then
        screen -S "$screen_bot" -X quit 2>/dev/null
    fi
    
    if screen_session_exists "$screen_anticheat"; then
        screen -S "$screen_anticheat" -X quit 2>/dev/null
    fi
    
    sleep 2
    ! is_port_in_use "$port"
}

check_world_exists() {
    local world_id="$1"
    local saves_dir="$HOME/GNUstep/Library/ApplicationSupport/TheBlockheads/saves"
    [ -d "$saves_dir/$world_id" ] || {
        print_error "World '$world_id' does not exist in: $saves_dir/"
        echo ""
        print_warning "To create a world, run: ${GREEN}./blockheads_server171 -n${NC}"
        print_warning "After creating the world, press ${YELLOW}CTRL+C${NC} to exit"
        print_warning "and then start the server with: ${GREEN}$0 start $world_id $port${NC}"
        return 1
    }
    return 0
}

start_server() {
    local world_id="$1"
    local port="${2:-$DEFAULT_PORT}"

    # Define screen names with port
    local SCREEN_SERVER="blockheads_server_$port"
    local SCREEN_BOT="blockheads_bot_$port"
    local SCREEN_ANTICHEAT="blockheads_anticheat_$port"

    # Verify server binary exists
    if [ ! -f "$SERVER_BINARY" ]; then
        print_error "Server binary not found: $SERVER_BINARY"
        print_warning "Run the installer first: ${GREEN}./installer.sh${NC}"
        return 1
    fi

    # Verify world exists
    if ! check_world_exists "$world_id"; then
        return 1
    fi

    # Check if port is in use
    if is_port_in_use "$port"; then
        print_warning "Port $port is in use."
        if ! free_port "$port"; then
            print_error "Could not free port $port"
            print_warning "Use a different port or terminate the process using it"
            return 1
        fi
    fi

    # Clean up previous sessions
    if screen_session_exists "$SCREEN_SERVER"; then
        screen -S "$SCREEN_SERVER" -X quit 2>/dev/null
    fi
    
    if screen_session_exists "$SCREEN_BOT"; then
        screen -S "$SCREEN_BOT" -X quit 2>/dev/null
    fi
    
    if screen_session_exists "$SCREEN_ANTICHEAT"; then
        screen -S "$SCREEN_ANTICHEAT" -X quit 2>/dev/null
    fi
    
    sleep 1

    local log_dir="$HOME/GNUstep/Library/ApplicationSupport/TheBlockheads/saves/$world_id"
    local log_file="$log_dir/console.log"
    mkdir -p "$log_dir"

    print_step "Starting server - World: $world_id, Port: $port"
    echo "$world_id" > "world_id_$port.txt"

    # Start server
    screen -dmS "$SCREEN_SERVER" bash -c "
        cd '$PWD'
        while true; do
            echo \"[\$(date '+%Y-%m-%d %H:%M:%S')] Starting server...\"
            if ./blockheads_server171 -o '$world_id' -p $port 2>&1 | tee -a '$log_file'; then
                echo \"[\$(date '+%Y-%m-%d %H:%M:%S')] Server closed normally\"
            else
                exit_code=\$?
                echo \"[\$(date '+%Y-%m-%d %H:%M:%S')] Server failed with code: \$exit_code\"
                if [ \$exit_code -eq 1 ] && tail -n 5 '$log_file' | grep -q \"port.*already in use\"; then
                    echo \"[\$(date '+%Y-%m-%d %H:%M:%S')] ERROR: Port already in use. Will not retry.\"
                    break
                fi
            fi
            echo \"[\$(date '+%Y-%m-%d %H:%M:%S')] Restarting in 5 seconds...\"
            sleep 5
        done
    "

    # Wait for server to start
    print_step "Waiting for server to start..."
    local wait_time=0
    while [ ! -f "$log_file" ] && [ $wait_time -lt 15 ]; do
        sleep 1
        ((wait_time++))
    done

    if [ ! -f "$log_file" ]; then
        print_error "Could not create log file. Server may not have started."
        return 1
    fi

    # Wait for server to be ready
    local server_ready=false
    for i in {1..30}; do
        if grep -q "World load complete\|Server started\|Ready for connections\|using seed:\|save delay:" "$log_file"; then
            server_ready=true
            break
        fi
        sleep 1
    done

    if [ "$server_ready" = false ]; then
        print_warning "Server did not show complete startup messages, but continuing..."
        if screen_session_exists "$SCREEN_SERVER"; then
            print_success "Server screen session is active. Continuing..."
        else
            print_error "Server screen session not found. Server may have failed to start."
            return 1
        fi
    else
        print_success "Server started successfully!"
    fi

    # Start bot
    print_step "Starting server bot..."
    screen -dmS "$SCREEN_BOT" bash -c "
        cd '$PWD'
        echo 'Starting server bot for port $port...'
        ./server_bot.sh '$log_file' '$port'
    "

    # Start anticheat
    print_step "Starting anticheat security system..."
    screen -dmS "$SCREEN_ANTICHEAT" bash -c "
        cd '$PWD'
        echo 'Starting anticheat for port $port...'
        ./anticheat_secure.sh '$log_file' '$port'
    "

    # Verify all processes started correctly
    local server_started=0
    local bot_started=0
    local anticheat_started=0
    
    if screen_session_exists "$SCREEN_SERVER"; then
        server_started=1
    fi
    
    if screen_session_exists "$SCREEN_BOT"; then
        bot_started=1
    fi
    
    if screen_session_exists "$SCREEN_ANTICHEAT"; then
        anticheat_started=1
    fi
    
    if [ "$server_started" -eq 1 ] && [ "$bot_started" -eq 1 ] && [ "$anticheat_started" -eq 1 ]; then
        print_header "SERVER, BOT AND ANTICHEAT STARTED SUCCESSFULLY!"
        print_success "World: $world_id"
        print_success "Port: $port"
        echo ""
        print_status "To view server console: ${CYAN}screen -r $SCREEN_SERVER${NC}"
        print_status "To view bot: ${CYAN}screen -r $SCREEN_BOT${NC}"
        print_status "To view anticheat: ${CYAN}screen -r $SCREEN_ANTICHEAT${NC}"
        echo ""
        print_warning "To exit console without stopping server: ${YELLOW}CTRL+A, D${NC}"
        print_header "SERVER IS NOW RUNNING"
    else
        print_warning "Could not verify all screen sessions"
        print_status "Server started: $server_started, Bot started: $bot_started, Anticheat started: $anticheat_started"
        print_warning "Use 'screen -list' to view active sessions"
    fi
}

stop_server() {
    local port="$1"
    
    if [ -z "$port" ]; then
        print_step "Stopping all servers, bots and anticheat..."
        
        # Stop all servers
        for server_session in $(screen -list | grep "blockheads_server_" | awk '{print $1}'); do
            screen -S "${server_session}" -X quit 2>/dev/null
            print_success "Stopped server: ${server_session}"
        done
        
        # Stop all bots
        for bot_session in $(screen -list | grep "blockheads_bot_" | awk '{print $1}'); do
            screen -S "${bot_session}" -X quit 2>/dev/null
            print_success "Stopped bot: ${bot_session}"
        done
        
        # Stop all anticheat
        for anticheat_session in $(screen -list | grep "blockheads_anticheat_" | awk '{print $1}'); do
            screen -S "${anticheat_session}" -X quit 2>/dev/null
            print_success "Stopped anticheat: ${anticheat_session}"
        done
        
        pkill -f "$SERVER_BINARY" 2>/dev/null || true
        print_success "Cleanup completed for all servers."
    else
        print_step "Stopping server, bot and anticheat on port $port..."
        
        local screen_server="blockheads_server_$port"
        local screen_bot="blockheads_bot_$port"
        local screen_anticheat="blockheads_anticheat_$port"
        
        if screen_session_exists "$screen_server"; then
            screen -S "$screen_server" -X quit 2>/dev/null
            print_success "Server stopped on port $port."
        else
            print_warning "Server was not running on port $port."
        fi
        
        if screen_session_exists "$screen_bot"; then
            screen -S "$screen_bot" -X quit 2>/dev/null
            print_success "Bot stopped on port $port."
        else
            print_warning "Bot was not running on port $port."
        fi
        
        if screen_session_exists "$screen_anticheat"; then
            screen -S "$screen_anticheat" -X quit 2>/dev/null
            print_success "Anticheat stopped on port $port."
        else
            print_warning "Anticheat was not running on port $port."
        fi
        
        pkill -f "$SERVER_BINARY.*$port" 2>/dev/null || true
        print_success "Cleanup completed for port $port."
    fi
}

list_servers() {
    print_header "LIST OF RUNNING SERVERS"
    
    local servers=$(screen -list | grep "blockheads_server_" | awk '{print $1}' | sed 's/\.blockheads_server_/ - Port: /')
    
    if [ -z "$servers" ]; then
        print_warning "No servers are currently running."
    else
        print_status "Running servers:"
        while IFS= read -r server; do
            print_status "  $server"
        done <<< "$servers"
    fi
    
    print_header "END OF LIST"
}

show_status() {
    local port="$1"
    
    if [ -z "$port" ]; then
        print_header "THE BLOCKHEADS SERVER STATUS - ALL SERVERS"
        
        # Check all servers
        local servers=$(screen -list | grep "blockheads_server_" | awk '{print $1}' | sed 's/\.blockheads_server_//')
        
        if [ -z "$servers" ]; then
            print_error "No servers are currently running."
        else
            while IFS= read -r server_port; do
                if screen_session_exists "blockheads_server_$server_port"; then
                    print_success "Server on port $server_port: RUNNING"
                else
                    print_error "Server on port $server_port: STOPPED"
                fi
                
                if screen_session_exists "blockheads_bot_$server_port"; then
                    print_success "Bot on port $server_port: RUNNING"
                else
                    print_error "Bot on port $server_port: STOPPED"
                fi
                
                if screen_session_exists "blockheads_anticheat_$server_port"; then
                    print_success "Anticheat on port $server_port: RUNNING"
                else
                    print_error "Anticheat on port $server_port: STOPPED"
                fi
                
                # Show world info if exists
                if [ -f "world_id_$server_port.txt" ]; then
                    local WORLD_ID=$(cat "world_id_$server_port.txt" 2>/dev/null)
                    print_status "World for port $server_port: ${CYAN}$WORLD_ID${NC}"
                fi
                
                echo ""
            done <<< "$servers"
        fi
    else
        print_header "THE BLOCKHEADS SERVER STATUS - PORT $port"
        
        # Check specific server
        if screen_session_exists "blockheads_server_$port"; then
            print_success "Server: RUNNING"
        else
            print_error "Server: STOPPED"
        fi
        
        # Check bot
        if screen_session_exists "blockheads_bot_$port"; then
            print_success "Bot: RUNNING"
        else
            print_error "Bot: STOPPED"
        fi
        
        # Check anticheat
        if screen_session_exists "blockheads_anticheat_$port"; then
            print_success "Anticheat: RUNNING"
        else
            print_error "Anticheat: STOPPED"
        fi
        
        # Show world info if exists
        if [ -f "world_id_$port.txt" ]; then
            local WORLD_ID=$(cat "world_id_$port.txt" 2>/dev/null)
            print_status "Current world: ${CYAN}$WORLD_ID${NC}"
            
            # Show port if server is running
            if screen_session_exists "blockheads_server_$port"; then
                print_status "To view console: ${CYAN}screen -r blockheads_server_$port${NC}"
                print_status "To view bot: ${CYAN}screen -r blockheads_bot_$port${NC}"
                print_status "To view anticheat: ${CYAN}screen -r blockheads_anticheat_$port${NC}"
            fi
        else
            print_warning "World: Not configured for port $port (run 'start' first)"
        fi
    fi
    
    print_header "END OF STATUS"
}

# Command handling
case "$1" in
    start)
        if [ -z "$2" ]; then
            print_error "You must specify a WORLD_NAME"
            show_usage
            exit 1
        fi
        start_server "$2" "$3"
        ;;
    stop)
        stop_server "$2"
        ;;
    status)
        show_status "$2"
        ;;
    list)
        list_servers
        ;;
    help|--help|-h|*)
        show_usage
        ;;
esac
EOF

# Create server_bot.sh
cat > server_bot.sh << 'EOF'
#!/bin/bash

# Enhanced Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Function to print status messages
print_status() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_header() {
    echo -e "${PURPLE}================================================================"
    echo -e "$1"
    echo -e "===============================================================${NC}"
}
print_step() { echo -e "${CYAN}[STEP]${NC} $1"; }

# Function to validate player names
is_valid_player_name() {
    local player_name="$1"
    [[ "$player_name" =~ ^[a-zA-Z0-9_]+$ ]}
}

# Bot configuration - now supports multiple servers
if [ $# -ge 2 ]; then
    PORT="$2"
    LOG_DIR=$(dirname "$1")
    ECONOMY_FILE="$LOG_DIR/economy_data_$PORT.json"
    SCREEN_SERVER="blockheads_server_$PORT"
else
    LOG_DIR=$(dirname "$1")
    ECONOMY_FILE="$LOG_DIR/economy_data.json"
    SCREEN_SERVER="blockheads_server"
fi

# Authorization files
AUTHORIZED_ADMINS_FILE="$LOG_DIR/authorized_admins.txt"
AUTHORIZED_MODS_FILE="$LOG_DIR/authorized_mods.txt"

# Function to add player to authorized list
add_to_authorized() {
    local player_name="$1" list_type="$2"
    local auth_file="$LOG_DIR/authorized_${list_type}s.txt"
    
    [ ! -f "$auth_file" ] && print_error "Authorization file not found: $auth_file" && return 1
    
    if ! grep -q -i "^$player_name$" "$auth_file"; then
        echo "$player_name" >> "$auth_file"
        print_success "Added $player_name to authorized ${list_type}s"
        return 0
    else
        print_warning "$player_name is already in authorized ${list_type}s"
        return 1
    fi
}

initialize_economy() {
    [ ! -f "$ECONOMY_FILE" ] && echo '{"players": {}, "transactions": []}' > "$ECONOMY_FILE" &&
    print_success "Economy data file created: $ECONOMY_FILE"
}

is_player_in_list() {
    local player_name="$1" list_type="$2"
    local list_file="$LOG_DIR/${list_type}list.txt"
    
    [ -f "$list_file" ] && grep -v "^[[:space:]]*#" "$list_file" | grep -q -i "^$player_name$" && return 0
    return 1
}

add_player_if_new() {
    local player_name="$1"
    local current_data=$(cat "$ECONOMY_FILE" 2>/dev/null || echo '{}')
    local player_exists=$(echo "$current_data" | grep -q "\"$player_name\"" && echo true || echo false)
    
    if [ "$player_exists" = "false" ]; then
        current_data=$(echo "$current_data" | sed "s/\"players\": {}/\"players\": {\"$player_name\": {\"tickets\": 0, \"last_login\": 0, \"last_welcome_time\": 0, \"last_help_time\": 0, \"last_greeting_time\": 0, \"purchases\": []}}}/")
        echo "$current_data" > "$ECONOMY_FILE"
        print_success "Added new player: $player_name"
        give_first_time_bonus "$player_name"
        return 0
    fi
    return 1
}

give_first_time_bonus() {
    local player_name="$1" current_time=$(date +%s) time_str="$(date '+%Y-%m-%d %H:%M:%S')"
    local current_data=$(cat "$ECONOMY_FILE")
    current_data=$(echo "$current_data" | sed "s/\"$player_name\": {\"tickets\": [0-9]*/\"$player_name\": {\"tickets\": 1/")
    current_data=$(echo "$current_data" | sed "s/\"last_login\": [0-9]*/\"last_login\": $current_time/")
    current_data=$(echo "$current_data" | sed "s/\"transactions\": \[\]/\"transactions\": [{\"player\": \"$player_name\", \"type\": \"welcome_bonus\", \"tickets\": 1, \"time\": \"$time_str\"}]/")
    echo "$current_data" > "$ECONOMY_FILE"
    print_success "Gave first-time bonus to $player_name"
}

grant_login_ticket() {
    local player_name="$1" current_time=$(date +%s) time_str="$(date '+%Y-%m-%d %H:%M:%S')"
    local current_data=$(cat "$ECONOMY_FILE")
    local last_login=$(echo "$current_data" | grep -o "\"last_login\": [0-9]*" | grep -o "[0-9]*" | tail -1)
    last_login=${last_login:-0}
    
    if [ "$last_login" -eq 0 ] || [ $((current_time - last_login)) -ge 3600 ]; then
        local current_tickets=$(echo "$current_data" | grep -o "\"tickets\": [0-9]*" | grep -o "[0-9]*" | tail -1)
        current_tickets=${current_tickets:-0}
        local new_tickets=$((current_tickets + 1))
        
        current_data=$(echo "$current_data" | sed "s/\"tickets\": $current_tickets/\"tickets\": $new_tickets/")
        current_data=$(echo "$current_data" | sed "s/\"last_login\": $last_login/\"last_login\": $current_time/")
        current_data=$(echo "$current_data" | sed "s/\"transactions\": \[/\"transactions\": [{\"player\": \"$player_name\", \"type\": \"login_bonus\", \"tickets\": 1, \"time\": \"$time_str\"},/")
        
        echo "$current_data" > "$ECONOMY_FILE"
        print_success "Granted 1 ticket to $player_name for logging in (Total: $new_tickets)"
    else
        local next_login=$((last_login + 3600))
        local time_left=$((next_login - current_time))
        print_warning "$player_name must wait $((time_left / 60)) minutes for next ticket"
    fi
}

show_welcome_message() {
    local player_name="$1" is_new_player="$2" force_send="${3:-0}"
    local current_time=$(date +%s)
    local current_data=$(cat "$ECONOMY_FILE")
    local last_welcome_time=$(echo "$current_data" | grep -o "\"last_welcome_time\": [0-9]*" | grep -o "[0-9]*" | tail -1)
    last_welcome_time=${last_welcome_time:-0}
    
    if [ "$force_send" -eq 1 ] || [ "$last_welcome_time" -eq 0 ] || [ $((current_time - last_welcome_time)) -ge 180 ]; then
        if [ "$is_new_player" = "true" ]; then
            send_server_command "Hello $player_name! Welcome to the server. Type !help to check available commands."
        else
            local last_greeting_time=$(echo "$current_data" | grep -o "\"last_greeting_time\": [0-9]*" | grep -o "[0-9]*" | tail -1)
            if [ $((current_time - last_greeting_time)) -ge 600 ]; then
                send_server_command "Welcome back $player_name! Type !help to see available commands."
                current_data=$(echo "$current_data" | sed "s/\"last_greeting_time\": [0-9]*/\"last_greeting_time\": $current_time/")
                echo "$current_data" > "$ECONOMY_FILE"
            fi
        fi
        current_data=$(echo "$current_data" | sed "s/\"last_welcome_time\": [0-9]*/\"last_welcome_time\": $current_time/")
        echo "$current_data" > "$ECONOMY_FILE"
    else
        print_warning "Skipping welcome for $player_name due to cooldown"
    fi
}

send_server_command() {
    if screen -S "$SCREEN_SERVER" -X stuff "$1$(printf \\r)" 2>/dev/null; then
        print_success "Sent message to server: $1"
    else
        print_error "Could not send message to server. Is the server running?"
    fi
}

has_purchased() {
    local player_name="$1" item="$2"
    local current_data=$(cat "$ECONOMY_FILE")
    echo "$current_data" | grep -q "\"$item\"" && return 0 || return 1
}

add_purchase() {
    local player_name="$1" item="$2"
    local current_data=$(cat "$ECONOMY_FILE")
    current_data=$(echo "$current_data" | sed "s/\"purchases\": \[/\"purchases\": [\"$item\",/")
    echo "$current_data" > "$ECONOMY_FILE"
}

# Function to process give_rank commands
process_give_rank() {
    local giver_name="$1" target_player="$2" rank_type="$3"
    local current_data=$(cat "$ECONOMY_FILE")
    local giver_tickets=$(echo "$current_data" | grep -o "\"tickets\": [0-9]*" | grep -o "[0-9]*" | tail -1)
    giver_tickets=${giver_tickets:-0}
    
    local cost=0
    [ "$rank_type" = "admin" ] && cost=140
    [ "$rank_type" = "mod" ] && cost=70
    
    if [ "$giver_tickets" -lt "$cost" ]; then
        send_server_command "$giver_name, you need $cost tickets to give $rank_type rank, but you only have $giver_tickets."
        return 1
    fi
    
    # Validate target player name
    if ! is_valid_player_name "$target_player"; then
        send_server_command "$giver_name, invalid player name: $target_player"
        return 1
    fi
    
    # Deduct tickets from giver
    local new_tickets=$((giver_tickets - cost))
    current_data=$(echo "$current_data" | sed "s/\"tickets\": $giver_tickets/\"tickets\": $new_tickets/")
    
    # Record transaction
    local time_str="$(date '+%Y-%m-%d %H:%M:%S')"
    current_data=$(echo "$current_data" | sed "s/\"transactions\": \[/\"transactions\": [{\"giver\": \"$giver_name\", \"recipient\": \"$target_player\", \"type\": \"rank_gift\", \"rank\": \"$rank_type\", \"tickets\": -$cost, \"time\": \"$time_str\"},/")
    
    echo "$current_data" > "$ECONOMY_FILE"
    
    # Add to authorized list and assign rank
    add_to_authorized "$target_player" "$rank_type"
    screen -S "$SCREEN_SERVER" -X stuff "/$rank_type $target_player$(printf \\r)"
    
    send_server_command "Congratulations! $giver_name has gifted $rank_type rank to $target_player for $cost tickets."
    send_server_command "$giver_name, your new ticket balance: $new_tickets"
    return 0
}

process_message() {
    local player_name="$1" message="$2"
    local current_data=$(cat "$ECONOMY_FILE")
    local player_tickets=$(echo "$current_data" | grep -o "\"tickets\": [0-9]*" | grep -o "[0-9]*" | tail -1)
    player_tickets=${player_tickets:-0}
    
    case "$message" in
        "hi"|"hello"|"Hi"|"Hello"|"hola"|"Hola")
            local current_time=$(date +%s)
            local last_greeting_time=$(echo "$current_data" | grep -o "\"last_greeting_time\": [0-9]*" | grep -o "[0-9]*" | tail -1)
            
            # 10-minute cooldown for greetings
            if [ "$last_greeting_time" -eq 0 ] || [ $((current_time - last_greeting_time)) -ge 600 ]; then
                send_server_command "Hello $player_name! Welcome to the server. Type !help to check available commands."
                current_data=$(echo "$current_data" | sed "s/\"last_greeting_time\": [0-9]*/\"last_greeting_time\": $current_time/")
                echo "$current_data" > "$ECONOMY_FILE"
            else
                print_warning "Skipping greeting for $player_name due to cooldown"
            fi
            ;;
        "!tickets")
            send_server_command "$player_name, you have $player_tickets tickets."
            ;;
        "!buy_mod")
            if has_purchased "$player_name" "mod" || is_player_in_list "$player_name" "mod"; then
                send_server_command "$player_name, you already have MOD rank. No need to purchase again."
            elif [ "$player_tickets" -ge 50 ]; then
                local new_tickets=$((player_tickets - 50))
                current_data=$(echo "$current_data" | sed "s/\"tickets\": $player_tickets/\"tickets\": $new_tickets/")
                add_purchase "$player_name" "mod"
                local time_str="$(date '+%Y-%m-%d %H:%M:%S')"
                current_data=$(echo "$current_data" | sed "s/\"transactions\": \[/\"transactions\": [{\"player\": \"$player_name\", \"type\": \"purchase\", \"item\": \"mod\", \"tickets\": -50, \"time\": \"$time_str\"},/")
                echo "$current_data" > "$ECONOMY_FILE"
                
                # First add to authorized mods, then assign rank
                add_to_authorized "$player_name" "mod"
                screen -S "$SCREEN_SERVER" -X stuff "/mod $player_name$(printf \\r)"
                send_server_command "Congratulations $player_name! You have been promoted to MOD for 50 tickets. Remaining tickets: $new_tickets"
            else
                send_server_command "$player_name, you need $((50 - player_tickets)) more tickets to buy MOD rank."
            fi
            ;;
        "!buy_admin")
            if has_purchased "$player_name" "admin" || is_player_in_list "$player_name" "admin"; then
                send_server_command "$player_name, you already have ADMIN rank. No need to purchase again."
            elif [ "$player_tickets" -ge 100 ]; then
                local new_tickets=$((player_tickets - 100))
                current_data=$(echo "$current_data" | sed "s/\"tickets\": $player_tickets/\"tickets\": $new_tickets/")
                add_purchase "$player_name" "admin"
                local time_str="$(date '+%Y-%m-%d %H:%M:%S')"
                current_data=$(echo "$current_data" | sed "s/\"transactions\": \[/\"transactions\": [{\"player\": \"$player_name\", \"type\": \"purchase\", \"item\": \"admin\", \"tickets\": -100, \"time\": \"$time_str\"},/")
                echo "$current_data" > "$ECONOMY_FILE"
                
                # First add to authorized admins, then assign rank
                add_to_authorized "$player_name" "admin"
                screen -S "$SCREEN_SERVER" -X stuff "/admin $player_name$(printf \\r)"
                send_server_command "Congratulations $player_name! You have been promoted to ADMIN for 100 tickets. Remaining tickets: $new_tickets"
            else
                send_server_command "$player_name, you need $((100 - player_tickets)) more tickets to buy ADMIN rank."
            fi
            ;;
        "!give_admin "*)
            if [[ "$message" =~ !give_admin\ ([a-zA-Z0-9_]+) ]]; then
                local target_player="${BASH_REMATCH[1]}"
                process_give_rank "$player_name" "$target_player" "admin"
            else
                send_server_command "Usage: !give_admin PLAYER_NAME"
            fi
            ;;
        "!give_mod "*)
            if [[ "$message" =~ !give_mod\ ([a-zA-Z0-9_]+) ]]; then
                local target_player="${BASH_REMATCH[1]}"
                process_give_rank "$player_name" "$target_player" "mod"
            else
                send_server_command "Usage: !give_mod PLAYER_NAME"
            fi
            ;;
        "!set_admin"|"!set_mod")
            send_server_command "$player_name, these commands are only available to server console operators."
            ;;
        "!help")
            send_server_command "Available commands:"
            send_server_command "!tickets - Check your tickets"
            send_server_command "!buy_mod - Buy MOD rank for 50 tickets"
            send_server_command "!buy_admin - Buy ADMIN rank for 100 tickets"
            send_server_command "!give_mod PLAYER - Gift MOD rank (70 tickets)"
            send_server_command "!give_admin PLAYER - Gift ADMIN rank (140 tickets)"
            ;;
    esac
}

process_admin_command() {
    local command="$1" current_data=$(cat "$ECONOMY_FILE")
    
    if [[ "$command" =~ ^!send_ticket\ ([a-zA-Z0-9_]+)\ ([0-9]+)$ ]]; then
        local player_name="${BASH_REMATCH[1]}" tickets_to_add="${BASH_REMATCH[2]}"
        
        # Validate player name
        if ! is_valid_player_name "$player_name"; then
            print_error "Invalid player name: $player_name"
            return 1
        fi
        
        # Validate ticket amount
        if [[ ! "$tickets_to_add" =~ ^[0-9]+$ ]] || [ "$tickets_to_add" -le 0 ]; then
            print_error "Invalid ticket amount: $tickets_to_add"
            return 1
        fi
        
        local player_exists=$(echo "$current_data" | grep -q "\"$player_name\"" && echo true || echo false)
        [ "$player_exists" = "false" ] && print_error "Player $player_name not found in economy system" && return 1
        
        local current_tickets=$(echo "$current_data" | grep -o "\"tickets\": [0-9]*" | grep -o "[0-9]*" | tail -1)
        current_tickets=${current_tickets:-0}
        local new_tickets=$((current_tickets + tickets_to_add))
        
        current_data=$(echo "$current_data" | sed "s/\"tickets\": $current_tickets/\"tickets\": $new_tickets/")
        current_data=$(echo "$current_data" | sed "s/\"transactions\": \[/\"transactions\": [{\"player\": \"$player_name\", \"type\": \"admin_gift\", \"tickets\": $tickets_to_add, \"time\": \"$(date '+%Y-%m-%d %H:%M:%S')\"},/")
        
        echo "$current_data" > "$ECONOMY_FILE"
        print_success "Added $tickets_to_add tickets to $player_name (Total: $new_tickets)"
        send_server_command "$player_name received $tickets_to_add tickets from admin! Total: $new_tickets"
    elif [[ "$command" =~ ^!set_mod\ ([a-zA-Z0-9_]+)$ ]]; then
        local player_name="${BASH_REMATCH[1]}"
        
        # Validate player name
        if ! is_valid_player_name "$player_name"; then
            print_error "Invalid player name: $player_name"
            return 1
        fi
        
        print_success "Setting $player_name as MOD"
        # First add to authorized mods, then assign rank
        add_to_authorized "$player_name" "mod"
        screen -S "$SCREEN_SERVER" -X stuff "/mod $player_name$(printf \\r)"
        send_server_command "$player_name has been set as MOD by server console!"
    elif [[ "$command" =~ ^!set_admin\ ([a-zA-Z0-9_]+)$ ]]; then
        local player_name="${BASH_REMATCH[1]}"
        
        # Validate player name
        if ! is_valid_player_name "$player_name"; then
            print_error "Invalid player name: $player_name"
            return 1
        fi
        
        print_success "Setting $player_name as ADMIN"
        # First add to authorized admins, then assign rank
        add_to_authorized "$player_name" "admin"
        screen -S "$SCREEN_SERVER" -X stuff "/admin $player_name$(printf \\r)"
        send_server_command "$player_name has been set as ADMIN by server console!"
    else
        print_error "Unknown admin command: $command"
        print_status "Available admin commands:"
        echo -e "!send_ticket <player> <amount>"
        echo -e "!set_mod <player> (console only)"
        echo -e "!set_admin <player> (console only)"
    fi
}

server_sent_welcome_recently() {
    local player_name="$1"
    [ -z "$LOG_FILE" ] || [ ! -f "$LOG_FILE" ] && return 1
    local player_lc=$(echo "$player_name" | tr '[:upper:]' '[:lower:]')
    
    # Check for server welcome messages in the last 100 lines
    if tail -n 100 "$LOG_FILE" 2>/dev/null | grep -i "server:.*welcome.*$player_lc" | head -1 | grep -q .; then
        return 0
    fi
    
    # Check economy data for last welcome time
    local current_time=$(date +%s)
    local current_data=$(cat "$ECONOMY_FILE")
    local last_welcome_time=$(echo "$current_data" | grep -o "\"last_welcome_time\": [0-9]*" | grep -o "[0-9]*" | tail -1)
    
    # If we have welcomed in the last 30 seconds, then return true (already welcomed)
    if [ "$last_welcome_time" -gt 0 ] && [ $((current_time - last_welcome_time)) -le 30 ]; then
        return 0
    fi
    
    return 1
}

filter_server_log() {
    while read line; do
        [[ "$line" == *"Server closed"* || "$line" == *"Starting server"* || \
          ("$line" == *"SERVER: say"* && "$line" == *"Welcome"*) || \
          "$line" == *"adminlist.txt"* || "$line" == *"modlist.txt"* ]] && continue
        echo "$line"
    done
}

# Cleanup function for signal handling
cleanup() {
    print_status "Cleaning up..."
    rm -f "$admin_pipe" 2>/dev/null
    # Kill background processes
    kill $(jobs -p) 2>/dev/null
    print_status "Cleanup done."
    exit 0
}

monitor_log() {
    local log_file="$1"
    LOG_FILE="$log_file"

    initialize_economy

    # Set up signal handling
    trap cleanup EXIT INT TERM

    print_header "STARTING ECONOMY BOT"
    print_status "Monitoring: $log_file"
    print_status "Bot commands: !tickets, !buy_mod, !buy_admin, !give_mod, !give_admin, !help"
    print_status "Admin commands: !send_ticket <player> <amount>, !set_mod <player>, !set_admin <player>"
    print_header "IMPORTANT: Admin commands must be typed in THIS terminal, NOT in the game chat!"
    print_status "Type admin commands below and press Enter:"
    print_header "READY FOR COMMANDS"

    local admin_pipe="/tmp/blockheads_admin_pipe_$$"
    rm -f "$admin_pipe"
    mkfifo "$admin_pipe"

    # Background process to read admin commands from the pipe
    while read -r admin_command < "$admin_pipe"; do
        print_status "Processing admin command: $admin_command"
        if [[ "$admin_command" == "!send_ticket "* || "$admin_command" == "!set_mod "* || "$admin_command" == "!set_admin "* ]]; then
            process_admin_command "$admin_command"
        else
            print_error "Unknown admin command. Use: !send_ticket <player> <amount>, !set_mod <player>, or !set_admin <player>"
        fi
        print_header "READY FOR NEXT COMMAND"
    done &

    # Forward stdin to the admin pipe
    while read -r admin_command; do
        echo "$admin_command" > "$admin_pipe"
    done &

    declare -A welcome_shown

    # Monitor the log file
    tail -n 0 -F "$log_file" | filter_server_log | while read line; do
        # Detect player connections
        if [[ "$line" =~ Player\ Connected\ ([a-zA-Z0-9_]+)\ \|\ ([0-9a-fA-F.:]+) ]]; then
            local player_name="${BASH_REMATCH[1]}" player_ip="${BASH_REMATCH[2]}"
            [ "$player_name" == "SERVER" ] && continue

            # Validate player name
            if ! is_valid_player_name "$player_name"; then
                print_warning "Invalid player name detected: $player_name"
                continue
            fi

            print_success "Player connected: $player_name (IP: $player_ip)"

            # Extract timestamp
            ts_str=$(echo "$line" | awk '{print $1" "$2}')
            ts_no_ms=${ts_str%.*}
            conn_epoch=$(date -d "$ts_no_ms" +%s 2>/dev/null || echo 0)

            local is_new_player="false"
            add_player_if_new "$player_name" && is_new_player="true"

            sleep 3

            if ! server_sent_welcome_recently "$player_name"; then
                show_welcome_message "$player_name" "$is_new_player" 1
            else
                print_warning "Server already welcomed $player_name"
            fi

            [ "$is_new_player" = "false" ] && grant_login_ticket "$player_name"
            continue
        fi

        if [[ "$line" =~ Player\ Disconnected\ ([a-zA-Z0-9_]+) ]]; then
            local player_name="${BASH_REMATCH[1]}"
            [ "$player_name" == "SERVER" ] && continue
            
            # Validate player name
            if ! is_valid_player_name "$player_name"; then
                print_warning "Invalid player name detected: $player_name"
                continue
            fi
            
            print_warning "Player disconnected: $player_name"
            unset welcome_shown["$player_name"]
            continue
        fi

        if [[ "$line" =~ ([a-zA-Z0-9_]+):\ (.+)$ ]]; then
            local player_name="${BASH_REMATCH[1]}" message="${BASH_REMATCH[2]}"
            [ "$player_name" == "SERVER" ] && continue
            
            # Validate player name
            if ! is_valid_player_name "$player_name"; then
                print_warning "Invalid player name detected: $player_name"
                continue
            fi
            
            print_status "Chat: $player_name: $message"
            add_player_if_new "$player_name"
            process_message "$player_name" "$message"
            continue
        fi

        print_status "Other log line: $line"
    done

    wait
    rm -f "$admin_pipe"
}

if [ $# -eq 1 ] || [ $# -eq 2 ]; then
    initialize_economy
    monitor_log "$1"
else
    print_error "Usage: $0 <server_log_file> [port]"
    exit 1
fi
EOF

# Create anticheat_secure.sh
cat > anticheat_secure.sh << 'EOF'
#!/bin/bash
# anticheat_secure.sh - Enhanced security system for The Blockheads server

# Enhanced Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Function to print status messages
print_status() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_header() {
    echo -e "${PURPLE}================================================================"
    echo -e "$1"
    echo -e "===============================================================${NC}"
}

# Configuration
LOG_FILE="$1"
PORT="$2"
LOG_DIR=$(dirname "$LOG_FILE")
ADMIN_OFFENSES_FILE="$LOG_DIR/admin_offenses_$PORT.json"
AUTHORIZED_ADMINS_FILE="$LOG_DIR/authorized_admins.txt"
AUTHORIZED_MODS_FILE="$LOG_DIR/authorized_mods.txt"
SCREEN_SERVER="blockheads_server_$PORT"

# Security monitoring variables
SECURITY_LOG="$LOG_DIR/security_incidents.log"
CONNECTION_THRESHOLD=10  # Max connections per minute from single IP
CONNECTION_TRACKER="$LOG_DIR/connection_tracker.json"

# Function to validate player names
is_valid_player_name() {
    local player_name="$1"
    [[ "$player_name" =~ ^[a-zA-Z0-9_]+$ ]]
}

# Function to safely read JSON files
read_json_file() {
    local file_path="$1"
    if [ ! -f "$file_path" ]; then
        print_error "JSON file not found: $file_path"
        echo "{}"
        return 1
    fi
    
    cat "$file_path"
}

# Function to safely write JSON files
write_json_file() {
    local file_path="$1"
    local content="$2"
    
    if [ ! -f "$file_path" ]; then
        print_error "JSON file not found: $file_path"
        return 1
    fi
    
    echo "$content" > "$file_path"
    return $?
}

# Function to initialize authorization files
initialize_authorization_files() {
    [ ! -f "$AUTHORIZED_ADMINS_FILE" ] && touch "$AUTHORIZED_ADMINS_FILE" && print_success "Created authorized admins file: $AUTHORIZED_ADMINS_FILE"
    [ ! -f "$AUTHORIZED_MODS_FILE" ] && touch "$AUTHORIZED_MODS_FILE" && print_success "Created authorized mods file: $AUTHORIZED_MODS_FILE"
}

# Function to check and correct admin/mod lists
validate_authorization() {
    local admin_list="$LOG_DIR/adminlist.txt"
    local mod_list="$LOG_DIR/modlist.txt"
    
    # Check adminlist.txt against authorized_admins.txt
    if [ -f "$admin_list" ]; then
        while IFS= read -r admin; do
            if [[ -n "$admin" && ! "$admin" =~ ^[[:space:]]*# && ! "$admin" =~ "Usernames in this file" ]]; then
                if ! grep -q -i "^$admin$" "$AUTHORIZED_ADMINS_FILE"; then
                    print_warning "Unauthorized admin detected: $admin"
                    send_server_command "/unadmin $admin"
                    remove_from_list_file "$admin" "admin"
                    print_success "Removed unauthorized admin: $admin"
                fi
            fi
        done < <(grep -v "^[[:space:]]*#" "$admin_list")
    fi
    
    # Check modlist.txt against authorized_mods.txt
    if [ -f "$mod_list" ]; then
        while IFS= read -r mod; do
            if [[ -n "$mod" && ! "$mod" =~ ^[[:space:]]*# && ! "$mod" =~ "Usernames in this file" ]]; then
                if ! grep -q -i "^$mod$" "$AUTHORIZED_MODS_FILE"; then
                    print_warning "Unauthorized mod detected: $mod"
                    send_server_command "/unmod $mod"
                    remove_from_list_file "$mod" "mod"
                    print_success "Removed unauthorized mod: $mod"
                fi
            fi
        done < <(grep -v "^[[:space:]]*#" "$mod_list")
    fi
}

# Function to add player to authorized list
add_to_authorized() {
    local player_name="$1" list_type="$2"
    local auth_file="$LOG_DIR/authorized_${list_type}s.txt"
    
    [ ! -f "$auth_file" ] && print_error "Authorization file not found: $auth_file" && return 1
    
    if ! grep -q -i "^$player_name$" "$auth_file"; then
        echo "$player_name" >> "$auth_file"
        print_success "Added $player_name to authorized ${list_type}s"
        return 0
    else
        print_warning "$player_name is already in authorized ${list_type}s"
        return 1
    fi
}

# Function to remove player from authorized list
remove_from_authorized() {
    local player_name="$1" list_type="$2"
    local auth_file="$LOG_DIR/authorized_${list_type}s.txt"
    
    [ ! -f "$auth_file" ] && print_error "Authorization file not found: $auth_file" && return 1
    
    # Use case-insensitive deletion with sed
    if grep -q -i "^$player_name$" "$auth_file"; then
        sed -i "/^$player_name$/Id" "$auth_file"
        print_success "Removed $player_name from authorized ${list_type}s"
        return 0
    else
        print_warning "Player $player_name not found in authorized ${list_type}s"
        return 1
    fi
}

# Initialize admin offenses tracking
initialize_admin_offenses() {
    [ ! -f "$ADMIN_OFFENSES_FILE" ] && echo '{}' > "$ADMIN_OFFENSES_FILE" && 
    print_success "Admin offenses tracking file created: $ADMIN_OFFENSES_FILE"
}

# Function to record admin offense
record_admin_offense() {
    local admin_name="$1" current_time=$(date +%s)
    local offenses_data=$(read_json_file "$ADMIN_OFFENSES_FILE" 2>/dev/null || echo '{}')
    local current_offenses=$(echo "$offenses_data" | grep -o "\"$admin_name\".*\"count\": [0-9]*" | grep -o "[0-9]*" | tail -1)
    current_offenses=${current_offenses:-0}
    local last_offense_time=$(echo "$offenses_data" | grep -o "\"$admin_name\".*\"last_offense\": [0-9]*" | grep -o "[0-9]*" | tail -1)
    last_offense_time=${last_offense_time:-0}
    
    [ $((current_time - last_offense_time)) -gt 300 ] && current_offenses=0
    current_offenses=$((current_offenses + 1))
    
    offenses_data=$(echo "$offenses_data" | sed "/\"$admin_name\"/d")
    offenses_data=$(echo "$offenses_data" | sed "s/^{/{/; s/}$//")
    offenses_data=$(echo "$offenses_data" | sed "s/{/{\"$admin_name\": {\"count\": $current_offenses, \"last_offense\": $current_time},/")
    offenses_data=$(echo "$offenses_data" | sed "s/,$//")
    offenses_data=$(echo "$offenses_data" | sed "s/^{$/{\"$admin_name\": {\"count\": $current_offenses, \"last_offense\": $current_time}}/")
    
    write_json_file "$ADMIN_OFFENSES_FILE" "$offenses_data"
    print_warning "Recorded offense #$current_offenses for admin $admin_name"
    return $current_offenses
}

# Function to clear admin offenses
clear_admin_offenses() {
    local admin_name="$1"
    local offenses_data=$(read_json_file "$ADMIN_OFFENSES_FILE" 2>/dev/null || echo '{}')
    offenses_data=$(echo "$offenses_data" | sed "/\"$admin_name\"/d")
    write_json_file "$ADMIN_OFFENSES_FILE" "$offenses_data"
    print_success "Cleared offenses for admin $admin_name"
}

# Function to remove player from list file
remove_from_list_file() {
    local player_name="$1" list_type="$2"
    local list_file="$LOG_DIR/${list_type}list.txt"
    
    [ ! -f "$list_file" ] && print_error "List file not found: $list_file" && return 1
    
    # Use case-insensitive deletion with sed
    if grep -v "^[[:space:]]*#" "$list_file" | grep -q -i "^$player_name$"; then
        sed -i "/^$player_name$/Id" "$list_file"
        print_success "Removed $player_name from ${list_type}list.txt"
        return 0
    else
        print_warning "Player $player_name not found in ${list_type}list.txt"
        return 1
    fi
}

# Function to send delayed unadmin/unmod commands (SILENT VERSION)
send_delayed_uncommands() {
    local target_player="$1" command_type="$2"
    (
        sleep 2; send_server_command_silent "/un${command_type} $target_player"
        sleep 2; send_server_command_silent "/un${command_type} $target_player"
        sleep 1; send_server_command_silent "/un${command_type} $target_player"
        remove_from_list_file "$target_player" "$command_type"
    ) &
}

# Silent version of send_server_command
send_server_command_silent() {
    screen -S "$SCREEN_SERVER" -X stuff "$1$(printf \\r)" 2>/dev/null
}

# Function to send server command
send_server_command() {
    if screen -S "$SCREEN_SERVER" -X stuff "$1$(printf \\r)" 2>/dev/null; then
        print_success "Sent message to server: $1"
    else
        print_error "Could not send message to server. Is the server running?"
    fi
}

# Function to check if player is in list
is_player_in_list() {
    local player_name="$1" list_type="$2"
    local list_file="$LOG_DIR/${list_type}list.txt"
    
    [ -f "$list_file" ] && grep -v "^[[:space:]]*#" "$list_file" | grep -q -i "^$player_name$" && return 0
    return 1
}

# Function to handle unauthorized admin/mod commands
handle_unauthorized_command() {
    local player_name="$1" command="$2" target_player="$3"
    
    if is_player_in_list "$player_name" "admin"; then
        print_error "UNAUTHORIZED COMMAND: Admin $player_name attempted to use $command on $target_player"
        send_server_command "WARNING: Admin $player_name attempted unauthorized rank assignment!"
        
        local command_type=""
        [ "$command" = "/admin" ] && command_type="admin"
        [ "$command" = "/mod" ] && command_type="mod"
        
        if [ -n "$command_type" ]; then
            send_server_command_silent "/un${command_type} $target_player"
            remove_from_list_file "$target_player" "$command_type"
            print_success "Revoked ${command_type} rank from $target_player"
            send_delayed_uncommands "$target_player" "$command_type"
        fi
        
        record_admin_offense "$player_name"
        local offense_count=$?
        
        if [ "$offense_count" -eq 1 ]; then
            send_server_command "$player_name, this is your first warning! Only the server console can assign ranks using !set_admin or !set_mod."
            print_warning "First offense recorded for admin $player_name"
        elif [ "$offense_count" -eq 2 ]; then
            print_warning "SECOND OFFENSE: Admin $player_name is being demoted to mod for unauthorized command usage"
            
            # First add to authorized mods before removing admin privileges
            add_to_authorized "$player_name" "mod"
            
            # Remove from authorized admins
            remove_from_authorized "$player_name" "admin"
            
            # Remove admin privileges
            send_server_command_silent "/unadmin $player_name"
            remove_from_list_file "$player_name" "admin"
            
            # Assign mod rank - ensure the player is added to modlist before sending the command
            send_server_command "/mod $player_name"
            send_server_command "ALERT: Admin $player_name has been demoted to moderator for repeatedly attempting unauthorized admin commands!"
            send_server_command "Only the server console can assign ranks using !set_admin or !set_mod."
            
            # Clear offenses after punishment
            clear_admin_offenses "$player_name"
        fi
    else
        print_warning "Non-admin player $player_name attempted to use $command on $target_player"
        send_server_command "$player_name, you don't have permission to assign ranks."
        
        if [ "$command" = "/admin" ]; then
            send_server_command_silent "/unadmin $target_player"
            remove_from_list_file "$target_player" "admin"
            send_delayed_uncommands "$target_player" "admin"
        elif [ "$command" = "/mod" ]; then
            send_server_command_silent "/unmod $target_player"
            remove_from_list_file "$target_player" "mod"
            send_delayed_uncommands "$target_player" "mod"
        fi
    fi
}

# Function to detect and handle malformed packets
detect_malformed_packets() {
    local line="$1"
    
    # Detect malformed or illegal packets
    if [[ "$line" =~ .*Malformed.* ]] || [[ "$line" =~ .*Illegal.* ]] || [[ "$line" =~ .*Exception.* ]]; then
        local player_name=$(echo "$line" | grep -oE 'Player: [a-zA-Z0-9_]+' | cut -d' ' -f2)
        local ip_address=$(echo "$line" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+')
        
        if [ -n "$player_name" ] && [ -n "$ip_address" ]; then
            print_error "MALFORMED PACKET DETECTED: $player_name ($ip_address)"
            
            # Log security incident
            echo "$(date '+%Y-%m-%d %H:%M:%S') - Malformed packet from $player_name ($ip_address): $line" >> "$SECURITY_LOG"
            
            # Automatic ban for clearly malicious patterns
            if [[ "$line" =~ .*Critical.* ]] || [[ "$line" =~ .*Exploit.* ]] || [[ "$line" =~ .*Buffer.* ]]; then
                send_server_command "/ban $player_name"
                print_success "Player $player_name banned for malicious packet"
            fi
        fi
    fi
}

# Function to track connections and detect DDoS attempts
track_connections() {
    local line="$1"
    
    if [[ "$line" =~ Player\ Connected\ ([a-zA-Z0-9_]+)\ \|\ ([0-9a-fA-F.:]+) ]]; then
        local player_name="${BASH_REMATCH[1]}"
        local ip_address="${BASH_REMATCH[2]}"
        
        # Initialize connection tracker if not exists
        if [ ! -f "$CONNECTION_TRACKER" ]; then
            echo '{}' > "$CONNECTION_TRACKER"
        fi
        
        local current_time=$(date +%s)
        local tracker_data=$(read_json_file "$CONNECTION_TRACKER")
        local ip_connections=$(echo "$tracker_data" | grep -o "\"$ip_address\".*\"count\": [0-9]*" | grep -o "[0-9]*" | tail -1)
        ip_connections=${ip_connections:-0}
        local last_connection=$(echo "$tracker_data" | grep -o "\"$ip_address\".*\"last_connection\": [0-9]*" | grep -o "[0-9]*" | tail -1)
        last_connection=${last_connection:-0}
        
        # Reset count if more than 1 minute has passed
        if [ $((current_time - last_connection)) -gt 60 ]; then
            ip_connections=0
        fi
        
        ip_connections=$((ip_connections + 1))
        
        # Update tracker
        tracker_data=$(echo "$tracker_data" | sed "/\"$ip_address\"/d")
        tracker_data=$(echo "$tracker_data" | sed "s/^{/{/; s/}$//")
        tracker_data=$(echo "$tracker_data" | sed "s/{/{\"$ip_address\": {\"count\": $ip_connections, \"last_connection\": $current_time},/")
        tracker_data=$(echo "$tracker_data" | sed "s/,$//")
        tracker_data=$(echo "$tracker_data" | sed "s/^{$/{\"$ip_address\": {\"count\": $ip_connections, \"last_connection\": $current_time}}/")
        
        write_json_file "$CONNECTION_TRACKER" "$tracker_data"
        
        # Check for DDoS attempt
        if [ "$ip_connections" -gt "$CONNECTION_THRESHOLD" ]; then
            print_error "DDoS ATTEMPT DETECTED: $ip_address ($ip_connections connections/minute)"
            echo "$(date '+%Y-%m-%d %H:%M:%S') - DDoS attempt from $ip_address ($ip_connections connections)" >> "$SECURITY_LOG"
        fi
    fi
}

# Filter server log to exclude certain messages
filter_server_log() {
    while read line; do
        [[ "$line" == *"Server closed"* || "$line" == *"Starting server"* || \
          ("$line" == *"SERVER: say"* && "$line" == *"Welcome"*) || \
          "$line" == *"adminlist.txt"* || "$line" == *"modlist.txt"* ]] && continue
        echo "$line"
    done
}

# Cleanup function for signal handling
cleanup() {
    print_status "Cleaning up anticheat..."
    kill $(jobs -p) 2>/dev/null
    print_status "Anticheat cleanup done."
    exit 0
}

# Main anticheat monitoring function
monitor_log() {
    local log_file="$1"
    LOG_FILE="$log_file"

    initialize_authorization_files
    initialize_admin_offenses

    # Initialize security log
    touch "$SECURITY_LOG"
    print_success "Security log initialized: $SECURITY_LOG"

    # Start authorization validation in background
    (
        while true; do 
            sleep 3
            validate_authorization
        done
    ) &
    local validation_pid=$!

    # Set up signal handling
    trap cleanup EXIT INT TERM

    print_header "STARTING ANTICHEAT SECURITY SYSTEM"
    print_status "Monitoring: $log_file"
    print_status "Port: $PORT"
    print_status "Log directory: $LOG_DIR"
    print_header "SECURITY SYSTEM ACTIVE"

    # Monitor the log file for unauthorized commands and security threats
    tail -n 0 -F "$log_file" | filter_server_log | while read line; do
        # Detect unauthorized admin/mod commands
        if [[ "$line" =~ ([a-zA-Z0-9_]+):\ \/(admin|mod)\ ([a-zA-Z0-9_]+) ]]; then
            local command_user="${BASH_REMATCH[1]}" command_type="${BASH_REMATCH[2]}" target_player="${BASH_REMATCH[3]}"
            
            # Validate player names
            if ! is_valid_player_name "$command_user" || ! is_valid_player_name "$target_player"; then
                print_warning "Invalid player name in command: $command_user or $target_player"
                continue
            fi
            
            [ "$command_user" != "SERVER" ] && handle_unauthorized_command "$command_user" "/$command_type" "$target_player"
        fi
        
        # Detect malformed packets
        detect_malformed_packets "$line"
        
        # Track connections for DDoS detection
        track_connections "$line"
    done

    wait
    kill $validation_pid 2>/dev/null
}

if [ $# -eq 1 ] || [ $# -eq 2 ]; then
    if [ ! -f "$LOG_FILE" ]; then
        print_error "Log file not found: $LOG_FILE"
        print_status "Waiting for log file to be created..."
        
        # Wait for log file to be created
        local wait_time=0
        while [ ! -f "$LOG_FILE" ] && [ $wait_time -lt 30 ]; do
            sleep 1
            ((wait_time++))
        done
        
        if [ ! -f "$LOG_FILE" ]; then
            print_error "Log file never appeared: $LOG_FILE"
            exit 1
        fi
    fi
    
    monitor_log "$1"
else
    print_error "Usage: $0 <server_log_file> [port]"
    exit 1
fi
EOF

# Set permissions for all scripts
chmod +x server_manager.sh
chmod +x server_bot.sh
chmod +x anticheat_secure.sh

print_success "Helper scripts created"

print_step "[6/7] Create economy data file"
sudo -u "$ORIGINAL_USER" bash -c 'echo "{\"players\": {}, \"transactions\": []}" > economy_data.json' || true
chown "$ORIGINAL_USER:$ORIGINAL_USER" economy_data.json 2>/dev/null || true
print_success "Economy data file created"

print_step "[7/7] Finalizing installation..."
rm -f "$TEMP_FILE"

print_success "Installation completed successfully"
echo ""
print_header "USAGE INSTRUCTIONS FOR NEW USERS"
print_status "1. FIRST create a world manually with:"
echo "   ./blockheads_server171 -n"
echo ""
print_warning "IMPORTANT: After creating the world, press CTRL+C to exit"
echo ""
print_status "2. Then start the server and bot with:"
echo "   ./server_manager.sh start WORLD_NAME PORT"
echo ""
print_status "3. To stop the server:"
echo "   ./server_manager.sh stop"
echo ""
print_status "4. To check status:"
echo "   ./server_manager.sh status"
echo ""
print_status "5. For help:"
echo "   ./server_manager.sh help"
echo "   ./blockheads_server171 -h"
echo ""
print_warning "NOTE: Default port is 12153 if not specified"
print_header "INSTALLATION COMPLETE"
