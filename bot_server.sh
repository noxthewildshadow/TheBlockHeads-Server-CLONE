#!/usr/bin/env bash
# bot_server.sh - Bot robusto para monitorear logs de The Blockheads y manejar economía/IP-ranks
# Uso: ./bot_server.sh /ruta/al/console.log
# Requisitos: jq, screen, sha256sum o shasum

# Colores
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

ECONOMY_FILE="economy_data.json"
IP_RANKS_FILE="ip_ranks.json"
LOG_FILE=""
TAIL_LINES=500

# Tiempo máximo de espera para que aparezca el log (segundos). 0 = esperar indefinidamente.
LOG_WAIT_TIMEOUT=120

# -------------------------
# Utilidades
# -------------------------
normalize_ip() { echo -n "$1" | tr -d '[:space:]'; }

ip_hash() {
    local ip_norm
    ip_norm="$(normalize_ip "$1")"
    if command -v sha256sum >/dev/null 2>&1; then
        echo -n "$ip_norm" | sha256sum | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        echo -n "$ip_norm" | shasum -a 256 | awk '{print $1}'
    else
        echo -n "$ip_norm"
    fi
}

# -------------------------
# Inicialización
# -------------------------
initialize_files() {
    [ ! -f "$ECONOMY_FILE" ] && echo '{"players": {}, "transactions": []}' > "$ECONOMY_FILE"
    [ ! -f "$IP_RANKS_FILE" ] && echo '{"admins": {}, "mods": {}}' > "$IP_RANKS_FILE"
}

get_stored_value_for_player() {
    local player="$1"; local rank="$2"
    cat "$IP_RANKS_FILE" 2>/dev/null | jq -r --arg p "$player" --arg r "$rank" '.[$r][$p] // ""'
}

is_sha256_hex() { [[ "$1" =~ ^[0-9a-f]{64}$ ]]; }

stored_matches_current_ip() {
    local stored="$1"; local curip="$2"
    [ -z "$stored" ] && return 1
    if is_sha256_hex "$stored"; then
        [ "$(ip_hash "$curip")" = "$stored" ] && return 0 || return 1
    else
        [ "$(normalize_ip "$stored")" = "$(normalize_ip "$curip")" ] && return 0 || return 1
    fi
}

update_ip_for_rank() {
    local player="$1"; local player_ip="$2"; local rank_type="$3"
    [ "$rank_type" != "admins" ] && [ "$rank_type" != "mods" ] && return 1
    local prev; prev="$(get_stored_value_for_player "$player" "$rank_type")"
    local newval
    if is_sha256_hex "$prev"; then newval="$(ip_hash "$player_ip")"
    else newval="$(normalize_ip "$player_ip")"; fi
    local tmp; tmp="$(mktemp)"
    jq --arg p "$player" --arg v "$newval" --arg r "$rank_type" '.[$r][$p]=$v' "$IP_RANKS_FILE" > "$tmp" && mv "$tmp" "$IP_RANKS_FILE"
    echo -e "${GREEN}IP registrada para $player en $rank_type -> $newval${NC}"
}

send_server_command() {
    local message="$1"
    if screen -S blockheads_server -X stuff "$message$(printf \\r)" 2>/dev/null; then
        echo -e "${GREEN}Sent message to server: $message${NC}"
    else
        echo -e "${YELLOW}No pude enviar al server: $message (¿screen 'blockheads_server' corriendo?)${NC}"
    fi
}

warn_player_for_ip_mismatch() {
    local player="$1"; local player_ip="$2"
    local key="/tmp/bh_warn_${player}"
    local count=0
    [ -f "$key" ] && count="$(cat "$key")"
    count=$((count+1)); echo "$count" > "$key"
    send_server_command "say SECURITY WARNING: $player connected from unexpected IP ($player_ip). (Warn #$count)"
    echo -e "${YELLOW}Advertencia #$count para $player por IP inesperada${NC}"
    if [ "$count" -ge 2 ]; then
        send_server_command "/kick $player"
        rm -f "$key"
        echo -e "${RED}Jugador $player pateado por segunda advertencia${NC}"
    fi
}

