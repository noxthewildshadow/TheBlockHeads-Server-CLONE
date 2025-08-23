#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Bot configuration
ECONOMY_FILE="economy_data.json"
SCAN_INTERVAL=5
SERVER_WELCOME_WINDOW=15
TAIL_LINES=500

initialize_economy() {
    if [ ! -f "$ECONOMY_FILE" ]; then
        echo '{"players": {}, "transactions": []}' > "$ECONOMY_FILE"
        echo -e "${GREEN}Economy data file created.${NC}"
    fi
}

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

add_player_if_new() {
    local player_name="$1"
    local current_data=$(cat "$ECONOMY_FILE")
    local player_exists=$(echo "$current_data" | jq --arg player "$player_name" '.players | has($player)')
    if [ "$player_exists" = "false" ]; then
        current_data=$(echo "$current_data" | jq --arg player "$player_name" '.players[$player] = {"tickets": 0, "last_login": 0, "last_welcome_time": 0, "last_help_time": 0, "purchases": []}')
        echo "$current_data" > "$ECONOMY_FILE"
        echo -e "${GREEN}Added new player: $player_name${NC}"
        give_first_time_bonus "$player_name"
        return 0
    fi
    return 1
}

give_first_time_bonus() {
    local player_name="$1"
    local current_data=$(cat "$ECONOMY_FILE")
    local current_time=$(date +%s)
    local time_str="$(date '+%Y-%m-%d %H:%M:%S')"
    current_data=$(echo "$current_data" | jq --arg player "$player_name" '.players[$player].tickets = 1')
    current_data=$(echo "$current_data" | jq --arg player "$player_name" --argjson time "$current_time" '.players[$player].last_login = $time')
    current_data=$(echo "$current_data" | jq --arg player "$player_name" --arg time "$time_str" '.transactions += [{"player": $player, "type": "welcome_bonus", "tickets": 1, "time": $time}]')
    echo "$current_data" > "$ECONOMY_FILE"
    echo -e "${GREEN}Gave first-time bonus to $player_name${NC}"
}

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
        echo -e "${GREEN}Granted 1 ticket to $player_name for logging in (Total: $new_tickets)${NC}"
        send_server_command "$player_name, you received 1 login ticket! You now have $new_tickets tickets."
    else
        local next_login=$((last_login + 3600))
        local time_left=$((next_login - current_time))
        echo -e "${YELLOW}$player_name must wait $((time_left / 60)) minutes for next ticket${NC}"
    fi
}

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
        echo -e "${YELLOW}Skipping welcome for $player_name due to cooldown (use force to override).${NC}"
    fi
}

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

send_server_command() {
    local message="$1"
    if screen -S blockheads_server -X stuff "$message$(printf \\r)" 2>/dev/null; then
        echo -e "${GREEN}Sent message to server: $message${NC}"
    else
        echo -e "${RED}Error: Could not send message to server. Is the server running?${NC}"
    fi
}

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

add_purchase() {
    local player_name="$1"
    local item="$2"
    local current_data=$(cat "$ECONOMY_FILE")
    current_data=$(echo "$current_data" | jq --arg player "$player_name" --arg item "$item" '.players[$player].purchases += [$item]')
    echo "$current_data" > "$ECONOMY_FILE"
}

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
        "!economy_help")
            send_server_command "Economy commands: !tickets (check your tickets), !buy_mod (10 tickets for MOD), !buy_admin (20 tickets for ADMIN)"
            ;;
    esac
}

