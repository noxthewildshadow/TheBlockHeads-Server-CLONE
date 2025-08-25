#!/bin/bash
# blockheads_bot.sh
# Versión corregida y mejorada — todo en uno (backups post-revoke, atomic writes, flock, checksum)
# Uso: ./blockheads_bot.sh /ruta/a/tu/server.log

set -euo pipefail

# --------------------------
# Config / Colores / utils
# --------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
NC='\033[0m' # No Color

print_status() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_header() {
  echo -e "${PURPLE}================================================================${NC}"
  echo -e "$1"
  echo -e "${PURPLE}================================================================${NC}"
}

# --------------------------
# Requisitos mínimos
# --------------------------
require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { print_error "Se necesita '$1' en PATH. Instálalo e inténtalo de nuevo."; exit 1; }
}

require_cmd jq
require_cmd mktemp
require_cmd sha256sum
require_cmd tar
require_cmd flock
require_cmd screen

# --------------------------
# Configuración del bot
# --------------------------
ECONOMY_FILE="economy_data.json"
ADMIN_OFFENSES_FILE="admin_offenses.json"
BACKUP_DIR="list_backups"
RESTORE_PENDING_FILE="restore_pending.txt"
TAIL_LINES=500
TMP_PREFIX="/tmp/blockheads_bot_$$"

# LOG_FILE se establece cuando se ejecuta monitor_log
LOG_FILE=""

# --------------------------
# Utilidades de escritura atómica y locking
# --------------------------

# atomic_write <dest> <tmpfile>
# usa stdin como contenido a escribir en dest -> escribe en tmp en mismo dir y mv (atómico en mismo FS)
atomic_write() {
  local dest="$1"
  local dir
  dir=$(dirname "$dest")
  mkdir -p "$dir"
  local tmp
  tmp=$(mktemp "${dir}/.tmp.XXXXXX") || { print_error "mktemp falló"; return 1; }
  cat - > "$tmp" || { rm -f "$tmp"; return 1; }
  # fsync no está garantizado; opcional: sync
  mv -f "$tmp" "$dest" || { rm -f "$tmp"; return 1; }
  return 0
}

# with_lock <lockfile> <command...>
# Ejecuta el comando dentro de un lock exclusivo (flock) usando descriptor 200.
with_lock() {
  local lockfile="$1"
  shift
  local fdfile="${lockfile}.lock"
  # crear lockfile si no existe
  mkdir -p "$(dirname "$fdfile")"
  touch "$fdfile"
  exec 200>"$fdfile"
  flock -x 200 || { print_error "No se pudo adquirir flock en $fdfile"; return 1; }
  # ejecutar comando(s)
  "$@"
  local rc=$?
  flock -u 200
  exec 200>&-
  return $rc
}

# --------------------------
# Checksum helpers
# --------------------------
# Guarda checksum de adminlist.txt en BACKUP_DIR/latest_adminlist.sha256
save_latest_adminlist_checksum() {
  local world_dir
  world_dir=$(dirname "$LOG_FILE" 2>/dev/null || echo ".")
  local adminfile="$world_dir/adminlist.txt"
  if [ -f "$adminfile" ]; then
    sha256sum "$adminfile" | awk '{print $1}' > "${BACKUP_DIR}/latest_adminlist.sha256"
    print_status "Saved adminlist checksum to ${BACKUP_DIR}/latest_adminlist.sha256"
  else
    # Si no existe, guarda cadena vacía para indicar ausencia
    echo "" > "${BACKUP_DIR}/latest_adminlist.sha256"
    print_status "adminlist.txt no existe; saved empty checksum marker"
  fi
}

# Devuelve 0 si checksum actual igual al guardado, 1 si distinto
compare_adminlist_checksum() {
  local world_dir
  world_dir=$(dirname "$LOG_FILE" 2>/dev/null || echo ".")
  local adminfile="$world_dir/adminlist.txt"
  local saved="${BACKUP_DIR}/latest_adminlist.sha256"
  if [ ! -f "$saved" ]; then
    # no hay referencia -> consideramos diferente para seguridad
    return 1
  fi
  if [ ! -f "$adminfile" ]; then
    # si guardado es vacío y adminfile no existe -> igual
    local savedval
    savedval=$(cat "$saved" 2>/dev/null || echo "")
    if [ -z "$savedval" ]; then
      return 0
    else
      return 1
    fi
  fi
  local current
  current=$(sha256sum "$adminfile" | awk '{print $1}')
  local savedval
  savedval=$(cat "$saved" 2>/dev/null || echo "")
  if [ "$current" = "$savedval" ]; then
    return 0
  else
    return 1
  fi
}