# -------------------------
# Chequeos de seguridad
# -------------------------
check_username_ip_security() {
    local player="$1"; local player_ip="$2"
    local admin_val; admin_val="$(get_stored_value_for_player "$player" "admins")"
    if [ -n "$admin_val" ]; then
        if ! stored_matches_current_ip "$admin_val" "$player_ip"; then
            echo -e "${RED}SECURITY ALERT: $player is using a registered ADMIN username from a different IP${NC}"
            warn_player_for_ip_mismatch "$player" "$player_ip"
            return 1
        fi
        return 0
    fi
    local mod_val; mod_val="$(get_stored_value_for_player "$player" "mods")"
    if [ -n "$mod_val" ]; then
        if ! stored_matches_current_ip "$mod_val" "$player_ip"; then
            echo -e "${YELLOW}SECURITY WARNING: $player is using a registered MOD username from a different IP${NC}"
            warn_player_for_ip_mismatch "$player" "$player_ip"
            return 1
        fi
    fi
    return 0
}

check_ip_rank_security() {
    local player="$1"; local player_ip="$2"
    local ipr; ipr="$(cat "$IP_RANKS_FILE" 2>/dev/null || echo '{"admins": {}, "mods": {}}')"
    local a; a="$(echo "$ipr" | jq -r --arg p "$player" '.admins[$p] // ""')"
    if [ -n "$a" ]; then
        if ! stored_matches_current_ip "$a" "$player_ip"; then warn_player_for_ip_mismatch "$player" "$player_ip"; return 1; fi
        return 0
    fi
    local m; m="$(echo "$ipr" | jq -r --arg p "$player" '.mods[$p] // ""')"
    if [ -n "$m" ]; then
        if ! stored_matches_current_ip "$m" "$player_ip"; then warn_player_for_ip_mismatch "$player" "$player_ip"; return 1; fi
    fi
    return 0
}

is_player_in_list() {
    local player="$1"; local list_type="$2"
    local world_dir; world_dir="$(dirname "$LOG_FILE")"
    local list_file="$world_dir/${list_type}list.txt"
    [ -f "$list_file" ] && grep -qi "^$(echo "$player" | tr '[:upper:]' '[:lower:]')$" "$list_file" && return 0
    return 1
}

handle_unauthorized_command() {
    local player_name="$1"; local command="$2"; local target="$3"
    echo -e "${RED}UNAUTHORIZED COMMAND: $player_name attempted $command on $target${NC}"
    send_server_command "say WARNING: $player_name attempted unauthorized rank assignment!"
    if is_player_in_list "$player_name" "admin"; then
        send_server_command "/unadmin $player_name"
        local ip; ip="$(get_player_ip "$player_name" "$LOG_FILE" || true)"
        if [ -n "$ip" ]; then
            local tmp; tmp="$(mktemp)"
            jq --arg p "$player_name" 'del(.admins[$p])' "$IP_RANKS_FILE" > "$tmp" && mv "$tmp" "$IP_RANKS_FILE"
            update_ip_for_rank "$player_name" "$ip" "mods"
            send_server_command "/mod $player_name"
            send_server_command "say $player_name ha sido degradado a MOD por comando no autorizado."
        else
            echo -e "${RED}No pude obtener IP de $player_name para actualizar ip_ranks${NC}"
        fi
    fi
}

# -------------------------
# Economy minimal
# -------------------------
add_player_if_new() {
    local player="$1"; local cur; cur="$(cat "$ECONOMY_FILE")"
    local exists; exists="$(echo "$cur" | jq --arg p "$player" '.players | has($p)')"
    if [ "$exists" = "false" ]; then
        cur="$(echo "$cur" | jq --arg p "$player" '.players[$p] = {"tickets":0,"last_login":0,"last_welcome_time":0,"last_help_time":0,"purchases":[]}')"
        echo "$cur" > "$ECONOMY_FILE"
        give_first_time_bonus "$player"
        echo -e "${GREEN}Jugador nuevo añadido: $player${NC}"
        return 0
    fi
    return 1
}

give_first_time_bonus() {
    local player="$1"; local cur; cur="$(cat "$ECONOMY_FILE")"
    local now; now="$(date +%s)"; local ts; ts="$(date '+%Y-%m-%d %H:%M:%S')"
    cur="$(echo "$cur" | jq --arg p "$player" '.players[$p].tickets = 1')"
    cur="$(echo "$cur" | jq --arg p "$player" --argjson t "$now" '.players[$p].last_login = $t')"
    cur="$(echo "$cur" | jq --arg p "$player" --arg time "$ts" '.transactions += [{"player": $p, "type":"welcome_bonus","tickets":1,"time":$time}]')"
    echo "$cur" > "$ECONOMY_FILE"
    echo -e "${GREEN}Bono de bienvenida dado a $player${NC}"
}