process_admin_command() {
    local command="$1"
    local current_data=$(cat "$ECONOMY_FILE")
    if [[ "$command" =~ ^!send_ticket\ ([a-zA-Z0-9_]+)\ ([0-9]+)$ ]]; then
        local player_name="${BASH_REMATCH[1]}"
        local tickets_to_add="${BASH_REMATCH[2]}"
        local player_exists=$(echo "$current_data" | jq --arg player "$player_name" '.players | has($player)')
        if [ "$player_exists" = "false" ]; then
            echo -e "${RED}Player $player_name not found in economy system.${NC}"
            return
        fi
        local current_tickets=$(echo "$current_data" | jq -r --arg player "$player_name" '.players[$player].tickets // 0')
        current_tickets=${current_tickets:-0}
        local new_tickets=$((current_tickets + tickets_to_add))
        current_data=$(echo "$current_data" | jq --arg player "$player_name" --argjson tickets "$new_tickets" '.players[$player].tickets = $tickets')
        local time_str="$(date '+%Y-%m-%d %H:%M:%S')"
        current_data=$(echo "$current_data" | jq --arg player "$player_name" --arg time "$time_str" --argjson amount "$tickets_to_add" '.transactions += [{"player": $player, "type": "admin_gift", "tickets": $amount, "time": $time}]')
        echo "$current_data" > "$ECONOMY_FILE"
        echo -e "${GREEN}Added $tickets_to_add tickets to $player_name (Total: $new_tickets)${NC}"
        send_server_command "$player_name received $tickets_to_add tickets from admin! Total: $new_tickets"
    elif [[ "$command" =~ ^!make_mod\ ([a-zA-Z0-9_]+)$ ]]; then
        local player_name="${BASH_REMATCH[1]}"
        echo -e "${GREEN}Making $player_name a MOD${NC}"
        screen -S blockheads_server -X stuff "/mod $player_name$(printf \\r)"
        send_server_command "$player_name has been promoted to MOD by admin!"
    elif [[ "$command" =~ ^!make_admin\ ([a-zA-Z0-9_]+)$ ]]; then
        local player_name="${BASH_REMATCH[1]}"
        echo -e "${GREEN}Making $player_name an ADMIN${NC}"
        screen -S blockheads_server -X stuff "/admin $player_name$(printf \\r)"
        send_server_command "$player_name has been promoted to ADMIN by admin!"
    else
        echo -e "${RED}Unknown admin command: $command${NC}"
        echo -e "${YELLOW}Available admin commands:${NC}"
        echo -e "!send_ticket <player> <amount>"
        echo -e "!make_mod <player>"
        echo -e "!make_admin <player>"
    fi
}

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

    echo -e "${BLUE}================================================================"
    echo -e "Starting economy bot. Monitoring: $log_file"
    echo -e "Bot commands: !tickets, !buy_mod, !buy_admin, !economy_help"
    echo -e "Admin commands: !send_ticket <player> <amount>, !make_mod <player>, !make_admin <player>"
    echo -e "================================================================"
    echo -e "IMPORTANT: Admin commands must be typed in THIS terminal, NOT in the game chat!"
    echo -e "Type admin commands below and press Enter:"
    echo -e "================================================================"

    local admin_pipe="/tmp/blockheads_admin_pipe"
    rm -f "$admin_pipe"
    mkfifo "$admin_pipe"

    # Background process to read admin commands from the pipe
    while read -r admin_command < "$admin_pipe"; do
        echo -e "${CYAN}Processing admin command: $admin_command${NC}"
        if [[ "$admin_command" == "!send_ticket "* ]] || [[ "$admin_command" == "!make_mod "* ]] || [[ "$admin_command" == "!make_admin "* ]]; then
            process_admin_command "$admin_command"
        else
            echo -e "${RED}Unknown admin command. Use: !send_ticket <player> <amount>, !make_mod <player>, or !make_admin <player>${NC}"
        fi
        echo -e "${BLUE}================================================================"
        echo -e "Ready for next admin command:${NC}"
    done &

    # Forward stdin to the admin pipe
    while read -r admin_command; do
        echo "$admin_command" > "$admin_pipe"
    done &

    declare -A welcome_shown

    # Monitor the log file
    tail -n 0 -F "$log_file" | filter_server_log | while read line; do
        # Detect player connections
        if [[ "$line" =~ Player\ Connected\ ([a-zA-Z0-9_]+) ]]; then
            local player_name="${BASH_REMATCH[1]}"
            [ "$player_name" == "SERVER" ] && continue

            # Extract timestamp
            ts_str=$(echo "$line" | awk '{print $1" "$2}')
            ts_no_ms=${ts_str%.*}
            conn_epoch=$(date -d "$ts_no_ms" +%s 2>/dev/null || echo 0)

            echo -e "${GREEN}Player connected: $player_name (at $ts_no_ms)${NC}"

            local is_new_player="false"
            add_player_if_new "$player_name" && is_new_player="true"

            # Wait a bit for server welcome
            sleep 3

            if ! server_sent_welcome_recently "$player_name" "$conn_epoch"; then
                show_welcome_message "$player_name" "$is_new_player" 1
            else
                echo -e "${YELLOW}Server already welcomed $player_name${NC}"
            fi

            # Grant login ticket for returning players
            [ "$is_new_player" = "false" ] && grant_login_ticket "$player_name"

            continue
        fi

        if [[ "$line" =~ Player\ Disconnected\ ([a-zA-Z0-9_]+) ]]; then
            local player_name="${BASH_REMATCH[1]}"
            [ "$player_name" == "SERVER" ] && continue
            echo -e "${YELLOW}Player disconnected: $player_name${NC}"
            unset welcome_shown["$player_name"]
            continue
        fi

        if [[ "$line" =~ ([a-zA-Z0-9_]+):\ (.+)$ ]]; then
            local player_name="${BASH_REMATCH[1]}"
            local message="${BASH_REMATCH[2]}"
            [ "$player_name" == "SERVER" ] && continue
            echo -e "${CYAN}Chat: $player_name: $message${NC}"
            add_player_if_new "$player_name"
            process_message "$player_name" "$message"
            continue
        fi

        echo -e "${BLUE}Other log line: $line${NC}"
    done

    wait
    rm -f "$admin_pipe"
}

if [ $# -eq 1 ]; then
    initialize_economy
    monitor_log "$1"
else
    echo -e "${RED}Usage: $0 <server_log_file>${NC}"
    exit 1
fi
