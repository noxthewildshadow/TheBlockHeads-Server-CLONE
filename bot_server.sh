#!/bin/bash
# Bot for The Blockheads server - economy + tickets + admin terminal commands
# Requires: jq, screen

# === Config ===
ECONOMY_FILE="economy_data.json"
SCAN_INTERVAL=5
SERVER_WELCOME_WINDOW=15
TAIL_LINES=500

# Default currency settings (merged on init)
DEFAULT_CURRENCY_SETTINGS='{
  "currency_name":"coins",
  "daily_amount":50,
  "daily_cooldown":86400,
  "max_balance":null
}'

# -----------------------
# Initialization
# -----------------------
initialize_economy() {
    if [ ! -f "$ECONOMY_FILE" ]; then
        echo '{"players": {}, "transactions": [], "accounts": {"SERVER": {"balance": 0, "last_daily": 0}}, "bankers": [], "settings": '"$DEFAULT_CURRENCY_SETTINGS"'}' > "$ECONOMY_FILE"
        echo "Economy data file created."
        return
    fi

    # Merge missing keys if file exists
    local data
    data=$(cat "$ECONOMY_FILE")

    if ! echo "$data" | jq -e '.players' >/dev/null 2>&1; then
        data=$(echo "$data" | jq '. + {"players": {}}')
    fi
    if ! echo "$data" | jq -e '.transactions' >/dev/null 2>&1; then
        data=$(echo "$data" | jq '. + {"transactions": []}')
    fi
    if ! echo "$data" | jq -e '.accounts' >/dev/null 2>&1; then
        data=$(echo "$data" | jq --argjson a '{"SERVER":{"balance":0,"last_daily":0}}' '. + {"accounts": $a}')
    else
        if ! echo "$data" | jq -e '.accounts.SERVER' >/dev/null 2>&1; then
            data=$(echo "$data" | jq '.accounts.SERVER = {"balance":0,"last_daily":0} | .')
        fi
    fi
    if ! echo "$data" | jq -e '.bankers' >/dev/null 2>&1; then
        data=$(echo "$data" | jq '. + {"bankers": []}')
    fi
    if ! echo "$data" | jq -e '.settings' >/dev/null 2>&1; then
        data=$(echo "$data" | jq '. + {"settings": '"$DEFAULT_CURRENCY_SETTINGS"'}')
    fi

    echo "$data" > "$ECONOMY_FILE"
    echo "Economy data file initialized/merged."
}

# -----------------------
# Player list utilities
# -----------------------
is_player_in_list() {
    local player_name="$1"
    local list_type="$2"
    local world_dir
    world_dir=$(dirname "$LOG_FILE")
    local list_file="$world_dir/${list_type}list.txt"
    local lower_player_name
    lower_player_name=$(echo "$player_name" | tr '[:upper:]' '[:lower:]')
    if [ -f "$list_file" ]; then
        if grep -q "^$lower_player_name$" "$list_file"; then
            return 0
        fi
    fi
    return 1
}