# --------------------------
# Backup & Restore
# --------------------------

initialize_backup_dir() {
  if [ ! -d "$BACKUP_DIR" ]; then
    mkdir -p "$BACKUP_DIR"
    print_success "Backup directory created: $BACKUP_DIR"
  fi
}

# create_list_backup <reason>
create_list_backup() {
  local reason="$1"
  local world_dir
  world_dir=$(dirname "$LOG_FILE" 2>/dev/null || echo ".")
  if [ ! -d "$world_dir" ]; then
    print_error "World directory no encontrado: $world_dir"
    return 1
  fi

  # Lock while creamos backup para evitar race con restores/mods
  local lockfile="${BACKUP_DIR}/backup.lock"
  with_lock "$lockfile" bash -c '
    world_dir="$0"; reason="$1"; BACKUP_DIR="$2"
    timestamp=$(date +%Y%m%d_%H%M%S)
    backup_file="${BACKUP_DIR}/backup_${timestamp}_${reason}.tar.gz"
    # preparar lista de archivos que existen
    files=()
    for f in adminlist.txt modlist.txt blacklist.txt; do
      if [ -f "${world_dir}/${f}" ]; then
        files+=("$f")
      fi
    done

    if [ "${#files[@]}" -eq 0 ]; then
      echo "NO_FILES" 1>&2
      exit 2
    fi

    tar -czf "$backup_file" -C "$world_dir" "${files[@]}" 2>/dev/null || { echo "TAR_ERR" 1>&2; exit 3; }
    echo "$(realpath "$backup_file")" > "${BACKUP_DIR}/latest_backup.txt"
    ' "$world_dir" "$reason" "$BACKUP_DIR"
  local rc=$?
  if [ $rc -eq 0 ]; then
    # actualizar checksum cached
    save_latest_adminlist_checksum
    print_success "Created backup (reason=$reason) and updated latest_backup.txt"
    return 0
  elif [ $rc -eq 2 ]; then
    print_warning "No se encontraron archivos de listas para respaldar en $world_dir"
    return 1
  else
    print_error "Error creando backup (tar falló)"
    return 1
  fi
}

# restore_from_backup <backup_file>
restore_from_backup() {
  local backup_file="$1"
  local world_dir
  world_dir=$(dirname "$LOG_FILE" 2>/dev/null || echo ".")
  if [ ! -f "$backup_file" ]; then
    print_error "Backup file not found: $backup_file"
    return 1
  fi
  if [ ! -d "$world_dir" ]; then
    print_error "World directory not found: $world_dir"
    return 1
  fi

  # Lock during restore to avoid concurrent modifications
  local lockfile="${BACKUP_DIR}/backup.lock"
  with_lock "$lockfile" bash -c '
    backup="$0"; world_dir="$1"
    # extraer los archivos del tar en el directorio world_dir
    tar -xzf "$backup" -C "$world_dir"
    ' "$backup_file" "$world_dir"
  local rc=$?
  if [ $rc -ne 0 ]; then
    print_error "Error al extraer backup: $backup_file"
    return 1
  fi

  # Al restaurar, actualizamos checksum guardada (porque ahora la lista coincide con el backup)
  save_latest_adminlist_checksum

  send_server_command "WARNING: Restored legitimate lists from backup. If you notice permission issues, please rejoin the server."
  print_success "Restored from backup: $backup_file"
  return 0
}

