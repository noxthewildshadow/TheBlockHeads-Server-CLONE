#!/bin/bash
# bot_server.sh - economy + tickets bot (currency-ready)
# Usage: ./bot_server.sh /path/to/console.log
set -euo pipefail

ECONOMY_FILE="economy_data.json"
TAIL_LINES=500
SERVER_WELCOME_WINDOW=15

DEFAULT_CURRENCY_SETTINGS='{
  "currency_name":"coins",
  "daily_amount":50,
  "daily_cooldown":86400,
  "max_balance":null
}'

initialize_economy() {
  if [ ! -f "$ECONOMY_FILE" ]; then
    echo '{"players": {}, "transactions": [], "accounts": {"SERVER": {"balance": 0, "last_daily": 0}}, "bankers": [], "settings": '"$DEFAULT_CURRENCY_SETTINGS"'}' > "$ECONOMY_FILE"
    return
  fi
  # merge missing keys (safe-guard)
  local data
  data=$(cat "$ECONOMY_FILE")
  if ! echo "$data" | jq -e '.players' >/dev/null 2>&1; then data=$(echo "$data" | jq '. + {"players": {}}'); fi
  if ! echo "$data" | jq -e '.transactions' >/dev/null 2>&1; then data=$(echo "$data" | jq '. + {"transactions": []}'); fi
  if ! echo "$data" | jq -e '.accounts' >/dev/null 2>&1; then data=$(echo "$data" | jq '. + {"accounts":{"SERVER":{"balance":0,"last_daily":0}}}'); fi
  if ! echo "$data" | jq -e '.bankers' >/dev/null 2>&1; then data=$(echo "$data" | jq '. + {"bankers": []}'); fi
  if ! echo "$data" | jq -e '.settings' >/dev/null 2>&1; then data=$(echo "$data" | jq '. + {"settings": '"$DEFAULT_CURRENCY_SETTINGS"'}'); fi
  echo "$data" > "$ECONOMY_FILE"
}

