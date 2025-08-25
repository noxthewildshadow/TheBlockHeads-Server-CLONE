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
SCREEN_SERVER="blockheads_server"
SCREEN_BOT="blockheads_bot"
ECONOMY_FILE="economy_data.json"
SCAN_INTERVAL=5
SERVER_WELCOME_WINDOW=15
TAIL_LINES=500

# Security and backup configuration
WARNING_THRESHOLD=2
ADMIN_OFFENSES_FILE="admin_offenses.json"
SECURITY_LOG="security.log"
BACKUP_DIR="./list_backups"
BACKUP_INTERVAL=10  # Backup every 10 seconds
CRITICAL_LISTS=("adminlist.txt" "modlist.txt" "blacklist.txt" "whitelist.txt")

# Initialize backup system
initialize_backup_system() {
    mkdir -p "$BACKUP_DIR"
    print_success "Backup directory created: $BACKUP_DIR"
}

# Backup critical lists
backup_critical_lists() {
    local world_dir=$(dirname "$LOG_FILE")
    
    for list in "${CRITICAL_LISTS[@]}"; do
        local list_file="$world_dir/$list"
        if [ -f "$list_file" ]; then
            local backup_file="$BACKUP_DIR/${list}.backup"
            cp "$list_file" "$backup_file"
        fi
    done
}

# Restore critical lists from backup
restore_critical_lists() {
    local world_dir=$(dirname "$LOG_FILE")
    
    for list in "${CRITICAL_LISTS[@]}"; do
        local list_file="$world_dir/$list"
        local backup_file="$BACKUP_DIR/${list}.backup"
        
        if [ -f "$backup_file" ]; then
            cp "$backup_file" "$list_file"
            print_success "Restored $list from backup"
        fi
    done
}

# Start backup process in background
start_backup_process() {
    while true; do
        backup_critical_lists
        sleep $BACKUP_INTERVAL
    done
}

# Initialize security system
initialize_security_system() {
    initialize_admin_offenses
    
    if [ ! -f "$SECURITY_LOG" ]; then
        touch "$SECURITY_LOG"
        print_success "Security log file created"
    fi
    
    initialize_backup_system
}

# Initialize admin offenses tracking
initialize_admin_offenses() {
    if [ ! -f "$ADMIN_OFFENSES_FILE" ]; then
        echo '{}' > "$ADMIN_OFFENSES_FILE"
        print_success "Admin offenses tracking file created"
    fi
}

# Function to record admin offense
record_admin_offense() {
    local admin_name="$1"
    local command="$2"
    local target="${3:-N/A}"
    
    local current_time=$(date +%s)
    local offenses_data=$(cat "$ADMIN_OFFENSES_FILE" 2>/dev/null || echo '{}')
    
    # Get current offenses for this admin
    local current_offenses=$(echo "$offenses_data" | jq -r --arg admin "$admin_name" '.[$admin]?.count // 0')
    local last_offense_time=$(echo "$offenses_data" | jq -r --arg admin "$admin_name" '.[$admin]?.last_offense // 0')
    
    # Check if previous offense was more than 5 minutes ago
    if [ $((current_time - last_offense_time)) -gt 300 ]; then
        # Reset count if it's been more than 5 minutes
        current_offenses=0
    fi
    
    # Increment offense count
    current_offenses=$((current_offenses + 1))
    
    # Update offenses data
    offenses_data=$(echo "$offenses_data" | jq --arg admin "$admin_name" \
        --argjson count "$current_offenses" \
        --argjson time "$current_time" \
        '.[$admin] = {"count": $count, "last_offense": $time}')
    
    echo "$offenses_data" > "$ADMIN_OFFENSES_FILE"
    print_warning "Recorded offense #$current_offenses for admin $admin_name"
    
    # Log security event
    log_security_event "OFFENSE: Admin $admin_name used prohibited command '$command' on target '$target'. Offense count: $current_offenses"
    
    # Send warning to user
    if [ "$current_offenses" -le "$WARNING_THRESHOLD" ]; then
        send_server_command "WARNING $admin_name: Unauthorized command usage. This is warning $current_offenses/$WARNING_THRESHOLD. Next offense may result in demotion."
    fi
    
    # Check if threshold exceeded
    if [ "$current_offenses" -gt "$WARNING_THRESHOLD" ]; then
        handle_admin_demotion "$admin_name"
    fi
    
    return $current_offenses
}

# Log security event
log_security_event() {
    local event="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $event" >> "$SECURITY_LOG"
    print_status "Security event logged: $event"
}