# schedule_restore <backup_file> [delay_seconds]
# Antes de restaurar, solo restaura si el checksum actual difiere del guardado (indicando tampering)
schedule_restore() {
  local backup_file="$1"
  local delay_seconds="${2:-5}"

  # Guardar pending
  echo "$backup_file" > "$RESTORE_PENDING_FILE"
  (
    sleep "$delay_seconds"
    if [ ! -f "$RESTORE_PENDING_FILE" ]; then
      exit 0
    fi
    if [ "$(cat "$RESTORE_PENDING_FILE")" != "$backup_file" ]; then
      exit 0
    fi

    # Comprobamos si el adminlist actual coincide con el checksum guardado.
    if compare_adminlist_checksum; then
      # Si coincide, NO restauramos (evitamos reintroducir admins por backups viejos)
      print_status "Checksum coincide con latest; cancelando restauración automática para evitar reintroducción."
      rm -f "$RESTORE_PENDING_FILE"
      exit 0
    else
      print_warning "Checksum mismatch detectado; procediendo a restaurar backup para intentar reparar tampering."
      restore_from_backup "$backup_file"
      rm -f "$RESTORE_PENDING_FILE"
      exit 0
    fi
  ) &
  print_warning "Scheduled restore from $backup_file in $delay_seconds seconds (will check checksum before applying)"
}

cancel_restore() {
  if [ -f "$RESTORE_PENDING_FILE" ]; then
    rm -f "$RESTORE_PENDING_FILE"
    print_success "Cancelled pending restore operation"
  else
    print_status "No pending restore to cancel"
  fi
}

# --------------------------
# Admin offenses (jq safe)
# --------------------------
initialize_admin_offenses() {
  if [ ! -f "$ADMIN_OFFENSES_FILE" ]; then
    echo '{}' > "$ADMIN_OFFENSES_FILE"
    print_success "Admin offenses tracking file created"
  fi
}

record_admin_offense() {
  local admin_name="$1"
  local current_time
  current_time=$(date +%s)
  if [ ! -f "$ADMIN_OFFENSES_FILE" ]; then
    echo '{}' > "$ADMIN_OFFENSES_FILE"
  fi
  local tmp="${TMP_PREFIX}_admin_offenses.json"
  cat "$ADMIN_OFFENSES_FILE" | jq --arg admin "$admin_name" --argjson time "$current_time" '(.[$admin].count // 0) as $c | .[$admin] = {"count": ($c + 1), "last_offense": $time}' > "$tmp" && mv "$tmp" "$ADMIN_OFFENSES_FILE"
  print_warning "Recorded offense for admin $admin_name"
}

clear_admin_offenses() {
  local admin_name="$1"
  if [ ! -f "$ADMIN_OFFENSES_FILE" ]; then
    print_status "No admin offenses file"
    return 0
  fi
  local tmp="${TMP_PREFIX}_clear_admin_offenses.json"
  cat "$ADMIN_OFFENSES_FILE" | jq --arg admin "$admin_name" 'del(.[$admin])' > "$tmp" && mv "$tmp" "$ADMIN_OFFENSES_FILE"
  print_success "Cleared offenses for $admin_name"
}

# --------------------------
# Safe modifications to list files (atomic + flock)
# --------------------------

# remove_from_list_file <player_name> <list_type>
remove_from_list_file() {
  local player_name="$1"
  local list_type="$2"
  local world_dir
  world_dir=$(dirname "$LOG_FILE" 2>/dev/null || echo ".")
  local list_file="$world_dir/${list_type}list.txt"

  if [ ! -f "$list_file" ]; then
    print_warning "List file not found: $list_file"
    return 1
  fi

  # safe remove with lock and atomic write
  local lockfile="${list_file}.lock"
  with_lock "$lockfile" bash -c '
    p="$0"; file="$1"; TMP_PREFIX="$2"
    tmp=$(mktemp "$(dirname "$file")/.tmp.XXXXXX")
    # eliminar coincidencia exacta case-insensitive
    grep -ivx -- "$p" "$file" > "$tmp" || true
    mv -f "$tmp" "$file"
    ' "$player_name" "$list_file" "$TMP_PREFIX"
  local rc=$?
  if [ $rc -eq 0 ]; then
    print_success "Removed $player_name from ${list_type}list.txt"
    return 0
  else
    print_warning "Could not remove $player_name from ${list_type}list.txt"
    return 1
  fi
}

# --------------------------
# Economy helpers (safe jq writes)
# --------------------------
initialize_economy() {
  if [ ! -f "$ECONOMY_FILE" ]; then
    echo '{"players": {}, "transactions": []}' > "$ECONOMY_FILE"
    print_success "Economy data file created"
  fi
  initialize_admin_offenses
  initialize_backup_dir
}