# -------------------------
# Extracción robusta de IP desde el log
# -------------------------
get_player_ip() {
    local player="$1"; local log="$2"
    [ -z "$log" ] && return 1
    local line
    line="$(tail -n 200 "$log" 2>/dev/null | grep -i -E "player.*${player}" | tail -n 20 | grep -i -E "connect|connected|joined" | tail -n 1 || true)"
    [ -z "$line" ] && line="$(tail -n 500 "$log" 2>/dev/null | grep -i -E "player (connected|joined).*${player}" | tail -n 1 || true)"
    [ -z "$line" ] && return 1
    local ip=""
    if [[ "$line" =~ \(IP:\ ([0-9a-fA-F:.]+)\) ]]; then ip="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ \|\ ([0-9a-fA-F:.]+) ]]; then ip="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ IP[:=]\ *([0-9a-fA-F:.]+) ]]; then ip="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ ([0-9]{1,3}(\.[0-9]{1,3}){3}) ]]; then ip="${BASH_REMATCH[1]}"
    fi
    ip="$(normalize_ip "$ip")"
    [ -n "$ip" ] && echo "$ip" && return 0
    return 1
}

# -------------------------
# Procesamiento de mensajes (economía minimalista)
# -------------------------
process_message() {
    local player="$1"; local message="$2"
    local cur; cur="$(cat "$ECONOMY_FILE")"
    local tickets; tickets="$(echo "$cur" | jq -r --arg p "$player" '.players[$p].tickets // 0')"; tickets=${tickets:-0}
    case "$message" in
        "hi"|"hello"|"hola"|"Hola") send_server_command "say Hello $player! Type !tickets.";;
        "!tickets") send_server_command "say $player, you have $tickets tickets.";;
        "!economy_help") send_server_command "say Economy: !tickets, !buy_mod (10), !buy_admin (20)";;
        "!buy_mod")
            if echo "$cur" | jq -e --arg p "$player" '.players[$p].purchases | index("mod") != null' >/dev/null 2>&1; then
                send_server_command "say $player, you already have MOD."
            elif [ "$tickets" -ge 10 ]; then
                local new=$((tickets-10))
                cur="$(echo "$cur" | jq --arg p "$player" --argjson t "$new" '.players[$p].tickets = $t')"
                cur="$(echo "$cur" | jq --arg p "$player" '.players[$p].purchases += ["mod"]')"
                local ts; ts="$(date '+%Y-%m-%d %H:%M:%S')"
                cur="$(echo "$cur" | jq --arg p "$player" --arg time "$ts" '.transactions += [{"player": $p, "type":"purchase", "item":"mod","tickets":-10,"time":$time}]')"
                echo "$cur" > "$ECONOMY_FILE"
                local pip; pip="$(get_player_ip "$player" "$LOG_FILE" || true)"
                [ -n "$pip" ] && update_ip_for_rank "$player" "$pip" "mods"
                send_server_command "/mod $player"
                send_server_command "say Congratulations $player! You are now MOD."
            else
                send_server_command "say $player, you need $((10-tickets)) more tickets."
            fi
            ;;
        "!buy_admin")
            if echo "$cur" | jq -e --arg p "$player" '.players[$p].purchases | index("admin") != null' >/dev/null 2>&1; then
                send_server_command "say $player, you already have ADMIN."
            elif [ "$tickets" -ge 20 ]; then
                local new=$((tickets-20))
                cur="$(echo "$cur" | jq --arg p "$player" --argjson t "$new" '.players[$p].tickets = $t')"
                cur="$(echo "$cur" | jq --arg p "$player" '.players[$p].purchases += ["admin"]')"
                local ts; ts="$(date '+%Y-%m-%d %H:%M:%S')"
                cur="$(echo "$cur" | jq --arg p "$player" --arg time "$ts" '.transactions += [{"player": $p, "type":"purchase", "item":"admin","tickets":-20,"time":$time}]')"
                echo "$cur" > "$ECONOMY_FILE"
                local pip; pip="$(get_player_ip "$player" "$LOG_FILE" || true)"
                [ -n "$pip" ] && update_ip_for_rank "$player" "$pip" "admins"
                send_server_command "/admin $player"
                send_server_command "say Congratulations $player! You are now ADMIN."
            else
                send_server_command "say $player, you need $((20-tickets)) more tickets."
            fi
            ;;
    esac
}

