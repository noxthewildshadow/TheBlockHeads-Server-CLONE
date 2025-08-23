#!/usr/bin/env bash
# bot_server.sh - Economy / welcome bot for The Blockheads server
# Place in same folder as start_server.sh and server binary (or adapt paths)
set -euo pipefail

# CONFIG
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ECONOMY_FILE="$SCRIPT_DIR/economy_data.json"
ECONOMY_LOCK="$SCRIPT_DIR/economy_data.lock"
SCREEN_SERVER="${SCREEN_SERVER:-blockheads_server}"
TAIL_LINES=500
SERVER_WELCOME_WINDOW=15    # seconds window to consider server sent welcome
ADMIN_PIPE="/tmp/blockheads_admin_pipe_$$"
REQUIRED_CMDS=(jq screen lsof tail date mkfifo flock mktemp awk grep sed head tail)

# Ensure dependencies present
for cmd in "${REQUIRED_CMDS[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: required command '$cmd' not found. Install it (apt install $cmd) and retry."
        exit 1
    fi
done

# Safe write helper (atomic)
_write_economy() {
    local data_json="$1"
    local tmp
    tmp="$(mktemp "${ECONOMY_FILE}.tmp.XXXXXX")"
    printf '%s' "$data_json" > "$tmp"
    mv "$tmp" "$ECONOMY_FILE"
    chmod 600 "$ECONOMY_FILE" || true
}

_read_economy() {
    if [ -f "$ECONOMY_FILE" ]; then
        cat "$ECONOMY_FILE"
    else
        echo '{"players": {}, "transactions": []}'
    fi
}

# Export helper functions so child "bash -c" calls can access them
export -f _read_economy _write_economy

# File-locking wrapper for jq modifications (uses flock)
with_economy_lock() {
    # Usage: with_economy_lock <command>...
    exec 9>"$ECONOMY_LOCK"
    flock -x 9
    "$@"
    local status=$?
    flock -u 9
    exec 9>&-
    return $status
}

initialize_economy() {
    if [ ! -f "$ECONOMY_FILE" ]; then
        _write_economy '{"players": {}, "transactions": []}'
        echo "Economy data file created at: $ECONOMY_FILE"
    fi
}

is_player_in_list() {
    local player_name="$1"
    local list_type="$2"   # expects "mod" or "admin" -> files modlist.txt adminlist.txt in world dir
    local world_dir
    world_dir="$(dirname "${LOG_FILE:-$SCRIPT_DIR/server.log}")"
    local list_file="$world_dir/${list_type}list.txt"
    local lower_player_name
    lower_player_name="$(printf '%s' "$player_name" | tr '[:upper:]' '[:lower:]')"
    if [ -f "$list_file" ]; then
        if grep -iFxq "$lower_player_name" "$list_file"; then
            return 0
        fi
    fi
    return 1
}

add_player_if_new() {
    local player_name="$1"
    # Acquire lock and perform add in a sub-bash (functions exported above)
    with_economy_lock bash -c '
        current="$(_read_economy)"
        exists=$(printf "%s" "$current" | jq --arg player "'"$player_name"'" ".players | has(\$player)")
        if [ "$exists" = "false" ]; then
            new=$(printf "%s" "$current" | jq --arg player "'"$player_name"'" ".players[\$player] = {\"tickets\":0, \"last_login\":0, \"last_welcome_time\":0, \"last_help_time\":0, \"purchases\": []}")
            _write_economy "$new"
            printf "ADDED"
        else
            printf "EXISTS"
        fi
    '
}

give_first_time_bonus() {
    local player_name="$1"
    local current_time
    current_time="$(date +%s)"
    local time_str
    time_str="$(date '+%Y-%m-%d %H:%M:%S')"
    with_economy_lock bash -c '
        current="$(_read_economy)"
        updated=$(printf "%s" "$current" | jq --arg player "'"$player_name"'" --argjson time '"$current_time"' ".players[\$player].tickets = 1 | .players[\$player].last_login = \$time | .transactions += [{\"player\":\$player, \"type\":\"welcome_bonus\", \"tickets\":1, \"time\":\$time}]")
        _write_economy "$updated"
    '
    echo "Gave first-time bonus to $player_name"
}

