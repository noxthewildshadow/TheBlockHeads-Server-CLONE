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

# Bot configuration
ECONOMY_FILE="economy_data.json"
SCAN_INTERVAL=5
SERVER_WELCOME_WINDOW=15
TAIL_LINES=500
ADMIN_OFFENSES_FILE="admin_offenses.json"
BACKUP_DIR="list_backups"
RESTORE_PENDING_FILE="restore_pending.txt"

# Initialize admin offenses tracking
initialize_admin_offenses() {
    if [ ! -f "$ADMIN_OFFENSES_FILE" ]; then
        echo '{}' > "$ADMIN_OFFENSES_FILE"
        print_success "Admin offenses tracking file created"
    fi
}

# Initialize backup directory
initialize_backup_dir() {
    if [ ! -d "$BACKUP_DIR" ]; then
        mkdir -p "$BACKUP_DIR"
        print_success "Backup directory created: $BACKUP_DIR"
    fi
}

# Function to create backup of critical list files
create_list_backup() {
    local reason="$1"
    local world_dir
    world_dir=$(dirname "$LOG_FILE")
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_file="${BACKUP_DIR}/backup_${timestamp}_${reason}.tar.gz"

    if [ ! -d "$world_dir" ]; then
        print_error "World directory not found: $world_dir"
        return 1
    fi

    local files_to_backup=""
    for file in adminlist.txt modlist.txt blacklist.txt; do
        if [ -f "$world_dir/$file" ]; then
            files_to_backup="$files_to_backup $file"
        fi
    done

    if [ -z "$files_to_backup" ]; then
        print_error "No list files found to backup in $world_dir"
        return 1
    fi

    tar -czf "$backup_file" -C "$world_dir" $files_to_backup 2>/dev/null

    echo "$backup_file" > "${BACKUP_DIR}/latest_backup.txt"

    print_success "Created backup: $backup_file (Reason: $reason)"
}

# Function to restore from backup
restore_from_backup() {
    local backup_file="$1"
    local world_dir
    world_dir=$(dirname "$LOG_FILE")

    if [ ! -f "$backup_file" ]; then
        print_error "Backup file not found: $backup_file"
        return 1
    fi

    if [ ! -d "$world_dir" ]; then
        print_error "World directory not found: $world_dir"
        return 1
    fi

    tar -xzf "$backup_file" -C "$world_dir"
    print_success "Restored from backup: $backup_file"

    send_server_command "WARNING: Unauthorized list modifications detected! Restoring legitimate lists."
    send_server_command "Please rejoin the server if you experience permission issues."
}

# Schedule a restore operation
schedule_restore() {
    local backup_file="$1"
    local delay_seconds="${2:-5}"

    echo "$backup_file" > "$RESTORE_PENDING_FILE"
    (
        sleep "$delay_seconds"
        if [ -f "$RESTORE_PENDING_FILE" ] && [ "$(cat "$RESTORE_PENDING_FILE")" = "$backup_file" ]; then
            restore_from_backup "$backup_file"
            rm -f "$RESTORE_PENDING_FILE"
        fi
    ) &
    print_warning "Scheduled restore from $backup_file in $delay_seconds seconds"
}

# Cancel pending restore
cancel_restore() {
    if [ -f "$RESTORE_PENDING_FILE" ]; then
        rm -f "$RESTORE_PENDING_FILE"
        print_success "Cancelled pending restore operation"
    fi
}

# Function to record admin offense
# Now prints the offense count to stdout (caller should capture it)
record_admin_offense() {
    local admin_name="$1"
    local current_time
    current_time=$(date +%s)
    local offenses_data
    offenses_data=$(cat "$ADMIN_OFFENSES_FILE" 2>/dev/null || echo '{}')

    local current_offenses
    current_offenses=$(echo "$offenses_data" | jq -r --arg admin "$admin_name" '.[$admin]?.count // 0')
    current_offenses=${current_offenses:-0}
    local last_offense_time
    last_offense_time=$(echo "$offenses_data" | jq -r --arg admin "$admin_name" '.[$admin]?.last_offense // 0')
    last_offense_time=${last_offense_time:-0}

    if [ $((current_time - last_offense_time)) -gt 300 ]; then
        current_offenses=0
    fi

    current_offenses=$((current_offenses + 1))

    offenses_data=$(echo "$offenses_data" | jq --arg admin "$admin_name" \
        --argjson count "$current_offenses" \
        --argjson time "$current_time" \
        '.[$admin] = {"count": $count, "last_offense": $time}')

    echo "$offenses_data" > "$ADMIN_OFFENSES_FILE"
    print_warning "Recorded offense #$current_offenses for admin $admin_name"

    # Output the count so the caller can use it
    echo "$current_offenses"
    return 0
}