# -------------------------
# Admin commands desde la terminal
# -------------------------
process_admin_command() {
    local cmd="$1"
    if [[ "$cmd" =~ ^!send_ticket\ ([a-zA-Z0-9_]+)\ ([0-9]+)$ ]]; then
        local p="${BASH_REMATCH[1]}"; local amount="${BASH_REMATCH[2]}"
        local cur; cur="$(cat "$ECONOMY_FILE")"
        if [ "$(echo "$cur" | jq --arg p "$p" '.players | has($p)')" != "true" ]; then echo -e "${RED}Player $p no existe${NC}"; return; fi
        local curtickets; curtickets="$(echo "$cur" | jq -r --arg p "$p" '.players[$p].tickets // 0')"
        local new=$((curtickets+amount))
        cur="$(echo "$cur" | jq --arg p "$p" --argjson t "$new" '.players[$p].tickets = $t')"
        local ts; ts="$(date '+%Y-%m-%d %H:%M:%S')"
        cur="$(echo "$cur" | jq --arg p "$p" --arg time "$ts" --argjson a "$amount" '.transactions += [{"player": $p, "type":"admin_gift","tickets": $a,"time":$time}]')"
        echo "$cur" > "$ECONOMY_FILE"
        send_server_command "say $p received $amount tickets from admin! Total: $new"
    elif [[ "$cmd" =~ ^!make_mod\ ([a-zA-Z0-9_]+)$ ]]; then
        local p="${BASH_REMATCH[1]}"; local pip; pip="$(get_player_ip "$p" "$LOG_FILE" || true)"
        if [ -n "$pip" ]; then update_ip_for_rank "$p" "$pip" "mods"; send_server_command "/mod $p"; send_server_command "say $p has been promoted to MOD by admin."; else echo -e "${RED}Player $p no conectado${NC}"; fi
    elif [[ "$cmd" =~ ^!make_admin\ ([a-zA-Z0-9_]+)$ ]]; then
        local p="${BASH_REMATCH[1]}"; local pip; pip="$(get_player_ip "$p" "$LOG_FILE" || true)"
        if [ -n "$pip" ]; then update_ip_for_rank "$p" "$pip" "admins"; send_server_command "/admin $p"; send_server_command "say $p has been promoted to ADMIN by admin."; else echo -e "${RED}Player $p no conectado${NC}"; fi
    elif [[ "$cmd" =~ ^!set_mod\ ([a-zA-Z0-9_]+)$ ]]; then local p="${BASH_REMATCH[1]}"; local pip; pip="$(get_player_ip "$p" "$LOG_FILE" || true)"; if [ -n "$pip" ]; then update_ip_for_rank "$p" "$pip" "mods"; send_server_command "/mod $p"; send_server_command "say $p set as MOD by console."; else echo -e "${RED}Player $p no conectado${NC}"; fi
    elif [[ "$cmd" =~ ^!set_admin\ ([a-zA-Z0-9_]+)$ ]]; then local p="${BASH_REMATCH[1]}"; local pip; pip="$(get_player_ip "$p" "$LOG_FILE" || true)"; if [ -n "$pip" ]; then update_ip_for_rank "$p" "$pip" "admins"; send_server_command "/admin $p"; send_server_command "say $p set as ADMIN by console."; else echo -e "${RED}Player $p no conectado${NC}"; fi
    else
        echo -e "${YELLOW}Comando admin desconocido: $cmd${NC}"
    fi
}

# -------------------------
# Filtrado y monitor principal
# -------------------------
filter_server_log() {
    while read -r line; do
        if [[ "$line" == *"Server closed"* ]] || [[ "$line" == *"Starting server"* ]]; then continue; fi
        echo "$line"
    done
}