add_player_if_new() {
  local player_name="$1"
  if [ ! -f "$ECONOMY_FILE" ]; then
    initialize_economy
  fi
  local exists
  exists=$(cat "$ECONOMY_FILE" | jq --arg player "$player_name" '.players | has($player)')
  if [ "$exists" = "false" ]; then
    local tmp="${TMP_PREFIX}_add_player.json"
    cat "$ECONOMY_FILE" | jq --arg player "$player_name" '.players[$player] = {"tickets": 0, "last_login": 0, "last_welcome_time": 0, "last_help_time": 0, "purchases": []}' > "$tmp" && mv "$tmp" "$ECONOMY_FILE"
    print_success "Added new player: $player_name"
    give_first_time_bonus "$player_name"
    return 0
  fi
  return 1
}

give_first_time_bonus() {
  local player_name="$1"
  local current_time
  current_time=$(date +%s)
  local time_str
  time_str="$(date '+%Y-%m-%d %H:%M:%S')"
  local tmp="${TMP_PREFIX}_first_bonus.json"
  cat "$ECONOMY_FILE" | jq --arg player "$player_name" --argjson time "$current_time" '.players[$player].tickets = 1 | .players[$player].last_login = $time' | jq --arg player "$player_name" --arg time "$time_str" '.transactions += [{"player": $player, "type": "welcome_bonus", "tickets": 1, "time": $time}]' > "$tmp" && mv "$tmp" "$ECONOMY_FILE"
  print_success "Gave first-time bonus to $player_name"
}

grant_login_ticket() {
  local player_name="$1"
  local current_time
  current_time=$(date +%s)
  local time_str
  time_str="$(date '+%Y-%m-%d %H:%M:%S')"
  if [ ! -f "$ECONOMY_FILE" ]; then
    initialize_economy
  fi
  local last_login
  last_login=$(cat "$ECONOMY_FILE" | jq -r --arg player "$player_name" '.players[$player].last_login // 0')
  last_login=${last_login:-0}
  if [ "$last_login" -eq 0 ] || [ $((current_time - last_login)) -ge 3600 ]; then
    local current_tickets
    current_tickets=$(cat "$ECONOMY_FILE" | jq -r --arg player "$player_name" '.players[$player].tickets // 0')
    current_tickets=${current_tickets:-0}
    local new_tickets=$((current_tickets + 1))
    local tmp="${TMP_PREFIX}_login_ticket.json"
    cat "$ECONOMY_FILE" | jq --arg player "$player_name" --argjson tickets "$new_tickets" --argjson time "$current_time" '.players[$player].tickets = $tickets | .players[$player].last_login = $time' | jq --arg player "$player_name" --arg time "$time_str" '.transactions += [{"player": $player, "type": "login_bonus", "tickets": 1, "time": $time}]' > "$tmp" && mv "$tmp" "$ECONOMY_FILE"
    print_success "Granted 1 ticket to $player_name for logging in (Total: $new_tickets)"
    send_server_command "$player_name, you received 1 login ticket! You now have $new_tickets tickets."
  else
    local next_login=$((last_login + 3600))
    local time_left=$((next_login - current_time))
    print_warning "$player_name must wait $((time_left / 60)) minutes for next ticket"
  fi
}

remove_purchase_record() {
  local player_name="$1"
  local rank="$2"
  if [ ! -f "$ECONOMY_FILE" ]; then
    print_warning "Economy file not present"
    return 1
  fi
  local tmp="${TMP_PREFIX}_remove_purchase.json"
  cat "$ECONOMY_FILE" | jq --arg player "$player_name" --arg rank "$rank" 'if .players[$player] and (.players[$player].purchases|type == "array") then .players[$player].purchases |= map(select(. != $rank)) else . end' > "$tmp" && mv "$tmp" "$ECONOMY_FILE"
  print_success "Removed $rank purchase record for $player_name (if existed)"
}

is_player_in_list() {
  local player_name="$1"
  local list_type="$2"
  local world_dir
  world_dir=$(dirname "$LOG_FILE" 2>/dev/null || echo ".")
  local list_file="$world_dir/${list_type}list.txt"
  if [ -f "$list_file" ]; then
    if grep -iqx -- "$player_name" "$list_file"; then
      return 0
    fi
  fi
  return 1
}