# -----------------------
# Players & tickets
# -----------------------
add_player_if_new() {
    local player_name="$1"
    local current_data
    current_data=$(cat "$ECONOMY_FILE")
    local player_exists
    player_exists=$(echo "$current_data" | jq --arg player "$player_name" '.players | has($player)')

    if [ "$player_exists" = "false" ]; then
        current_data=$(echo "$current_data" | jq --arg player "$player_name" '.players[$player] = {"tickets": 0, "last_login": 0, "last_welcome_time": 0, "last_help_time": 0, "purchases": [], "online": true}')
        if ! echo "$current_data" | jq -e --arg player "$player_name" '.accounts | has($player)' >/dev/null 2>&1; then
            current_data=$(echo "$current_data" | jq --arg player "$player_name" '.accounts[$player] = {"balance": 0, "last_daily": 0}')
        fi
        echo "$current_data" > "$ECONOMY_FILE"
        echo "Added new player: $player_name"
        give_first_time_bonus "$player_name"
        return 0
    else
        # mark online true for reconnects
        current_data=$(echo "$current_data" | jq --arg player "$player_name" '.players[$player].online = true')
        if ! echo "$current_data" | jq -e --arg player "$player_name" '.accounts | has($player)' >/dev/null 2>&1; then
            current_data=$(echo "$current_data" | jq --arg player "$player_name" '.accounts[$player] = {"balance": 0, "last_daily": 0}')
        fi
        echo "$current_data" > "$ECONOMY_FILE"
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
    time_str="$(date '+%Y-%m-%d %H:%M:%S')"

    current_data=$(echo "$current_data" | jq --arg player "$player_name" '.players[$player].tickets = 1')
    current_data=$(echo "$current_data" | jq --arg player "$player_name" --argjson time "$current_time" '.players[$player].last_login = $time')

    local currency_welcome
    currency_welcome=$(echo "$current_data" | jq -r '.settings.daily_amount // 50')
    currency_welcome=$((currency_welcome/2))

    current_data=$(echo "$current_data" | jq --arg player "$player_name" --arg time "$time_str" --argjson cw "$currency_welcome" '.transactions += [{"player": $player, "type": "welcome_bonus", "tickets": 1, "currency": $cw, "time": $time}]')
    current_data=$(echo "$current_data" | jq --arg player "$player_name" --argjson cw "$currency_welcome" '.accounts[$player].balance += $cw')
    echo "$current_data" > "$ECONOMY_FILE"
    echo "Gave first-time bonus to $player_name (tickets +1, currency +${currency_welcome})"
}

grant_login_ticket() {
    local player_name="$1"
    local current_time
    current_time=$(date +%s)
    local time_str
    time_str="$(date '+%Y-%m-%d %H:%M:%S')"
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
        echo "Granted 1 ticket to $player_name for logging in (Total: $new_tickets)"
        send_server_command "$player_name, you received 1 login ticket! You now have $new_tickets tickets."
    else
        local next_login
        next_login=$((last_login + 3600))
        local time_left
        time_left=$((next_login - current_time))
        echo "$player_name must wait $((time_left / 60)) minutes for next ticket"
    fi
}

# -----------------------
# Currency helpers
# -----------------------
get_currency_name() {
    jq -r '.settings.currency_name // "coins"' "$ECONOMY_FILE"
}

get_balance() {
    local player="$1"
    jq -r --arg player "$player" '.accounts[$player].balance // 0' "$ECONOMY_FILE"
}