# Function to clear admin offenses
clear_admin_offenses() {
    local admin_name="$1"
    local offenses_data
    offenses_data=$(cat "$ADMIN_OFFENSES_FILE" 2>/dev/null || echo '{}')

    offenses_data=$(echo "$offenses_data" | jq --arg admin "$admin_name" 'del(.[$admin])')
    echo "$offenses_data" > "$ADMIN_OFFENSES_FILE"
    print_success "Cleared offenses for admin $admin_name"
}

# Function to remove player from list file (improved: cancel pending restore, create backup after removal)
remove_from_list_file() {
    local player_name="$1"
    local list_type="$2"  # "admin" or "mod"

    local world_dir
    world_dir=$(dirname "$LOG_FILE")
    local list_file="$world_dir/${list_type}list.txt"

    if [ ! -f "$list_file" ]; then
        print_error "List file not found: $list_file"
        return 1
    fi

    # Remove the player case-insensitively using fixed-string match
    grep -F -vi -x -- "$player_name" "$list_file" > "${list_file}.tmp" || true
    mv "${list_file}.tmp" "$list_file"

    sync "$list_file" 2>/dev/null || true

    print_success "Removed $player_name from ${list_type}list.txt (if it existed)"

    # Cancel any scheduled restore so an older backup doesn't re-add the player
    cancel_restore

    # Create a fresh backup to represent the new correct state
    create_list_backup "post_remove_${list_type}_${player_name}" >/dev/null 2>&1 || true

    return 0
}

# Function to remove purchase record for a rank
remove_purchase_record() {
    local player_name="$1"
    local rank="$2"  # "admin" or "mod"
    if [ ! -f "$ECONOMY_FILE" ]; then
        print_warning "Economy file not found when removing purchase record"
        return 1
    fi
    local current_data
    current_data=$(cat "$ECONOMY_FILE")

    # Remove the purchase record safely (if exists)
    current_data=$(echo "$current_data" | jq --arg player "$player_name" --arg rank "$rank" 'if .players[$player].purchases then .players[$player].purchases = (.players[$player].purchases | map(select(. != $rank))) else . end')
    echo "$current_data" > "$ECONOMY_FILE"
    print_success "Removed $rank purchase record for $player_name"
}

initialize_economy() {
    if [ ! -f "$ECONOMY_FILE" ]; then
        echo '{"players": {}, "transactions": []}' > "$ECONOMY_FILE"
        print_success "Economy data file created"
    fi
    initialize_admin_offenses
    initialize_backup_dir
}

is_player_in_list() {
    local player_name="$1"
    local list_type="$2"
    local world_dir
    world_dir=$(dirname "$LOG_FILE")
    local list_file="$world_dir/${list_type}list.txt"
    if [ -f "$list_file" ]; then
        if grep -qi -x -- "$player_name" "$list_file"; then
            return 0
        fi
    fi
    return 1
}

add_player_if_new() {
    local player_name="$1"
    local current_data
    current_data=$(cat "$ECONOMY_FILE")
    local player_exists
    player_exists=$(echo "$current_data" | jq --arg player "$player_name" '.players | has($player)')
    if [ "$player_exists" = "false" ]; then
        current_data=$(echo "$current_data" | jq --arg player "$player_name" '.players[$player] = {"tickets": 0, "last_login": 0, "last_welcome_time": 0, "last_help_time": 0, "purchases": []}')
        echo "$current_data" > "$ECONOMY_FILE"
        print_success "Added new player: $player_name"
        give_first_time_bonus "$player_name"
        return 0
    fi
    return 1
}