# Handle admin demotion
handle_admin_demotion() {
    local admin_name="$1"
    
    print_error "ADMIN DEMOTION: $admin_name exceeded offense limit. Automatically revoking admin privileges."
    log_security_event "DEMOTION: Admin $admin_name exceeded offense limit. Revoking admin privileges."
    
    # Execute unadmin
    send_server_command "/unadmin $admin_name"
    remove_from_list_file "$admin_name" "admin"
    
    # Send alert message
    send_server_command "ALERT: Admin $admin_name has been automatically demoted for repeated unauthorized actions!"
    
    # Clear offenses after punishment
    clear_admin_offenses "$admin_name"
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
    local player_name="$1"
    local list_type="$2"  # "admin" or "mod"
    
    # Get world directory from log file path
    local world_dir=$(dirname "$LOG_FILE")
    local list_file="$world_dir/${list_type}list.txt"
    local lower_player_name=$(echo "$player_name" | tr '[:upper:]' '[:lower:]')
    
    # Check if the list file exists
    if [ ! -f "$list_file" ]; then
        print_error "List file not found: $list_file"
        return 1
    fi
    
    # Create a backup of the original file
    cp "$list_file" "${list_file}.backup"
    
    # Remove the player from the list file
    if grep -q -i "^$lower_player_name$" "$list_file"; then
        # Use sed to remove the player name (case-insensitive)
        sed -i "/^$lower_player_name$/Id" "$list_file"
        
        # Double-check removal was successful
        if grep -q -i "^$lower_player_name$" "$list_file"; then
            print_error "Failed to remove $player_name from ${list_type}list.txt"
            # Restore from backup and try alternative method
            cp "${list_file}.backup" "$list_file"
            # Use awk as alternative method
            awk -v name="$lower_player_name" 'tolower($0) != tolower(name)' "$list_file" > "${list_file}.tmp" && \
            mv "${list_file}.tmp" "$list_file"
            
            # Final verification
            if grep -q -i "^$lower_player_name$" "$list_file"; then
                print_error "All attempts to remove $player_name from ${list_type}list.txt failed"
                rm -f "${list_file}.backup"
                return 1
            fi
        fi
        
        print_success "Removed $player_name from ${list_type}list.txt"
        rm -f "${list_file}.backup"
        return 0
    else
        print_warning "Player $player_name not found in ${list_type}list.txt"
        rm -f "${list_file}.backup"
        return 1
    fi
}

# Check if player is in a list
is_player_in_list() {
    local player_name="$1"
    local list_type="$2"
    local world_dir=$(dirname "$LOG_FILE")
    local list_file="$world_dir/${list_type}list.txt"
    local lower_player_name=$(echo "$player_name" | tr '[:upper:]' '[:lower:]')
    if [ -f "$list_file" ]; then
        if grep -q "^$lower_player_name$" "$list_file"; then
            return 0
        fi
    fi
    return 1
}

# Check player's current rank
check_player_rank() {
    local player_name="$1"
    
    if is_player_in_list "$player_name" "admin"; then
        echo "admin"
        return 0
    elif is_player_in_list "$player_name" "mod"; then
        echo "mod"
        return 0
    else
        echo "none"
        return 1
    fi
}

# Safe admin command validation
safe_admin_command() {
    local issuer="$1"
    local command="$2"
    local target_player="$3"
    
    # Prohibited commands for everyone
    local prohibited_commands=("/CLEAR-BLACKLIST" "/CLEAR-WHITELIST" "/CLEAR-MODLIST" "/CLEAR-ADMINLIST" "/UNADMIN")
    
    for prohibited in "${prohibited_commands[@]}"; do
        if [ "$command" = "$prohibited" ]; then
            print_error "PROHIBITED COMMAND: $issuer attempted to use $command"
            log_security_event "BLOCKED: $issuer attempted prohibited command: $command"
            
            # Restore lists from backup
            restore_critical_lists
            
            # Only record as offense if is admin
            if is_player_in_list "$issuer" "admin"; then
                record_admin_offense "$issuer" "$command" "$target_player"
                send_server_command "WARNING: Command $command is restricted to server console only."
            else
                send_server_command "$issuer, you don't have permission to use $command."
            fi
            
            return 1
        fi
    done
    
    # Handle /admin and /mod commands with validation
    if [ "$command" = "/admin" ] || [ "$command" = "/mod" ]; then
        local current_rank=$(check_player_rank "$target_player")
        local target_rank="mod"
        [ "$command" = "/admin" ] && target_rank="admin"
        
        # If target already has the rank or a higher one
        if [ "$current_rank" = "admin" ] && [ "$target_rank" = "mod" ]; then
            print_error "RANK CONFLICT: Cannot assign mod to admin $target_player"
            send_server_command "Cannot assign MOD to $target_player who is already an ADMIN."
            return 1
        elif [ "$current_rank" = "$target_rank" ]; then
            print_error "REDUNDANT COMMAND: $target_player is already $current_rank"
            send_server_command "$target_player is already $current_rank. No change needed."
            return 1
        elif [ "$current_rank" = "admin" ] || [ "$current_rank" = "mod" ]; then
            print_error "RANK DEMOTION: Cannot assign $target_rank to $current_rank $target_player"
            send_server_command "Cannot assign $target_rank to $target_player who is already $current_rank. Use /unadmin or /unmod first."
            return 1
        fi
    fi
    
    return 0
}