account_exists() {
    local player="$1"
    if jq -e --arg player "$player" '.accounts | has($player)' "$ECONOMY_FILE" >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

ensure_account() {
    local player="$1"
    local data
    data=$(cat "$ECONOMY_FILE")
    if ! echo "$data" | jq -e --arg player "$player" '.accounts | has($player)' >/dev/null 2>&1; then
        data=$(echo "$data" | jq --arg player "$player" '.accounts[$player] = {"balance": 0, "last_daily": 0}')
        echo "$data" > "$ECONOMY_FILE"
    fi
}

deposit_to() {
    local player="$1"
    local amount="$2"
    local current_data
    current_data=$(cat "$ECONOMY_FILE")
    current_data=$(echo "$current_data" | jq --arg player "$player" --argjson amount "$amount" '.accounts[$player].balance = (.accounts[$player].balance // 0) + $amount')
    current_data=$(echo "$current_data" | jq --arg player "$player" --argjson amount "$amount" '.transactions += [{"player": $player, "type": "deposit", "amount": $amount, "time": "'$(date '+%Y-%m-%d %H:%M:%S')'"}]')
    echo "$current_data" > "$ECONOMY_FILE"
}

withdraw_from() {
    local player="$1"
    local amount="$2"
    local current_data
    current_data=$(cat "$ECONOMY_FILE")
    local balance
    balance=$(echo "$current_data" | jq -r --arg player "$player" '.accounts[$player].balance // 0')
    balance=${balance:-0}
    if [ "$balance" -lt "$amount" ]; then
        return 1
    fi
    current_data=$(echo "$current_data" | jq --arg player "$player" --argjson amount "$amount" '.accounts[$player].balance = (.accounts[$player].balance // 0) - $amount')
    current_data=$(echo "$current_data" | jq --arg player "$player" --argjson amount "$amount" '.transactions += [{"player": $player, "type": "withdraw", "amount": -$amount, "time": "'$(date '+%Y-%m-%d %H:%M:%S')'"}]')
    echo "$current_data" > "$ECONOMY_FILE"
    return 0
}

transfer_funds() {
    local from="$1"
    local to="$2"
    local amount="$3"

    ensure_account "$from"
    ensure_account "$to"

    local bal
    bal=$(get_balance "$from")
    if [ "$bal" -lt "$amount" ]; then
        return 1
    fi

    local data
    data=$(cat "$ECONOMY_FILE")
    data=$(echo "$data" | jq --arg from "$from" --arg to "$to" --argjson amount "$amount" '
        .accounts[$from].balance = (.accounts[$from].balance // 0) - $amount |
        .accounts[$to].balance = (.accounts[$to].balance // 0) + $amount |
        .transactions += [{"player_from": $from, "player_to": $to, "type":"transfer","amount": $amount, "time":"'"$(date '+%Y-%m-%d %H:%M:%S')"'"}]
    ')
    echo "$data" > "$ECONOMY_FILE"
    return 0
}

give_daily() {
    local player="$1"
    local now
    now=$(date +%s)
    ensure_account "$player"
    local data
    data=$(cat "$ECONOMY_FILE")
    local last_daily
    last_daily=$(echo "$data" | jq -r --arg player "$player" '.accounts[$player].last_daily // 0')
    last_daily=${last_daily:-0}
    local cooldown
    cooldown=$(jq -r '.settings.daily_cooldown // 86400' "$ECONOMY_FILE")
    local amount
    amount=$(jq -r '.settings.daily_amount // 50' "$ECONOMY_FILE")
    if [ "$last_daily" -eq 0 ] || [ $((now - last_daily)) -ge "$cooldown" ]; then
        data=$(echo "$data" | jq --arg player "$player" --argjson now "$now" --argjson amount "$amount" '.accounts[$player].balance = (.accounts[$player].balance // 0) + $amount | .accounts[$player].last_daily = $now | .transactions += [{"player": $player, "type":"daily", "amount": $amount, "time":"'"$(date '+%Y-%m-%d %H:%M:%S')"'"}]')
        echo "$data" > "$ECONOMY_FILE"
        return 0
    else
        return 2
    fi
}

is_banker() {
    local player="$1"
    if jq -e --arg player "$player" '.bankers | index($player) != null' "$ECONOMY_FILE" >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

add_banker() {
    local player="$1"
    if is_banker "$player"; then
        return 1
    fi
    local data
    data=$(cat "$ECONOMY_FILE")
    data=$(echo "$data" | jq --arg player "$player" '.bankers += [$player] | .transactions += [{"type":"banker_add","player":$player,"time":"'"$(date '+%Y-%m-%d %H:%M:%S')"'"}]')
    echo "$data" > "$ECONOMY_FILE"
    return 0
}

remove_banker() {
    local player="$1"
    if ! is_banker "$player"; then
        return 1
    fi
    local data
    data=$(cat "$ECONOMY_FILE")
    data=$(echo "$data" | jq --arg player "$player" '.bankers = (.bankers | map(select(. != $player))) | .transactions += [{"type":"banker_remove","player":$player,"time":"'"$(date '+%Y-%m-%d %H:%M:%S')"'"}]')
    echo "$data" > "$ECONOMY_FILE"
    return 0
}

# -----------------------
# Messaging to server
# -----------------------
send_server_command() {
    local message="$1"
    if screen -S blockheads_server -X stuff "$message$(printf \\r)" 2>/dev/null; then
        echo "Sent message to server: $message"
    else
        echo "Error: Could not send message to server. Is the server running?"
    fi
}

# -----------------------
# Purchases & commands
# -----------------------
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

# -----------------------
# Chat processing
# -----------------------
process_message() {
    local player_name="$1"
    local message="$2"
    local current_data
    current_data=$(cat "$ECONOMY_FILE")
    local player_tickets
    player_tickets=$(echo "$current_data" | jq -r --arg player "$player_name" '.players[$player].tickets // 0')
    player_tickets=${player_tickets:-0}
    local currency
    currency=$(get_currency_name)

    case "$message" in
        "hi"|"hello"|"Hi"|"Hello"|"hola"|"Hola")
            send_server_command "Hello $player_name! Welcome to the server. Type !tickets to check your ticket balance."
            ;;
        "!tickets")
            send_server_command "$player_name, you have $player_tickets tickets."
            ;;
        "!balance"|"!bal"|"!check")
            ensure_account "$player_name"
            local bal
            bal=$(get_balance "$player_name")
            send_server_command "$player_name, you have ${bal} ${currency}."
            ;;
        "!daily")
            ensure_account "$player_name"
            if give_daily "$player_name"; then
                local amt
                amt=$(jq -r '.settings.daily_amount // 50' "$ECONOMY_FILE")
                send_server_command "$player_name, you received your daily reward of ${amt} ${currency}!"
            else
                send_server_command "$player_name, you have already claimed your daily reward. Try again later."
            fi
            ;;
        !([!])*) # pass to further parsing
            ;;
    esac

    # Transfers: !pay <amount> <player> OR !transfer <amount> <player>
    if [[ "$message" =~ ^\!(pay|transfer)\ ([0-9]+)\ ([a-zA-Z0-9_]+)$ ]]; then
        local amount="${BASH_REMATCH[2]}"
        local to_player="${BASH_REMATCH[3]}"
        local from_player="$player_name"
        ensure_account "$from_player"
        ensure_account "$to_player"
        if [ "$(get_balance "$from_player")" -lt "$amount" ]; then
            send_server_command "$from_player, you do not have enough ${currency} to transfer ${amount}."
        else
            if transfer_funds "$from_player" "$to_player" "$amount"; then
                send_server_command "Transferred ${amount} ${currency} from ${from_player} to ${to_player}."
            else
                send_server_command "$from_player, transfer failed."
            fi
        fi
    fi

    # Buy via tickets (existing functionality)
    if [[ "$message" =~ ^\!buy_mod$ ]]; then
        if has_purchased "$player_name" "mod" || is_player_in_list "$player_name" "mod"; then
            send_server_command "$player_name, you already have MOD rank. No need to purchase again."
        elif [ "$player_tickets" -ge 10 ]; then
            local new_tickets=$((player_tickets - 10))
            local current_data
            current_data=$(cat "$ECONOMY_FILE")
            current_data=$(echo "$current_data" | jq --arg player "$player_name" --argjson tickets "$new_tickets" '.players[$player].tickets = $tickets')
            add_purchase "$player_name" "mod"
            local time_str
            time_str="$(date '+%Y-%m-%d %H:%M:%S')"
            current_data=$(echo "$current_data" | jq --arg player "$player_name" --arg time "$time_str" '.transactions += [{"player": $player, "type": "purchase", "item": "mod", "tickets": -10, "time": $time}]')
            echo "$current_data" > "$ECONOMY_FILE"
            screen -S blockheads_server -X stuff "/mod $player_name$(printf \\r)"
            send_server_command "Congratulations $player_name! You have been promoted to MOD for 10 tickets. Remaining tickets: $new_tickets"
        else
            send_server_command "$player_name, you need $((10 - player_tickets)) more tickets to buy MOD rank."
        fi
    fi

    if [[ "$message" =~ ^\!buy_admin$ ]]; then
        if has_purchased "$player_name" "admin" || is_player_in_list "$player_name" "admin"; then
            send_server_command "$player_name, you already have ADMIN rank. No need to purchase again."
        elif [ "$player_tickets" -ge 20 ]; then
            local new_tickets=$((player_tickets - 20))
            local current_data
            current_data=$(cat "$ECONOMY_FILE")
            current_data=$(echo "$current_data" | jq --arg player "$player_name" --argjson tickets "$new_tickets" '.players[$player].tickets = $tickets')
            add_purchase "$player_name" "admin"
            local time_str
            time_str="$(date '+%Y-%m-%d %H:%M:%S')"
            current_data=$(echo "$current_data" | jq --arg player "$player_name" --arg time "$time_str" '.transactions += [{"player": $player, "type": "purchase", "item": "admin", "tickets": -20, "time": $time}]')
            echo "$current_data" > "$ECONOMY_FILE"
            screen -S blockheads_server -X stuff "/admin $player_name$(printf \\r)"
            send_server_command "Congratulations $player_name! You have been promoted to ADMIN for 20 tickets. Remaining tickets: $new_tickets"
        else
            send_server_command "$player_name, you need $((20 - player_tickets)) more tickets to buy ADMIN rank."
        fi
    fi

    if [[ "$message" =~ ^\!economy_help$ ]]; then
        send_server_command "Economy commands: !tickets, !balance (or !bal), !daily, !pay <amount> <player>. Admin: use terminal."
    fi
}