# Minimal helpers (balance, account)
get_currency_name() { jq -r '.settings.currency_name // "coins"' "$ECONOMY_FILE"; }
ensure_account() {
  local p="$1"
  local d
  d=$(cat "$ECONOMY_FILE")
  if ! echo "$d" | jq -e --arg p "$p" '.accounts | has($p)' >/dev/null 2>&1; then
    d=$(echo "$d" | jq --arg p "$p" '.accounts[$p] = {"balance":0,"last_daily":0}')
    echo "$d" > "$ECONOMY_FILE"
  fi
}
get_balance() { jq -r --arg p "$1" '.accounts[$p].balance // 0' "$ECONOMY_FILE"; }
deposit_to() {
  local p="$1" amt="$2"
  local d
  d=$(cat "$ECONOMY_FILE")
  d=$(echo "$d" | jq --arg p "$p" --argjson amt "$amt" '.accounts[$p].balance = (.accounts[$p].balance // 0) + $amt | .transactions += [{"player":$p,"type":"deposit","amount":$amt,"time":"'"$(date '+%Y-%m-%d %H:%M:%S')"'"}]')
  echo "$d" > "$ECONOMY_FILE"
}
withdraw_from() {
  local p="$1" amt="$2"
  local bal
  bal=$(get_balance "$p")
  if [ "$bal" -lt "$amt" ]; then return 1; fi
  local d
  d=$(cat "$ECONOMY_FILE")
  d=$(echo "$d" | jq --arg p "$p" --argjson amt "$amt" '.accounts[$p].balance = (.accounts[$p].balance // 0) - $amt | .transactions += [{"player":$p,"type":"withdraw","amount":- $amt,"time":"'"$(date '+%Y-%m-%d %H:%M:%S')"'"}]')
  echo "$d" > "$ECONOMY_FILE"
  return 0
}
transfer_funds() {
  local from="$1" to="$2" amt="$3"
  ensure_account "$from"; ensure_account "$to"
  local bal
  bal=$(get_balance "$from")
  if [ "$bal" -lt "$amt" ]; then return 1; fi
  local d
  d=$(cat "$ECONOMY_FILE")
  d=$(echo "$d" | jq --arg from "$from" --arg to "$to" --argjson amt "$amt" '
    .accounts[$from].balance = (.accounts[$from].balance // 0) - $amt |
    .accounts[$to].balance   = (.accounts[$to].balance   // 0) + $amt |
    .transactions += [{"player_from":$from,"player_to":$to,"type":"transfer","amount":$amt,"time":"'"$(date '+%Y-%m-%d %H:%M:%S')"'"}]')
  echo "$d" > "$ECONOMY_FILE"
  return 0
}

send_server_command() {
  local msg="$1"
  screen -S blockheads_server -X stuff "$msg$(printf \\r)" 2>/dev/null || echo "Could not send to server: $msg"
}

# Basic commands processing (concise)
process_message() {
  local player="$1" msg="$2"
  case "$msg" in
    "!tickets") local t; t=$(jq -r --arg p "$player" '.players[$p].tickets // 0' "$ECONOMY_FILE"); send_server_command "$player, you have $t tickets." ;;
    "!balance"|"!bal") ensure_account "$player"; local b; b=$(get_balance "$player"); send_server_command "$player, you have ${b} $(get_currency_name)." ;;
    "!daily") ensure_account "$player"; local res; res=0
      # daily logic
      res=$( (bash -c "set -o pipefail; \
        now=\$(date +%s); d=\$(cat $ECONOMY_FILE); last=\$(echo \"\$d\" | jq -r --arg p \"$player\" '.accounts[$p].last_daily // 0'); \
        cooldown=\$(echo \"\$d\" | jq -r '.settings.daily_cooldown // 86400'); amt=\$(echo \"\$d\" | jq -r '.settings.daily_amount // 50'); \
        if [ \"\$last\" -eq 0 ] || [ \$((now-last)) -ge \$cooldown ]; then \
          echo \"update\"; exit 0; \
        else echo \"cool\"; exit 2; fi" ) ) || true
      if [ "$res" = "update" ]; then
        # perform update
        local amt; amt=$(jq -r '.settings.daily_amount // 50' "$ECONOMY_FILE")
        local now; now=$(date +%s)
        local d; d=$(cat "$ECONOMY_FILE")
        d=$(echo "$d" | jq --arg p "$player" --argjson now "$now" --argjson amt "$amt" '.accounts[$p].balance = (.accounts[$p].balance // 0) + $amt | .accounts[$p].last_daily = $now | .transactions += [{"player": $p, "type":"daily", "amount": $amt, "time":"'"$(date '+%Y-%m-%d %H:%M:%S')"'"}]')
        echo "$d" > "$ECONOMY_FILE"
        send_server_command "$player, you received your daily of ${amt} $(get_currency_name)!"
      else
        send_server_command "$player, you already claimed your daily. Try later."
      fi
    ;;
    # transfer: !pay 10 Other
    \!pay*|\!transfer*)
      if [[ "$msg" =~ ^\!(pay|transfer)\ ([0-9]+)\ ([a-zA-Z0-9_]+)$ ]]; then
        local amt="${BASH_REMATCH[2]}" to="${BASH_REMATCH[3]}" from="$player"
        ensure_account "$from"; ensure_account "$to"
        if transfer_funds "$from" "$to" "$amt"; then
          send_server_command "Transferred ${amt} $(get_currency_name) from ${from} to ${to}."
        else
          send_server_command "$from, insufficient funds."
        fi
      fi
    ;;
    *) ;; # ignore other messages
  esac
}