give_first_time_bonus() {
    local player_name="$1"
    local current_data
    current_data=$(cat "$ECONOMY_FILE")
    local current_time
    current_time=$(date +%s)
    local time_str
    time_str=$(date '+%Y-%m-%d %H:%M:%S')
    current_data=$(echo "$current_data" | jq --arg player "$player_name" '.players[$player].tickets = 1')
    current_data=$(echo "$current_data" | jq --arg player "$player_name" --argjson time "$current_time" '.players[$player].last_login = $time')
    current_data=$(echo "$current_data" | jq --arg player "$player_name" --arg time "$time_str" '.transactions += [{"player": $player, "type": "welcome_bonus", "tickets": 1, "time": $time}]')
    echo "$current_data" > "$ECONOMY_FILE"
    print_success "Gave first-time bonus to $player_name"
}

grant_login_ticket() {
    local player_name="$1"
    local current_time
    current_time=$(date +%s)
    local time_str
    time_str=$(date '+%Y-%m-%d %H:%M:%S')
    local current_data
    current_data=$(cat "$ECONOMY_FILE")
    local last_login
    last_login=$(echo "$current_data" | jq -r --arg player "$player_name" '.players[$player].last_login // 0')
    last_login=${last_login:-0}
    if [ "$last_login" -eq 0 ] || [ $((current_time - last_login)) -ge 3600 ]; then
        local current_tickets
        current_tickets=$(echo "$current_data" | jq -r --arg player "$player_name" '.players[$player].tickets // 0')
        current_tickets=${current_tickets:-0}
        local new_tickets
        new_tickets=$((current_tickets + 1))
        current_data=$(echo "$current_data" | jq --arg player "$player_name" --argjson tickets "$new_tickets" '.players[$player].tickets = $tickets')
        current_data=$(echo "$current_data" | jq --arg player "$player_name" --argjson time "$current_time" '.players[$player].last_login = $time')
        current_data=$(echo "$current_data" | jq --arg player "$player_name" --arg time "$time_str" '.transactions += [{"player": $player, "type": "login_bonus", "tickets": 1, "time": $time}]')
        echo "$current_data" > "$ECONOMY_FILE"
        print_success "Granted 1 ticket to $player_name for logging in (Total: $new_tickets)"
        send_server_command "$player_name, you received 1 login ticket! You now have $new_tickets tickets."
    else
        local next_login
        next_login=$((last_login + 3600))
        local time_left
        time_left=$((next_login - current_time))
        print_warning "$player_name must wait $((time_left / 60)) minutes for next ticket"
    fi
}