# -----------------------
# Admin terminal processing (type in THIS terminal)
# -----------------------
process_admin_command() {
    local command="$1"
    local current_data
    current_data=$(cat "$ECONOMY_FILE")

    if [[ "$command" =~ ^!send_ticket\ ([a-zA-Z0-9_]+)\ ([0-9]+)$ ]]; then
        local player_name="${BASH_REMATCH[1]}"
        local tickets_to_add="${BASH_REMATCH[2]}"
        local player_exists
        player_exists=$(echo "$current_data" | jq --arg player "$player_name" '.players | has($player)')
        if [ "$player_exists" = "false" ]; then
            echo "Player $player_name not found in economy system."
            return
        fi
        local current_tickets
        current_tickets=$(echo "$current_data" | jq -r --arg player "$player_name" '.players[$player].tickets // 0')
        current_tickets=${current_tickets:-0}
        local new_tickets=$((current_tickets + tickets_to_add))
        current_data=$(echo "$current_data" | jq --arg player "$player_name" --argjson tickets "$new_tickets" '.players[$player].tickets = $tickets')
        local time_str
        time_str="$(date '+%Y-%m-%d %H:%M:%S')"
        current_data=$(echo "$current_data" | jq --arg player "$player_name" --arg time "$time_str" --argjson amount "$tickets_to_add" '.transactions += [{"player": $player, "type": "admin_gift", "tickets": $amount, "time": $time}]')
        echo "$current_data" > "$ECONOMY_FILE"
        echo "Added $tickets_to_add tickets to $player_name (Total: $new_tickets)"
        send_server_command "$player_name received $tickets_to_add tickets from admin! Total: $new_tickets"

    elif [[ "$command" =~ ^!make_mod\ ([a-zA-Z0-9_]+)$ ]]; then
        local player_name="${BASH_REMATCH[1]}"
        echo "Making $player_name a MOD"
        screen -S blockheads_server -X stuff "/mod $player_name$(printf \\r)"
        send_server_command "$player_name has been promoted to MOD by admin!"

    elif [[ "$command" =~ ^!make_admin\ ([a-zA-Z0-9_]+)$ ]]; then
        local player_name="${BASH_REMATCH[1]}"
        echo "Making $player_name an ADMIN"
        screen -S blockheads_server -X stuff "/admin $player_name$(printf \\r)"
        send_server_command "$player_name has been promoted to ADMIN by admin!"

    # Admin currency commands
    elif [[ "$command" =~ ^!addfund\ ([a-zA-Z0-9_]+)\ ([0-9]+)$ ]]; then
        local player_name="${BASH_REMATCH[1]}"
        local amount="${BASH_REMATCH[2]}"
        ensure_account "$player_name"
        deposit_to "$player_name" "$amount"
        echo "Added ${amount} to ${player_name}"
        send_server_command "Admin added ${amount} to ${player_name}."

    elif [[ "$command" =~ ^!removefund\ ([a-zA-Z0-9_]+)\ ([0-9]+)$ ]]; then
        local player_name="${BASH_REMATCH[1]}"
        local amount="${BASH_REMATCH[2]}"
        ensure_account "$player_name"
        if withdraw_from "$player_name" "$amount"; then
            echo "Removed ${amount} from ${player_name}"
            send_server_command "Admin removed ${amount} from ${player_name}."
        else
            echo "Insufficient funds for ${player_name}"
        fi

    elif [[ "$command" =~ ^!transfer_admin\ ([a-zA-Z0-9_]+)\ ([a-zA-Z0-9_]+)\ ([0-9]+)$ ]]; then
        local fromp="${BASH_REMATCH[1]}"
        local top="${BASH_REMATCH[2]}"
        local amt="${BASH_REMATCH[3]}"
        ensure_account "$fromp"
        ensure_account "$top"
        if transfer_funds "$fromp" "$top" "$amt"; then
            echo "Transferred ${amt} from ${fromp} to ${top}"
            send_server_command "Admin transferred ${amt} from ${fromp} to ${top}."
        else
            echo "Transfer failed (insufficient funds?)"
        fi

    elif [[ "$command" =~ ^!addonline\ ([0-9]+)$ ]]; then
        local amount="${BASH_REMATCH[1]}"
        local data
        data=$(cat "$ECONOMY_FILE")
        local online_players
        online_players=$(echo "$data" | jq -r '.players | to_entries | map(select(.value.online==true)) | .[].key')
        if [ -z "$online_players" ]; then
            echo "No online players found."
            return
        fi
        for p in $online_players; do
            ensure_account "$p"
            deposit_to "$p" "$amount"
        done
        send_server_command "Everyone online has received ${amount} $(get_currency_name)!"
        echo "Added ${amount} to online players."

    elif [[ "$command" =~ ^!banker\ ([a-zA-Z0-9_]+)$ ]]; then
        local who="${BASH_REMATCH[1]}"
        if add_banker "$who"; then
            echo "Added banker: $who"
            send_server_command "$who is now a banker."
        else
            echo "Banker already exists: $who"
        fi

    elif [[ "$command" =~ ^!unbanker\ ([a-zA-Z0-9_]+)$ ]]; then
        local who="${BASH_REMATCH[1]}"
        if remove_banker "$who"; then
            echo "Removed banker: $who"
            send_server_command "$who is no longer a banker."
        else
            echo "Not a banker: $who"
        fi

    else
        echo "Unknown admin command: $command"
        echo "Available admin commands:"
        echo "!send_ticket <player> <amount>"
        echo "!make_mod <player>"
        echo "!make_admin <player>"
        echo "!addfund <player> <amount>"
        echo "!removefund <player> <amount>"
        echo "!transfer_admin <from> <to> <amount>"
        echo "!addonline <amount>"
        echo "!banker <player>"
        echo "!unbanker <player>"
    fi
}