# Handle unauthorized commands
handle_unauthorized_command() {
    local player_name="$1"
    local command="$2"
    local target_player="$3"
    
    # Validate command first
    if ! safe_admin_command "$player_name" "$command" "$target_player"; then
        return 1  # Command blocked by safe_admin_command
    fi
    
    # Only track offenses for actual admins
    if is_player_in_list "$player_name" "admin"; then
        print_error "UNAUTHORIZED COMMAND: Admin $player_name attempted to use $command on $target_player"
        
        # Record the offense
        record_admin_offense "$player_name" "$command" "$target_player"
        local offense_count=$?
        
        # First offense: warning
        if [ "$offense_count" -eq 1 ]; then
            send_server_command "$player_name, this is your first warning! Only the server console can assign ranks using !set_admin or !set_mod."
        
        # Second offense: final warning
        elif [ "$offense_count" -eq 2 ]; then
            send_server_command "$player_name, this is your FINAL WARNING! Next offense will result in automatic demotion."
        fi
    else
        # For non-admins, just block the command
        print_warning "Non-admin player $player_name attempted to use $command on $target_player"
        send_server_command "$player_name, you don't have permission to assign ranks. Only server admins can use !give_mod or !give_admin commands."
    fi
    
    # Prevent execution of the original command
    return 1
}

# Initialize economy system
initialize_economy() {
    if [ ! -f "$ECONOMY_FILE" ]; then
        echo '{"players": {}, "transactions": []}' > "$ECONOMY_FILE"
        print_success "Economy data file created"
    fi
    initialize_security_system
}

# Add player if new
add_player_if_new() {
    local player_name="$1"
    local current_data=$(cat "$ECONOMY_FILE")
    local player_exists=$(echo "$current_data" | jq --arg player "$player_name" '.players | has($player)')
    if [ "$player_exists" = "false" ]; then
        current_data=$(echo "$current_data" | jq --arg player "$player_name" '.players[$player] = {"tickets": 0, "last_login": 0, "last_welcome_time": 0, "last_help_time": 0, "purchases": []}')
        echo "$current_data" > "$ECONOMY_FILE"
        print_success "Added new player: $player_name"
        give_first_time_bonus "$player_name"
        return 0
    fi
    return 1
}

# Give first time bonus
give_first_time_bonus() {
    local player_name="$1"
    local current_data=$(cat "$ECONOMY_FILE")
    local current_time=$(date +%s)
    local time_str="$(date '+%Y-%m-%d %H:%M:%S')"
    current_data=$(echo "$current_data" | jq --arg player "$player_name" '.players[$player].tickets = 1')
    current_data=$(echo "$current_data" | jq --arg player "$player_name" --argjson time "$current_time" '.players[$player].last_login = $time')
    current_data=$(echo "$current_data" | jq --arg player "$player_name" --arg time "$time_str" '.transactions += [{"player": $player, "type": "welcome_bonus", "tickets": 1, "time": $time}]')
    echo "$current_data" > "$ECONOMY_FILE"
    print_success "Gave first-time bonus to $player_name"
}

