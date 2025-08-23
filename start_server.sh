#!/usr/bin/env bash
set -euo pipefail

# start_server.sh endurecido
INSTALL_DIR="/opt/blockheads"
SERVER_BINARY="$INSTALL_DIR/blockheads_server171"
SERVICE_USER="blockheads"
DEFAULT_PORT=12153
SCREEN_SERVER="blockheads_server"
SCREEN_BOT="blockheads_bot"
WORLD_BASE="/home/$SERVICE_USER/GNUstep/Library/ApplicationSupport/TheBlockheads/saves"  # ruta fija

usage() {
  cat <<EOF
Uso: $0 start WORLD_ID [PORT]
       $0 stop
       $0 status
EOF
}

ensure_user() {
  if [ "$(id -u)" -eq 0 ]; then
    true
  else
    echo "Este script debe ejecutarse con sudo/root para administrar la pantalla, pero el servidor se ejecutará como $SERVICE_USER"
  fi
}

is_port_in_use() {
  local port="$1"
  ss -ltn "( sport = :$port )" | awk 'NR>1 {print $1}' | grep -q . && return 0 || return 1
}

free_port() {
  local port="$1"
  echo "Intentando liberar puerto $port de forma segura..."
  # busca procesos que estén escuchando ese puerto y termina solo los que coincidan con el binario del servicio
  local pids
  pids=$(ss -ltnp "( sport = :$port )" 2>/dev/null | awk -F',' '/users:/{print $2}' | sed -E 's/.*pid=([0-9]+).*/\1/' | tr '\n' ' ' || true)
  if [ -n "$pids" ]; then
    for pid in $pids; do
      if ps -p "$pid" -o comm= | grep -qi "blockheads"; then
        echo "Terminando PID $pid"
        kill "$pid" || kill -9 "$pid" || true
      else
        echo "PID $pid no parece ser blockheads; no lo mataré."
      fi
    done
  fi
  sleep 1
  if is_port_in_use "$port"; then
    echo "ERROR: El puerto $port sigue ocupado."
    return 1
  fi
  return 0
}

sanitize_world() {
  local w="$1"
  if [[ "$w" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "$w"
  else
    return 1
  fi
}

check_world_exists() {
  local world="$1"
  local path="$WORLD_BASE/$world"
  if [ ! -d "$path" ]; then
    echo "ERROR: Mundo no encontrado en $path"
    return 1
  fi
  return 0
}

start_server() {
  local world="$1"
  local port="${2:-$DEFAULT_PORT}"

  if ! sanitize_world "$world"; then
    echo "WORLD_ID inválido: $world"
    exit 1
  fi

  if is_port_in_use "$port"; then
    echo "Puerto $port en uso. Intentando liberar..."
    if ! free_port "$port"; then
      echo "No se pudo liberar puerto $port."
      exit 1
    fi
  fi

  if [ ! -x "$SERVER_BINARY" ]; then
    echo "ERROR: no se encontró el binario en $SERVER_BINARY"
    exit 1
  fi

  if ! check_world_exists "$world"; then
    exit 1
  fi

  # Iniciar servidor en screen como usuario no root (usar sudo -u)
  echo "Iniciando servidor (usuario: $SERVICE_USER) mundo: $world puerto: $port"
  sudo -u "$SERVICE_USER" bash -c "
    cd '$INSTALL_DIR' || exit 1
    screen -dmS '$SCREEN_SERVER' bash -lc '
      umask 027
      while true; do
        echo \"[\$(date +\"%F %T\")] Iniciando servidor...\"
        exec ./${SERVER_BINARY#./} -o \"${world}\" -p ${port} 2>&1 | tee -a \"/var/log/blockheads/${world}_console.log\"
        echo \"[\$(date +\"%F %T\")] Servidor finalizó, saliendo del bucle.\"
        sleep 5
      done
    '
  "

  echo "Servidor iniciado. Para ver la consola: sudo -u $SERVICE_USER screen -r $SCREEN_SERVER"
  # Inicia el bot (opcional)
  sudo -u "$SERVICE_USER" bash -c "cd '$INSTALL_DIR' && ./bot_server.sh /var/log/blockheads/${world}_console.log &"
}

stop_server() {
  echo "Deteniendo servidor y bot..."
  # Detener screen sessions controladamente
  if screen -list | grep -q "$SCREEN_BOT"; then
    screen -S "$SCREEN_BOT" -X quit || true
  fi
  if screen -list | grep -q "$SCREEN_SERVER"; then
    screen -S "$SCREEN_SERVER" -X quit || true
  fi
  # pkill de procesos blockheads pertenecientes al usuario blockheads solamente
  pkill -u "$SERVICE_USER" -f "blockheads_server171" || true
  echo "Detenido."
}

status() {
  echo "Estado:"
  screen -list | grep -E "$SCREEN_SERVER|$SCREEN_BOT" || echo "No hay sesiones screen."
}

case "${1:-help}" in
  start)
    if [ -z "${2:-}" ]; then
      echo "Falta WORLD_ID"
      usage
      exit 1
    fi
    start_server "$2" "$3"
    ;;
  stop)
    stop_server
    ;;
  status)
    status
    ;;
  *)
    usage
    ;;
esac