grant_login_ticket() {
    local player_name="$1"
    local current_time
    current_time="$(date +%s)"
    local time_str
    time_str="$(date '+%Y-%m-%d %H:%M:%S')"

    with_economy_lock bash -c '
        current="$(_read_economy)"
        last_login=$(printf "%s" "$current" | jq -r --arg player "'"$player_name"'" ".players[\$player].last_login // 0")
        last_login=${last_login:-0}
        if [ "$last_login" -eq 0 ] || [ $(( '"$current_time"' - last_login )) -ge 3600 ]; then
            current_tickets=$(printf "%s" "$current" | jq -r --arg player "'"$player_name"'" ".players[\$player].tickets // 0")
            current_tickets=${current_tickets:-0}
            new_tickets=$((current_tickets + 1))
            updated=$(printf "%s" "$current" | jq --arg player "'"$player_name"'" --argjson tickets "$new_tickets" --argjson time '"$current_time"' ".players[\$player].tickets = \$tickets | .players[\$player].last_login = \$time | .transactions += [{\"player\":\$player, \"type\":\"login_bonus\", \"tickets\":1, \"time\":\$time}]")
            _write_economy "$updated"
            printf "GRANTED:%s:%d" "'"$player_name"'" "$new_tickets"
        else
            next_login=$(( last_login + 3600 ))
            time_left=$(( next_login - '"$current_time"' ))
            printf "WAIT:%d" "$time_left"
        fi
    '
    # re-read current tickets for feedback
    local current_tickets
    current_tickets="$(printf '%s' "$(_read_economy)" | jq -r --arg player "$player_name" '.players[$player].tickets // 0')"
    if [ -n "$current_tickets" ]; then
        send_server_command "$player_name, you received 1 login ticket! You now have $current_tickets tickets."
        echo "Granted 1 ticket to $player_name (Total: $current_tickets)"
    fi
}

show_welcome_message() {
    local player_name="$1"
    local is_new_player="${2:-false}"
    local force_send="${3:-0}"
    local current_time
    current_time="$(date +%s)"
    local current_data
    current_data="$(_read_economy)"
    local last_welcome_time
    last_welcome_time="$(printf '%s' "$current_data" | jq -r --arg player "$player_name" '.players[$player].last_welcome_time // 0')"
    last_welcome_time=${last_welcome_time:-0}
    if [ "$force_send" -eq 1 ] || [ "$last_welcome_time" -eq 0 ] || [ $((current_time - last_welcome_time)) -ge 180 ]; then
        if [ "$is_new_player" = "true" ]; then
            send_server_command "Hello $player_name! Welcome to the server. Type !tickets to check your ticket balance."
        else
            send_server_command "Welcome back $player_name! Type !economy_help to see economy commands."
        fi
        with_economy_lock bash -c '
            current="$(_read_economy)"
            updated=$(printf "%s" "$current" | jq --arg player "'"$player_name"'" --argjson time '"$current_time"' ".players[\$player].last_welcome_time = \$time")
            _write_economy "$updated"
        '
    else
        echo "Skipping welcome for $player_name due to cooldown."
    fi
}

show_help_if_needed() {
    local player_name="$1"
    local current_time
    current_time="$(date +%s)"
    local last_help_time
    last_help_time="$(printf '%s' "$(_read_economy)" | jq -r --arg player "$player_name" '.players[$player].last_help_time // 0')"
    last_help_time=${last_help_time:-0}
    if [ "$last_help_time" -eq 0 ] || [ $((current_time - last_help_time)) -ge 300 ]; then
        send_server_command "$player_name, type !economy_help to see economy commands."
        with_economy_lock bash -c '
            current="$(_read_economy)"
            updated=$(printf "%s" "$current" | jq --arg player "'"$player_name"'" --argjson time '"$current_time"' ".players[\$player].last_help_time = \$time")
            _write_economy "$updated"
        '
    fi
}

send_server_command() {
    local message="$1"
    if screen -S "$SCREEN_SERVER" -X stuff "$message$(printf \\r)" 2>/dev/null; then
        echo "Sent message to server: $message"
    else
        echo "Error: Could not send message to server (screen session '$SCREEN_SERVER' not found?)."
    fi
}

has_purchased() {
    local player_name="$1"; local item="$2"
    local cur="$(_read_economy)"
    local has
    has="$(printf '%s' "$cur" | jq --arg player "$player_name" --arg item "$item" '.players[$player].purchases | index($item) != null')"
    if [ "$has" = "true" ]; then
        return 0
    fi
    return 1
}

add_purchase() {
    local player_name="$1"; local item="$2"
    with_economy_lock bash -c '
        current="$(_read_economy)"
        updated=$(printf "%s" "$current" | jq --arg player "'"$player_name"'" --arg item "'"$item"'" ".players[\$player].purchases += [\$item]")
        _write_economy "$updated"
    '
}