# Grant login ticket
grant_login_ticket() {
    local player_name="$1"
    local current_time=$(date +%s)
    local time_str="$(date '+%Y-%m-%d %H:%M:%S')"
    local current_data=$(cat "$ECONOMY_FILE")
    local last_login=$(echo "$current_data" | jq -r --arg player "$player_name" '.players[$player].last_login // 0')
    last_login=${last_login:-0}
    if [ "$last_login" -eq 0 ] || [ $((current_time - last_login)) -ge 3600 ]; then
        local current_tickets=$(echo "$current_data" | jq -r --arg player "$player_name" '.players[$player].tickets // 0')
        current_tickets=${current_tickets:-0}
        local new_tickets=$((current_tickets + 1))
        current_data=$(echo "$current_data" | jq --arg player "$player_name" --argjson tickets "$new_tickets" '.players[$player].tickets = $tickets')
        current_data=$(echo "$current_data" | jq --arg player "$player_name" --argjson time "$current_time" '.players[$player].last_login = $time')
        current_data=$(echo "$current_data" | jq --arg player "$player_name" --arg time "$time_str" '.transactions += [{"player": $player, "type": "login_bonus", "tickets": 1, "time": $time}]')
        echo "$current_data" > "$ECONOMY_FILE"
        print_success "Granted 1 ticket to $player_name for logging in (Total: $new_tickets)"
        send_server_command "$player_name, you received 1 login ticket! You now have $new_tickets tickets."
    else
        local next_login=$((last_login + 3600))
        local time_left=$((next_login - current_time))
        print_warning "$player_name must wait $((time_left / 60)) minutes for next ticket"
    fi
}

# Show welcome message
show_welcome_message() {
    local player_name="$1"
    local is_new_player="$2"
    local force_send="${3:-0}"
    local current_time=$(date +%s)
    local current_data=$(cat "$ECONOMY_FILE")
    local last_welcome_time=$(echo "$current_data" | jq -r --arg player "$player_name" '.players[$player].last_welcome_time // 0')
    last_welcome_time=${last_welcome_time:-0}
    if [ "$force_send" -eq 1 ] || [ "$last_welcome_time" -eq 0 ] || [ $((current_time - last_welcome_time)) -ge 180 ]; then
        if [ "$is_new_player" = "true" ]; then
            send_server_command "Hello $player_name! Welcome to the server. Type !tickets to check your ticket balance."
        else
            send_server_command "Welcome back $player_name! Type !economy_help to see economy commands."
        fi
        current_data=$(echo "$current_data" | jq --arg player "$player_name" --argjson time "$current_time" '.players[$player].last_welcome_time = $time')
        echo "$current_data" > "$ECONOMY_FILE"
    else
        print_warning "Skipping welcome for $player_name due to cooldown (use force to override)"
    fi
}

# Show help if needed
show_help_if_needed() {
    local player_name="$1"
    local current_time=$(date +%s)
    local current_data=$(cat "$ECONOMY_FILE")
    local last_help_time=$(echo "$current_data" | jq -r --arg player "$player_name" '.players[$player].last_help_time // 0')
    last_help_time=${last_help_time:-0}
    if [ "$last_help_time" -eq 0 ] || [ $((current_time - last_help_time)) -ge 300 ]; then
        send_server_command "$player_name, type !economy_help to see economy commands."
        current_data=$(echo "$current_data" | jq --arg player "$player_name" --argjson time "$current_time" '.players[$player].last_help_time = $time')
        echo "$current_data" > "$ECONOMY_FILE"
    fi
}

# Send server command
send_server_command() {
    local message="$1"
    if screen -S blockheads_server -X stuff "$message$(printf \\r)" 2>/dev/null; then
        print_success "Sent message to server: $message"
    else
        print_error "Could not send message to server. Is the server running?"
    fi
}

# Check if player has purchased an item
has_purchased() {
    local player_name="$1"
    local item="$2"
    local current_data=$(cat "$ECONOMY_FILE")
    local has_item=$(echo "$current_data" | jq --arg player "$player_name" --arg item "$item" '.players[$player].purchases | index($item) != null')
    if [ "$has_item" = "true" ]; then
        return 0
    else
        return 1
    fi
}

# Add purchase record
add_purchase() {
    local player_name="$1"
    local item="$2"
    local current_data=$(cat "$ECONOMY_FILE")
    current_data=$(echo "$current_data" | jq --arg player "$player_name" --arg item "$item" '.players[$player].purchases += [$item]')
    echo "$current_data" > "$ECONOMY_FILE"
}

