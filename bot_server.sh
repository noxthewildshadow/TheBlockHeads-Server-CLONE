#!/bin/bash
# bot_server.sh - Verbose economy + tickets bot
set -euo pipefail

ECONOMY_FILE="economy_data.json"
TAIL_LINES=500

DEFAULT_SETTINGS='{"currency_name":"coins","daily_amount":50,"daily_cooldown":86400,"max_balance":null}'

echo "bot_server.sh: inicio"

initialize_economy() {
  if [ ! -f "$ECONOMY_FILE" ]; then
    echo "Creando $ECONOMY_FILE..."
    printf '%s\n' '{"players":{},"transactions":[],"accounts":{"SERVER":{"balance":0,"last_daily":0}},"bankers":[],"settings":'"$DEFAULT_SETTINGS"'}' > "$ECONOMY_FILE"
    return
  fi
  local d; d=$(cat "$ECONOMY_FILE")
  echo "$d" | jq -e '.players' >/dev/null 2>&1 || d=$(echo "$d" | jq '. + {"players":{}}')
  echo "$d" | jq -e '.transactions' >/dev/null 2>&1 || d=$(echo "$d" | jq '. + {"transactions": []}')
  echo "$d" | jq -e '.accounts' >/dev/null 2>&1 || d=$(echo "$d" | jq '. + {"accounts":{"SERVER":{"balance":0,"last_daily":0}}}')
  echo "$d" | jq -e '.bankers' >/dev/null 2>&1 || d=$(echo "$d" | jq '. + {"bankers": []}')
  echo "$d" | jq -e '.settings' >/dev/null 2>&1 || d=$(echo "$d" | jq '. + {"settings": '"$DEFAULT_SETTINGS"'}')
  printf '%s\n' "$d" > "$ECONOMY_FILE"
  echo "$ECONOMY_FILE listo."
}

get_currency_name() { jq -r '.settings.currency_name // "coins"' "$ECONOMY_FILE"; }

ensure_account() {
  local p="$1"
  local d; d=$(cat "$ECONOMY_FILE")
  if ! echo "$d" | jq -e --arg p "$p" '.accounts | has($p)' >/dev/null 2>&1; then
    d=$(echo "$d" | jq --arg p "$p" '.accounts[$p] = {"balance":0,"last_daily":0}')
    printf '%s\n' "$d" > "$ECONOMY_FILE"
    echo "Cuenta creada para: $p"
  fi
}

get_balance() { jq -r --arg p "$1" '.accounts[$p].balance // 0' "$ECONOMY_FILE"; }

deposit_to() {
  local p="$1" amt="$2"
  local d; d=$(cat "$ECONOMY_FILE")
  d=$(echo "$d" | jq --arg p "$p" --argjson amt "$amt" '.accounts[$p].balance = (.accounts[$p].balance//0) + $amt | .transactions += [{"player":$p,"type":"deposit","amount":$amt,"time":"'"$(date '+%Y-%m-%d %H:%M:%S')"'"}]')
  printf '%s\n' "$d" > "$ECONOMY_FILE"
  echo "Deposit: $amt -> $p"
}

withdraw_from() {
  local p="$1" amt="$2"
  local bal; bal=$(get_balance "$p")
  if [ "$bal" -lt "$amt" ]; then
    echo "Withdraw failed: fondos insuficientes ($p tiene $bal, se pidió $amt)"
    return 1
  fi
  local d; d=$(cat "$ECONOMY_FILE")
  d=$(echo "$d" | jq --arg p "$p" --argjson amt "$amt" '.accounts[$p].balance = (.accounts[$p].balance//0) - $amt | .transactions += [{"player":$p,"type":"withdraw","amount":- $amt,"time":"'"$(date '+%Y-%m-%d %H:%M:%S')"'"}]')
  printf '%s\n' "$d" > "$ECONOMY_FILE"
  echo "Withdraw: $amt <- $p"
  return 0
}

transfer_funds() {
  local from="$1" to="$2" amt="$3"
  ensure_account "$from"; ensure_account "$to"
  local bal; bal=$(get_balance "$from")
  if [ "$bal" -lt "$amt" ]; then
    echo "Transfer failed: $from fondos insuficientes ($bal < $amt)"
    return 1
  fi
  local d; d=$(cat "$ECONOMY_FILE")
  d=$(echo "$d" | jq --arg from "$from" --arg to "$to" --argjson amt "$amt" '
    .accounts[$from].balance = (.accounts[$from].balance//0) - $amt |
    .accounts[$to].balance = (.accounts[$to].balance//0) + $amt |
    .transactions += [{"player_from": $from, "player_to": $to, "type":"transfer", "amount": $amt, "time":"'"$(date '+%Y-%m-%d %H:%M:%S')"'"}]')
  printf '%s\n' "$d" > "$ECONOMY_FILE"
  echo "Transfer: $amt de $from a $to"
  return 0
}

send_server_command() {
  local m="$1"
  if screen -S blockheads_server -X stuff "$m$(printf \\r)" 2>/dev/null; then
    echo "Enviado al servidor: $m"
  else
    echo "No se pudo enviar al servidor (screen invocación)."
  fi
}

process_message() {
  local player="$1" msg="$2"
  case "$msg" in
    "!tickets")
      local t; t=$(jq -r --arg p "$player" '.players[$p].tickets // 0' "$ECONOMY_FILE")
      send_server_command "$player, you have $t tickets."
      ;;
    "!balance"|"!bal")
      ensure_account "$player"
      send_server_command "$player, you have $(get_balance "$player") $(get_currency_name)."
      ;;
    "!daily")
      ensure_account "$player"
      local now; now=$(date +%s)
      local last; last=$(jq -r --arg p "$player" '.accounts[$p].last_daily // 0' "$ECONOMY_FILE")
      local cooldown; cooldown=$(jq -r '.settings.daily_cooldown // 86400' "$ECONOMY_FILE")
      local amount; amount=$(jq -r '.settings.daily_amount // 50' "$ECONOMY_FILE")
      if [ "$last" = "null" ] || [ -z "$last" ] || [ "$last" -eq 0 ] || [ $((now - last)) -ge "$cooldown" ]; then
        d=$(cat "$ECONOMY_FILE")
        d=$(echo "$d" | jq --arg p "$player" --argjson now "$now" --argjson amount "$amount" '.accounts[$p].balance = (.accounts[$p].balance//0) + $amount | .accounts[$p].last_daily = $now | .transactions += [{"player": $p, "type":"daily", "amount": $amount, "time":"'"$(date '+%Y-%m-%d %H:%M:%S')"'"}]')
        printf '%s\n' "$d" > "$ECONOMY_FILE"
        send_server_command "$player, you received your daily of ${amount} $(get_currency_name)!"
      else
        send_server_command "$player, you already claimed daily. Try later."
      fi
      ;;
    *)
      ;;
  esac

  if [[ "$msg" =~ ^\!(pay|transfer)\ ([0-9]+)\ ([a-zA-Z0-9_]+)$ ]]; then
    local amt="${BASH_REMATCH[2]}" to="${BASH_REMATCH[3]}" from="$player"
    ensure_account "$from"; ensure_account "$to"
    if transfer_funds "$from" "$to" "$amt"; then
      send_server_command "Transferred ${amt} $(get_currency_name) from ${from} to ${to}."
    else
      send_server_command "$from, insufficient funds."
    fi
  fi
}

