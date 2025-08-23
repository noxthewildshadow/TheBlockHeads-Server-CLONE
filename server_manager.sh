#!/bin/bash

# Configuración
SERVER_BINARY="./blockheads_server171"
DEFAULT_PORT=12153
SCREEN_SERVER="blockheads_server"
SCREEN_BOT="blockheads_bot"
ECONOMY_FILE="economy_data.json"

show_usage() {
    echo "Uso: $0 [comando]"
    echo "Comandos:"
    echo "  start [WORLD_ID] [PORT] - Inicia servidor y bot"
    echo "  stop                     - Detiene servidor y bot"
    echo "  status                   - Muestra estado del servidor"
    echo "  help                     - Muestra esta ayuda"
    echo ""
    echo "Nota: Primero crea un mundo con: ./blockheads_server171 -n"
}

is_port_in_use() {
    lsof -Pi ":$1" -sTCP:LISTEN -t >/dev/null
}

free_port() {
    local port="$1"
    echo "Liberando puerto $port..."
    local pids=$(lsof -ti ":$port")
    [ -n "$pids" ] && kill -9 $pids 2>/dev/null
    killall screen 2>/dev/null || true
    sleep 2
    ! is_port_in_use "$port"
}

check_world_exists() {
    local world_id="$1"
    local saves_dir="$HOME/GNUstep/Library/ApplicationSupport/TheBlockheads/saves"
    [ -d "$saves_dir/$world_id" ] || {
        echo "ERROR: Mundo '$world_id' no existe"
        echo "Crear primero con: ./blockheads_server171 -n"
        return 1
    }
}

start_server() {
    local world_id="$1"
    local port="${2:-$DEFAULT_PORT}"

    is_port_in_use "$port" && {
        echo "Puerto $port en uso."
        free_port "$port" || {
            echo "ERROR: No se pudo liberar puerto $port"
            return 1
        }
    }

    check_world_exists "$world_id" || return 1

    local log_dir="$HOME/GNUstep/Library/ApplicationSupport/TheBlockheads/saves/$world_id"
    local log_file="$log_dir/console.log"
    mkdir -p "$log_dir"

    echo "Iniciando servidor - Mundo: $world_id, Puerto: $port"
    echo "$world_id" > world_id.txt

    # Limpiar sesiones previas
    screen -S "$SCREEN_SERVER" -X quit 2>/dev/null || true
    screen -S "$SCREEN_BOT" -X quit 2>/dev/null || true

    # Iniciar servidor
    screen -dmS "$SCREEN_SERVER" bash -c "
        while true; do
            echo \"[\$(date '+%Y-%m-%d %H:%M:%S')] Iniciando servidor...\"
            if $SERVER_BINARY -o '$world_id' -p $port 2>&1 | tee -a '$log_file'; then
                echo \"[\$(date '+%Y-%m-%d %H:%M:%S')] Servidor cerrado normalmente\"
            else
                exit_code=\$?
                echo \"[\$(date '+%Y-%m-%d %H:%M:%S')] Servidor falló con código: \$exit_code\"
                if [ \$exit_code -eq 1 ] && tail -n 5 '$log_file' | grep -q \"port.*already in use\"; then
                    echo \"[\$(date '+%Y-%m-%d %H:%M:%S')] ERROR: Puerto ya en uso. No se reintentará.\"
                    break
                fi
            fi
            echo \"[\$(date '+%Y-%m-%d %H:%M:%S')] Reiniciando en 5 segundos...\"
            sleep 5
        done
    "

    # Esperar inicialización
    local wait_time=0
    while [ ! -f "$log_file" ] && [ $wait_time -lt 10 ]; do
        sleep 1
        ((wait_time++))
    done

    [ ! -f "$log_file" ] && {
        echo "ERROR: No se creó archivo de log"
        return 1
    }

    # Iniciar bot
    screen -dmS "$SCREEN_BOT" bash -c "
        echo 'Iniciando bot...'
        ./bot_server.sh '$log_file'
    "

    echo "Servidor iniciado correctamente"
    echo "Consola: screen -r $SCREEN_SERVER"
    echo "Bot: screen -r $SCREEN_BOT"
}

stop_server() {
    screen -S "$SCREEN_SERVER" -X quit 2>/dev/null && echo "Servidor detenido" || echo "El servidor no estaba en ejecución"
    screen -S "$SCREEN_BOT" -X quit 2>/dev/null && echo "Bot detenido" || echo "El bot no estaba en ejecución"
    pkill -f "$SERVER_BINARY" 2>/dev/null || true
}

show_status() {
    echo "=== ESTADO DEL SERVIDOR ==="
    screen -list | grep -q "$SCREEN_SERVER" && echo "Servidor: EJECUTANDOSE" || echo "Servidor: DETENIDO"
    screen -list | grep -q "$SCREEN_BOT" && echo "Bot: EJECUTANDOSE" || echo "Bot: DETENIDO"
    
    [ -f "world_id.txt" ] && {
        echo "Mundo actual: $(cat world_id.txt)"
        screen -list | grep -q "$SCREEN_SERVER" && {
            echo "Consola: screen -r $SCREEN_SERVER"
            echo "Bot: screen -r $SCREEN_BOT"
        }
    }
    echo "==========================="
}

# Manejo de comandos
case "$1" in
    start)
        [ -z "$2" ] && {
            echo "ERROR: Especificar WORLD_ID"
            show_usage
            exit 1
        }
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