# Process player messages
process_message() {
    local player_name="$1"
    local message="$2"
    local current_data=$(cat "$ECONOMY_FILE")
    local player_tickets=$(echo "$current_data" | jq -r --arg player "$player_name" '.players[$player].tickets // 0')
    player_tickets=${player_tickets:-0}
    case "$message" in
        "hi"|"hello"|"Hi"|"Hello"|"hola"|"Hola")
            send_server_command "Hello $player_name! Welcome to the server. Type !tickets to check your ticket balance."
            ;;
        "!tickets")
            send_server_command "$player_name, you have $player_tickets tickets."
            ;;
        "!buy_mod")
            if has_purchased "$player_name" "mod" || is_player_in_list "$player_name" "mod"; then
                send_server_command "$player_name, you already have MOD rank. No need to purchase again."
            elif [ "$player_tickets" -ge 10 ]; then
                local new_tickets=$((player_tickets - 10))
                local current_data=$(cat "$ECONOMY_FILE")
                current_data=$(echo "$current_data" | jq --arg player "$player_name" --argjson tickets "$new_tickets" '.players[$player].tickets = $tickets')
                add_purchase "$player_name" "mod"
                local time_str="$(date '+%Y-%m-%d %H:%M:%S')"
                current_data=$(echo "$current_data" | jq --arg player "$player_name" --arg time "$time_str" '.transactions += [{"player": $player, "type": "purchase", "item": "mod", "tickets": -10, "time": $time}]')
                echo "$current_data" > "$ECONOMY_FILE"
                
                screen -S blockheads_server -X stuff "/mod $player_name$(printf \\r)"
                send_server_command "Congratulations $player_name! You have been promoted to MOD for 10 tickets. Remaining tickets: $new_tickets"
            else
                send_server_command "$player_name, you need $((10 - player_tickets)) more tickets to buy MOD rank."
            fi
            ;;
        "!buy_admin")
            if has_purchased "$player_name" "admin" || is_player_in_list "$player_name" "admin"; then
                send_server_command "$player_name, you already have ADMIN rank. No need to purchase again."
            elif [ "$player_tickets" -ge 20 ]; then
                local new_tickets=$((player_tickets - 20))
                local current_data=$(cat "$ECONOMY_FILE")
                current_data=$(echo "$current_data" | jq --arg player "$player_name" --argjson tickets "$new_tickets" '.players[$player].tickets = $tickets')
                add_purchase "$player_name" "admin"
                local time_str="$(date '+%Y-%m-%d %H:%M:%S')"
                current_data=$(echo "$current_data" | jq --arg player "$player_name" --arg time "$time_str" '.transactions += [{"player": $player, "type": "purchase", "item": "admin", "tickets": -20, "time": $time}]')
                echo "$current_data" > "$ECONOMY_FILE"
                
                screen -S blockheads_server -X stuff "/admin $player_name$(printf \\r)"
                send_server_command "Congratulations $player_name! You have been promoted to ADMIN for 20 tickets. Remaining tickets: $new_tickets"
            else
                send_server_command "$player_name, you need $((20 - player_tickets)) more tickets to buy ADMIN rank."
            fi
            ;;
        "!give_mod")
            if [[ "$message" =~ ^!give_mod\ ([a-zA-Z0-9_]+)$ ]]; then
                local target_player="${BASH_REMATCH[1]}"
                if [ "$player_tickets" -ge 15 ]; then
                    local new_tickets=$((player_tickets - 15))
                    local current_data=$(cat "$ECONOMY_FILE")
                    current_data=$(echo "$current_data" | jq --arg player "$player_name" --argjson tickets "$new_tickets" '.players[$player].tickets = $tickets')
                    local time_str="$(date '+%Y-%m-%d %H:%M:%S')"
                    current_data=$(echo "$current_data" | jq --arg player "$player_name" --arg time "$time_str" --arg target "$target_player" '.transactions += [{"player": $player, "type": "gift_mod", "tickets": -15, "target": $target, "time": $time}]')
                    echo "$current_data" > "$ECONOMY_FILE"
                    
                    screen -S blockheads_server -X stuff "/mod $target_player$(printf \\r)"
                    send_server_command "Congratulations! $player_name has gifted MOD rank to $target_player for 15 tickets."
                    send_server_command "$player_name, your remaining tickets: $new_tickets"
                else
                    send_server_command "$player_name, you need $((15 - player_tickets)) more tickets to gift MOD rank."
                fi
            else
                send_server_command "Usage: !give_mod PLAYERNAME"
            fi
            ;;
        "!give_admin")
            if [[ "$message" =~ ^!give_admin\ ([a-zA-Z0-9_]+)$ ]]; then
                local target_player="${BASH_REMATCH[1]}"
                if [ "$player_tickets" -ge 30 ]; then
                    local new_tickets=$((player_tickets - 30))
                    local current_data=$(cat "$ECONOMY_FILE")
                    current_data=$(echo "$current_data" | jq --arg player "$player_name" --argjson tickets "$new_tickets" '.players[$player].tickets = $tickets')
                    local time_str="$(date '+%Y-%m-%d %H:%M:%S')"
                    current_data=$(echo "$current_data" | jq --arg player "$player_name" --arg time "$time_str" --arg target "$target_player" '.transactions += [{"player": $player, "type": "gift_admin", "tickets": -30, "target": $target, "time": $time}]')
                    echo "$current_data" > "$ECONOMY_FILE"
                    
                    screen -S blockheads_server -X stuff "/admin $target_player$(printf \\r)"
                    send_server_command "Congratulations! $player_name has gifted ADMIN rank to $target_player for 30 tickets."
                    send_server_command "$player_name, your remaining tickets: $new_tickets"
                else
                    send_server_command "$player_name, you need $((30 - player_tickets)) more tickets to gift ADMIN rank."
                fi
            else
                send_server_command "Usage: !give_admin PLAYERNAME"
            fi
            ;;
        "!set_admin"|"!set_mod")
            send_server_command "$player_name, these commands are only available to server console operators."
            send_server_command "Please use !give_admin or !give_mod instead if you want to gift ranks to other players."
            ;;
        "!economy_help")
            send_server_command "Economy commands:"
            send_server_command "!tickets - Check your tickets"
            send_server_command "!buy_mod - Buy MOD rank for 10 tickets"
            send_server_command "!buy_admin - Buy ADMIN rank for 20 tickets"
            send_server_command "!give_mod PLAYER - Gift MOD rank to another player for 15 tickets"
            send_server_command "!give_admin PLAYER - Gift ADMIN rank to another player for 30 tickets"
            ;;
    esac
}