# --------------------------
# Send command to server (screen)
# --------------------------
send_server_command() {
  local message="$1"
  if screen -S blockheads_server -X stuff "$message$(printf \\r)" 2>/dev/null; then
    print_success "Sent message to server: $message"
  else
    print_error "Could not send message to server. Is the server running and named 'blockheads_server'?"
  fi
}

# --------------------------
# Handle unauthorized attempts
# --------------------------
handle_unauthorized_command() {
  local player_name="$1"
  local command="$2"
  local target_player="$3"

  if is_player_in_list "$player_name" "admin"; then
    print_error "UNAUTHORIZED COMMAND: Admin $player_name attempted to use $command on $target_player"
    send_server_command "WARNING: Admin $player_name attempted unauthorized rank assignment!"

    if [ "$command" = "/admin" ]; then
      send_server_command "/unadmin $target_player"
      remove_from_list_file "$target_player" "admin"
      print_success "Revoked admin rank from $target_player (in-server + file)"
    elif [ "$command" = "/mod" ]; then
      send_server_command "/unmod $target_player"
      remove_from_list_file "$target_player" "mod"
      print_success "Revoked mod rank from $target_player (in-server + file)"
    fi

    # Crear backup post-revoke para que latest_backup refleje el estado sin el usuario
    create_list_backup "post_revoke"

    # Registrar ofensa
    record_admin_offense "$player_name"
    local offense_count
    offense_count=$(cat "$ADMIN_OFFENSES_FILE" | jq -r --arg admin "$player_name" '.[$admin]?.count // 0')

    if [ "$offense_count" -eq 1 ]; then
      send_server_command "$player_name, this is your first warning! Only the server console can assign ranks using !set_admin or !set_mod."
    elif [ "$offense_count" -ge 2 ]; then
      print_warning "SECOND OFFENSE: Demoting admin $player_name to mod."
      send_server_command "/unadmin $player_name"
      remove_from_list_file "$player_name" "admin"
      remove_purchase_record "$player_name" "admin"
      send_server_command "/mod $player_name"
      send_server_command "ALERT: Admin $player_name has been demoted to moderator for repeated unauthorized commands!"
      clear_admin_offenses "$player_name"
      create_list_backup "demotion_punishment"
    fi
  else
    print_warning "Non-admin $player_name attempted $command on $target_player"
    send_server_command "$player_name, you don't have permission to assign ranks."

    if [ "$command" = "/admin" ]; then
      send_server_command "/unadmin $target_player"
      remove_from_list_file "$target_player" "admin"
    elif [ "$command" = "/mod" ]; then
      send_server_command "/unmod $target_player"
      remove_from_list_file "$target_player" "mod"
    fi

    create_list_backup "post_revoke_nonadmin"
  fi
}

