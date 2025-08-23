#!/usr/bin/env bash
set -euo pipefail

# bot_server.sh endurecido
INSTALL_DIR="/opt/blockheads"
SERVICE_USER="blockheads"
SCREEN_SERVER="blockheads_server"
ECONOMY_FILE="/var/lib/blockheads/economy_data.json"
LOCK_FD=200
ADMIN_PIPE_DIR="/run/blockheads"
ADMIN_PIPE="${ADMIN_PIPE_DIR}/admin_pipe"
TAIL_LINES=500
SERVER_WELCOME_WINDOW=15

# Asegurarse de que economy file exista
if [ ! -f "$ECONOMY_FILE" ]; then
  mkdir -p "$(dirname "$ECONOMY_FILE")"
  chown "$SERVICE_USER":"$SERVICE_USER" "$(dirname "$ECONOMY_FILE")"
  umask 077
  echo '{"players": {}, "transactions": []}' > "$ECONOMY_FILE"
  chown "$SERVICE_USER":"$SERVICE_USER" "$ECONOMY_FILE"
fi
chmod 600 "$ECONOMY_FILE"

# Crear admin pipe seguro
mkdir -p "$ADMIN_PIPE_DIR"
chown "$SERVICE_USER":"$SERVICE_USER" "$ADMIN_PIPE_DIR"
chmod 700 "$ADMIN_PIPE_DIR"
if [ ! -p "$ADMIN_PIPE" ]; then
  rm -f "$ADMIN_PIPE"
  ( umask 077; mkfifo "$ADMIN_PIPE" )
  chown "$SERVICE_USER":"$SERVICE_USER" "$ADMIN_PIPE"
  chmod 600 "$ADMIN_PIPE"
fi

# Helper: lock economy (usar file descriptor)
lock_economy() {
  exec {LOCK_FD}>"$ECONOMY_FILE.lock"
  flock -x "$LOCK_FD"
}
unlock_economy() {
  flock -u "$LOCK_FD" || true
  eval "exec $LOCK_FD>&-"
}

# Sanitize player names: sólo alfanumérico y underscore
sanitize_player() {
  local p="$1"
  if [[ "$p" =~ ^[A-Za-z0-9_]+$ ]]; then
    echo "$p"
    return 0
  fi
  return 1
}

# Atomic write helper for JSON using jq
atomic_write_json() {
  local tmp
  tmp=$(mktemp --tmpdir -p /var/tmp blockheads_json.XXXXXX) || tmp="/tmp/blockheads_json.$$"
  cat > "$tmp"
  mv -f "$tmp" "$ECONOMY_FILE"
  chown "$SERVICE_USER":"$SERVICE_USER" "$ECONOMY_FILE"
  chmod 600 "$ECONOMY_FILE"
}

send_server_command() {
  local message="$1"
  # Limit length and remove control chars
  message="$(echo "$message" | tr -d '\000')"
  # Use screen to send safely
  if screen -list | grep -q "$SCREEN_SERVER"; then
    screen -S "$SCREEN_SERVER" -p 0 -X stuff "$(printf '%s\r' "$message")"
    echo "Enviado: $message"
  else
    echo "Servidor no ejecutándose; no se puede enviar: $message"
  fi
}

# Añadir jugador si no existe (con bloqueo)
add_player_if_new() {
  local player="$1"
  lock_economy
  local exists
  exists=$(jq --arg p "$player" '.players | has($p)' "$ECONOMY_FILE")
  if [ "$exists" = "false" ]; then
    # Actualizar con jq y escribir atómicamente
    tmp=$(mktemp)
    jq --arg p "$player" '.players[$p] = {"tickets":0,"last_login":0,"last_welcome_time":0,"last_help_time":0,"purchases": []}' "$ECONOMY_FILE" > "$tmp"
    mv -f "$tmp" "$ECONOMY_FILE"
    chown "$SERVICE_USER":"$SERVICE_USER" "$ECONOMY_FILE"
    chmod 600 "$ECONOMY_FILE"
    unlock_economy
    return 0
  fi
  unlock_economy
  return 1
}

give_first_time_bonus() {
  local player="$1"
  lock_economy
  tmp=$(mktemp)
  jq --arg p "$player" --arg time "$(date '+%Y-%m-%d %H:%M:%S')" \
    '.players[$p].tickets = 1 | .players[$p].last_login = (now|floor) | .transactions += [{"player": $p, "type":"welcome_bonus", "tickets":1, "time": $time}]' \
    "$ECONOMY_FILE" > "$tmp"
  mv -f "$tmp" "$ECONOMY_FILE"
  chown "$SERVICE_USER":"$SERVICE_USER" "$ECONOMY_FILE"
  chmod 600 "$ECONOMY_FILE"
  unlock_economy
  send_server_command "Hello $player! Received 1 welcome ticket."
}