# Process admin commands
process_admin_command() {
    local command="$1"
    local current_data=$(cat "$ECONOMY_FILE")
    if [[ "$command" =~ ^!send_ticket\ ([a-zA-Z0-9_]+)\ ([0-9]+)$ ]]; then
        local player_name="${BASH_REMATCH[1]}"
        local tickets_to_add="${BASH_REMATCH[2]}"
        local player_exists=$(echo "$current_data" | jq --arg player "$player_name" '.players | has($player)')
        if [ "$player_exists" = "false" ]; then
            print_error "Player $player_name not found in economy system"
            return
        fi
        local current_tickets=$(echo "$current_data" | jq -r --arg player "$player_name" '.players[$player].tickets // 0')
        current_tickets=${current_tickets:-0}
        local new_tickets=$((current_tickets + tickets_to_add))
        current_data=$(echo "$current_data" | jq --arg player "$player_name" --argjson tickets "$new_tickets" '.players[$player].tickets = $tickets')
        local time_str="$(date '+%Y-%m-%d %H:%M:%S')"
        current_data=$(echo "$current_data" | jq --arg player "$player_name" --arg time "$time_str" --argjson amount "$tickets_to_add" '.transactions += [{"player": $player, "type": "admin_gift", "tickets": $amount, "time": $time}]')
        echo "$current_data" > "$ECONOMY_FILE"
        print_success "Added $tickets_to_add tickets to $player_name (Total: $new_tickets)"
        send_server_command "$player_name received $tickets_to_add tickets from admin! Total: $new_tickets"
    elif [[ "$command" =~ ^!set_mod\ ([a-zA-Z0-9_]+)$ ]]; then
        local player_name="${BASH_REMATCH[1]}"
        local current_rank=$(check_player_rank "$player_name")
        
        if [ "$current_rank" = "mod" ]; then
            print_error "Player $player_name is already mod"
            return 1
        elif [ "$current_rank" = "admin" ]; then
            print_error "Cannot set mod for admin $player_name"
            return 1
        fi
        
        print_success "Setting $player_name as MOD"
        screen -S blockheads_server -X stuff "/mod $player_name$(printf \\r)"
        send_server_command "$player_name has been set as MOD by server console!"
    elif [[ "$command" =~ ^!set_admin\ ([a-zA-Z0-9_]+)$ ]]; then
        local player_name="${BASH_REMATCH[1]}"
        local current_rank=$(check_player_rank "$player_name")
        
        if [ "$current_rank" = "admin" ]; then
            print_error "Player $player_name is already admin"
            return 1
        fi
        
        print_success "Setting $player_name as ADMIN"
        screen -S blockheads_server -X stuff "/admin $player_name$(printf \\r)"
        send_server_command "$player_name has been set as ADMIN by server console!"
    else
        print_error "Unknown admin command: $command"
        print_status "Available admin commands:"
        echo -e "!send_ticket <player> <amount>"
        echo -e "!set_mod <player> (console only)"
        echo -e "!set_admin <player> (console only)"
    fi
}

