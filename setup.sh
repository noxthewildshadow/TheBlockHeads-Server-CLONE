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

print_step "[1/8] Installing required packages..."
{
    add-apt-repository multiverse -y || true
    apt-get update -y
    apt-get install -y libgnustep-base1.28 libdispatch-dev patchelf wget jq screen lsof software-properties-common
} > /dev/null 2>&1
if [ $? -eq 0 ]; then
    print_success "Required packages installed"
else
    print_error "Failed to install required packages"
    print_status "Trying alternative approach..."
    apt-get install -y software-properties-common
    add-apt-repository multiverse -y
    apt-get update -y
    apt-get install -y libgnustep-base1.28 libdispatch-dev patchelf wget jq screen lsof || {
        print_error "Still failed to install packages. Please check your internet connection."
        exit 1
    }
fi

print_step "[2/8] Creating helper scripts..."

# Create server_manager.sh
cat > server_manager.sh << 'SERVER_MANAGER_EOF'
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
    echo -e "  ${GREEN}start${NC} [WORLD_NAME] [PORT] - Start server and bot"
    echo -e "  ${RED}stop${NC} [PORT]                - Stop server and bot (specific port or all)"
    echo -e "  ${CYAN}status${NC} [PORT]              - Show server status (specific port or all)"
    echo -e "  ${YELLOW}list${NC}                     - List all running servers"
    echo -e "  ${YELLOW}help${NC}                      - Show this help"
    echo ""
    print_status "Examples:"
    echo -e "  ${GREEN}$0 start MyWorld 12153${NC}"
    echo -e "  ${GREEN}$0 start MyWorld${NC}        (uses default port 12153)"
    echo -e "  ${RED}$0 stop${NC}                   (stops all servers)"
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
    lsof -Pi ":$1" -sTCP:LISTEN -t >/dev/null
}

free_port() {
    local port="$1"
    print_warning "Freeing port $port..."
    local pids=$(lsof -ti ":$port")
    [ -n "$pids" ] && kill -9 $pids 2>/dev/null
    
    # Use our function to check if screen sessions exist before trying to quit them
    local screen_server="blockheads_server_$port"
    local screen_bot="blockheads_bot_$port"
    
    if screen_session_exists "$screen_server"; then
        screen -S "$screen_server" -X quit 2>/dev/null
    fi
    
    if screen_session_exists "$screen_bot"; then
        screen -S "$screen_bot" -X quit 2>/dev/null
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
    
    sleep 1

    local log_dir="$HOME/GNUstep/Library/ApplicationSupport/TheBlockheads/saves/$world_id"
    local log_file="$log_dir/console.log"
    mkdir -p "$log_dir"

    print_step "Starting server - World: $world_id, Port: $port"
    echo "$world_id" > "world_id_$port.txt"

    # Start server - FIXED DATE FORMAT
    # Create a temporary script to avoid date formatting issues
    cat > /tmp/start_server_$$.sh << EOF
#!/bin/bash
cd '$PWD'
while true; do
    echo "[\$(date '+%Y-%m-%d %H:%M:%S')] Starting server..."
    if ./blockheads_server171 -o '$world_id' -p $port 2>&1 | tee -a '$log_file'; then
        echo "[\$(date '+%Y-%m-%d %H:%M:%S')] Server closed normally"
    else
        exit_code=\$?
        echo "[\$(date '+%Y-%m-%d %H:%M:%S')] Server failed with code: \$exit_code"
        if [ \$exit_code -eq 1 ] && tail -n 5 '$log_file' | grep -q "port.*already in use"; then
            echo "[\$(date '+%Y-%m-%d %H:%M:%S')] ERROR: Port already in use. Will not retry."
            break
        fi
    fi
    echo "[\$(date '+%Y-%m-%d %H:%M:%S')] Restarting in 5 seconds..."
    sleep 5
done
EOF

    chmod +x /tmp/start_server_$$.sh
    
    screen -dmS "$SCREEN_SERVER" /tmp/start_server_$$.sh

    # Clean up temp script after a delay
    (sleep 10; rm -f /tmp/start_server_$$.sh) &

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

    # Wait for server to be ready - IMPROVED DETECTION
    local server_ready=false
    for i in {1..30}; do  # Increased timeout to 30 seconds
        # Check for various success messages that might indicate server is ready
        if grep -q "World load complete\|Server started\|Ready for connections\|using seed:\|save delay:" "$log_file"; then
            server_ready=true
            break
        fi
        sleep 1
    done

    if [ "$server_ready" = false ]; then
        print_warning "Server did not show complete startup messages, but continuing..."
        print_warning "This is normal for some server versions. Checking if server process is running..."
        
        # Additional check: see if the server process is actually running
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
        print_header "SERVER AND BOT STARTED SUCCESSFULLY!"
        print_success "World: $world_id"
        print_success "Port: $port"
        echo ""
        print_status "To view server console: ${CYAN}screen -r $SCREEN_SERVER${NC}"
        print_status "To view bot: ${CYAN}screen -r $SCREEN_BOT${NC}"
        echo ""
        print_warning "To exit console without stopping server: ${YELLOW}CTRL+A, D${NC}"
        print_header "SERVER IS NOW RUNNING"
    else
        print_warning "Could not verify all screen sessions"
        print_status "Server started: $server_started, Bot started: $bot_started"
        print_warning "Use 'screen -list' to view active sessions"
    fi
}