# --------------------------
# Message processing (economy etc.)
# --------------------------
process_message() {
  local player_name="$1"
  local message="$2"
  if [ ! -f "$ECONOMY_FILE" ]; then
    initialize_economy
  fi
  local player_tickets
  player_tickets=$(cat "$ECONOMY_FILE" | jq -r --arg player "$player_name" '.players[$player].tickets // 0')
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
        send_server_command "$player_name, you already have MOD rank."
      elif [ "$player_tickets" -ge 10 ]; then
        local new_tickets=$((player_tickets - 10))
        local tmp="${TMP_PREFIX}_buy_mod.json"
        cat "$ECONOMY_FILE" | jq --arg player "$player_name" --argjson tickets "$new_tickets" '.players[$player].tickets = $tickets' > "$tmp" && mv "$tmp" "$ECONOMY_FILE"
        add_purchase "$player_name" "mod"
        local time_str
        time_str="$(date '+%Y-%m-%d %H:%M:%S')"
        local tmp2="${TMP_PREFIX}_tx_mod.json"
        cat "$ECONOMY_FILE" | jq --arg player "$player_name" --arg time "$time_str" '.transactions += [{"player": $player, "type": "purchase", "item": "mod", "tickets": -10, "time": $time}]' > "$tmp2" && mv "$tmp2" "$ECONOMY_FILE"
        screen -S blockheads_server -X stuff "/mod $player_name$(printf \\r)"
        send_server_command "Congratulations $player_name! You have been promoted to MOD for 10 tickets. Remaining tickets: $new_tickets"
        create_list_backup "buy_mod"
      else
        send_server_command "$player_name, you need $((10 - player_tickets)) more tickets to buy MOD rank."
      fi
      ;;
    "!buy_admin")
      if is_player_in_list "$player_name" "admin"; then
        send_server_command "$player_name, you already have ADMIN rank."
      elif [ "$player_tickets" -ge 20 ]; then
        local new_tickets=$((player_tickets - 20))
        local tmp="${TMP_PREFIX}_buy_admin.json"
        cat "$ECONOMY_FILE" | jq --arg player "$player_name" --argjson tickets "$new_tickets" '.players[$player].tickets = $tickets' > "$tmp" && mv "$tmp" "$ECONOMY_FILE"
        add_purchase "$player_name" "admin"
        local time_str
        time_str="$(date '+%Y-%m-%d %H:%M:%S')"
        local tmp2="${TMP_PREFIX}_tx_admin.json"
        cat "$ECONOMY_FILE" | jq --arg player "$player_name" --arg time "$time_str" '.transactions += [{"player": $player, "type": "purchase", "item": "admin", "tickets": -20, "time": $time}]' > "$tmp2" && mv "$tmp2" "$ECONOMY_FILE"
        screen -S blockheads_server -X stuff "/admin $player_name$(printf \\r)"
        send_server_command "Congratulations $player_name! You have been promoted to ADMIN for 20 tickets. Remaining tickets: $new_tickets"
        create_list_backup "buy_admin"
      else
        send_server_command "$player_name, you need $((20 - player_tickets)) more tickets to buy ADMIN rank."
      fi
      ;;
    !(*))
      # simple fallback: no action
      ;;
  esac
}

# add_purchase simple wrapper
add_purchase() {
  local player="$1"; local item="$2"
  local tmp="${TMP_PREFIX}_purchase.json"
  cat "$ECONOMY_FILE" | jq --arg player "$player" --arg item "$item" '.players[$player].purchases += [$item]' > "$tmp" && mv "$tmp" "$ECONOMY_FILE"
}

# --------------------------
# Admin command processing from console pipe
# --------------------------
process_admin_command() {
  local command="$1"
  if [[ "$command" =~ ^!send_ticket\ ([a-zA-Z0-9_]+)\ ([0-9]+)$ ]]; then
    local player_name="${BASH_REMATCH[1]}"
    local tickets_to_add="${BASH_REMATCH[2]}"
    if [ ! -f "$ECONOMY_FILE" ]; then
      print_error "Economy system not initialized."
      return
    fi
    local current_tickets
    current_tickets=$(cat "$ECONOMY_FILE" | jq -r --arg player "$player_name" '.players[$player].tickets // 0')
    current_tickets=${current_tickets:-0}
    local new_tickets=$((current_tickets + tickets_to_add))
    local tmp="${TMP_PREFIX}_send_ticket.json"
    cat "$ECONOMY_FILE" | jq --arg player "$player_name" --argjson tickets "$new_tickets" '.players[$player].tickets = $tickets' > "$tmp" && mv "$tmp" "$ECONOMY_FILE"
    local time_str
    time_str="$(date '+%Y-%m-%d %H:%M:%S')"
    local tmp2="${TMP_PREFIX}_tx_send_ticket.json"
    cat "$ECONOMY_FILE" | jq --arg player "$player_name" --arg time "$time_str" --argjson amount "$tickets_to_add" '.transactions += [{"player": $player, "type": "admin_gift", "tickets": $amount, "time": $time}]' > "$tmp2" && mv "$tmp2" "$ECONOMY_FILE"
    print_success "Added $tickets_to_add tickets to $player_name (Total: $new_tickets)"
    send_server_command "$player_name received $tickets_to_add tickets from admin! Total: $new_tickets"
  elif [[ "$command" =~ ^!set_mod\ ([a-zA-Z0-9_]+)$ ]]; then
    local player_name="${BASH_REMATCH[1]}"
    screen -S blockheads_server -X stuff "/mod $player_name$(printf \\r)"
    send_server_command "$player_name has been set as MOD by server console!"
    create_list_backup "set_mod"
  elif [[ "$command" =~ ^!set_admin\ ([a-zA-Z0-9_]+)$ ]]; then
    local player_name="${BASH_REMATCH[1]}"
    screen -S blockheads_server -X stuff "/admin $player_name$(printf \\r)"
    send_server_command "$player_name has been set as ADMIN by server console!"
    create_list_backup "set_admin"
  else
    print_error "Unknown admin command: $command"
  fi
}