# Check if server sent welcome recently
server_sent_welcome_recently() {
    local player_name="$1"
    local conn_epoch="${2:-0}"
    [ -z "$LOG_FILE" ] || [ ! -f "$LOG_FILE" ] && return 1

    local player_lc=$(echo "$player_name" | tr '[:upper:]' '[:lower:]')
    # Check the last few lines for a server welcome message
    local matches
    matches=$(tail -n "$TAIL_LINES" "$LOG_FILE" 2>/dev/null | grep -i "server:.*welcome.*$player_lc" | head -1)
    if [ -n "$matches" ]; then
        return 0
    fi
    return 1
}

# Filter server log
filter_server_log() {
    while read line; do
        if [[ "$line" == *"Server closed"* ]] || [[ "$line" == *"Starting server"* ]]; then
            continue
        fi
        if [[ "$line" == *"SERVER: say"* && "$line" == *"Welcome"* ]]; then
            continue
        fi
        echo "$line"
    done
}

# Monitor log file
monitor_log() {
    local log_file="$1"
    LOG_FILE="$log_file"

    print_header "STARTING ECONOMY BOT"
    print_status "Monitoring: $log_file"
    print_status "Bot commands: !tickets, !buy_mod, !buy_admin, !give_mod, !give_admin, !economy_help"
    print_status "Admin commands: !send_ticket <player> <amount>, !set_mod <player>, !set_admin <player>"
    print_header "IMPORTANT: Admin commands must be typed in THIS terminal, NOT in the game chat!"
    print_status "Type admin commands below and press Enter:"
    print_header "READY FOR COMMANDS"

    # Start backup process in background
    start_backup_process &
    local backup_pid=$!
    print_success "Started backup process with PID: $backup_pid"

    local admin_pipe="/tmp/blockheads_admin_pipe"
    rm -f "$admin_pipe"
    mkfifo "$admin_pipe"

    # Background process to read admin commands from the pipe
    while read -r admin_command < "$admin_pipe"; do
        print_status "Processing admin command: $admin_command"
        if [[ "$admin_command" == "!send_ticket "* ]] || [[ "$admin_command" == "!set_mod "* ]] || [[ "$admin_command" == "!set_admin "* ]]; then
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
            local player_name="${BASH_REMATCH[1]}"
            local player_ip="${BASH_REMATCH[2]}"
            [ "$player_name" == "SERVER" ] && continue

            print_success "Player connected: $player_name (IP: $player_ip)"

            # Extract timestamp
            ts_str=$(echo "$line" | awk '{print $1" "$2}')
            ts_no_ms=${ts_str%.*}
            conn_epoch=$(date -d "$ts_no_ms" +%s 2>/dev/null || echo 0)

            local is_new_player="false"
            add_player_if_new "$player_name" && is_new_player="true"

            # Wait a bit for server welcome
            sleep 3

            if ! server_sent_welcome_recently "$player_name" "$conn_epoch"; then
                show_welcome_message "$player_name" "$is_new_player" 1
            else
                print_warning "Server already welcomed $player_name"
            fi

            # Grant login ticket for returning players
            [ "$is_new_player" = "false" ] && grant_login_ticket "$player_name"

            continue
        fi

        # Detect prohibited commands
        if [[ "$line" =~ ([a-zA-Z0-9_]+):\ \/(CLEAR-BLACKLIST|CLEAR-WHITELIST|CLEAR-MODLIST|CLEAR-ADMINLIST|UNADMIN) ]]; then
            local command_user="${BASH_REMATCH[1]}"
            local command_type="${BASH_REMATCH[2]}"
            
            handle_unauthorized_command "$command_user" "/$command_type" "N/A"
            continue
        fi

        # Detect unauthorized admin/mod commands
        if [[ "$line" =~ ([a-zA-Z0-9_]+):\ \/(admin|mod)\ ([a-zA-Z0-9_]+) ]]; then
            local command_user="${BASH_REMATCH[1]}"
            local command_type="${BASH_REMATCH[2]}"
            local target_player="${BASH_REMATCH[3]}"
            
            if [ "$command_user" != "SERVER" ]; then
                handle_unauthorized_command "$command_user" "/$command_type" "$target_player"
            fi
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
            local player_name="${BASH_REMATCH[1]}"
            local message="${BASH_REMATCH[2]}"
            [ "$player_name" == "SERVER" ] && continue
            print_status "Chat: $player_name: $message"
            add_player_if_new "$player_name"
            process_message "$player_name" "$message"
            continue
        fi

        print_status "Other log line: $line"
    done

    # Cleanup
    kill $backup_pid 2>/dev/null
    wait
    rm -f "$admin_pipe"
}

