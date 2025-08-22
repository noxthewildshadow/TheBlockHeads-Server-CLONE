#!/usr/bin/env bash
set -euo pipefail

# Single-file installer + controller for TheBlockHeads server (Ubuntu 22.04)
# Usage:
#   sudo bash ./setup.sh          -> instala todo (default)
#   /usr/local/bin/blockheadsctl start WORLD_ID [PORT]
#   /usr/local/bin/blockheadsctl stop
#   /usr/local/bin/blockheadsctl status
#   /usr/local/bin/blockheadsctl bot /path/to/console.log   -> internal; launched inside screen
# Notes:
#   - This script will copy itself to /usr/local/bin/blockheadsctl (executable).
#   - Installation target dir: $USER_HOME/blockheads_server
#   - Create a world manually (recommendation): ./blockheads_server171 -n WORLD_NAME
# -------------------------------------------------------------------------

ORIGINAL_USER="${SUDO_USER:-${USER:-root}}"
# Resolve ORIGINAL_USER home robustly
USER_HOME="$(getent passwd "$ORIGINAL_USER" | cut -d: -f6 || echo "/home/$ORIGINAL_USER")"
INSTALL_DIR="$USER_HOME/blockheads_server"
BIN_SYMLINK="/usr/local/bin/blockheadsctl"

# Downloaded server URL (kept from provided script; best-effort)
SERVER_ARCHIVE_URL="https://web.archive.org/web/20240309015235if_/https://majicdave.com/share/blockheads_server171.tar.gz"
TEMP_TAR="/tmp/blockheads_server171_$$.tar.gz"

# Default values
DEFAULT_PORT=12153
SCREEN_SERVER="blockheads_server"
SCREEN_BOT="blockheads_bot"
SERVER_BINARY_NAME="blockheads_server171"
SERVER_BINARY_PATH="$INSTALL_DIR/$SERVER_BINARY_NAME"
ECONOMY_FILE_REL="economy_data.json"

# Helper: echo to stderr for errors
_err(){ echo "$*" >&2; }

# --- INSTALL / PREP STEPS ---
install_requirements() {
    echo "[1/6] Installing required packages (apt)..."
    # allow noninteractive
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y >/dev/null 2>&1 || true
    # install recommended tools; patchelf often needed for binary fixes
    apt-get install -y libgnustep-base1.28 libdispatch0 patchelf wget jq screen lsof >/dev/null 2>&1 || {
        echo "WARNING: apt install encountered issues. Please check network or run manually:"
        echo "  sudo apt update && sudo apt install libgnustep-base1.28 libdispatch0 patchelf wget jq screen lsof"
    }
}

download_and_extract_server() {
    echo "[2/6] Creating install dir: $INSTALL_DIR"
    mkdir -p "$INSTALL_DIR"
    chown "$ORIGINAL_USER:$ORIGINAL_USER" "$INSTALL_DIR" || true

    echo "[3/6] Downloading server archive..."
    rm -f "$TEMP_TAR"
    if ! wget -q "$SERVER_ARCHIVE_URL" -O "$TEMP_TAR"; then
        _err "ERROR: Failed to download server archive from $SERVER_ARCHIVE_URL"
        return 1
    fi

    echo "[4/6] Extracting archive to $INSTALL_DIR..."
    tar xzf "$TEMP_TAR" -C "$INSTALL_DIR" || {
        _err "ERROR: Extraction failed. Tar content listing:"
        tar tzf "$TEMP_TAR" || true
        return 1
    }
    rm -f "$TEMP_TAR"
    chown -R "$ORIGINAL_USER:$ORIGINAL_USER" "$INSTALL_DIR" || true

    # Look for binary if not exact name
    if [ ! -f "$SERVER_BINARY_PATH" ]; then
        echo "Server binary $SERVER_BINARY_NAME not found at expected path. Searching..."
        alt="$(find "$INSTALL_DIR" -maxdepth 3 -type f -executable -iname "*blockheads*" | head -n1 || true)"
        if [ -n "$alt" ]; then
            echo "Found candidate binary: $alt"
            mv "$alt" "$SERVER_BINARY_PATH" || cp "$alt" "$SERVER_BINARY_PATH"
            chown "$ORIGINAL_USER:$ORIGINAL_USER" "$SERVER_BINARY_PATH" || true
            chmod +x "$SERVER_BINARY_PATH" || true
        else
            _err "ERROR: Could not find server binary inside archive."
            return 1
        fi
    fi
    chmod +x "$SERVER_BINARY_PATH" || true
}