process_message() {
    local player_name="$1"
    local message="$2"
    local cur="$(_read_economy)"
    local player_tickets
    player_tickets="$(printf '%s' "$cur" | jq -r --arg player "$player_name" '.players[$player].tickets // 0')"
    player_tickets=${player_tickets:-0}

    case "$message" in
        hi|hello|Hi|Hello|hola|Hola)
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
                with_economy_lock bash -c '
                    current="$(_read_economy)"
                    updated=$(printf "%s" "$current" | jq --arg player "'"$player_name"'" --argjson tickets '"$new_tickets"' --arg time "'"$(date '+%Y-%m-%d %H:%M:%S')"'" ".players[\$player].tickets = \$tickets | .transactions += [{\"player\":\$player, \"type\":\"purchase\", \"item\":\"mod\", \"tickets\":-10, \"time\":\$time}]")
                    _write_economy "$updated"
                '
                add_purchase "$player_name" "mod"
                screen -S "$SCREEN_SERVER" -X stuff "/mod $player_name$(printf \\r)"
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
                with_economy_lock bash -c '
                    current="$(_read_economy)"
                    updated=$(printf "%s" "$current" | jq --arg player "'"$player_name"'" --argjson tickets '"$new_tickets"' --arg time "'"$(date '+%Y-%m-%d %H:%M:%S')"'" ".players[\$player].tickets = \$tickets | .transactions += [{\"player\":\$player, \"type\":\"purchase\", \"item\":\"admin\", \"tickets\":-20, \"time\":\$time}]")
                    _write_economy "$updated"
                '
                add_purchase "$player_name" "admin"
                screen -S "$SCREEN_SERVER" -X stuff "/admin $player_name$(printf \\r)"
                send_server_command "Congratulations $player_name! You have been promoted to ADMIN for 20 tickets. Remaining tickets: $new_tickets"
            else
                send_server_command "$player_name, you need $((20 - player_tickets)) more tickets to buy ADMIN rank."
            fi
            ;;
        "!economy_help")
            send_server_command "Economy commands: !tickets (check your tickets), !buy_mod (10 tickets for MOD), !buy_admin (20 tickets for ADMIN)"
            ;;
        *)
            # ignore other commands
            ;;
    esac
}

process_admin_command() {
    local command="$1"
    local cur="$(_read_economy)"
    if [[ "$command" =~ ^!send_ticket[[:space:]]+([a-zA-Z0-9_]+)[[:space:]]+([0-9]+)$ ]]; then
        local player_name="${BASH_REMATCH[1]}"
        local tickets_to_add="${BASH_REMATCH[2]}"
        local player_exists
        player_exists="$(printf '%s' "$cur" | jq --arg player "$player_name" '.players | has($player)')"
        if [ "$player_exists" = "false" ]; then
            echo "Player $player_name not found in economy system."
            return 1
        fi
        with_economy_lock bash -c '
            current="$(_read_economy)"
            current_tickets=$(printf "%s" "$current" | jq -r --arg player "'"$player_name"'" ".players[\$player].tickets // 0")
            new_tickets=$((current_tickets + '"$tickets_to_add"'))
            updated=$(printf "%s" "$current" | jq --arg player "'"$player_name"'" --argjson tickets "$new_tickets" --arg time "'"$(date '+%Y-%m-%d %H:%M:%S')"'" --argjson amount '"$tickets_to_add"' ".players[\$player].tickets = \$tickets | .transactions += [{\"player\":\$player, \"type\":\"admin_gift\", \"tickets\":\$amount, \"time\":\$time}]")
            _write_economy "$updated"
        '
        send_server_command "$player_name received $tickets_to_add tickets from admin! Total: $(printf '%s' "$(_read_economy)" | jq -r --arg player "$player_name" '.players[$player].tickets // 0')"
        echo "Added $tickets_to_add tickets to $player_name"
    elif [[ "$command" =~ ^!make_mod[[:space:]]+([a-zA-Z0-9_]+)$ ]]; then
        local player_name="${BASH_REMATCH[1]}"
        screen -S "$SCREEN_SERVER" -X stuff "/mod $player_name$(printf \\r)"
        send_server_command "$player_name has been promoted to MOD by admin!"
    elif [[ "$command" =~ ^!make_admin[[:space:]]+([a-zA-Z0-9_]+)$ ]]; then
        local player_name="${BASH_REMATCH[1]}"
        screen -S "$SCREEN_SERVER" -X stuff "/admin $player_name$(printf \\r)"
        send_server_command "$player_name has been promoted to ADMIN by admin!"
    else
        echo "Unknown admin command: $command"
    fi
}