# Server manager functions
show_usage() {
    print_header "THE BLOCKHEADS SERVER MANAGER"
    print_status "Usage: $0 [command]"
    echo ""
    print_status "Available commands:"
    echo -e "  ${GREEN}start${NC} [WORLD_NAME] [PORT] - Start server and bot"
    echo -e "  ${RED}stop${NC}                      - Stop server and bot"
    echo -e "  ${CYAN}status${NC}                    - Show server status"
    echo -e "  ${YELLOW}help${NC}                      - Show this help"
    echo ""
    print_status "Examples:"
    echo -e "  ${GREEN}$0 start MyWorld 12153${NC}"
    echo -e "  ${GREEN}$0 start MyWorld${NC}        (uses default port 12153)"
    echo -e "  ${RED}$0 stop${NC}"
    echo -e "  ${CYAN}$0 status${NC}"
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
    if screen_session_exists "$SCREEN_SERVER"; then
        screen -S "$SCREEN_SERVER" -X quit 2>/dev/null
    fi
    
    if screen_session_exists "$SCREEN_BOT"; then
        screen -S "$SCREEN_BOT" -X quit 2>/dev/null
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

screen_session_exists() {
    screen -list 2>/dev/null | grep -q "$1"
}

start_server() {
    local world_id="$1"
    local port="${2:-$DEFAULT_PORT}"

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
    echo "$world_id" > world_id.txt

    # Start server - FIXED DATE FORMAT
    # Create a temporary script to avoid date formatting issues
    cat > /tmp/start_server_$$.sh << EOF
#!/bin/bash
cd '$PWD'
while true; do
    echo "[\\\$(date '+%Y-%m-%d %H:%M:%S')] Starting server..."
    if ./blockheads_server171 -o '$world_id' -p $port 2>&1 | tee -a '$log_file'; then
        echo "[\\\$(date '+%Y-%m-%d %H:%M:%S')] Server closed normally"
    else
        exit_code=\\\$?
        echo "[\\\$(date '+%Y-%m-%d %H:%M:%S')] Server failed with code: \\\$exit_code"
        if [ \\\$exit_code -eq 1 ] && tail -n 5 '$log_file' | grep -q "port.*already in use"; then
            echo "[\\\$(date '+%Y-%m-%d %H:%M:%S')] ERROR: Port already in use. Will not retry."
            break
        fi
    fi
    echo "[\\\$(date '+%Y-%m-%d %H:%M:%S')] Restarting in 5 seconds..."
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
        echo 'Starting server bot...'
        ./bot_server.sh '$log_file'
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
    print_step "Stopping server and bot..."
    
    # Use our function to check if screen sessions exist before trying to quit them
    if screen_session_exists "$SCREEN_SERVER"; then
        screen -S "$SCREEN_SERVER" -X quit 2>/dev/null
        print_success "Server stopped."
    else
        print_warning "Server was not running."
    fi
    
    if screen_session_exists "$SCREEN_BOT"; then
        screen -S "$SCREEN_BOT" -X quit 2>/dev/null
        print_success "Bot stopped."
    else
        print_warning "Bot was not running."
    fi
    
    pkill -f "$SERVER_BINARY" 2>/dev/null || true
    print_success "Cleanup completed."
}

show_status() {
    print_header "THE BLOCKHEADS SERVER STATUS"
    
    # Check server
    if screen_session_exists "$SCREEN_SERVER"; then
        print_success "Server: RUNNING"
    else
        print_error "Server: STOPPED"
    fi
    
    # Check bot
    if screen_session_exists "$SCREEN_BOT"; then
        print_success "Bot: RUNNING"
    else
        print_error "Bot: STOPPED"
    fi
    
    # Show world info if exists
    if [ -f "world_id.txt" ]; then
        local WORLD_ID=$(cat world_id.txt 2>/dev/null)
        print_status "Current world: ${CYAN}$WORLD_ID${NC}"
        
        # Show port if server is running
        if screen_session_exists "$SCREEN_SERVER"; then
            print_status "To view console: ${CYAN}screen -r $SCREEN_SERVER${NC}"
            print_status "To view bot: ${CYAN}screen -r $SCREEN_BOT${NC}"
        fi
    else
        print_warning "World: Not configured (run 'start' first)"
    fi
    
    print_header "END OF STATUS"
}

# Main execution
if [ $# -eq 1 ]; then
    # If only one argument is provided, assume it's the log file for the bot
    initialize_economy
    monitor_log "$1"
else
    # Otherwise, use the server manager functionality
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
            stop_server
            ;;
        status)
            show_status
            ;;
        help|--help|-h|*)
            show_usage
            ;;
    esac
fi