apply_patchelf_fixes() {
    echo "[5/6] Attempting patchelf compatibility replacements (best-effort)."
    # Many replacements are best-effort; ignore errors but warn
    set +e
    patchelf --replace-needed libgnustep-base.so.1.24 libgnustep-base.so.1.28 "$SERVER_BINARY_PATH" 2>/dev/null || echo "patchelf: libgnustep-base patch warning"
    patchelf --replace-needed libobjc.so.4.6 libobjc.so.4 "$SERVER_BINARY_PATH" 2>/dev/null || true
    patchelf --replace-needed libgnutls.so.26 libgnutls.so.30 "$SERVER_BINARY_PATH" 2>/dev/null || true
    patchelf --replace-needed libgcrypt.so.11 libgcrypt.so.20 "$SERVER_BINARY_PATH" 2>/dev/null || true
    patchelf --replace-needed libffi.so.6 libffi.so.8 "$SERVER_BINARY_PATH" 2>/dev/null || true
    patchelf --replace-needed libicui18n.so.48 libicui18n.so.70 "$SERVER_BINARY_PATH" 2>/dev/null || true
    patchelf --replace-needed libicuuc.so.48 libicuuc.so.70 "$SERVER_BINARY_PATH" 2>/dev/null || true
    patchelf --replace-needed libicudata.so.48 libicudata.so.70 "$SERVER_BINARY_PATH" 2>/dev/null || true
    patchelf --replace-needed libdispatch.so libdispatch.so.0 "$SERVER_BINARY_PATH" 2>/dev/null || true
    set -e
}

create_economy_file() {
    echo "[6/6] Creating economy data file (if missing)..."
    sudo -u "$ORIGINAL_USER" bash -lc "cd '$INSTALL_DIR' && \
        [ -f '$ECONOMY_FILE_REL' ] || echo '{\"players\": {}, \"transactions\": []}' > '$ECONOMY_FILE_REL'"
    chown "$ORIGINAL_USER:$ORIGINAL_USER" "$INSTALL_DIR/$ECONOMY_FILE_REL" || true
}

install_self_symlink() {
    # Copy this script to /usr/local/bin/blockheadsctl so user can call it
    echo "Installing controller to $BIN_SYMLINK"
    cp --preserve=mode "$0" "$INSTALL_DIR/setup_self.sh" 2>/dev/null || cp "$0" "$INSTALL_DIR/setup_self.sh"
    chown "$ORIGINAL_USER:$ORIGINAL_USER" "$INSTALL_DIR/setup_self.sh" || true
    chmod +x "$INSTALL_DIR/setup_self.sh" || true
    # Use cp to /usr/local/bin (requires root) so commands available system-wide
    cp "$INSTALL_DIR/setup_self.sh" "$BIN_SYMLINK"
    chmod 755 "$BIN_SYMLINK"
}

# --- SERVER CONTROL + BOT (single-file; same script handles subcommands) ---
# Helper: path to saves (uses ORIGINAL_USER home, not root)
saves_dir_for_user() {
    echo "$USER_HOME/GNUstep/Library/ApplicationSupport/TheBlockheads/saves"
}