show_welcome_message() {
    local player_name="$1"
    local is_new_player="$2"
    local force_send="${3:-0}"
    local current_time
    current_time=$(date +%s)
    local current_data
    current_data=$(cat "$ECONOMY_FILE")
    local last_welcome_time
    last_welcome_time=$(echo "$current_data" | jq -r --arg player "$player_name" '.players[$player].last_welcome_time // 0')
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

show_help_if_needed() {
    local player_name="$1"
    local current_time
    current_time=$(date +%s)
    local current_data
    current_data=$(cat "$ECONOMY_FILE")
    local last_help_time
    last_help_time=$(echo "$current_data" | jq -r --arg player "$player_name" '.players[$player].last_help_time // 0')
    last_help_time=${last_help_time:-0}
    if [ "$last_help_time" -eq 0 ] || [ $((current_time - last_help_time)) -ge 300 ]; then
        send_server_command "$player_name, type !economy_help to see economy commands."
        current_data=$(echo "$current_data" | jq --arg player "$player_name" --argjson time "$current_time" '.players[$player].last_help_time = $time')
        echo "$current_data" > "$ECONOMY_FILE"
    fi
}

send_server_command() {
    local message="$1"

    # Try to use GNU screen if the session exists
    if screen -ls 2>/dev/null | grep -q "blockheads_server"; then
        if screen -S blockheads_server -X stuff "$message$(printf \r)" 2>/dev/null; then
            print_success "Sent message to server via screen: $message"
            return 0
        else
            print_error "Screen session exists but failed to send message."
        fi
    fi

    # Try tmux as an alternative if installed and session exists
    if command -v tmux >/dev/null 2>&1 && tmux ls 2>/dev/null | grep -q "^blockheads_server:"; then
        if tmux send-keys -t blockheads_server "$message" C-m 2>/dev/null; then
            print_success "Sent message to server via tmux: $message"
            return 0
        else
            print_error "tmux session exists but failed to send message."
        fi
    fi

    # Fallback: queue command to a file so an operator can inject it later
    local queue_file="${BACKUP_DIR}/server_cmd_queue.txt"
    echo "$message" >> "$queue_file"
    print_warning "No screen/tmux session found. Command queued to: $queue_file"
    print_status "To apply queued commands later, start the server in a detached screen named 'blockheads_server' and run:"
    echo -e "  while read cmd; do screen -S blockheads_server -X stuff \"$cmd\
\"; done < ${queue_file}"
    return 1
}

has_purchased() {
    local player_name="$1"
    local item="$2"
    local current_data
    current_data=$(cat "$ECONOMY_FILE")
    local has_item
    has_item=$(echo "$current_data" | jq --arg player "$player_name" --arg item "$item" '.players[$player].purchases | index($item) != null')
    if [ "$has_item" = "true" ]; then
        return 0
    else
        return 1
    fi
}

add_purchase() {
    local player_name="$1"
    local item="$2"
    local current_data
    current_data=$(cat "$ECONOMY_FILE")
    current_data=$(echo "$current_data" | jq --arg player "$player_name" --arg item "$item" '.players[$player].purchases += [$item]')
    echo "$current_data" > "$ECONOMY_FILE"
}

# Function to handle unauthorized admin/mod commands
handle_unauthorized_command() {
    local player_name="$1"
    local command="$2"
    local target_player="$3"

    if is_player_in_list "$player_name" "admin"; then
        print_error "UNAUTHORIZED COMMAND: Admin $player_name attempted to use $command on $target_player"
        send_server_command "WARNING: Admin $player_name attempted unauthorized rank assignment!"

        if [ "$command" = "/admin" ]; then
            send_server_command "/unadmin $target_player"
            if ! remove_from_list_file "$target_player" "admin"; then
                # failed to remove from file -> fallback to restore
                if [ -f "${BACKUP_DIR}/latest_backup.txt" ]; then
                    local latest_backup
                    latest_backup=$(cat "${BACKUP_DIR}/latest_backup.txt")
                    schedule_restore "$latest_backup" 5
                else
                    print_error "No backup available to restore from!"
                fi
            else
                print_success "Revoked admin rank from $target_player"
            fi
        elif [ "$command" = "/mod" ]; then
            send_server_command "/unmod $target_player"
            if ! remove_from_list_file "$target_player" "mod"; then
                if [ -f "${BACKUP_DIR}/latest_backup.txt" ]; then
                    local latest_backup
                    latest_backup=$(cat "${BACKUP_DIR}/latest_backup.txt")
                    schedule_restore "$latest_backup" 5
                else
                    print_error "No backup available to restore from!"
                fi
            else
                print_success "Revoked mod rank from $target_player"
            fi
        fi

        # Record the offense and capture the count
        local offense_count
        offense_count=$(record_admin_offense "$player_name" 2>/dev/null || echo 0)

        # First offense: warning
        if [ "$offense_count" -eq 1 ]; then
            send_server_command "$player_name, this is your first warning! Only the server console can assign ranks using !set_admin or !set_mod."
            print_warning "First offense recorded for admin $player_name"

        # Second offense within 5 minutes: demote to mod
        elif [ "$offense_count" -ge 2 ]; then
            print_warning "SECOND OFFENSE: Admin $player_name is being demoted to mod for unauthorized command usage"

            send_server_command "/unadmin $player_name"
            remove_from_list_file "$player_name" "admin"

            remove_purchase_record "$player_name" "admin"

            send_server_command "/mod $player_name"
            send_server_command "ALERT: Admin $player_name has been demoted to moderator for repeatedly attempting unauthorized admin commands!"
            send_server_command "Only the server console can assign ranks using !set_admin or !set_mod."

            clear_admin_offenses "$player_name"
        fi
    else
        # Non-admin players just get a warning and the command is blocked
        print_warning "Non-admin player $player_name attempted to use $command on $target_player"
        send_server_command "$player_name, you don't have permission to assign ranks. Only server admins can use !give_mod or !give_admin commands."

        if [ "$command" = "/admin" ]; then
            send_server_command "/unadmin $target_player"
            if ! remove_from_list_file "$target_player" "admin"; then
                if [ -f "${BACKUP_DIR}/latest_backup.txt" ]; then
                    local latest_backup
                    latest_backup=$(cat "${BACKUP_DIR}/latest_backup.txt")
                    schedule_restore "$latest_backup" 5
                else
                    print_error "No backup available to restore from!"
                fi
            fi
        elif [ "$command" = "/mod" ]; then
            send_server_command "/unmod $target_player"
            if ! remove_from_list_file "$target_player" "mod"; then
                if [ -f "${BACKUP_DIR}/latest_backup.txt" ]; then
                    local latest_backup
                    latest_backup=$(cat "${BACKUP_DIR}/latest_backup.txt")
                    schedule_restore "$latest_backup" 5
                else
                    print_error "No backup available to restore from!"
                fi
            fi
        fi

    fi
}

process_message() {
    local player_name="$1"
    local message="$2"
    local current_data
    current_data=$(cat "$ECONOMY_FILE")
    local player_tickets
    player_tickets=$(echo "$current_data" | jq -r --arg player "$player_name" '.players[$player].tickets // 0')
    player_tickets=${player_tickets:-0}
    case "$message" in
        "hi"|"hello"|"Hi"|"Hello"|"hola"|"Hola")
            send_server_command "Hello $player_name! Welcome to the server. Type !tickets to check your ticket balance."
            ;;
        "!tickets")
            send_server_command "$player_name, you have $player_tickets tickets."
            ;;
        "!buy_mod")
            if is_player_in_list "$player_name" "mod"; then
                send_server_command "$player_name, you already have MOD rank. No need to purchase again."
            elif [ "$player_tickets" -ge 10 ]; then
                local new_tickets
                new_tickets=$((player_tickets - 10))
                current_data=$(cat "$ECONOMY_FILE")
                current_data=$(echo "$current_data" | jq --arg player "$player_name" --argjson tickets "$new_tickets" '.players[$player].tickets = $tickets')
                add_purchase "$player_name" "mod"
                local time_str
                time_str=$(date '+%Y-%m-%d %H:%M:%S')
                current_data=$(echo "$current_data" | jq --arg player "$player_name" --arg time "$time_str" '.transactions += [{"player": $player, "type": "purchase", "item": "mod", "tickets": -10, "time": $time}]')
                echo "$current_data" > "$ECONOMY_FILE"

                screen -S blockheads_server -X stuff "/mod $player_name$(printf \\\r)"
                send_server_command "Congratulations $player_name! You have been promoted to MOD for 10 tickets. Remaining tickets: $new_tickets"

                create_list_backup "buy_mod"
            else
                send_server_command "$player_name, you need $((10 - player_tickets)) more tickets to buy MOD rank."
            fi
            ;;
        "!buy_admin")
            if is_player_in_list "$player_name" "admin"; then
                send_server_command "$player_name, you already have ADMIN rank. No need to purchase again."
            elif [ "$player_tickets" -ge 20 ]; then
                local new_tickets
                new_tickets=$((player_tickets - 20))
                current_data=$(cat "$ECONOMY_FILE")
                current_data=$(echo "$current_data" | jq --arg player "$player_name" --argjson tickets "$new_tickets" '.players[$player].tickets = $tickets')
                add_purchase "$player_name" "admin"
                local time_str
                time_str=$(date '+%Y-%m-%d %H:%M:%S')
                current_data=$(echo "$current_data" | jq --arg player "$player_name" --arg time "$time_str" '.transactions += [{"player": $player, "type": "purchase", "item": "admin", "tickets": -20, "time": $time}]')
                echo "$current_data" > "$ECONOMY_FILE"

                screen -S blockheads_server -X stuff "/admin $player_name$(printf \\\r)"
                send_server_command "Congratulations $player_name! You have been promoted to ADMIN for 20 tickets. Remaining tickets: $new_tickets"

                create_list_backup "buy_admin"
            else
                send_server_command "$player_name, you need $((20 - player_tickets)) more tickets to buy ADMIN rank."
            fi
            ;;
        "!give_mod")
            if [[ "$message" =~ ^!give_mod\ ([a-zA-Z0-9_]+)$ ]]; then
                local target_player
                target_player="${BASH_REMATCH[1]}"
                if [ "$player_tickets" -ge 15 ]; then
                    local new_tickets
                    new_tickets=$((player_tickets - 15))
                    current_data=$(cat "$ECONOMY_FILE")
                    current_data=$(echo "$current_data" | jq --arg player "$player_name" --argjson tickets "$new_tickets" '.players[$player].tickets = $tickets')
                    local time_str
                    time_str=$(date '+%Y-%m-%d %H:%M:%S')
                    current_data=$(echo "$current_data" | jq --arg player "$player_name" --arg time "$time_str" --arg target "$target_player" '.transactions += [{"player": $player, "type": "gift_mod", "tickets": -15, "target": $target, "time": $time}]')
                    echo "$current_data" > "$ECONOMY_FILE"

                    screen -S blockheads_server -X stuff "/mod $target_player$(printf \\\r)"
                    send_server_command "Congratulations! $player_name has gifted MOD rank to $target_player for 15 tickets."
                    send_server_command "$player_name, your remaining tickets: $new_tickets"

                    create_list_backup "give_mod"
                else
                    send_server_command "$player_name, you need $((15 - player_tickets)) more tickets to gift MOD rank."
                fi
            else
                send_server_command "Usage: !give_mod PLAYERNAME"
            fi
            ;;
        "!give_admin")
            if [[ "$message" =~ ^!give_admin\ ([a-zA-Z0-9_]+)$ ]]; then
                local target_player
                target_player="${BASH_REMATCH[1]}"
                if [ "$player_tickets" -ge 30 ]; then
                    local new_tickets
                    new_tickets=$((player_tickets - 30))
                    current_data=$(cat "$ECONOMY_FILE")
                    current_data=$(echo "$current_data" | jq --arg player "$player_name" --argjson tickets "$new_tickets" '.players[$player].tickets = $tickets')
                    local time_str
                    time_str=$(date '+%Y-%m-%d %H:%M:%S')
                    current_data=$(echo "$current_data" | jq --arg player "$player_name" --arg time "$time_str" --arg target "$target_player" '.transactions += [{"player": $player, "type": "gift_admin", "tickets": -30, "target": $target, "time": $time}]')
                    echo "$current_data" > "$ECONOMY_FILE"

                    screen -S blockheads_server -X stuff "/admin $target_player$(printf \\\r)"
                    send_server_command "Congratulations! $player_name has gifted ADMIN rank to $target_player for 30 tickets."
                    send_server_command "$player_name, your remaining tickets: $new_tickets"

                    create_list_backup "give_admin"
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