server_sent_welcome_recently() {
    local player_name="$1"
    local conn_epoch="${2:-0}"
    if [ -z "${LOG_FILE:-}" ] || [ ! -f "$LOG_FILE" ]; then
        return 1
    fi
    local player_lc
    player_lc="$(printf '%s' "$player_name" | tr '[:upper:]' '[:lower:]')"
    local matches
    matches="$(tail -n "$TAIL_LINES" "$LOG_FILE" 2>/dev/null | tr '[:upper:]' '[:lower:]' | grep -iE 'server: .*welcome' | grep -i "$player_lc" || true)"
    if [ -z "$matches" ]; then
        return 1
    fi
    while IFS= read -r line; do
        ts_str="$(printf '%s' "$line" | awk '{print $1" "$2}')"
        ts_no_ms="${ts_str%.*}"
        if ts_epoch=$(date -d "$ts_no_ms" +%s 2>/dev/null); then
            if [ "$ts_epoch" -ge "$conn_epoch" ] && [ "$ts_epoch" -le $((conn_epoch + SERVER_WELCOME_WINDOW)) ]; then
                return 0
            fi
        fi
    done <<< "$matches"
    return 1
}

filter_server_log() {
    while IFS= read -r line; do
        if [[ "$line" == *"Server closed"* ]] || [[ "$line" == *"Starting server"* ]]; then
            continue
        fi
        if [[ "$line" == *"SERVER: say"* && "$line" == *"Welcome"* ]]; then
            continue
        fi
        printf '%s\n' "$line"
    done
}

cleanup() {
    echo "Shutting down bot and cleaning up..."
    rm -f "$ADMIN_PIPE" 2>/dev/null || true
    rm -f "$ECONOMY_LOCK" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

monitor_log() {
    local log_file="$1"
    LOG_FILE="$log_file"
    initialize_economy

    echo "Starting economy bot. Monitoring: $log_file"
    echo "Bot commands: !tickets, !buy_mod, !buy_admin, !economy_help"
    echo "Admin commands (type in THIS terminal): !send_ticket <player> <amount>, !make_mod <player>, !make_admin <player>"
    echo "================================================================"

    rm -f "$ADMIN_PIPE" || true
    mkfifo "$ADMIN_PIPE"

    ( while true; do
        if read -r admin_command < "$ADMIN_PIPE"; then
            echo "Processing admin command: $admin_command"
            process_admin_command "$admin_command" || true
            echo "================================================================"
        else
            sleep 0.1
        fi
    done ) &

    declare -A welcome_shown

    tail -n 0 -F "$log_file" 2>/dev/null | filter_server_log | while IFS= read -r line; do
        if [[ "$line" =~ Player[[:space:]]Connected[[:space:]]([a-zA-Z0-9_]+) ]]; then
            player_name="${BASH_REMATCH[1]}"
            if [[ "$player_name" == "SERVER" ]]; then
                echo "Ignoring system player: $player_name"
                continue
            fi
            ts_str="$(printf '%s' "$line" | awk '{print $1" "$2}')"
            ts_no_ms="${ts_str%.*}"
            conn_epoch=0
            conn_epoch=$(date -d "$ts_no_ms" +%s 2>/dev/null || echo 0)
            echo "Player connected: $player_name (ts: $ts_no_ms, epoch: $conn_epoch)"

            local is_new_player="false"
            if [ "$(add_player_if_new "$player_name")" = "ADDED" ]; then
                is_new_player="true"
                give_first_time_bonus "$player_name"
            fi

            if [ "$is_new_player" = "true" ]; then
                echo "New player $player_name connected - bot will not double-welcome if server handled it"
                welcome_shown["$player_name"]=1
                continue
            fi

            if [ -z "${welcome_shown[$player_name]:-}" ]; then
                sleep 5
                if server_sent_welcome_recently "$player_name" "$conn_epoch"; then
                    echo "Server already sent welcome for $player_name; skipping bot welcome."
                    welcome_shown["$player_name"]=1
                else
                    echo "Server did not send welcome; bot will send welcome."
                    show_welcome_message "$player_name" "$is_new_player" 1
                    welcome_shown["$player_name"]=1
                fi
            fi

            grant_login_ticket "$player_name"
            continue
        fi

        if [[ "$line" =~ Player[[:space:]]Disconnected[[:space:]]([a-zA-Z0-9_]+) ]]; then
            player_name="${BASH_REMATCH[1]}"
            if [[ "$player_name" == "SERVER" ]]; then
                continue
            fi
            echo "Player disconnected: $player_name"
            unset welcome_shown["$player_name"]
            continue
        fi

        if [[ "$line" =~ ^([a-zA-Z0-9_]+):[[:space:]](.+)$ ]]; then
            player_name="${BASH_REMATCH[1]}"
            message="${BASH_REMATCH[2]}"
            if [[ "$player_name" == "SERVER" ]]; then
                echo "Ignoring system message: $message"
                continue
            fi
            echo "Chat: $player_name: $message"
            add_player_if_new "$player_name" >/dev/null || true
            process_message "$player_name" "$message" || true
            continue
        fi

        echo "Other log line: $line"
    done

    wait
}

# MAIN
if [ $# -ne 1 ]; then
    echo "Usage: $0 <server_log_file>"
    exit 1
fi

monitor_log "$1"