is_port_in_use() {
    local port="$1"
    if lsof -Pi ":$port" -sTCP:LISTEN -t >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# Try to free port gently (kill processes bound to port)
free_port() {
    local port="$1"
    echo "Intentando liberar el puerto $port..."
    local pids
    pids="$(lsof -ti tcp:"$port" 2>/dev/null || true)"
    if [ -n "$pids" ]; then
        echo "Procesos usando el puerto $port: $pids"
        kill -9 $pids 2>/dev/null || true
        sleep 1
    fi
    if is_port_in_use "$port"; then
        echo "ERROR: No se pudo liberar el puerto $port"
        return 1
    fi
    return 0
}

check_world_exists() {
    local world_id="$1"
    local saves_dir
    saves_dir="$(saves_dir_for_user)"
    local world_dir="$saves_dir/$world_id"
    if [ ! -d "$world_dir" ]; then
        echo "Error: El mundo '$world_id' no existe en: $world_dir"
        echo "Crea el mundo manualmente con (como $ORIGINAL_USER en $INSTALL_DIR):"
        echo "  cd '$INSTALL_DIR' && ./blockheads_server171 -n WORLD_NAME"
        return 1
    fi
    return 0
}

# Start server: will run as ORIGINAL_USER inside a screen session and create log
start_server() {
    local world_id="$1"
    local port="${2:-$DEFAULT_PORT}"

    if [ -z "$world_id" ]; then
        _err "Debe especificar WORLD_ID. Ej: blockheadsctl start MI_MUNDO $DEFAULT_PORT"
        return 1
    fi

    if is_port_in_use "$port"; then
        echo "El puerto $port está en uso. Intentando liberarlo..."
        if ! free_port "$port"; then
            _err "No se puede usar el puerto $port."
            return 1
        fi
    fi

    if ! check_world_exists "$world_id"; then
        return 1
    fi

    local log_dir
    log_dir="$(saves_dir_for_user)/$world_id"
    mkdir -p "$log_dir"
    chown "$ORIGINAL_USER:$ORIGINAL_USER" "$log_dir" || true
    local log_file="$log_dir/console.log"

    echo "Guardando world_id actual en $INSTALL_DIR/world_id.txt"
    echo "$world_id" > "$INSTALL_DIR/world_id.txt"
    chown "$ORIGINAL_USER:$ORIGINAL_USER" "$INSTALL_DIR/world_id.txt" || true

    # Create a small server runner script inside INSTALL_DIR (owned by user) to simplify quoting in screen
    local runner="$INSTALL_DIR/.blockheads_server_runner.sh"
    cat > "$runner" <<'EOF'
#!/usr/bin/env bash
set -e
INSTALL_DIR="@INSTALL_DIR@"
SERVER_BINARY="@SERVER_BINARY@"
WORLD_ID="@WORLD_ID@"
PORT="@PORT@"
LOG_FILE="@LOG_FILE@"

cd "$INSTALL_DIR" || exit 1
while true; do
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Iniciando servidor..."
    # Ejecutar servidor y redirigir salida al log
    "$SERVER_BINARY" -o "$WORLD_ID" -p "$PORT" 2>&1 | tee -a "$LOG_FILE"
    exit_code=${PIPESTATUS[0]:-0}
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Servidor salido con código: $exit_code" | tee -a "$LOG_FILE"
    if [ "$exit_code" -eq 1 ] && tail -n 5 "$LOG_FILE" | grep -qi "port.*already in use"; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Puerto ya en uso. No se reintentará." | tee -a "$LOG_FILE"
        break
    fi
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Reiniciando en 5 segundos..." | tee -a "$LOG_FILE"
    sleep 5
done
EOF

    # Replace placeholders
    sed -i "s|@INSTALL_DIR@|$INSTALL_DIR|g" "$runner"
    sed -i "s|@SERVER_BINARY@|$SERVER_BINARY_PATH|g" "$runner"
    sed -i "s|@WORLD_ID@|$world_id|g" "$runner"
    sed -i "s|@PORT@|$port|g" "$runner"
    sed -i "s|@LOG_FILE@|$log_file|g" "$runner"

    chown "$ORIGINAL_USER:$ORIGINAL_USER" "$runner" || true
    chmod +x "$runner" || true

    # Kill older sessions with same name (only the specific screen name, do NOT killall)
    if screen -list | grep -q "$SCREEN_SERVER"; then
        echo "Session $SCREEN_SERVER existente. Deteniéndola primero..."
        su - "$ORIGINAL_USER" -c "screen -S '$SCREEN_SERVER' -X quit" || true
        sleep 1
    fi

    # Start screen as ORIGINAL_USER and execute runner
    su - "$ORIGINAL_USER" -s /bin/bash -c "cd '$INSTALL_DIR' && screen -dmS '$SCREEN_SERVER' bash -lc '$runner'"

    echo "Esperando a que se cree el archivo de log..."
    local wait=0
    while [ ! -f "$log_file" ] && [ $wait -lt 10 ]; do
        sleep 1; wait=$((wait+1))
    done

    if [ ! -f "$log_file" ]; then
        _err "ERROR: No se pudo crear el archivo de log. El servidor puede no haber iniciado."
        return 1
    fi

    # Start bot (monitor) after a small wait
    start_bot "$log_file"

    echo "Servidor iniciado (screen: $SCREEN_SERVER). Log: $log_file"
    echo "Ver consola: su - $ORIGINAL_USER -c 'screen -r $SCREEN_SERVER'"
    echo "Ver bot: su - $ORIGINAL_USER -c 'screen -r $SCREEN_BOT'"
    return 0
}

# Create and start bot (launches this script with the 'bot' argument inside screen)
start_bot() {
    local log_file="$1"
    if screen -list | grep -q "$SCREEN_BOT"; then
        echo "Bot ya está ejecutándose."
        return 0
    fi
    echo "Iniciando bot en screen: $SCREEN_BOT"
    # Launch this same controller (copied to /usr/local/bin) with the bot command as ORIGINAL_USER
    su - "$ORIGINAL_USER" -s /bin/bash -c "cd '$INSTALL_DIR' && screen -dmS '$SCREEN_BOT' bash -lc '$BIN_SYMLINK bot \"$log_file\"'"
    sleep 1
    echo "Bot iniciado."
}

stop_server_and_bot() {
    echo "Deteniendo servidor y bot (si existen)..."
    # stop screens only by name
    if screen -list | grep -q "$SCREEN_SERVER"; then
        screen -S "$SCREEN_SERVER" -X quit || true
        echo "Servidor detenido (screen)."
    else
        echo "Servidor (screen) no encontrado."
    fi
    if screen -list | grep -q "$SCREEN_BOT"; then
        screen -S "$SCREEN_BOT" -X quit || true
        echo "Bot detenido (screen)."
    else
        echo "Bot (screen) no encontrado."
    fi
    # kill server binary if still running
    pkill -f "$SERVER_BINARY_PATH" 2>/dev/null || true
    pkill -f "tail -n 0 -F" 2>/dev/null || true
}

show_status() {
    echo "=== ESTADO THE BLOCKHEADS ==="
    if screen -list | grep -q "$SCREEN_SERVER"; then
        echo "Servidor: EJECUTÁNDOSE (screen: $SCREEN_SERVER)"
    else
        echo "Servidor: DETENIDO"
    fi
    if screen -list | grep -q "$SCREEN_BOT"; then
        echo "Bot: EJECUTÁNDOSE (screen: $SCREEN_BOT)"
    else
        echo "Bot: DETENIDO"
    fi
    if [ -f "$INSTALL_DIR/world_id.txt" ]; then
        echo "Mundo actual: $(cat "$INSTALL_DIR/world_id.txt")"
    fi
    echo "Instalado en: $INSTALL_DIR"
    echo "Control: $BIN_SYMLINK start|stop|status"
    echo "============================="
}

# ---------------- BOT MONITOR (port of bot_server.sh) ----------------
# This function runs when script is invoked with: blockheadsctl bot /path/to/console.log
monitor_log() {
    local LOG_FILE="$1"

    # Config
    local ECONOMY_FILE="$INSTALL_DIR/$ECONOMY_FILE_REL"
    local SCAN_INTERVAL=5
    local SERVER_WELCOME_WINDOW=15
    local TAIL_LINES=500

    # Initialization helpers:
    initialize_economy() {
        if [ ! -f "$ECONOMY_FILE" ]; then
            echo '{"players": {}, "transactions": []}' > "$ECONOMY_FILE"
            echo "Economy data file created: $ECONOMY_FILE"
            chown "$ORIGINAL_USER:$ORIGINAL_USER" "$ECONOMY_FILE" || true
        fi
    }

    is_player_in_list() {
        local player_name="$1"
        local list_type="$2"
        local world_dir
        world_dir="$(dirname "$LOG_FILE")"
        local list_file="$world_dir/${list_type}list.txt"
        local lower_player_name
        lower_player_name="$(echo "$player_name" | tr '[:upper:]' '[:lower:]')"
        if [ -f "$list_file" ]; then
            if grep -q "^$lower_player_name$" "$list_file"; then
                return 0
            fi
        fi
        return 1
    }

    add_player_if_new() {
        local player_name="$1"
        local current_data
        current_data="$(cat "$ECONOMY_FILE")"
        local player_exists
        player_exists="$(echo "$current_data" | jq --arg player "$player_name" '.players | has($player)')"
        if [ "$player_exists" = "false" ]; then
            current_data="$(echo "$current_data" | jq --arg player "$player_name" '.players[$player] = {"tickets": 0, "last_login": 0, "last_welcome_time": 0, "last_help_time": 0, "purchases": []}')"
            echo "$current_data" > "$ECONOMY_FILE"
            echo "Added new player: $player_name"
            give_first_time_bonus "$player_name"
            return 0
        fi
        return 1
    }

    give_first_time_bonus() {
        local player_name="$1"
        local current_data
        current_data="$(cat "$ECONOMY_FILE")"
        local current_time
        current_time="$(date +%s)"
        local time_str
        time_str="$(date '+%Y-%m-%d %H:%M:%S')"
        current_data="$(echo "$current_data" | jq --arg player "$player_name" '.players[$player].tickets = 1')"
        current_data="$(echo "$current_data" | jq --arg player "$player_name" --argjson time "$current_time" '.players[$player].last_login = $time')"
        current_data="$(echo "$current_data" | jq --arg player "$player_name" --arg time "$time_str" '.transactions += [{"player": $player, "type": "welcome_bonus", "tickets": 1, "time": $time}]')"
        echo "$current_data" > "$ECONOMY_FILE"
        echo "Gave first-time bonus to $player_name"
    }

    grant_login_ticket() {
        local player_name="$1"
        local current_time
        current_time="$(date +%s)"
        local time_str
        time_str="$(date '+%Y-%m-%d %H:%M:%S')"
        local current_data
        current_data="$(cat "$ECONOMY_FILE")"
        local last_login
        last_login="$(echo "$current_data" | jq -r --arg player "$player_name" '.players[$player].last_login // 0')"
        last_login=${last_login:-0}
        if [ "$last_login" -eq 0 ] || [ $((current_time - last_login)) -ge 3600 ]; then
            local current_tickets
            current_tickets="$(echo "$current_data" | jq -r --arg player "$player_name" '.players[$player].tickets // 0')"
            current_tickets=${current_tickets:-0}
            local new_tickets=$((current_tickets + 1))
            current_data="$(echo "$current_data" | jq --arg player "$player_name" --argjson tickets "$new_tickets" '.players[$player].tickets = $tickets')"
            current_data="$(echo "$current_data" | jq --arg player "$player_name" --argjson time "$current_time" '.players[$player].last_login = $time')"
            current_data="$(echo "$current_data" | jq --arg player "$player_name" --arg time "$time_str" '.transactions += [{"player": $player, "type": "login_bonus", "tickets": 1, "time": $time}]')"
            echo "$current_data" > "$ECONOMY_FILE"
            echo "Granted 1 ticket to $player_name (Total: $new_tickets)"
            send_server_command "$player_name, you received 1 login ticket! You now have $new_tickets tickets."
        else
            local next_login=$((last_login + 3600))
            local time_left=$((next_login - current_time))
            echo "$player_name must wait $((time_left / 60)) minutes for next ticket"
        fi
    }

    show_welcome_message() {
        local player_name="$1"
        local is_new_player="$2"
        local force_send="${3:-0}"
        local current_time
        current_time="$(date +%s)"
        local current_data
        current_data="$(cat "$ECONOMY_FILE")"
        local last_welcome_time
        last_welcome_time="$(echo "$current_data" | jq -r --arg player "$player_name" '.players[$player].last_welcome_time // 0')"
        last_welcome_time=${last_welcome_time:-0}
        if [ "$force_send" -eq 1 ] || [ "$last_welcome_time" -eq 0 ] || [ $((current_time - last_welcome_time)) -ge 180 ]; then
            if [ "$is_new_player" = "true" ]; then
                send_server_command "Hello $player_name! Welcome to the server. Type !tickets to check your ticket balance."
            else
                send_server_command "Welcome back $player_name! Type !economy_help to see economy commands."
            fi
            current_data="$(echo "$current_data" | jq --arg player "$player_name" --argjson time "$current_time" '.players[$player].last_welcome_time = $time')"
            echo "$current_data" > "$ECONOMY_FILE"
        else
            echo "Skipping welcome for $player_name due to cooldown."
        fi
    }

    show_help_if_needed() {
        local player_name="$1"
        local current_time
        current_time="$(date +%s)"
        local current_data
        current_data="$(cat "$ECONOMY_FILE")"
        local last_help_time
        last_help_time="$(echo "$current_data" | jq -r --arg player "$player_name" '.players[$player].last_help_time // 0')"
        last_help_time=${last_help_time:-0}
        if [ "$last_help_time" -eq 0 ] || [ $((current_time - last_help_time)) -ge 300 ]; then
            send_server_command "$player_name, type !economy_help to see economy commands."
            current_data="$(echo "$current_data" | jq --arg player "$player_name" --argjson time "$current_time" '.players[$player].last_help_time = $time')"
            echo "$current_data" > "$ECONOMY_FILE"
        fi
    }

    send_server_command() {
        local message="$1"
        # Send to screen session; the server screen must be named SCREEN_SERVER
        if screen -S "$SCREEN_SERVER" -X stuff "$message$(printf \\r)" 2>/dev/null; then
            echo "Sent message to server: $message"
        else
            echo "Error: Could not send message to server. Is the server running?"
        fi
    }

    has_purchased() {
        local player_name="$1"
        local item="$2"
        local current_data
        current_data="$(cat "$ECONOMY_FILE")"
        local has_item
        has_item="$(echo "$current_data" | jq --arg player "$player_name" --arg item "$item" '.players[$player].purchases | index($item) != null')"
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
        current_data="$(cat "$ECONOMY_FILE")"
        current_data="$(echo "$current_data" | jq --arg player "$player_name" --arg item "$item" '.players[$player].purchases += [$item]')"
        echo "$current_data" > "$ECONOMY_FILE"
    }

    process_message() {
        local player_name="$1"
        local message="$2"
        local current_data
        current_data="$(cat "$ECONOMY_FILE")"
        local player_tickets
        player_tickets="$(echo "$current_data" | jq -r --arg player "$player_name" '.players[$player].tickets // 0')"
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
                    send_server_command "$player_name, you already have MOD rank."
                elif [ "$player_tickets" -ge 10 ]; then
                    local new_tickets=$((player_tickets - 10))
                    local current_data
                    current_data="$(cat "$ECONOMY_FILE")"
                    current_data="$(echo "$current_data" | jq --arg player "$player_name" --argjson tickets "$new_tickets" '.players[$player].tickets = $tickets')"
                    add_purchase "$player_name" "mod"
                    local time_str
                    time_str="$(date '+%Y-%m-%d %H:%M:%S')"
                    current_data="$(echo "$current_data" | jq --arg player "$player_name" --arg time "$time_str" '.transactions += [{"player": $player, "type": "purchase", "item": "mod", "tickets": -10, "time": $time}]')"
                    echo "$current_data" > "$ECONOMY_FILE"
                    screen -S "$SCREEN_SERVER" -X stuff "/mod $player_name$(printf \\r)"
                    send_server_command "Congratulations $player_name! You have been promoted to MOD for 10 tickets. Remaining tickets: $new_tickets"
                else
                    send_server_command "$player_name, you need $((10 - player_tickets)) more tickets to buy MOD rank."
                fi
                ;;
            "!buy_admin")
                if has_purchased "$player_name" "admin" || is_player_in_list "$player_name" "admin"; then
                    send_server_command "$player_name, you already have ADMIN rank."
                elif [ "$player_tickets" -ge 20 ]; then
                    local new_tickets=$((player_tickets - 20))
                    local current_data
                    current_data="$(cat "$ECONOMY_FILE")"
                    current_data="$(echo "$current_data" | jq --arg player "$player_name" --argjson tickets "$new_tickets" '.players[$player].tickets = $tickets')"
                    add_purchase "$player_name" "admin"
                    local time_str
                    time_str="$(date '+%Y-%m-%d %H:%M:%S')"
                    current_data="$(echo "$current_data" | jq --arg player "$player_name" --arg time "$time_str" '.transactions += [{"player": $player, "type": "purchase", "item": "admin", "tickets": -20, "time": $time}]')"
                    echo "$current_data" > "$ECONOMY_FILE"
                    screen -S "$SCREEN_SERVER" -X stuff "/admin $player_name$(printf \\r)"
                    send_server_command "Congratulations $player_name! You have been promoted to ADMIN for 20 tickets. Remaining tickets: $new_tickets"
                else
                    send_server_command "$player_name, you need $((20 - player_tickets)) more tickets to buy ADMIN rank."
                fi
                ;;
            "!economy_help")
                send_server_command "Economy commands: !tickets, !buy_mod (10), !buy_admin (20)"
                ;;
        esac
    }

    process_admin_command() {
        local command="$1"
        local current_data
        current_data="$(cat "$ECONOMY_FILE")"
        if [[ "$command" =~ ^!send_ticket\ ([a-zA-Z0-9_]+)\ ([0-9]+)$ ]]; then
            local player_name="${BASH_REMATCH[1]}"
            local tickets_to_add="${BASH_REMATCH[2]}"
            local player_exists
            player_exists="$(echo "$current_data" | jq --arg player "$player_name" '.players | has($player)')"
            if [ "$player_exists" = "false" ]; then
                echo "Player $player_name not found in economy system."
                return
            fi
            local current_tickets
            current_tickets="$(echo "$current_data" | jq -r --arg player "$player_name" '.players[$player].tickets // 0')"
            current_tickets=${current_tickets:-0}
            local new_tickets=$((current_tickets + tickets_to_add))
            current_data="$(echo "$current_data" | jq --arg player "$player_name" --argjson tickets "$new_tickets" '.players[$player].tickets = $tickets')"
            local time_str
            time_str="$(date '+%Y-%m-%d %H:%M:%S')"
            current_data="$(echo "$current_data" | jq --arg player "$player_name" --arg time "$time_str" --argjson amount "$tickets_to_add" '.transactions += [{"player": $player, "type": "admin_gift", "tickets": $amount, "time": $time}]')"
            echo "$current_data" > "$ECONOMY_FILE"
            echo "Added $tickets_to_add tickets to $player_name (Total: $new_tickets)"
            send_server_command "$player_name received $tickets_to_add tickets from admin! Total: $new_tickets"
        elif [[ "$command" =~ ^!make_mod\ ([a-zA-Z0-9_]+)$ ]]; then
            local player_name="${BASH_REMATCH[1]}"
            echo "Making $player_name a MOD"
            screen -S "$SCREEN_SERVER" -X stuff "/mod $player_name$(printf \\r)"
            send_server_command "$player_name has been promoted to MOD by admin!"
        elif [[ "$command" =~ ^!make_admin\ ([a-zA-Z0-9_]+)$ ]]; then
            local player_name="${BASH_REMATCH[1]}"
            echo "Making $player_name an ADMIN"
            screen -S "$SCREEN_SERVER" -X stuff "/admin $player_name$(printf \\r)"
            send_server_command "$player_name has been promoted to ADMIN by admin!"
        else
            echo "Unknown admin command: $command"
        fi
    }

    server_sent_welcome_recently() {
        local player_name="$1"
        local conn_epoch="${2:-0}"
        if [ -z "$LOG_FILE" ] || [ ! -f "$LOG_FILE" ]; then
            return 1
        fi

        local player_lc
        player_lc="$(echo "$player_name" | tr '[:upper:]' '[:lower:]')"

        local matches
        matches="$(tail -n "$TAIL_LINES" "$LOG_FILE" 2>/dev/null | tr '[:upper:]' '[:lower:]' | grep -iE "server: .*welcome" | grep -i "$player_lc" || true)"
        if [ -z "$matches" ]; then
            return 1
        fi

        while IFS= read -r line; do
            ts_str="$(echo "$line" | awk '{print $1" "$2}')"
            ts_no_ms="${ts_str%.*}"
            ts_epoch="$(date -d "$ts_no_ms" +%s 2>/dev/null || echo 0)"
            if [ "$ts_epoch" -ge "$conn_epoch" ] && [ "$ts_epoch" -le $((conn_epoch + SERVER_WELCOME_WINDOW)) ]; then
                return 0
            fi
        done < <(tail -n "$TAIL_LINES" "$LOG_FILE" 2>/dev/null | grep -i "server: .*welcome" | grep -i "$player_lc" || true)

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
            echo "$line"
        done
    }

    initialize_economy

    echo "Starting economy bot. Monitoring: $LOG_FILE"
    echo "Type admin commands here (in the screen running the bot), e.g.:"
    echo "  !send_ticket PLAYER 5"
    echo "  !make_mod PLAYER"
    echo "================================================================"

    # admin pipe for interactive admin commands (kept inside bot screen)
    local admin_pipe="/tmp/blockheads_admin_pipe_$$"
    rm -f "$admin_pipe"
    mkfifo "$admin_pipe"

    # background process to read from the pipe and process admin commands
    ( while read -r admin_command < "$admin_pipe"; do
          echo "Processing admin command: $admin_command"
          if [[ "$admin_command" == "!send_ticket "* ]] || [[ "$admin_command" == "!make_mod "* ]] || [[ "$admin_command" == "!make_admin "* ]]; then
              process_admin_command "$admin_command"
          else
              echo "Unknown admin command. Use: !send_ticket <player> <amount> | !make_mod <player> | !make_admin <player>"
          fi
          echo "================================================================"
      done ) &

    # feed standard input into admin pipe (read from screen user input)
    ( while read -r admin_command; do
          echo "$admin_command" > "$admin_pipe"
      done ) &

    declare -A welcome_shown

    # Main tail loop: follow log and process events
    tail -n 0 -F "$LOG_FILE" 2>/dev/null | filter_server_log | while IFS= read -r line; do
        if [[ "$line" =~ Player\ Connected\ ([a-zA-Z0-9_]+) ]]; then
            local player_name="${BASH_REMATCH[1]}"
            if [[ "$player_name" == "SERVER" ]]; then
                continue
            fi

            ts_str="$(echo "$line" | awk '{print $1" "$2}')"
            ts_no_ms="${ts_str%.*}"
            conn_epoch="$(date -d "$ts_no_ms" +%s 2>/dev/null || echo 0)"

            echo "Player connected: $player_name (ts: $ts_no_ms)"

            local is_new_player="false"
            if add_player_if_new "$player_name"; then
                is_new_player="true"
            fi

            if [ "$is_new_player" = "true" ]; then
                echo "New player $player_name connected - server will handle welcome message"
                welcome_shown["$player_name"]=1
                # brand-new gets welcome bonus already; don't give login ticket now
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
            echo "Player disconnected: $player_name"
            unset welcome_shown["$player_name"]
            continue
        fi

        if [[ "$line" =~ ([a-zA-Z0-9_]+):\ (.+)$ ]]; then
            local player_name="${BASH_REMATCH[1]}"
            local message="${BASH_REMATCH[2]}"
            echo "Chat: $player_name: $message"
            add_player_if_new "$player_name"
            process_message "$player_name" "$message"
            continue
        fi

        # fallback
        echo "Other log line: $line"
    done

    # cleanup
    rm -f "$admin_pipe" 2>/dev/null || true
}