# --------------------------
# Log monitoring & main loop
# --------------------------
server_sent_welcome_recently() {
  local player_name="$1"
  [ -z "$LOG_FILE" ] || [ ! -f "$LOG_FILE" ] && return 1
  local player_lc
  player_lc=$(echo "$player_name" | tr '[:upper:]' '[:lower:]')
  local matches
  matches=$(tail -n "$TAIL_LINES" "$LOG_FILE" 2>/dev/null | grep -i "server:.*welcome.*$player_lc" | head -1 || true)
  if [ -n "$matches" ]; then
    return 0
  fi
  return 1
}

filter_server_log() {
  while read -r line; do
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
  print_status "Bot commands: !tickets, !buy_mod, !buy_admin, !economy_help"
  print_header "IMPORTANT: Admin commands must be typed in THIS terminal, NOT in the game chat!"
  print_header "READY FOR COMMANDS"

  local admin_pipe="/tmp/blockheads_admin_pipe"
  rm -f "$admin_pipe" || true
  mkfifo "$admin_pipe" || true

  # admin pipe reader
  ( while read -r admin_command < "$admin_pipe"; do
      print_status "Processing admin command: $admin_command"
      process_admin_command "$admin_command"
    done ) &

  # forward stdin into admin pipe
  ( while read -r admin_command; do
      echo "$admin_command" > "$admin_pipe"
    done ) &

  declare -A welcome_shown

  tail -n 0 -F "$log_file" | filter_server_log | while read -r line; do
    # Conexiones
    if [[ "$line" =~ Player\ Connected\ ([a-zA-Z0-9_]+)\ \|\ ([0-9a-fA-F.:]+) ]]; then
      local player_name="${BASH_REMATCH[1]}"
      local player_ip="${BASH_REMATCH[2]}"
      [ "$player_name" == "SERVER" ] && continue
      print_success "Player connected: $player_name (IP: $player_ip)"

      ts_str=$(echo "$line" | awk '{print $1" "$2}')
      ts_no_ms=${ts_str%.*}
      conn_epoch=$(date -d "$ts_no_ms" +%s 2>/dev/null || echo 0)

      local is_new_player="false"
      add_player_if_new "$player_name" && is_new_player="true"
      sleep 3
      if ! server_sent_welcome_recently "$player_name" "$conn_epoch"; then
        show_welcome_message="$player_name"
        # send welcome message
        if [ "$is_new_player" = "true" ]; then
          send_server_command "Hello $player_name! Welcome to the server. Type !tickets to check your ticket balance."
        else
          send_server_command "Welcome back $player_name! Type !economy_help to see economy commands."
        fi
      fi

      [ "$is_new_player" = "false" ] && grant_login_ticket "$player_name"
      continue
    fi

    # Unauthorized admin/mod attempts:
    if [[ "$line" =~ ([a-zA-Z0-9_]+):\ \/(admin|mod)\ ([a-zA-Z0-9_]+) ]]; then
      local command_user="${BASH_REMATCH[1]}"
      local command_type="${BASH_REMATCH[2]}"
      local target_player="${BASH_REMATCH[3]}"
      if [ "$command_user" != "SERVER" ]; then
        handle_unauthorized_command "$command_user" "/$command_type" "$target_player"
      fi
      continue
    fi

    # Disconnects
    if [[ "$line" =~ Player\ Disconnected\ ([a-zA-Z0-9_]+) ]]; then
      local player_name="${BASH_REMATCH[1]}"
      [ "$player_name" == "SERVER" ] && continue
      print_warning "Player disconnected: $player_name"
      continue
    fi

    # Chat lines
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

  wait
  rm -f "$admin_pipe" || true
}

# --------------------------
# Entrypoint
# --------------------------
if [ $# -ne 1 ]; then
  print_error "Usage: $0 <server_log_file>"
  exit 1
fi

initialize_economy
initialize_backup_dir
save_latest_adminlist_checksum

monitor_log "$1"