stop_server() {
    local port="$1"
    
    if [ -z "$port" ]; then
        print_step "Stopping all servers and bots..."
        
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
        
        pkill -f "$SERVER_BINARY" 2>/dev/null || true
        print_success "Cleanup completed for all servers."
    else
        print_step "Stopping server and bot on port $port..."
        
        local screen_server="blockheads_server_$port"
        local screen_bot="blockheads_bot_$port"
        
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
        
        # Show world info if exists
        if [ -f "world_id_$port.txt" ]; then
            local WORLD_ID=$(cat "world_id_$port.txt" 2>/dev/null)
            print_status "Current world: ${CYAN}$WORLD_ID${NC}"
            
            # Show port if server is running
            if screen_session_exists "blockheads_server_$port"; then
                print_status "To view console: ${CYAN}screen -r blockheads_server_$port${NC}"
                print_status "To view bot: ${CYAN}screen -r blockheads_bot_$port${NC}"
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
SERVER_MANAGER_EOF

# Create server_bot.sh
cat > server_bot.sh << 'SERVER_BOT_EOF'
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

# Bot configuration - now supports multiple servers
if [ $# -ge 2 ]; then
    PORT="$2"
    ECONOMY_FILE="economy_data_$PORT.json"
    ADMIN_OFFENSES_FILE="admin_offenses_$PORT.json"
    SCREEN_SERVER="blockheads_server_$PORT"
else
    ECONOMY_FILE="economy_data.json"
    ADMIN_OFFENSES_FILE="admin_offenses.json"
    SCREEN_SERVER="blockheads_server"
fi

# Authorization files
AUTHORIZED_ADMINS_FILE="authorized_admins.txt"
AUTHORIZED_MODS_FILE="authorized_mods.txt"
AUTHORIZED_BLACKLIST_FILE="authorized_blacklist.txt"
SCAN_INTERVAL=5
SERVER_WELCOME_WINDOW=15
TAIL_LINES=500

# Function to initialize authorization files
initialize_authorization_files() {
    local world_dir=$(dirname "$LOG_FILE")
    local auth_admins="$world_dir/$AUTHORIZED_ADMINS_FILE"
    local auth_mods="$world_dir/$AUTHORIZED_MODS_FILE"
    local auth_blacklist="$world_dir/$AUTHORIZED_BLACKLIST_FILE"
    
    [ ! -f "$auth_admins" ] && touch "$auth_admins" && print_success "Created authorized admins file: $auth_admins"
    [ ! -f "$auth_mods" ] && touch "$auth_mods" && print_success "Created authorized mods file: $auth_mods"
    [ ! -f "$auth_blacklist" ] && touch "$auth_blacklist" && print_success "Created authorized blacklist file: $auth_blacklist"
    
    # Add xero and packets to authorized blacklist if not already present
    for player in "xero" "packets"; do
        if ! grep -q -i "^$player$" "$auth_blacklist"; then
            echo "$player" >> "$auth_blacklist"
            print_success "Added $player to authorized blacklist"
        fi
    done
}

# Function to check and correct admin/mod lists
validate_authorization() {
    local world_dir=$(dirname "$LOG_FILE")
    local auth_admins="$world_dir/$AUTHORIZED_ADMINS_FILE"
    local auth_mods="$world_dir/$AUTHORIZED_MODS_FILE"
    local auth_blacklist="$world_dir/$AUTHORIZED_BLACKLIST_FILE"
    local admin_list="$world_dir/adminlist.txt"
    local mod_list="$world_dir/modlist.txt"
    local black_list="$world_dir/blacklist.txt"
    
    # Check adminlist.txt against authorized_admins.txt
    if [ -f "$admin_list" ]; then
        while IFS= read -r admin; do
            if [[ -n "$admin" && ! "$admin" =~ ^[[:space:]]*# && ! "$admin" =~ "Usernames in this file" ]]; then
                if ! grep -q -i "^$admin$" "$auth_admins"; then
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
                if ! grep -q -i "^$mod$" "$auth_mods"; then
                    print_warning "Unauthorized mod detected: $mod"
                    send_server_command "/unmod $mod"
                    remove_from_list_file "$mod" "mod"
                    print_success "Removed unauthorized mod: $mod"
                fi
            fi
        done < <(grep -v "^[[:space:]]*#" "$mod_list")
    fi
    
    # Check blacklist.txt against authorized_blacklist.txt
    if [ -f "$black_list" ]; then
        while IFS= read -r banned; do
            # Skip header line and comment lines in blacklist
            if [[ -n "$banned" && ! "$banned" =~ ^[[:space:]]*# && ! "$banned" =~ "Usernames or IP addresses" ]]; then
                if ! grep -q -i "^$banned$" "$auth_blacklist"; then
                    print_warning "Non-authorized banned player detected: $banned"
                    send_server_command_silent "/unban $banned"
                    remove_from_list_file "$banned" "black"
                    print_success "Removed non-authorized banned player: $banned"
                fi
            fi
        done < <(grep -v "^[[:space:]]*#" "$black_list")
    fi
    
    # Ensure all authorized banned players are in blacklist.txt
    if [ -f "$auth_blacklist" ]; then
        while IFS= read -r banned; do
            if [[ -n "$banned" && ! "$banned" =~ ^[[:space:]]*# ]]; then
                # Skip header line when checking blacklist
                if ! (tail -n +2 "$black_list" 2>/dev/null | grep -v "^[[:space:]]*#" | grep -q -i "^$banned$"); then
                    print_warning "Authorized banned player $banned not found in blacklist.txt, adding..."
                    send_server_command_silent "/ban $banned"
                    # Also add to blacklist.txt file directly
                    echo "$banned" >> "$black_list"
                    print_success "Added $banned to blacklist.txt"
                fi
            fi
        done < "$auth_blacklist"
    fi
}

# Function to add player to authorized list
add_to_authorized() {
    local player_name="$1" list_type="$2"
    local world_dir=$(dirname "$LOG_FILE")
    local auth_file="$world_dir/authorized_${list_type}s.txt"
    
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
    local world_dir=$(dirname "$LOG_FILE")
    local auth_file="$world_dir/authorized_${list_type}s.txt"
    local lower_player_name=$(echo "$player_name" | tr '[:upper:]' '[:lower:]')
    
    [ ! -f "$auth_file" ] && print_error "Authorization file not found: $auth_file" && return 1
    
    if grep -q -i "^$lower_player_name$" "$auth_file"; then
        sed -i "/^$lower_player_name$/Id" "$auth_file"
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
    local offenses_data=$(cat "$ADMIN_OFFENSES_FILE" 2>/dev/null || echo '{}')
    local current_offenses=$(echo "$offenses_data" | jq -r --arg admin "$admin_name" '.[$admin]?.count // 0')
    local last_offense_time=$(echo "$offenses_data" | jq -r --arg admin "$admin_name" '.[$admin]?.last_offense // 0')
    
    [ $((current_time - last_offense_time)) -gt 300 ] && current_offenses=0
    current_offenses=$((current_offenses + 1))
    
    offenses_data=$(echo "$offenses_data" | jq --arg admin "$admin_name" \
        --argjson count "$current_offenses" --argjson time "$current_time" \
        '.[$admin] = {"count": $count, "last_offense": $time}')
    
    echo "$offenses_data" > "$ADMIN_OFFENSES_FILE"
    print_warning "Recorded offense #$current_offenses for admin $admin_name"
    return $current_offenses
}

# Function to clear admin offenses
clear_admin_offenses() {
    local admin_name="$1"
    local offenses_data=$(cat "$ADMIN_OFFENSES_FILE" 2>/dev/null || echo '{}')
    offenses_data=$(echo "$offenses_data" | jq --arg admin "$admin_name" 'del(.[$admin])')
    echo "$offenses_data" > "$ADMIN_OFFENSES_FILE"
    print_success "Cleared offenses for admin $admin_name"
}

# Function to remove player from list file
remove_from_list_file() {
    local player_name="$1" list_type="$2"
    local world_dir=$(dirname "$LOG_FILE")
    local list_file="$world_dir/${list_type}list.txt"
    local lower_player_name=$(echo "$player_name" | tr '[:upper:]' '[:lower:]')
    
    [ ! -f "$list_file" ] && print_error "List file not found: $list_file" && return 1
    
    if grep -v "^[[:space:]]*#" "$list_file" | grep -q "^$lower_player_name$"; then
        sed -i "/^$lower_player_name$/Id" "$list_file"
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

initialize_economy() {
    [ ! -f "$ECONOMY_FILE" ] && echo '{"players": {}, "transactions": []}' > "$ECONOMY_FILE" &&
    print_success "Economy data file created: $ECONOMY_FILE"
    initialize_admin_offenses
}

is_player_in_list() {
    local player_name="$1" list_type="$2"
    local world_dir=$(dirname "$LOG_FILE")
    local list_file="$world_dir/${list_type}list.txt"
    local lower_player_name=$(echo "$player_name" | tr '[:upper:]' '[:lower:]')
    
    [ -f "$list_file" ] && grep -v "^[[:space:]]*#" "$list_file" | grep -q "^$lower_player_name$" && return 0
    return 1
}

add_player_if_new() {
    local player_name="$1"
    local current_data=$(cat "$ECONOMY_FILE")
    local player_exists=$(echo "$current_data" | jq --arg player "$player_name" '.players | has($player)')
    
    if [ "$player_exists" = "false" ]; then
        current_data=$(echo "$current_data" | jq --arg player "$player_name" \
            '.players[$player] = {"tickets": 0, "last_login": 0, "last_welcome_time": 0, "last_help_time": 0, "last_greeting_time": 0, "purchases": []}')
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
    current_data=$(echo "$current_data" | jq --arg player "$player_name" '.players[$player].tickets = 1')
    current_data=$(echo "$current_data" | jq --arg player "$player_name" --argjson time "$current_time" '.players[$player].last_login = $time')
    current_data=$(echo "$current_data" | jq --arg player "$player_name" --arg time "$time_str" \
        '.transactions += [{"player": $player, "type": "welcome_bonus", "tickets": 1, "time": $time}]')
    echo "$current_data" > "$ECONOMY_FILE"
    print_success "Gave first-time bonus to $player_name"
}

grant_login_ticket() {
    local player_name="$1" current_time=$(date +%s) time_str="$(date '+%Y-%m-%d %H:%M:%S')"
    local current_data=$(cat "$ECONOMY_FILE")
    local last_login=$(echo "$current_data" | jq -r --arg player "$player_name" '.players[$player].last_login // 0')
    last_login=${last_login:-0}
    
    if [ "$last_login" -eq 0 ] || [ $((current_time - last_login)) -ge 3600 ]; then
        local current_tickets=$(echo "$current_data" | jq -r --arg player "$player_name" '.players[$player].tickets // 0')
        current_tickets=${current_tickets:-0}
        local new_tickets=$((current_tickets + 1))
        current_data=$(echo "$current_data" | jq --arg player "$player_name" --argjson tickets "$new_tickets" '.players[$player].tickets = $tickets')
        current_data=$(echo "$current_data" | jq --arg player "$player_name" --argjson time "$current_time" '.players[$player].last_login = $time')
        current_data=$(echo "$current_data" | jq --arg player "$player_name" --arg time "$time_str" \
            '.transactions += [{"player": $player, "type": "login_bonus", "tickets": 1, "time": $time}]')
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
    local last_welcome_time=$(echo "$current_data" | jq -r --arg player "$player_name" '.players[$player].last_welcome_time // 0')
    last_welcome_time=${last_welcome_time:-0}
    
    if [ "$force_send" -eq 1 ] || [ "$last_welcome_time" -eq 0 ] || [ $((current_time - last_welcome_time)) -ge 180 ]; then
        if [ "$is_new_player" = "true" ]; then
            send_server_command "Hello $player_name! Welcome to the server. Type !tickets to check your ticket balance."
        else
            local last_greeting_time=$(echo "$current_data" | jq -r --arg player "$player_name" '.players[$player].last_greeting_time // 0')
            if [ $((current_time - last_greeting_time)) -ge 600 ]; then
                send_server_command "Welcome back $player_name! Type !economy_help to see economy commands."
                # Update last_greeting_time to prevent spam
                current_data=$(echo "$current_data" | jq --arg player "$player_name" --argjson time "$current_time" '.players[$player].last_greeting_time = $time')
            fi
        fi
        current_data=$(echo "$current_data" | jq --arg player "$player_name" --argjson time "$current_time" '.players[$player].last_welcome_time = $time')
        echo "$current_data" > "$ECONOMY_FILE"
    else
        print_warning "Skipping welcome for $player_name due to cooldown"
    fi
}

show_help_if_needed() {
    local player_name="$1" current_time=$(date +%s)
    local current_data=$(cat "$ECONOMY_FILE")
    local last_help_time=$(echo "$current_data" | jq -r --arg player "$player_name" '.players[$player].last_help_time // 0')
    last_help_time=${last_help_time:-0}
    
    if [ "$last_help_time" -eq 0 ] || [ $((current_time - last_help_time)) -ge 300 ]; then
        send_server_command "$player_name, type !economy_help to see economy commands."
        current_data=$(echo "$current_data" | jq --arg player "$player_name" --argjson time "$current_time" '.players[$player].last_help_time = $time')
        echo "$current_data" > "$ECONOMY_FILE"
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
    local has_item=$(echo "$current_data" | jq --arg player "$player_name" --arg item "$item" '.players[$player].purchases | index($item) != null')
    [ "$has_item" = "true" ] && return 0 || return 1
}

add_purchase() {
    local player_name="$1" item="$2"
    local current_data=$(cat "$ECONOMY_FILE")
    current_data=$(echo "$current_data" | jq --arg player "$player_name" --arg item "$item" '.players[$player].purchases += [$item]')
    echo "$current_data" > "$ECONOMY_FILE"
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

process_message() {
    local player_name="$1" message="$2"
    local current_data=$(cat "$ECONOMY_FILE")
    local player_tickets=$(echo "$current_data" | jq -r --arg player "$player_name" '.players[$player].tickets // 0')
    player_tickets=${player_tickets:-0}
    
    case "$message" in
        "hi"|"hello"|"Hi"|"Hello"|"hola"|"Hola")
            local current_time=$(date +%s)
            local last_greeting_time=$(echo "$current_data" | jq -r --arg player "$player_name" '.players[$player].last_greeting_time // 0')
            
            # 10-minute cooldown for greetings
            if [ "$last_greeting_time" -eq 0 ] || [ $((current_time - last_greeting_time)) -ge 600 ]; then
                send_server_command "Hello $player_name! Welcome to the server. Type !tickets to check your ticket balance."
                # Update last_greeting_time
                current_data=$(echo "$current_data" | jq --arg player "$player_name" --argjson time "$current_time" '.players[$player].last_greeting_time = $time')
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
                current_data=$(echo "$current_data" | jq --arg player "$player_name" --argjson tickets "$new_tickets" '.players[$player].tickets = $tickets')
                add_purchase "$player_name" "mod"
                local time_str="$(date '+%Y-%m-%d %H:%M:%S')"
                current_data=$(echo "$current_data" | jq --arg player "$player_name" --arg time "$time_str" \
                    '.transactions += [{"player": $player, "type": "purchase", "item": "mod", "tickets": -50, "time": $time}]')
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
                current_data=$(echo "$current_data" | jq --arg player "$player_name" --argjson tickets "$new_tickets" '.players[$player].tickets = $tickets')
                add_purchase "$player_name" "admin"
                local time_str="$(date '+%Y-%m-%d %H:%M:%S')"
                current_data=$(echo "$current_data" | jq --arg player "$player_name" --arg time "$time_str" \
                    '.transactions += [{"player": $player, "type": "purchase", "item": "admin", "tickets": -100, "time": $time}]')
                echo "$current_data" > "$ECONOMY_FILE"
                
                # First add to authorized admins, then assign rank
                add_to_authorized "$player_name" "admin"
                screen -S "$SCREEN_SERVER" -X stuff "/admin $player_name$(printf \\r)"
                send_server_command "Congratulations $player_name! You have been promoted to ADMIN for 100 tickets. Remaining tickets: $new_tickets"
            else
                send_server_command "$player_name, you need $((100 - player_tickets)) more tickets to buy ADMIN rank."
            fi
            ;;
        "!set_admin"|"!set_mod")
            send_server_command "$player_name, these commands are only available to server console operators."
            ;;
        "!economy_help")
            send_server_command "Economy commands:"
            send_server_command "!tickets - Check your tickets"
            send_server_command "!buy_mod - Buy MOD rank for 50 tickets"
            send_server_command "!buy_admin - Buy ADMIN rank for 100 tickets"
            ;;
    esac
}

process_admin_command() {
    local command="$1" current_data=$(cat "$ECONOMY_FILE")
    
    if [[ "$command" =~ ^!send_ticket\ ([a-zA-Z0-9_]+)\ ([0-9]+)$ ]]; then
        local player_name="${BASH_REMATCH[1]}" tickets_to_add="${BASH_REMATCH[2]}"
        local player_exists=$(echo "$current_data" | jq --arg player "$player_name" '.players | has($player)')
        [ "$player_exists" = "false" ] && print_error "Player $player_name not found in economy system" && return
        
        local current_tickets=$(echo "$current_data" | jq -r --arg player "$player_name" '.players[$player].tickets // 0')
        current_tickets=${current_tickets:-0}
        local new_tickets=$((current_tickets + tickets_to_add))
        current_data=$(echo "$current_data" | jq --arg player "$player_name" --argjson tickets "$new_tickets" '.players[$player].tickets = $tickets')
        local time_str="$(date '+%Y-%m-%d %H:%M:%S')"
        current_data=$(echo "$current_data" | jq --arg player "$player_name" --arg time "$time_str" --argjson amount "$tickets_to_add" \
            '.transactions += [{"player": $player, "type": "admin_gift", "tickets": $amount, "time": $time}]')
        echo "$current_data" > "$ECONOMY_FILE"
        print_success "Added $tickets_to_add tickets to $player_name (Total: $new_tickets)"
        send_server_command "$player_name received $tickets_to_add tickets from admin! Total: $new_tickets"
    elif [[ "$command" =~ ^!set_mod\ ([a-zA-Z0-9_]+)$ ]]; then
        local player_name="${BASH_REMATCH[1]}"
        print_success "Setting $player_name as MOD"
        # First add to authorized mods, then assign rank
        add_to_authorized "$player_name" "mod"
        screen -S "$SCREEN_SERVER" -X stuff "/mod $player_name$(printf \\r)"
        send_server_command "$player_name has been set as MOD by server console!"
    elif [[ "$command" =~ ^!set_admin\ ([a-zA-Z0-9_]+)$ ]]; then
        local player_name="${BASH_REMATCH[1]}"
        print_success "Setting $player_name as ADMIN"
        # First add to authorized admins, then assign rank
        add_to_authorized "$player_name" "admin"
        screen -S "$SCREEN_SERVER" -X stuff "/admin $player_name$(printf \\r)"
        send_server_command "$player_name has been set as ADMIN by server console!"
    elif [[ "$command" =~ ^!ban\ ([a-zA-Z0-9_]+)$ ]]; then
        local player_name="${BASH_REMATCH[1]}"
        print_success "Banning $player_name"
        # Add to authorized blacklist first
        add_to_authorized "$player_name" "blacklist"
        # Then execute ban command
        send_server_command "/ban $player_name"
        send_server_command "$player_name has been banned by server console!"
    else
        print_error "Unknown admin command: $command"
        print_status "Available admin commands:"
        echo -e "!send_ticket <player> <amount>"
        echo -e "!set_mod <player> (console only)"
        echo -e "!set_admin <player> (console only)"
        echo -e "!ban <player> (console only)"
    fi
}

server_sent_welcome_recently() {
    local player_name="$1" conn_epoch="${2:-0}"
    [ -z "$LOG_FILE" ] || [ ! -f "$LOG_FILE" ] && return 1
    local player_lc=$(echo "$player_name" | tr '[:upper:]' '[:lower:]')
    tail -n "$TAIL_LINES" "$LOG_FILE" 2>/dev/null | grep -i "server:.*welcome.*$player_lc" | head -1 | grep -q . && return 0
    return 1
}

filter_server_log() {
    while read line; do
        [[ "$line" == *"Server closed"* || "$line" == *"Starting server"* || \
          ("$line" == *"SERVER: say"* && "$line" == *"Welcome"*) || \
          "$line" == *"adminlist.txt"* || "$line" == *"modlist.txt"* || \
          "$line" == *"blacklist.txt"* ]] && continue
        echo "$line"
    done
}

monitor_log() {
    local log_file="$1"
    LOG_FILE="$log_file"

    initialize_authorization_files

    # Start authorization validation in background
    (
        while true; do sleep 3; validate_authorization; done
    ) &
    local validation_pid=$!

    print_header "STARTING ECONOMY BOT"
    print_status "Monitoring: $log_file"
    print_status "Bot commands: !tickets, !buy_mod, !buy_admin, !economy_help"
    print_status "Admin commands: !send_ticket <player> <amount>, !set_mod <player>, !set_admin <player>, !ban <player>"
    print_header "IMPORTANT: Admin commands must be typed in THIS terminal, NOT in the game chat!"
    print_status "Type admin commands below and press Enter:"
    print_header "READY FOR COMMANDS"

    local admin_pipe="/tmp/blockheads_admin_pipe_$$"
    rm -f "$admin_pipe"
    mkfifo "$admin_pipe"

    # Background process to read admin commands from the pipe
    while read -r admin_command < "$admin_pipe"; do
        print_status "Processing admin command: $admin_command"
        if [[ "$admin_command" == "!send_ticket "* || "$admin_command" == "!set_mod "* || "$admin_command" == "!set_admin "* || "$admin_command" == "!ban "* ]]; then
            process_admin_command "$admin_command"
        else
            print_error "Unknown admin command. Use: !send_ticket <player> <amount>, !set_mod <player>, !set_admin <player>, or !ban <player>"
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

            print_success "Player connected: $player_name (IP: $player_ip)"

            # Extract timestamp
            ts_str=$(echo "$line" | awk '{print $1" "$2}')
            ts_no_ms=${ts_str%.*}
            conn_epoch=$(date -d "$ts_no_ms" +%s 2>/dev/null || echo 0)

            local is_new_player="false"
            add_player_if_new "$player_name" && is_new_player="true"

            sleep 3

            if ! server_sent_welcome_recently "$player_name" "$conn_epoch"; then
                show_welcome_message "$player_name" "$is_new_player" 1
            else
                print_warning "Server already welcomed $player_name"
            fi

            [ "$is_new_player" = "false" ] && grant_login_ticket "$player_name"
            continue
        fi

        # Detect unauthorized admin/mod commands
        if [[ "$line" =~ ([a-zA-Z0-9_]+):\ \/(admin|mod)\ ([a-zA-Z0-9_]+) ]]; then
            local command_user="${BASH_REMATCH[1]}" command_type="${BASH_REMATCH[2]}" target_player="${BASH_REMATCH[3]}"
            [ "$command_user" != "SERVER" ] && handle_unauthorized_command "$command_user" "/$command_type" "$target_player"
            continue
        fi

        if [[ "$line" =~ Player\ Disconnected\ ([a-zA-Z0-9_]+) ]]; then
            local player_name="${BASH_REMATCH[1]}"
            [ "$player_name" == "SERVER" ] && continue
            print_warning "Player disconnected: $player_name"
            unset welcome_shown["$player_name"]
            continue
        fi

        if [[ "$line" =~ ([a-zA-Z0-9_]+):\ (.+)$ ]]; then
            local player_name="${BASH_REMATCH[1]}" message="${BASH_REMATCH[2]}"
            [ "$player_name" == "SERVER" ] && continue
            print_status "Chat: $player_name: $message"
            add_player_if_new "$player_name"
            process_message "$player_name" "$message"
            continue
        fi

        print_status "Other log line: $line"
    done

    wait
    rm -f "$admin_pipe"
    kill $validation_pid 2>/dev/null
}

if [ $# -eq 1 ] || [ $# -eq 2 ]; then
    initialize_economy
    monitor_log "$1"
else
    print_error "Usage: $0 <server_log_file> [port]"
    exit 1
fi
SERVER_BOT_EOF

chmod +x server_manager.sh server_bot.sh
print_success "Helper scripts created"

print_step "[3/8] Downloading server archive..."
if ! wget -q --timeout=60 --tries=3 "$SERVER_URL" -O "$TEMP_FILE"; then
    print_error "Failed to download server file."
    print_status "This might be due to:"
    print_status "1. Internet connection issues"
    print_status "2. The server file is no longer available at the expected URL"
    exit 1
fi
print_success "Server archive downloaded"

print_step "[4/8] Extracting files..."
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

print_step "[5/8] Applying patchelf compatibility patches (best-effort)..."
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

print_step "[6/8] Set ownership and permissions for helper scripts and binary"
chown "$ORIGINAL_USER:$ORIGINAL_USER" server_manager.sh server_bot.sh "$SERVER_BINARY" ./*.json 2>/dev/null || true
chmod 755 server_manager.sh server_bot.sh "$SERVER_BINARY" ./*.json 2>/dev/null || true
print_success "Permissions set"

print_step "[7/8] Create economy data file"
sudo -u "$ORIGINAL_USER" bash -c 'echo "{\"players\": {}, \"transactions\": []}" > economy_data.json' || true
chown "$ORIGINAL_USER:$ORIGINAL_USER" economy_data.json 2>/dev/null || true
print_success "Economy data file created"

rm -f "$TEMP_FILE"

print_step "[8/8] Installation completed successfully"
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
print_header "NEED HELP?"
print_status "Visit the GitHub repository for more information:"
print_status "https://github.com/noxthewildshadow/The-Blockheads-Server-BETA"
print_header "INSTALLATION COMPLETE"