# monitor log
monitor_log() {
  local log_file="$1"
  if [ -z "$log_file" ] || [ ! -f "$log_file" ]; then
    echo "Usage: $0 /path/to/console.log"
    exit 1
  fi
  LOG_FILE="$log_file"
  initialize_economy
  echo "Economy bot monitoring: $LOG_FILE"

  # admin pipe
  local admin_pipe="/tmp/blockheads_admin_pipe"
  rm -f "$admin_pipe"
  mkfifo "$admin_pipe"

  # admin reader
  while read -r admin_cmd < "$admin_pipe"; do
    case "$admin_cmd" in
      !addfund* )
        if [[ "$admin_cmd" =~ ^!addfund\ ([a-zA-Z0-9_]+)\ ([0-9]+)$ ]]; then
          ensure_account "${BASH_REMATCH[1]}"; deposit_to "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"; send_server_command "Admin added ${BASH_REMATCH[2]} to ${BASH_REMATCH[1]}."
        fi;;
      !removefund* )
        if [[ "$admin_cmd" =~ ^!removefund\ ([a-zA-Z0-9_]+)\ ([0-9]+)$ ]]; then
          ensure_account "${BASH_REMATCH[1]}"; withdraw_from "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" && send_server_command "Admin removed ${BASH_REMATCH[2]} from ${BASH_REMATCH[1]}." || echo "Insufficient funds"
        fi;;
      * ) echo "Unknown admin command: $admin_cmd";;
    esac
  done &

  # pipe stdin -> admin_pipe
  while read -r admin_line; do
    echo "$admin_line" > "$admin_pipe"
  done &

  tail -n 0 -F "$LOG_FILE" | while read -r line; do
    # Player Connected
    if [[ "$line" =~ Player\ Connected\ ([a-zA-Z0-9_]+) ]]; then
      player="${BASH_REMATCH[1]}"
      # mark online + add if new
      initialize_economy
      # add player entry if missing
      if ! jq -e --arg p "$player" '.players | has($p)' "$ECONOMY_FILE" >/dev/null 2>&1; then
        d=$(cat "$ECONOMY_FILE")
        d=$(echo "$d" | jq --arg p "$player" '.players[$p] = {"tickets":0,"last_login":0,"last_welcome_time":0,"last_help_time":0,"purchases":[],"online":true}')
        d=$(echo "$d" | jq --arg p "$player" '.accounts[$p] = (.accounts[$p] // {"balance":0,"last_daily":0})')
        echo "$d" > "$ECONOMY_FILE"
      else
        d=$(cat "$ECONOMY_FILE")
        d=$(echo "$d" | jq --arg p "$player" '.players[$p].online = true')
        echo "$d" > "$ECONOMY_FILE"
      fi
      # give ticket if eligible
      # simplified: always call grant logic via existing fields
      # (grant login ticket)
      # reuse grant logic by simulating previous behavior:
      now=$(date +%s)
      last=$(jq -r --arg p "$player" '.players[$p].last_login // 0' "$ECONOMY_FILE")
      if [ "$last" = "null" ] || [ -z "$last" ] || [ "$last" -eq 0 ] || [ $((now - last)) -ge 3600 ]; then
        d=$(cat "$ECONOMY_FILE")
        tickets=$(echo "$d" | jq -r --arg p "$player" '.players[$p].tickets // 0')
        tickets=$((tickets+1))
        d=$(echo "$d" | jq --arg p "$player" --argjson tickets "$tickets" --argjson now "$now" '.players[$p].tickets = $tickets | .players[$p].last_login = $now | .transactions += [{"player": $p, "type":"login_bonus","tickets":1,"time":"'"$(date '+%Y-%m-%d %H:%M:%S')"'"}]')
        echo "$d" > "$ECONOMY_FILE"
        send_server_command "$player, you received 1 login ticket! You now have $tickets tickets."
      fi
    fi

    # Player chat: "Name: message"
    if [[ "$line" =~ ^([a-zA-Z0-9_]+):[[:space:]](.+)$ ]]; then
      p="${BASH_REMATCH[1]}"; m="${BASH_REMATCH[2]}"
      process_message "$p" "$m"
    fi
  done
}

# entrypoint
if [ $# -eq 1 ]; then
  monitor_log "$1"
else
  echo "Usage: $0 /path/to/console.log"
  exit 1
fi
