#!/bin/bash
# secure_blockheads_bot.sh
# Script completo y corregido para monitorear console.log y manejar ranks de forma segura.
# Requisitos: jq, screen, awk, flock, tail, date

set -euo pipefail

# -------------------------
# Colores para salida
# -------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
NC='\033[0m'

print_status()  { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
print_header()  {
    echo -e "${PURPLE}================================================================"
    echo -e "$1"
    echo -e "===============================================================${NC}"
}

# -------------------------
# CONFIG: Ajusta esto
# -------------------------
# Cambia ID_DEL_MUNDO por el id de tu mundo. Si tu ruta real usa "AplicationSupport" (sin espacio), cámbialo aquí.
WORLD_DIR="$HOME/Library/Application Support/TheBlockheads/saves/ID_DEL_MUNDO/aqui"
# Si quieres una ruta absoluta sin $HOME, por ejemplo:
# WORLD_DIR="/home/MI USUARIO/Library/AplicationSupport/TheBlockheads/saves/id_del_mundo/aqui"

LOG_FILE="$WORLD_DIR/console.log"
ADMIN_LIST_FILE="$WORLD_DIR/adminlist.txt"
MOD_LIST_FILE="$WORLD_DIR/modlist.txt"
WHITELIST_FILE="$WORLD_DIR/whitelist.txt"
BLACKLIST_FILE="$WORLD_DIR/blacklist.txt"

ECONOMY_FILE="$WORLD_DIR/economy_data.json"
ADMIN_OFFENSES_FILE="$WORLD_DIR/admin_offenses.json"
SECURITY_LOG="$WORLD_DIR/security_attempts.log"

TAIL_LINES=500

# Comandos prohibidos para admins (comparación case-insensitive)
FORBIDDEN_CMDS=("CLEAR-BLACKLIST" "CLEAR-WHITELIST" "CLEAR-MODLIST" "CLEAR-ADMINLIST" "UNADMIN")

# -------------------------
# Utilidades de locking
# -------------------------
# Usaremos un lockfile general para serializar escrituras a archivos críticos.
LOCK_DIR="/tmp/secure_blockheads_locks"
mkdir -p "$LOCK_DIR"

with_lock() {
    # Uso: with_lock <name> <command...>
    local lockname="$1"; shift
    local lockfile="$LOCK_DIR/${lockname}.lock"
    # flock con timeout 5 seg
    (
        flock -w 5 200 || { print_error "No se pudo obtener lock $lockname"; exit 1; }
        "$@"
    ) 200> "$lockfile"
}

# -------------------------
# Inicialización
# -------------------------
initialize_files() {
    mkdir -p "$WORLD_DIR"
    touch "$LOG_FILE" "$ADMIN_LIST_FILE" "$MOD_LIST_FILE" "$WHITELIST_FILE" "$BLACKLIST_FILE" "$SECURITY_LOG"
    if [ ! -f "$ECONOMY_FILE" ]; then
        echo '{"players": {}, "transactions": []}' > "$ECONOMY_FILE"
        print_success "Economy data file created: $ECONOMY_FILE"
    fi
    if [ ! -f "$ADMIN_OFFENSES_FILE" ]; then
        echo '{}' > "$ADMIN_OFFENSES_FILE"
        print_success "Admin offenses tracking file created: $ADMIN_OFFENSES_FILE"
    fi
}

# -------------------------
# Logging de seguridad (JSON-Lines)
# -------------------------
log_security_event() {
    local actor="$1"
    local command="$2"
    local target="$3"
    local result="$4"
    local details="${5:-}"
    local ts
    ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    printf '%s\n' "{\"timestamp\":\"$ts\",\"actor\":\"$actor\",\"command\":\"$command\",\"target\":\"$target\",\"result\":\"$result\",\"details\":\"$details\"}" >> "$SECURITY_LOG"
}

# -------------------------
# Admin offenses: record/clear/consulta
# Todas las escrituras usan with_lock "admin_offenses"
# -------------------------
record_admin_offense() {
    local admin_name="$1"
    local now
    now=$(date +%s)

    with_lock "admin_offenses" bash -c "
        data=\$(cat \"$ADMIN_OFFENSES_FILE\" 2>/dev/null || echo '{}')
        count=\$(echo \"\$data\" | jq -r --arg a \"$admin_name\" '.[$a]?.count // 0')
        last=\$(echo \"\$data\" | jq -r --arg a \"$admin_name\" '.[$a]?.last_offense // 0')
        if [ \"\$last\" -eq 0 ] || [ \$(( $now - last )) -gt 300 ]; then
            count=0
        fi
        count=\$((count + 1))
        new=\$(echo \"\$data\" | jq --arg a \"$admin_name\" --argjson c \$count --argjson t $now '.[$a] = {\"count\": \$c, \"last_offense\": \$t}')
        echo \"\$new\" > \"$ADMIN_OFFENSES_FILE\"
        echo \$count
    " 
    # with_lock prints count; capture it
    # Note: the above with_lock will output the count to stdout of this function
}

clear_admin_offenses() {
    local admin_name="$1"
    with_lock "admin_offenses" bash -c "
        data=\$(cat \"$ADMIN_OFFENSES_FILE\" 2>/dev/null || echo '{}')
        new=\$(echo \"\$data\" | jq --arg a \"$admin_name\" 'del(.[$a])')
        echo \"\$new\" > \"$ADMIN_OFFENSES_FILE\"
    "
    print_success "Cleared offenses for $admin_name"
}

get_admin_offense_count() {
    local admin_name="$1"
    jq -r --arg a "$admin_name" '.[$a]?.count // 0' "$ADMIN_OFFENSES_FILE" 2>/dev/null || echo 0
}

# -------------------------
# Helpers: case-insensitive check in list files
# -------------------------
is_player_in_list() {
    local player_name="$1"
    local list_file="$2"
    local lower
    lower=$(echo "$player_name" | tr '[:upper:]' '[:lower:]')
    if [ ! -f "$list_file" ]; then
        return 1
    fi
    if awk -v name="$lower" 'BEGIN{found=0} { if(tolower($0)==name) found=1 } END{ exit !found }' "$list_file"; then
        return 0
    fi
    return 1
}

# -------------------------
# Safe add/remove with flock and validations
# -------------------------
safe_add_to_list_file() {
    local player_name="$1"
    local list_file="$2"
    local lower
    lower=$(echo "$player_name" | tr '[:upper:]' '[:lower:]')

    with_lock "$(basename "$list_file")" bash -c "
        mkdir -p \"$(dirname "$list_file")\"
        touch \"$list_file\"
        if awk -v name=\"$lower\" 'BEGIN{found=0} { if(tolower(\$0)==name) found=1 } END{ exit !found }' \"$list_file\"; then
            echo 'ALREADY_PRESENT'
            exit 0
        fi
        cp \"$list_file\" \"${list_file}.bak\"
        printf '%s\n' \"$lower\" >> \"${list_file}.bak\"
        orig=\$(wc -l < \"$list_file\" 2>/dev/null || echo 0)
        new=\$(wc -l < \"${list_file}.bak\" 2>/dev/null || echo 0)
        if [ \"\$new\" -lt \"\$orig\" ]; then
            echo 'VALIDATION_FAIL'
            mv \"${list_file}.bak\" \"$list_file\" 2>/dev/null || true
            exit 1
        fi
        mv \"${list_file}.bak\" \"$list_file\"
        echo 'OK'
    "
}

safe_remove_from_list_file() {
    local player_name="$1"
    local list_file="$2"
    local lower
    lower=$(echo "$player_name" | tr '[:upper:]' '[:lower:]')

    with_lock "$(basename "$list_file")" bash -c "
        if [ ! -f \"$list_file\" ]; then
            echo 'NO_FILE'
            exit 0
        fi
        cp \"$list_file\" \"${list_file}.bak\"
        awk -v name=\"$lower\" 'tolower(\$0) != name' \"$list_file\" > \"${list_file}.tmp\"
        if awk -v name=\"$lower\" 'BEGIN{found=0} { if(tolower(\$0)==name) found=1 } END{ exit found }' \"${list_file}.tmp\"; then
            mv \"${list_file}.bak\" \"$list_file\"
            echo 'REMOVE_FAIL'
            exit 1
        fi
        mv \"${list_file}.tmp\" \"$list_file\"
        rm -f \"${list_file}.bak\"
        echo 'OK'
    "
}

# -------------------------
# Send messages to server (usa screen como antes)
# -------------------------
send_server_command() {
    local message="$1"
    if screen -S blockheads_server -X stuff "$message$(printf \\r)" 2>/dev/null; then
        print_success "Sent message to server: $message"
    else
        print_error "Could not send message to server. Is the server screen named 'blockheads_server' running?"
    fi
}

send_direct_message() {
    local player="$1"
    local msg="$2"
    send_server_command "$player, $msg"
}

# -------------------------
# Forbidden command check (case-insensitive)
# -------------------------
is_forbidden_for_admin() {
    local cmd="$1"
    local uc
    uc=$(echo "$cmd" | tr '[:lower:]' '[:upper:]')
    for f in "${FORBIDDEN_CMDS[@]}"; do
        if [ "$uc" = "$f" ]; then
            return 0
        fi
    done
    return 1
}

# -------------------------
# Manejo de intentos prohibidos
# -------------------------
handle_forbidden_command_attempt() {
    local actor="$1"
    local command="$2"
    local target="$3"
    print_error "FORBIDDEN ATTEMPT: $actor intentó $command ${target:+sobre $target}"
    send_direct_message "$actor" "Intento prohibido: no puedes ejecutar '$command' desde el chat. Esta acción está registrada."

    log_security_event "$actor" "$command" "$target" "blocked" "Prohibited command attempted via chat"

    local count
    count=$(record_admin_offense "$actor")
    # record_admin_offense echoes the new count; capture it:
    # If with_lock printed to stdout earlier, it's returned above. If function printed nothing, count may be empty.
    # Guard:
    count=${count:-0}

    if [ "$count" -ge 3 ]; then
        send_server_command "/unadmin $actor"
        safe_remove_from_list_file "$actor" "$ADMIN_LIST_FILE" >/dev/null || true
        send_direct_message "$actor" "Has excedido el límite de advertencias. Se te ha removido el rango de ADMIN."
        log_security_event "$actor" "UNADMIN (auto)" "$actor" "executed" "Auto-unadmin after 3 offenses"
        clear_admin_offenses "$actor"
    else
        send_direct_message "$actor" "Advertencia #$count: No intentes ejecutar comandos administrativos desde el chat."
    fi
}

# -------------------------
# Manejo de intento de cambio de rango (/admin /mod) vía chat
# -------------------------
handle_rank_change_attempt() {
    local actor="$1"
    local cmd="$2"   # admin | mod
    local target="$3"

    local uc_cmd
    uc_cmd=$(echo "$cmd" | tr '[:lower:]' '[:upper:]')

    # Si el comando está en la lista prohibida -> tratarlo como intento inválido
    if is_forbidden_for_admin "$uc_cmd"; then
        handle_forbidden_command_attempt "$actor" "$uc_cmd" "$target"
        return
    fi

    # Si actor es admin: no puede desde chat (lo bloqueamos), pero damos mensajes más informativos
    if is_player_in_list "$actor" "$ADMIN_LIST_FILE"; then
        # Si target ya tiene rango (mod/admin) -> rechazar y NO modificar listas
        if is_player_in_list "$target" "$ADMIN_LIST_FILE" || is_player_in_list "$target" "$MOD_LIST_FILE"; then
            send_direct_message "$actor" "Operación rechazada: $target ya tiene rango de mod/admin. Ninguna lista fue modificada."
            log_security_event "$actor" "/$uc_cmd" "$target" "rejected" "Target already had rank"
            local cnt
            cnt=$(record_admin_offense "$actor")
            cnt=${cnt:-0}
            if [ "$cnt" -ge 3 ]; then
                send_server_command "/unadmin $actor"
                safe_remove_from_list_file "$actor" "$ADMIN_LIST_FILE" >/dev/null || true
                send_direct_message "$actor" "Has excedido el límite de advertencias. Se te ha removido el rango de ADMIN."
                log_security_event "$actor" "UNADMIN (auto)" "$actor" "executed" "Auto-unadmin after 3 offenses"
                clear_admin_offenses "$actor"
            else
                send_direct_message "$actor" "Advertencia #$cnt: No uses comandos de asignación de rangos desde el chat."
            fi
            return
        else
            # Target no tiene rango, pero aun así bloquear asignaciones desde chat
            send_direct_message "$actor" "Operación inválida: no puedes asignar rangos desde el chat. Usa la consola."
            log_security_event "$actor" "/$uc_cmd" "$target" "blocked" "Admin attempted rank assignment via chat (target had no rank)"
            local cnt
            cnt=$(record_admin_offense "$actor")
            cnt=${cnt:-0}
            if [ "$cnt" -ge 3 ]; then
                send_server_command "/unadmin $actor"
                safe_remove_from_list_file "$actor" "$ADMIN_LIST_FILE" >/dev/null || true
                send_direct_message "$actor" "Has excedido el límite de advertencias. Se te ha removido el rango de ADMIN."
                log_security_event "$actor" "UNADMIN (auto)" "$actor" "executed" "Auto-unadmin after 3 offenses"
                clear_admin_offenses "$actor"
            else
                send_direct_message "$actor" "Advertencia #$cnt: No uses comandos de asignación de rangos desde el chat."
            fi
            return
        fi
    else
        # No es admin -> bloquear y loggear
        send_direct_message "$actor" "No tienes permisos para asignar rangos. Acción bloqueada."
        log_security_event "$actor" "/$uc_cmd" "$target" "blocked" "Non-admin attempted rank change"
        return
    fi
}

# -------------------------
# Process admin console commands (desde admin_pipe)
# -------------------------
process_admin_command() {
    local cmd="$1"
    if [[ "$cmd" =~ ^!send_ticket[[:space:]]+([a-zA-Z0-9_]+)[[:space:]]+([0-9]+)$ ]]; then
        local player="${BASH_REMATCH[1]}"
        local amount="${BASH_REMATCH[2]}"
        # actualizar economy file de forma segura
        with_lock "economy" bash -c "
            data=\$(cat \"$ECONOMY_FILE\")
            exists=\$(echo \"\$data\" | jq --arg p \"$player\" '.players | has(\$p)')
            if [ \"\$exists\" = \"false\" ]; then
                echo 'PLAYER_NOT_FOUND'
                exit 0
            fi
            cur=\$(echo \"\$data\" | jq -r --arg p \"$player\" '.players[$p].tickets // 0')
            new=\$((cur + $amount))
            data=\$(echo \"\$data\" | jq --arg p \"$player\" --argjson t \$new '.players[$p].tickets = \$t')
            time=\"$(date '+%Y-%m-%d %H:%M:%S')\"
            data=\$(echo \"\$data\" | jq --arg p \"$player\" --arg time \"\$time\" --argjson amt $amount '.transactions += [{\"player\":$p,\"type\":\"admin_gift\",\"tickets\":$amt,\"time\":$time}]' 2>/dev/null || echo \"\$data\")
            echo \"\$data\" > \"$ECONOMY_FILE\"
            echo \"OK:\$new\"
        "
        # Notificamos al servidor (sin confirmar la salida aquí para simplicidad)
        send_server_command "$player received $amount tickets from admin!"
    elif [[ "$cmd" =~ ^!set_mod[[:space:]]+([a-zA-Z0-9_]+)$ ]]; then
        local player="${BASH_REMATCH[1]}"
        print_status "Console: Setting $player as MOD"
        send_server_command "/mod $player"
        send_server_command "$player has been set as MOD by server console!"
    elif [[ "$cmd" =~ ^!set_admin[[:space:]]+([a-zA-Z0-9_]+)$ ]]; then
        local player="${BASH_REMATCH[1]}"
        print_status "Console: Setting $player as ADMIN"
        send_server_command "/admin $player"
        send_server_command "$player has been set as ADMIN by server console!"
    else
        print_error "Unknown admin command: $cmd"
    fi
}

# -------------------------
# Mensajería y economía (funciones mínimas necesarias)
# -------------------------
add_player_if_new() {
    local player="$1"
    with_lock "economy" bash -c "
        data=\$(cat \"$ECONOMY_FILE\")
        has=\$(echo \"\$data\" | jq --arg p \"$player\" '.players | has(\$p)')
        if [ \"\$has\" = \"false\" ]; then
            data=\$(echo \"\$data\" | jq --arg p \"$player\" '.players[$p] = {\"tickets\":0,\"last_login\":0,\"last_welcome_time\":0,\"last_help_time\":0,\"purchases\":[]}') 
            echo \"\$data\" > \"$ECONOMY_FILE\"
            echo 'NEW'
        else
            echo 'EXISTS'
        fi
    "
}

give_first_time_bonus() {
    local player="$1"
    with_lock "economy" bash -c "
        data=\$(cat \"$ECONOMY_FILE\")
        time=$(date +%s)
        timestr=\"$(date '+%Y-%m-%d %H:%M:%S')\"
        data=\$(echo \"\$data\" | jq --arg p \"$player\" '.players[$p].tickets = 1')
        data=\$(echo \"\$data\" | jq --arg p \"$player\" --argjson t $time '.players[$p].last_login = $t')
        data=\$(echo \"\$data\" | jq --arg p \"$player\" --arg time \"\$timestr\" '.transactions += [{\"player\": $p, \"type\": \"welcome_bonus\", \"tickets\": 1, \"time\": \$time}]')
        echo \"\$data\" > \"$ECONOMY_FILE\"
    "
    send_server_command "$player received a welcome bonus!"
}

grant_login_ticket() {
    local player="$1"
    with_lock "economy" bash -c "
        data=\$(cat \"$ECONOMY_FILE\")
        last=\$(echo \"\$data\" | jq -r --arg p \"$player\" '.players[$p].last_login // 0')
        now=$(date +%s)
        if [ \"\$last\" -eq 0 ] || [ \$((now - last)) -ge 3600 ]; then
            cur=\$(echo \"\$data\" | jq -r --arg p \"$player\" '.players[$p].tickets // 0')
            new=\$((cur + 1))
            data=\$(echo \"\$data\" | jq --arg p \"$player\" --argjson t \$new '.players[$p].tickets = \$t')
            data=\$(echo \"\$data\" | jq --arg p \"$player\" --argjson l $now '.players[$p].last_login = $l')
            timestr=\"$(date '+%Y-%m-%d %H:%M:%S')\"
            data=\$(echo \"\$data\" | jq --arg p \"$player\" --arg time \"\$timestr\" '.transactions += [{\"player\": $p, \"type\": \"login_bonus\", \"tickets\": 1, \"time\": \$time}]')
            echo \"\$data\" > \"$ECONOMY_FILE\"
            echo \"GRANTED:\$new\"
        else
            echo \"COOLDOWN\"
        fi
    "
}

# -------------------------
# Procesamiento de mensajes normales (economy, compra de ranks, etc.)
# -------------------------
process_message() {
    local player="$1"
    local message="$2"
    local lowered
    lowered=$(echo "$message" | tr '[:upper:]' '[:lower:]')

    case "$lowered" in
        "hi"|"hello"|"hola")
            send_server_command "Hello $player! Welcome to the server. Type !tickets to check your ticket balance."
            ;;
        "!tickets")
            # Leer tickets
            local tickets
            tickets=$(jq -r --arg p "$player" '.players[$p].tickets // 0' "$ECONOMY_FILE" 2>/dev/null || echo 0)
            send_server_command "$player, you have $tickets tickets."
            ;;
        "!buy_mod")
            # Simplificado: comprobar y cobrar 10 tickets
            local player_tickets
            player_tickets=$(jq -r --arg p "$player" '.players[$p].tickets // 0' "$ECONOMY_FILE" 2>/dev/null || echo 0)
            if [ "$player_tickets" -ge 10 ]; then
                with_lock "economy" bash -c "
                    data=\$(cat \"$ECONOMY_FILE\")
                    cur=\$(echo \"\$data\" | jq -r --arg p \"$player\" '.players[$p].tickets // 0')
                    new=\$((cur - 10))
                    data=\$(echo \"\$data\" | jq --arg p \"$player\" --argjson t \$new '.players[$p].tickets = \$t')
                    data=\$(echo \"\$data\" | jq --arg p \"$player\" '.players[$p].purchases += [\"mod\"]')
                    timestr=\"$(date '+%Y-%m-%d %H:%M:%S')\"
                    data=\$(echo \"\$data\" | jq --arg p \"$player\" --arg time \"\$timestr\" '.transactions += [{\"player\": $p, \"type\": \"purchase\", \"item\": \"mod\", \"tickets\": -10, \"time\": \$time}]')
                    echo \"\$data\" > \"$ECONOMY_FILE\"
                "
                send_server_command "/mod $player"
                send_server_command "Congratulations $player! You have been promoted to MOD for 10 tickets."
            else
                send_server_command "$player, you need $((10 - player_tickets)) more tickets to buy MOD rank."
            fi
            ;;
        "!buy_admin")
            local player_tickets
            player_tickets=$(jq -r --arg p "$player" '.players[$p].tickets // 0' "$ECONOMY_FILE" 2>/dev/null || echo 0)
            if [ "$player_tickets" -ge 20 ]; then
                with_lock "economy" bash -c "
                    data=\$(cat \"$ECONOMY_FILE\")
                    cur=\$(echo \"\$data\" | jq -r --arg p \"$player\" '.players[$p].tickets // 0')
                    new=\$((cur - 20))
                    data=\$(echo \"\$data\" | jq --arg p \"$player\" --argjson t \$new '.players[$p].tickets = \$t')
                    data=\$(echo \"\$data\" | jq --arg p \"$player\" '.players[$p].purchases += [\"admin\"]')
                    timestr=\"$(date '+%Y-%m-%d %H:%M:%S')\"
                    data=\$(echo \"\$data\" | jq --arg p \"$player\" --arg time \"\$timestr\" '.transactions += [{\"player\": $p, \"type\": \"purchase\", \"item\": \"admin\", \"tickets\": -20, \"time\": \$time}]')
                    echo \"\$data\" > \"$ECONOMY_FILE\"
                "
                send_server_command "/admin $player"
                send_server_command "Congratulations $player! You have been promoted to ADMIN for 20 tickets."
            else
                send_server_command "$player, you need $((20 - player_tickets)) more tickets to buy ADMIN rank."
            fi
            ;;
        "!economy_help")
            send_server_command "Economy commands: !tickets, !buy_mod (10), !buy_admin (20), !give_mod, !give_admin"
            ;;
        *)
            # mensajes no manejados
            ;;
    esac
}

# -------------------------
# Filtrado básico de log (puedes ajustar)
# -------------------------
filter_server_log() {
    while read -r line; do
        # Omitir líneas superfluous
        if [[ "$line" == *"Server closed"* ]] || [[ "$line" == *"Starting server"* ]]; then
            continue
        fi
        echo "$line"
    done
}

# -------------------------
# Monitor principal
# -------------------------
monitor_log() {
    print_header "STARTING SECURE ECONOMY BOT"
    print_status "WORLD_DIR: $WORLD_DIR"
    print_status "LOG_FILE: $LOG_FILE"
    print_status "Admin lists: $ADMIN_LIST_FILE, $MOD_LIST_FILE"
    print_header "READY"

    # tubería de admin console
    local admin_pipe="/tmp/blockheads_admin_pipe"
    rm -f "$admin_pipe"
    mkfifo "$admin_pipe"

    # lee comandos de consola en background
    while read -r admin_cmd < "$admin_pipe"; do
        process_admin_command "$admin_cmd"
    done &

    # forward stdin a la pipe
    while read -r admin_cmd; do
        echo "$admin_cmd" > "$admin_pipe"
    done &

    # lee y procesa console.log
    tail -n 0 -F "$LOG_FILE" | filter_server_log | while read -r line; do
        # Detecta conexión: "Player Connected NAME | IP"
        if [[ "$line" =~ Player\ Connected\ ([a-zA-Z0-9_]+)\ \|\ ([0-9a-fA-F.:]+) ]]; then
            local player="${BASH_REMATCH[1]}"
            add_player_if_new "$player" >/dev/null || true
            sleep 1
            send_server_command "Welcome $player!"
            # concede ticket si corresponde (simplificado)
            grant_login_ticket "$player" >/dev/null || true
            continue
        fi

        # Detecta comandos en chat: "User: /command target"
        if [[ "$line" =~ ^([a-zA-Z0-9_]+):\ /(.*)$ ]]; then
            local user="${BASH_REMATCH[1]}"
            local rest="${BASH_REMATCH[2]}"
            # separa token y target
            local token
            token=$(echo "$rest" | awk '{print $1}')
            local token_uc
            token_uc=$(echo "$token" | tr '[:lower:]' '[:upper:]')
            local target
            target=$(echo "$rest" | awk '{print $2}' || true)

            # si es /admin o /mod o comandos forbiddens
            if [[ "$token_uc" == "ADMIN" || "$token_uc" == "MOD" ]]; then
                handle_rank_change_attempt "$user" "$token_uc" "$target"
                continue
            fi

            # Si coincide con CLEAR-* o UNADMIN (intento de comando prohibido)
            if is_forbidden_for_admin "$token_uc"; then
                if is_player_in_list "$user" "$ADMIN_LIST_FILE"; then
                    handle_forbidden_command_attempt "$user" "$token_uc" "$target"
                else
                    send_direct_message "$user" "No tienes permisos para ejecutar '$token_uc'. Acción bloqueada."
                    log_security_event "$user" "$token_uc" "$target" "blocked" "Non-admin attempted forbidden command"
                fi
                continue
            fi
        fi

        # Detecta chat general "User: message"
        if [[ "$line" =~ ^([a-zA-Z0-9_]+):\ (.+)$ ]]; then
            local user="${BASH_REMATCH[1]}"
            local msg="${BASH_REMATCH[2]}"
            add_player_if_new "$user" >/dev/null || true
            process_message "$user" "$msg"
            continue
        fi

        # Detecta desconexión
        if [[ "$line" =~ Player\ Disconnected\ ([a-zA-Z0-9_]+) ]]; then
            local player="${BASH_REMATCH[1]}"
            print_status "Player disconnected: $player"
            continue
        fi

    done

    rm -f "$admin_pipe"
}

# -------------------------
# ENTRY
# -------------------------
if [ $# -eq 0 ]; then
    initialize_files
    monitor_log
else
    echo "Usage: $0"
    echo "Edit WORLD_DIR at top of script to point to your world folder, then run without args."
    exit 1
fi