monitor_log() {
    local log="$1"; LOG_FILE="$log"
    initialize_files

    echo -e "${BLUE}Iniciando bot - monitoreando: $log${NC}"
    local admin_pipe="/tmp/blockheads_admin_pipe"
    rm -f "$admin_pipe"
    mkfifo "$admin_pipe"

    # Hilo para recibir comandos de admin desde la terminal
    ( while true; do if read -r admin_cmd < "$admin_pipe"; then echo -e "${CYAN}Procesando admin command: $admin_cmd${NC}"; process_admin_command "$admin_cmd"; fi; done ) &

    # Forward stdin a admin pipe (te permite escribir comandos aquí)
    ( while read -r admin_cmd; do echo "$admin_cmd" > "$admin_pipe"; done ) &

    trap 'echo "Bot detenido (trap). Limpio temporales."; rm -f /tmp/bh_warn_*; rm -f "$admin_pipe"; exit 0' INT TERM

    # Esperar a que exista el log (no salir si no existe)
    if [ ! -f "$LOG_FILE" ]; then
        echo -e "${YELLOW}El log no existe todavía: $LOG_FILE${NC}"
        if [ "$LOG_WAIT_TIMEOUT" -le 0 ]; then
            echo -e "${YELLOW}Esperando indefinidamente a que aparezca el log...${NC}"
            while [ ! -f "$LOG_FILE" ]; do sleep 1; done
        else
            echo -e "${YELLOW}Esperando hasta $LOG_WAIT_TIMEOUT segundos a que aparezca...${NC}"
            local waited=0
            while [ ! -f "$LOG_FILE" ] && [ "$waited" -lt "$LOG_WAIT_TIMEOUT" ]; do sleep 1; waited=$((waited+1)); done
            if [ ! -f "$LOG_FILE" ]; then
                echo -e "${RED}Timeout esperando el log. El bot continuará pero no podrá monitorear hasta que el log exista.${NC}"
            fi
        fi
    fi

    tail -n 0 -F "$LOG_FILE" 2>/dev/null | filter_server_log | while read -r line; do
        # Conexiones
        if [[ "$line" =~ [Pp]layer\ (connected|Connected|joined)[:]?\ ?([a-zA-Z0-9_]+) ]]; then
            if [[ "$line" =~ [Pp]layer\ (connected|Connected|joined).*[: ]([a-zA-Z0-9_]+).*\(IP:\ ([0-9a-fA-F:.]+)\) ]]; then
                player_name="${BASH_REMATCH[2]}"; player_ip="${BASH_REMATCH[3]}"
            elif [[ "$line" =~ [Pp]layer\ (connected|Connected|joined).*([a-zA-Z0-9_]+)\ \|\ ([0-9a-fA-F:.]+) ]]; then
                player_name="${BASH_REMATCH[2]}"; player_ip="${BASH_REMATCH[3]}"
            elif [[ "$line" =~ ([a-zA-Z0-9_]+).*(IP[:=]\ *([0-9a-fA-F:.]+)) ]]; then
                player_name="${BASH_REMATCH[1]}"; player_ip="${BASH_REMATCH[3]}"
            else
                player_name="$(echo "$line" | sed -n 's/.*[Pp]layer [Cc]onnected[: ]*\([a-zA-Z0-9_]\+\).*/\1/p' || true)"
                player_ip="$(get_player_ip "$player_name" "$LOG_FILE" 2>/dev/null || true)"
            fi
            player_name="$(echo -n "$player_name" | tr -d '\r\n')"
            player_ip="$(normalize_ip "$player_ip")"

            [ -z "$player_name" ] && continue
            [ "$player_name" = "SERVER" ] && continue

            echo -e "${GREEN}Player connected: $player_name (IP: ${player_ip:-UNKNOWN})${NC}"

            if ! check_username_ip_security "$player_name" "$player_ip"; then continue; fi
            if ! check_ip_rank_security "$player_name" "$player_ip"; then continue; fi

            local is_new="false"
            if add_player_if_new "$player_name"; then is_new="true"; fi

            if [ "$is_new" = "true" ]; then send_server_command "say Hello $player_name! Welcome to the server. Type !tickets."; else send_server_command "say Welcome back $player_name!"; fi
            continue
        fi

        # comandos no autorizados
        if [[ "$line" =~ ^([a-zA-Z0-9_]+):\ \/(admin|mod)\ ([a-zA-Z0-9_]+) ]]; then
            local command_user="${BASH_REMATCH[1]}"; local command_type="${BASH_REMATCH[2]}"; local target_player="${BASH_REMATCH[3]}"
            [ "$command_user" != "SERVER" ] && handle_unauthorized_command "$command_user" "/$command_type" "$target_player"
            continue
        fi

        # chat
        if [[ "$line" =~ ^([a-zA-Z0-9_]+):\ (.+)$ ]]; then
            local chat_player="${BASH_REMATCH[1]}"; local chat_msg="${BASH_REMATCH[2]}"
            [ "$chat_player" = "SERVER" ] && continue
            echo -e "${CYAN}Chat: $chat_player: $chat_msg${NC}"
            add_player_if_new "$chat_player"
            process_message "$chat_player" "$chat_msg"
            continue
        fi

        echo -e "${BLUE}Other log line: $line${NC}"
    done

    rm -f "$admin_pipe"
}

# -------------------------
# Entrada principal
# -------------------------
if [ $# -ne 1 ]; then
    echo -e "${RED}Uso: $0 <server_log_file>${NC}"
    exit 1
fi

LOG_FILE="$1"
initialize_files
monitor_log "$LOG_FILE"