monitor_log() {
  local log_file="$1"
  if [ ! -f "$log_file" ]; then
    echo "ERROR: log file no existe: $log_file" >&2
    exit 1
  fi
  initialize_economy

  local admin_pipe="/tmp/blockheads_admin_pipe"
  rm -f "$admin_pipe"
  mkfifo "$admin_pipe"

  while read -r admin_cmd < "$admin_pipe"; do
    case "$admin_cmd" in
      !addfund* )
        if [[ "$admin_cmd" =~ ^!addfund\ ([a-zA-Z0-9_]+)\ ([0-9]+)$ ]]; then
          ensure_account "${BASH_REMATCH[1]}"
          deposit_to "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
          send_server_command "Admin added ${BASH_REMATCH[2]} to ${BASH_REMATCH[1]}."
        fi
        ;;
      !removefund* )
        if [[ "$admin_cmd" =~ ^!removefund\ ([a-zA-Z0-9_]+)\ ([0-9]+)$ ]]; then
          ensure_account "${BASH_REMATCH[1]}"
          withdraw_from "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" && send_server_command "Admin removed ${BASH_REMATCH[2]} from ${BASH_REMATCH[1]}." || true
        fi
        ;;
      * )
        echo "Admin: comando desconocido: $admin_cmd"
        ;;
    esac
  done &

  while read -r admin_line; do echo "$admin_line" > "$admin_pipe"; done &

  echo "Monitorizando log: $log_file"
  tail -n 0 -F "$log_file" | while read -r line; do
    if [[ "$line" =~ Player\ Connected\ ([a-zA-Z0-9_]+) ]]; then
      p="${BASH_REMATCH[1]}"
      initialize_economy
      if ! jq -e --arg p "$p" '.players | has($p)' "$ECONOMY_FILE" >/dev/null 2>&1; then
        local d; d=$(cat "$ECONOMY_FILE")
        d=$(echo "$d" | jq --arg p "$p" '.players[$p] = {"tickets":0,"last_login":0,"last_welcome_time":0,"last_help_time":0,"purchases":[],"online":true}')
        d=$(echo "$d" | jq --arg p "$p" '.accounts[$p] = (.accounts[$p] // {"balance":0,"last_daily":0})')
        printf '%s\n' "$d" > "$ECONOMY_FILE"
        echo "Jugador añadido: $p"
      else
        local d; d=$(cat "$ECONOMY_FILE")
        d=$(echo "$d" | jq --arg p "$p" '.players[$p].online = true')
        printf '%s\n' "$d" > "$ECONOMY_FILE"
      fi

      local now; now=$(date +%s)
      local last; last=$(jq -r --arg p "$p" '.players[$p].last_login // 0' "$ECONOMY_FILE")
      if [ "$last" = "null" ] || [ -z "$last" ] || [ "$last" -eq 0 ] || [ $((now - last)) -ge 3600 ]; then
        local d; d=$(cat "$ECONOMY_FILE")
        local tickets; tickets=$(echo "$d" | jq -r --arg p "$p" '.players[$p].tickets // 0')
        tickets=$((tickets + 1))
        d=$(echo "$d" | jq --arg p "$p" --argjson tickets "$tickets" --argjson now "$now" '.players[$p].tickets = $tickets | .players[$p].last_login = $now | .transactions += [{"player": $p, "type":"login_bonus","tickets":1,"time":"'"$(date '+%Y-%m-%d %H:%M:%S')"'"}]')
        printf '%s\n' "$d" > "$ECONOMY_FILE"
        send_server_command "$p, you received 1 login ticket! You now have $tickets tickets."
      fi
    fi

    if [[ "$line" =~ ^([a-zA-Z0-9_]+):[[:space:]](.+)$ ]]; then
      p="${BASH_REMATCH[1]}"; m="${BASH_REMATCH[2]}"
      process_message "$p" "$m"
    fi
  done
}

if [ $# -ne 1 ]; then
  echo "Usage: $0 /path/to/console.log" >&2
  exit 1
fi

monitor_log "$1"