# -----------------------
# Server welcome detection & log filtering
# -----------------------
server_sent_welcome_recently() {
    local player_name="$1"
    local conn_epoch="${2:-0}"
    if [ -z "$LOG_FILE" ] || [ ! -f "$LOG_FILE" ]; then
        return 1
    fi

    local player_lc
    player_lc=$(echo "$player_name" | tr '[:upper:]' '[:lower:]')
    local matches
    matches=$(tail -n "$TAIL_LINES" "$LOG_FILE" 2>/dev/null | tr '[:upper:]' '[:lower:]' | grep -iE "server: .*welcome" | grep -i "$player_lc" || true)
    if [ -z "$matches" ]; then
        return 1
    fi

    while IFS= read -r line; do
        ts_str=$(echo "$line" | awk '{print $1" "$2}')
        ts_no_ms=${ts_str%.*}
        ts_epoch=$(date -d "$ts_no_ms" +%s 2>/dev/null || echo 0)
        if [ "$ts_epoch" -ge "$conn_epoch" ] && [ "$ts_epoch" -le $((conn_epoch + SERVER_WELCOME_WINDOW)) ]; then
            return 0
        fi
    done < <(tail -n "$TAIL_LINES" "$LOG_FILE" 2>/dev/null | grep -i "server: .*welcome" | grep -i "$player_lc" || true)

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

# -----------------------
# Main monitor loop
# -----------------------
monitor_log() {
    local log_file="$1"
    LOG_FILE="$log_file"

    echo "Starting economy bot. Monitoring: $log_file"
    echo "Bot commands: !tickets, !balance, !daily, !pay <amount> <player>, !economy_help"
    echo "Admin commands (in terminal): !send_ticket <player> <amount>, !addfund <player> <amount>, !removefund <player> <amount>, !addonline <amount>, !banker <player>, !unbanker <player>"
    echo "================================================================"
    echo "IMPORTANT: Admin commands must be typed in THIS terminal, NOT in the game chat!"
    echo "Type admin commands below and press Enter:"
    echo "================================================================"

    local admin_pipe="/tmp/blockheads_admin_pipe"
    rm -f "$admin_pipe"
    mkfifo "$admin_pipe"

    while read -r admin_command < "$admin_pipe"; do
        echo "Processing admin command: $admin_command"
        process_admin_command "$admin_command"
        echo "================================================================"
        echo "Ready for next admin command:"
    done &

    while read -r admin_command; do
        echo "$admin_command" > "$admin_pipe"
    done &

    declare -A welcome_shown

    tail -n 0 -F "$log_file" | filter_server_log | while read line; do
        if [[ "$line" =~ Player\ Connected\ ([a-zA-Z0-9_]+) ]]; then
            local player_name="${BASH_REMATCH[1]}"

            if [[ "$player_name" == "SERVER" ]]; then
                echo "Ignoring system player: $player_name"
                continue
            fi

            ts_str=$(echo "$line" | awk '{print $1" "$2}')
            ts_no_ms=${ts_str%.*}
            conn_epoch=$(date -d "$ts_no_ms" +%s 2>/dev/null || echo 0)

            echo "Player connected: $player_name (ts: $ts_no_ms, epoch: $conn_epoch)"

            local is_new_player="false"
            if add_player_if_new "$player_name"; then
                is_new_player="true"
            fi

            if [ "$is_new_player" = "true" ]; then
                echo "New player $player_name connected - server will handle welcome message"
                welcome_shown["$player_name"]=1
                continue
            fi

            if [ -z "${welcome_shown[$player_name]}" ]; then
                sleep 5
                if server_sent_welcome_recently "$player_name" "$conn_epoch"; then
                    echo "Server already sent welcome for $player_name; skipping bot welcome."
                    welcome_shown["$player_name"]=1
                else
                    echo "Server did not send welcome for $player_name within window; bot will send welcome."
                    show_welcome_message "$player_name" "$is_new_player" 1
                    welcome_shown["$player_name"]=1
                fi
            fi

            grant_login_ticket "$player_name"
            continue
        fi

        if [[ "$line" =~ Player\ Disconnected\ ([a-zA-Z0-9_]+) ]]; then
            local player_name="${BASH_REMATCH[1]}"
            if [[ "$player_name" == "SERVER" ]]; then
                continue
            fi
            echo "Player disconnected: $player_name"
            local data
            data=$(cat "$ECONOMY_FILE")
            if echo "$data" | jq -e --arg player "$player_name" '.players | has($player)' >/dev/null 2>&1; then
                data=$(echo "$data" | jq --arg player "$player_name" '.players[$player].online = false')
                echo "$data" > "$ECONOMY_FILE"
            fi
            unset welcome_shown["$player_name"]
            continue
        fi

        if [[ "$line" =~ ([a-zA-Z0-9_]+):\ (.+)$ ]]; then
            local player_name="${BASH_REMATCH[1]}"
            local message="${BASH_REMATCH[2]}"
            if [[ "$player_name" == "SERVER" ]]; then
                echo "Ignoring system message: $message"
                continue
            fi
            echo "Chat: $player_name: $message"
            add_player_if_new "$player_name"
            process_message "$player_name" "$message"
            continue
        fi

        echo "Other log line: $line"
    done

    wait
    rm -f "$admin_pipe"
}

# Welcome message helper
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
        echo "Skipping welcome for $player_name due to cooldown (use force to override)."
    fi
}

# Entrypoint
if [ $# -eq 1 ]; then
    initialize_economy
    monitor_log "$1"
else
    echo "Usage: $0 <server_log_file>"
    exit 1
fi