grant_login_ticket() {
  local player="$1"
  lock_economy
  local last_login
  last_login=$(jq -r --arg p "$player" '.players[$p].last_login // 0' "$ECONOMY_FILE")
  local current_time
  current_time=$(date +%s)
  if [ -z "$last_login" ] || [ "$((current_time - last_login))" -ge 3600 ]; then
    tmp=$(mktemp)
    jq --arg p "$player" --argjson now "$current_time" '.players[$p].tickets += 1 | .players[$p].last_login = $now | .transactions += [{"player": $p, "type":"login_bonus", "tickets":1, "time": (now|floor)}]' "$ECONOMY_FILE" > "$tmp"
    mv -f "$tmp" "$ECONOMY_FILE"
    chown "$SERVICE_USER":"$SERVICE_USER" "$ECONOMY_FILE"
    chmod 600 "$ECONOMY_FILE"
    unlock_economy
    send_server_command "$player, you received 1 login ticket!"
  else
    unlock_economy
    # nothing
  fi
}

# Admin command processor: leer desde fifo pero solo si el pipe existe y es propiedad del servicio
process_admin_command() {
  local cmd="$1"
  # permitir solo comandos con formato controlado
  if [[ "$cmd" =~ ^!send_ticket[[:space:]]+([A-Za-z0-9_]+)[[:space:]]+([0-9]+)$ ]]; then
    local player="${BASH_REMATCH[1]}"
    local amount="${BASH_REMATCH[2]}"
    if ! sanitize_player "$player"; then
      echo "Admin: nombre de jugador inválido: $player"
      return
    fi
    lock_economy
    tmp=$(mktemp)
    jq --arg p "$player" --argjson amt "$amount" '.players[$p].tickets += $amt | .transactions += [{"player": $p, "type":"admin_gift", "tickets": $amt, "time": (now|floor)}]' "$ECONOMY_FILE" > "$tmp"
    mv -f "$tmp" "$ECONOMY_FILE"
    chown "$SERVICE_USER":"$SERVICE_USER" "$ECONOMY_FILE"
    chmod 600 "$ECONOMY_FILE"
    unlock_economy
    send_server_command "$player received $amount tickets from admin!"
  elif [[ "$cmd" =~ ^!make_mod[[:space:]]+([A-Za-z0-9_]+)$ ]]; then
    local player="${BASH_REMATCH[1]}"
    if ! sanitize_player "$player"; then
      echo "Admin: nombre de jugador inválido: $player"
      return
    fi
    send_server_command "/mod $player"
  elif [[ "$cmd" =~ ^!make_admin[[:space:]]+([A-Za-z0-9_]+)$ ]]; then
    local player="${BASH_REMATCH[1]}"
    if ! sanitize_player "$player"; then
      echo "Admin: nombre de jugador inválido: $player"
      return
    fi
    send_server_command "/admin $player"
  else
    echo "Comando admin desconocido: $cmd"
  fi
}

# Monitor log (simplificado): recibe la ruta del log como $1
monitor_log() {
  local LOG_FILE="$1"

  if [ ! -f "$LOG_FILE" ]; then
    echo "No existe log: $LOG_FILE"
    exit 1
  fi

  echo "Bot iniciado. Monitorizando: $LOG_FILE"
  # Abre un background que lee admin pipe
  (
    while true; do
      if [ -p "$ADMIN_PIPE" ]; then
        if read -r cmd < "$ADMIN_PIPE"; then
          echo "Admin input: $cmd"
          process_admin_command "$cmd"
        fi
      else
        sleep 1
      fi
    done
  ) &

  # tail -F el log y procesar eventos
  tail -n 0 -F "$LOG_FILE" | while IFS= read -r line; do
    # Ejemplo: detectar "Player Connected <NAME>"
    if [[ "$line" =~ Player\ Connected\ ([A-Za-z0-9_]+) ]]; then
      player="${BASH_REMATCH[1]}"
      if ! sanitize_player "$player"; then
        echo "Nombre de jugador no válido (ignored): $player"
        continue
      fi
      if add_player_if_new "$player"; then
        give_first_time_bonus "$player"
        continue
      fi
      grant_login_ticket "$player"
      continue
    fi

    # Chat detection: "NAME: message"
    if [[ "$line" =~ ^([A-Za-z0-9_]+):[[:space:]](.+)$ ]]; then
      p="${BASH_REMATCH[1]}"
      msg="${BASH_REMATCH[2]}"
      if sanitize_player "$p"; then
        # manejar comandos simples
        case "$msg" in
          "!tickets")
            lock_economy
            local tickets
            tickets=$(jq -r --arg p "$p" '.players[$p].tickets // 0' "$ECONOMY_FILE")
            unlock_economy
            send_server_command "$p, you have $tickets tickets."
            ;;
          "!economy_help")
            send_server_command "Economy commands: !tickets, !buy_mod (10), !buy_admin (20)"
            ;;
        esac
      fi
    fi
  done

  wait
}

if [ $# -ne 1 ]; then
  echo "Uso: $0 <server_console_log>"
  exit 1
fi

monitor_log "$1"