# -------------------------------------------------------------------------
# Entrypoint behavior
if [ "${1:-}" = "install" ] || [ $# -eq 0 ] && [ "$(basename "$0")" = "setup.sh" -o "$(basename "$0")" = "setup_self.sh" ]; then
    # Default install flow when running installer file directly
    if [ "$(id -u)" -ne 0 ]; then
        _err "Se requieren privilegios root para la instalación. Ejecuta con sudo."
        exit 1
    fi

    echo "================================================================"
    echo "The Blockheads Server Installer (single-file)"
    echo "Instalando como root pero los binarios y el servidor se colocarán en: $INSTALL_DIR (propietario: $ORIGINAL_USER)"
    echo "================================================================"

    install_requirements
    download_and_extract_server
    apply_patchelf_fixes
    create_economy_file
    install_self_symlink

    echo ""
    echo "INSTALACIÓN COMPLETADA."
    echo "Control del servidor disponible en: $BIN_SYMLINK"
    echo "Para crear un mundo (hazlo como $ORIGINAL_USER):"
    echo "  su - $ORIGINAL_USER -s /bin/bash -c 'cd \"$INSTALL_DIR\" && ./blockheads_server171 -n WORLD_NAME'"
    echo ""
    echo "Para iniciar servidor y bot:"
    echo "  $BIN_SYMLINK start WORLD_NAME [PORT]"
    echo ""
    exit 0
fi

# If script was invoked as the installed controller (/usr/local/bin/blockheadsctl)
case "${1:-}" in
    start)
        if [ "$(id -u)" -ne 0 ]; then
            # allow non-root user to start/stop; but starting may need to signal processes, so allow user
            # If running not as root, we still can run start (it will run screen as ORIGINAL_USER).
            true
        fi
        if [ -z "${2:-}" ]; then
            _err "Uso: $BIN_SYMLINK start WORLD_ID [PORT]"
            exit 1
        fi
        start_server "$2" "${3:-$DEFAULT_PORT}"
        ;;
    stop)
        stop_server_and_bot
        ;;
    status)
        show_status
        ;;
    bot)
        # internal: launched inside screen by start_bot
        if [ -z "${2:-}" ]; then
            _err "Usage: $0 bot /path/to/console.log"
            exit 1
        fi
        monitor_log "$2"
        ;;
    *)
        echo "Uso: $BIN_SYMLINK start|stop|status"
        echo "  start WORLD_ID [PORT] - Inicia servidor + bot"
        echo "  stop                  - Detiene servidor y bot"
        echo "  status                - Muestra estado"
        exit 1
        ;;
esac