process_admin_command() {
    local command="$1"
    local current_data
    current_data=$(cat "$ECONOMY_FILE")
    if [[ "$command" =~ ^!send_ticket\ ([a-zA-Z0-9_]+)\ ([0-9]+)$ ]]; then
        local player_name
        player_name="${BASH_REMATCH[1]}"
        local tickets_to_add
        tickets_to_add="${BASH_REMATCH[2]}"
        local player_exists
        player_exists=$(echo "$current_data" | jq --arg player "$player_name" '.players | has($player)')
        if [ "$player_exists" = "false" ]; then
            print_error "Player $player_name not found in economy system"
            return
        fi
        local current_tickets
        current_tickets=$(echo "$current_data" | jq -r --arg player "$player_name" '.players[$player].tickets // 0')
        current_tickets=${current_tickets:-0}
        local new_tickets
        new_tickets=$((current_tickets + tickets_to_add))
        current_data=$(echo "$current_data" | jq --arg player "$player_name" --argjson tickets "$new_tickets" '.players[$player].tickets = $tickets')
        local time_str
        time_str=$(date '+%Y-%m-%d %H:%M:%S')
        current_data=$(echo "$current_data" | jq --arg player "$player_name" --arg time "$time_str" --argjson amount "$tickets_to_add" '.transactions += [{"player": $player, "type": "admin_gift", "tickets": $amount, "time": $time}]')
        echo "$current_data" > "$ECONOMY_FILE"
        print_success "Added $tickets_to_add tickets to $player_name (Total: $new_tickets)"
        send_server_command "$player_name received $tickets_to_add tickets from admin! Total: $new_tickets"
    elif [[ "$command" =~ ^!set_mod\ ([a-zA-Z0-9_]+)$ ]]; then
        local player_name
        player_name="${BASH_REMATCH[1]}"
        print_success "Setting $player_name as MOD"

        screen -S blockheads_server -X stuff "/mod $player_name$(printf \\\r)"
        send_server_command "$player_name has been set as MOD by server console!"

        create_list_backup "set_mod"
    elif [[ "$command" =~ ^!set_admin\ ([a-zA-Z0-9_]+)$ ]]; then
        local player_name
        player_name="${BASH_REMATCH[1]}"
        print_success "Setting $player_name as ADMIN"

        screen -S blockheads_server -X stuff "/admin $player_name$(printf \\\r)"
        send_server_command "$player_name has been set as ADMIN by server console!"

        create_list_backup "set_admin"
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
    local conn_epoch="${2:-0}"
    [ -z "$LOG_FILE" ] || [ ! -f "$LOG_FILE" ] && return 1

    local player_lc
    player_lc=$(echo "$player_name" | tr '[:upper:]' '[:lower:]')
    local matches
    matches=$(tail -n "$TAIL_LINES" "$LOG_FILE" 2>/dev/null | grep -i "server:.*welcome.*$player_lc" | head -1)
    if [ -n "$matches" ]; then
        return 0
    fi
    return 1
}

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

    local admin_pipe="/tmp/blockheads_admin_pipe"
    rm -f "$admin_pipe"
    mkfifo "$admin_pipe"

    while read -r admin_command < "$admin_pipe"; do
        print_status "Processing admin command: $admin_command"
        if [[ "$admin_command" == "!send_ticket "* ]] || [[ "$admin_command" == "!set_mod "* ]] || [[ "$admin_command" == "!set_admin "* ]]; then
            process_admin_command "$admin_command"
        else
            print_error "Unknown admin command. Use: !send_ticket <player> <amount>, !set_mod <player>, or !set_admin <player>"
        fi
        print_header "READY FOR NEXT COMMAND"
    done &

    while read -r admin_command; do
        echo "$admin_command" > "$admin_pipe"
    done &

    declare -A welcome_shown

    tail -n 0 -F "$log_file" | filter_server_log | while read line; do
        if [[ "$line" =~ Player\\ Connected\\ ([a-zA-Z0-9_]+)\\ \|\\ ([0-9a-fA-F.:]+) ]]; then
            local player_name
            player_name="${BASH_REMATCH[1]}"
            local player_ip
            player_ip="${BASH_REMATCH[2]}"
            [ "$player_name" == "SERVER" ] && continue

            print_success "Player connected: $player_name (IP: $player_ip)"

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

        if [[ "$line" =~ ([a-zA-Z0-9_]+):\\ \\/(admin|mod)\\ ([a-zA-Z0-9_]+) ]]; then
            local command_user
            command_user="${BASH_REMATCH[1]}"
            local command_type
            command_type="${BASH_REMATCH[2]}"
            local target_player
            target_player="${BASH_REMATCH[3]}"

            if [ "$command_user" != "SERVER" ]; then
                handle_unauthorized_command "$command_user" "/$command_type" "$target_player"
            fi
            continue
        fi

        if [[ "$line" =~ Player\\ Disconnected\\ ([a-zA-Z0-9_]+) ]]; then
            local player_name
            player_name="${BASH_REMATCH[1]}"
            [ "$player_name" == "SERVER" ] && continue
            print_warning "Player disconnected: $player_name"
            unset welcome_shown["$player_name"]
            continue
        fi

        if [[ "$line" =~ ([a-zA-Z0-9_]+):\\ (.+)$ ]]; then
            local player_name
            player_name="${BASH_REMATCH[1]}"
            local message
            message="${BASH_REMATCH[2]}"
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
}

if [ $# -eq 1 ]; then
    initialize_economy
    monitor_log "$1"
else
    print_error "Usage: $0 <server_log_file>"
    exit 1
fi
