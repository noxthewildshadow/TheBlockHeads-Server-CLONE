#!/bin/bash

# Configuración
SERVER_BINARY="./blockheads_server171"
DEFAULT_PORT=12153
SCREEN_SERVER="blockheads_server"
SCREEN_BOT="blockheads_bot"

show_usage() {
    echo "Uso: $0 start [WORLD_ID] [PORT]"
    echo "  start WORLD_ID PORT - Inicia el servidor y el bot con el mundo y puerto especificados"
    echo "  stop                - Detiene el servidor y el bot"
    echo "  status              - Muestra el estado del servidor y bot"
    echo "  help                - Muestra esta ayuda"
    echo ""
    echo "Nota: Primero debes crear un mundo manualmente con:"
    echo "  ./blockheads_server171 -n"
}

is_port_in_use() {
    local port="$1"
    if lsof -Pi ":$port" -sTCP:LISTEN -t >/dev/null ; then
        return 0
    else
        return 1
    fi
}

free_port() {
    local port="$1"
    echo "Intentando liberar el puerto $port..."
    local pids=$(lsof -ti ":$port")
    if [ -n "$pids" ]; then
        echo "Encontrados procesos usando el puerto $port: $pids"
        kill -9 $pids 2>/dev/null || true
        sleep 2
    fi
    killall screen 2>/dev/null || true
    if is_port_in_use "$port"; then
        echo "ERROR: No se pudo liberar el puerto $port"
        return 1
    else
        echo "Puerto $port liberado correctamente"
        return 0
    fi
}

check_world_exists() {
    local world_id="$1"
    local saves_dir="$HOME/GNUstep/Library/ApplicationSupport/TheBlockheads/saves"
    local world_dir="$saves_dir/$world_id"
    if [ ! -d "$world_dir" ]; then
        echo "Error: El mundo '$world_id' no existe."
        echo "Primero crea un mundo con: ./blockheads_server171 -n"
        return 1
    fi
    return 0
}

start_server() {
    local world_id="$1"
    local port="${2:-$DEFAULT_PORT}"

    if is_port_in_use "$port"; then
        echo "El puerto $port está en uso."
        if ! free_port "$port"; then
            echo "No se puede iniciar el servidor. El puerto $port no está disponible."
            return 1
        fi
    fi

    killall screen 2>/dev/null || true
    sleep 1

    if ! check_world_exists "$world_id"; then
        return 1
    fi

    local log_dir="$HOME/GNUstep/Library/ApplicationSupport/TheBlockheads/saves/$world_id"
    local log_file="$log_dir/console.log"
    mkdir -p "$log_dir"

    echo "Iniciando servidor con mundo: $world_id, puerto: $port"
    echo "$world_id" > world_id.txt

    screen -dmS "$SCREEN_SERVER" bash -c "
        while true; do
            echo \"[$(date '+%Y-%m-%d %H:%M:%S')] Iniciando servidor...\"
            if $SERVER_BINARY -o '$world_id' -p $port 2>&1 | tee -a '$log_file'; then
                echo \"[$(date '+%Y-%m-%d %H:%M:%S')] Servidor cerrado normalmente.\"
            else
                exit_code=\$?
                echo \"[$(date '+%Y-%m-%d %H:%M:%S')] Servidor falló con código: \$exit_code\"
                if [ \$exit_code -eq 1 ] && tail -n 5 '$log_file' | grep -q \"port.*already in use\"; then
                    echo \"[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: Puerto ya en uso. No se reintentará.\"
                    break
                fi
            fi
            echo \"[$(date '+%Y-%m-%d %H:%M:%S')] Reiniciando en 5 segundos...\"
            sleep 5
        done
    "

    echo "Esperando a que el servidor inicie..."
    local wait_time=0
    while [ ! -f "$log_file" ] && [ $wait_time -lt 10 ]; do
        sleep 1
        ((wait_time++))
    done

    if [ ! -f "$log_file" ]; then
        echo "ERROR: No se pudo crear el archivo de log. El servidor puede no haber iniciado."
        return 1
    fi

    if grep -q "Failed to start server\|port.*already in use" "$log_file"; then
        echo "ERROR: El servidor no pudo iniciarse. Verifique el puerto $port."
        return 1
    fi

    start_bot "$log_file"

    echo "Servidor iniciado correctamente."
    echo "Para ver la consola: screen -r $SCREEN_SERVER"
    echo "Para ver el bot: screen -r $SCREEN_BOT"
}

start_bot() {
    local log_file="$1"

    if screen -list | grep -q "$SCREEN_BOT"; then
        echo "El bot ya está ejecutándose."
        return 0
    fi

    echo "Esperando a que el servidor esté listo..."
    sleep 5

    screen -dmS "$SCREEN_BOT" bash -c "
        echo 'Iniciando bot del servidor...'
        ./bot_server.sh '$log_file'
    "

    echo "Bot iniciado correctamente."
}

stop_server() {
    if screen -list | grep -q "$SCREEN_SERVER"; then
        screen -S "$SCREEN_SERVER" -X quit
        echo "Servidor detenido."
    else
        echo "El servidor no estaba ejecutándose."
    fi

    if screen -list | grep -q "$SCREEN_BOT"; then
        screen -S "$SCREEN_BOT" -X quit
        echo "Bot detenido."
    else
        echo "El bot no estaba ejecutándose."
    fi

    pkill -f "$SERVER_BINARY" 2>/dev/null || true
    pkill -f "tail -n 0 -F" 2>/dev/null || true
    killall screen 2>/dev/null || true
}

show_status() {
    echo "=== ESTADO DEL SERVIDOR THE BLOCKHEADS ==="
    if screen -list | grep -q "$SCREEN_SERVER"; then
        echo "Servidor: EJECUTÁNDOSE"
    else
        echo "Servidor: DETENIDO"
    fi
    if screen -list | grep -q "$SCREEN_BOT"; then
        echo "Bot: EJECUTÁNDOSE"
    else
        echo "Bot: DETENIDO"
    fi
    if [ -f "world_id.txt" ]; then
        WORLD_ID=$(cat world_id.txt)
        echo "Mundo actual: $WORLD_ID"
        if screen -list | grep -q "$SCREEN_SERVER"; then
            echo "Para ver la consola: screen -r $SCREEN_SERVER"
            echo "Para ver el bot: screen -r $SCREEN_BOT"
        fi
    fi
    echo "========================================"
}

case "$1" in
    start)
        if [ -z "$2" ]; then
            echo "Error: Debes especificar el WORLD_ID"
            show_usage
            exit 1
        fi
        start_server "$2" "$3"
        ;;
    stop)
        stop_server
        ;;
    status)
        show_status
        ;;
    help|*)
        show_usage
        ;;
esac
