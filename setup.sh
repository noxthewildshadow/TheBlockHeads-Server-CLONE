#!/usr/bin/env bash
# setup.sh - Instalador/gestor todo-en-uno para TheBlockHeads Server
# Autor: Generado por ChatGPT (entregado al usuario)
# Fecha: 2025-08-22
#
# Funcionalidad:
#  - install: instala la aplicación (descarga o usa archivo local), crea usuario, configura systemd, logs, permisos.
#  - start/stop/status/restart: control del servicio systemd (si se creó) o arranque directo.
#  - update: actualiza desde URL/archivo (hace backup de la versión actual).
#  - uninstall: detiene, quita servicio, elimina archivos opcionales (pregunta antes).
#
# Recomendación: ejecutar en entorno de pruebas antes de producción.
set -euo pipefail
IFS=$'\n\t'

# ---------------------------
# Valores por defecto
# ---------------------------
INSTALL_DIR="/opt/blockheads"
SERVICE_NAME="blockheads"
SERVICE_USER="blockheads"
SERVICE_GROUP="$SERVICE_USER"
BIN_NAME=""               # si se conoce, se puede pasar; si no, el script buscará ejecutables en el paquete
WORLD_NAME=""             # obligatorio al iniciar (ver mensaje)
DEFAULT_PORT=12153
LOG_DIR="/var/log/${SERVICE_NAME}"
BACKUP_DIR="/var/backups/${SERVICE_NAME}"
TEMP_DIR=""
SYSTEMCTL_BIN="$(command -v systemctl || true)"
PACKAGE_MANAGER=""        # detectado más abajo
DOWNLOAD_CMD=""
OS_FAMILY=""

# ---------------------------
# Utilidades / mensajes
# ---------------------------
log()   { echo -e "[setup] $*"; }
info()  { echo -e "\e[34m[info]\e[0m $*"; }
warn()  { echo -e "\e[33m[warn]\e[0m $*"; }
err()   { echo -e "\e[31m[err]\e[0m $*"; }
fatal() { err "$*"; exit 1; }

usage() {
cat <<EOF
Uso: sudo ./setup.sh <comando> [opciones]

Comandos:
  install    --binary-url URL | --local-file FILE   Instala el servidor.
             --checksum SHA256                      (opcional) sha256 para verificar descarga.
             --install-dir PATH                     (opcional) directorio de instalación. Default: /opt/blockheads
             --user NAME                             (opcional) user de sistema. Default: blockheads
             --service-name NAME                     (opcional) nombre del servicio systemd. Default: blockheads
             --port PORT                             (opcional) puerto por defecto. Default: 12153
             --world-name NAME                       (recomendado) nombre del mundo a crear/iniciar.
  start      [--world-name NAME] [--port PORT]      Inicia el servidor via systemd (si existe) o directo.
  stop                                               Detiene el servidor.
  restart                                            Reinicia servidor.
  status                                             Muestra estado del servicio.
  update    --binary-url URL | --local-file FILE    Actualiza la instalación (hace backup).
  uninstall                                          Quitar instalación (pregunta confirmación).
  help                                               Muestra esta ayuda.

Ejemplo de instalación (modo no interactivo):
  sudo ./setup.sh install --binary-url "https://example.com/blockheads.tar.gz" --checksum "SHA256HERE" --world-name "MiMundo"

EOF
}

# ---------------------------
# Helpers
# ---------------------------
require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    fatal "Este script debe ejecutarse como root (sudo)."
  fi
}

detect_pkg_mgr_and_tools() {
  if command -v apt-get >/dev/null 2>&1; then
    PACKAGE_MANAGER="apt"
    OS_FAMILY="debian"
  elif command -v yum >/dev/null 2>&1 || command -v dnf >/dev/null 2>&1; then
    PACKAGE_MANAGER="yum"
    OS_FAMILY="redhat"
  elif command -v pacman >/dev/null 2>&1; then
    PACKAGE_MANAGER="pacman"
    OS_FAMILY="arch"
  else
    PACKAGE_MANAGER=""
    OS_FAMILY="unknown"
  fi

  if command -v curl >/dev/null 2>&1; then
    DOWNLOAD_CMD="curl -fsSL"
  elif command -v wget >/dev/null 2>&1; then
    DOWNLOAD_CMD="wget -qO-"
  else
    DOWNLOAD_CMD=""
  fi
}

ensure_commands() {
  local cmds=("tar" "sha256sum" "useradd" "chown" "chmod" "systemctl" "mktemp" "lsof" "grep" "awk")
  # patchelf is optional (only if binary needs patching)
  local missing=()
  for c in "${cmds[@]}"; do
    if ! command -v "$c" >/dev/null 2>&1; then
      missing+=("$c")
    fi
  done

  if [ "${#missing[@]}" -ne 0 ]; then
    warn "Faltan comandos: ${missing[*]}. Intentando instalarlos (según el package manager)."
    if [ -z "$PACKAGE_MANAGER" ]; then
      warn "No se detectó un gestor de paquetes compatible. Instala manualmente: ${missing[*]}"
      return 1
    fi

    case "$PACKAGE_MANAGER" in
      apt)
        apt-get update -y
        apt-get install -y "${missing[@]}"
        ;;
      yum)
        yum install -y "${missing[@]}"
        ;;
      pacman)
        pacman -Sy --noconfirm "${missing[@]}"
        ;;
      *)
        warn "Gestor de paquetes no soportado por el instalador automático. Instala manualmente: ${missing[*]}"
        return 1
        ;;
    esac
  fi
  return 0
}

mktempdir() {
  TEMP_DIR="$(mktemp -d /tmp/blockheads.XXXXXX)"
  trap 'cleanup' EXIT INT TERM
}

cleanup() {
  if [ -n "${TEMP_DIR:-}" ] && [ -d "$TEMP_DIR" ]; then
    rm -rf "$TEMP_DIR" || true
  fi
}

safe_mv_with_backup() {
  local src="$1" dst="$2"
  if [ -e "$dst" ]; then
    mkdir -p "$BACKUP_DIR"
    local ts
    ts="$(date +%Y%m%d_%H%M%S)"
    mv "$dst" "${dst}.bak_${ts}"
    info "Backup: ${dst} -> ${dst}.bak_${ts}"
  fi
  mv "$src" "$dst"
}

# ---------------------------
# Core: extracción e instalación
# ---------------------------
install_from_archive() {
  local archive_path="$1"
  local checksum_expected="${2:-}"
  local install_dir="$3"
  local service_user="$4"
  local service_group="$5"

  mkdir -p "$install_dir"
  mkdir -p "$LOG_DIR"
  mkdir -p "$BACKUP_DIR"

  # Validar checksum si se proporcionó
  if [ -n "$checksum_expected" ]; then
    info "Verificando checksum SHA256 de $archive_path..."
    if ! sha256sum -c <<<"${checksum_expected}  ${archive_path}" >/dev/null 2>&1; then
      fatal "Checksum SHA256 no coincide. Aborting."
    fi
    info "Checksum OK."
  fi

  # Extraer en temp
  mktempdir
  info "Extrayendo $archive_path a $TEMP_DIR..."
  tar -xzf "$archive_path" -C "$TEMP_DIR"

  # Buscar binarios ejecutables dentro del temp
  info "Buscando binarios ejecutables dentro del paquete..."
  local found_bins
  mapfile -t found_bins < <(find "$TEMP_DIR" -type f -perm /111 -maxdepth 4 -iname "*blockheads*" -print || true)

  if [ "${#found_bins[@]}" -eq 0 ]; then
    # si no encontró por nombre, buscar cualquier ejecutable
    mapfile -t found_bins < <(find "$TEMP_DIR" -type f -perm /111 -maxdepth 4 -print || true)
  fi

  if [ "${#found_bins[@]}" -eq 0 ]; then
    fatal "No se encontraron ejecutables en el paquete. Revisa el contenido del archivo."
  fi

  # Elegir el binario principal. Si hay varios, mostrar y pedir confirmación
  BIN_PATH="${found_bins[0]}"
  if [ "${#found_bins[@]}" -gt 1 ]; then
    info "Se encontraron múltiples ejecutables. Seleccionando el primero por defecto:"
    for i in "${!found_bins[@]}"; do
      echo "  [$i] ${found_bins[$i]}"
    done
    echo "Puedes editar el archivo .bin_path después de la instalación si deseas otro."
  fi

  # Backup de instalación previa (si existe)
  if [ -d "$install_dir" ] && [ "$(ls -A "$install_dir")" ]; then
    info "Directorio de instalación existente. Haciendo backup de $install_dir en $BACKUP_DIR"
    local ts
    ts="$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$BACKUP_DIR/$ts"
    cp -a "$install_dir/"* "$BACKUP_DIR/$ts/" || true
  fi

  # Copiar archivos al install_dir
  info "Copiando archivos a $install_dir..."
  rsync -a --delete "$TEMP_DIR"/ "$install_dir"/

  # Asegurar ownership y permisos
  if ! id -u "$service_user" >/dev/null 2>&1; then
    info "Usuario $service_user no existe; creando (system account, sin login)."
    useradd --system --no-create-home --home-dir "$install_dir" --shell /usr/sbin/nologin "$service_user" || true
  fi
  chown -R "$service_user:$service_group" "$install_dir"
  find "$install_dir" -type d -exec chmod 0755 {} \;
  find "$install_dir" -type f -exec chmod 0644 {} \;
  # Ejecutables: conservar permisos ejecutables
  for f in $(find "$install_dir" -type f -perm /111 -print || true); do
    chmod 0755 "$f" || true
  done

  info "Instalación copia completada."
  # Guardar ruta del binario principal detectado en archivo de config
  local detected_bin_rel
  detected_bin_rel="$(realpath --relative-to="$install_dir" "$BIN_PATH" 2>/dev/null || true)"
  echo "$detected_bin_rel" >"$install_dir/.bin_path" || true
  info "Binario principal detectado: $detected_bin_rel (guardado en $install_dir/.bin_path)"
}

# ---------------------------
# systemd unit creation
# ---------------------------
install_systemd_unit() {
  local install_dir="$1"
  local svc_name="$2"
  local svc_user="$3"
  local port="$4"
  local world_name="$5"

  local unit_path="/etc/systemd/system/${svc_name}.service"
  local bin_rel
  bin_rel="$(cat "$install_dir/.bin_path" 2>/dev/null || true)"
  if [ -z "$bin_rel" ]; then
    fatal "No se encontró .bin_path en $install_dir. No puedo crear la unidad systemd."
  fi
  local exec_path="${install_dir%/}/${bin_rel}"

  # Verificaciones
  if [ ! -x "$exec_path" ]; then
    warn "Ejecutable $exec_path no existe o no es ejecutable. Revisa permisos."
  fi

  info "Creando unidad systemd en $unit_path ..."
  cat > "$unit_path" <<EOF
[Unit]
Description=TheBlockHeads Server
After=network.target

[Service]
Type=simple
User=${svc_user}
Group=${svc_user}
WorkingDirectory=${install_dir}
# ajusta flags de inicio según necesites
ExecStart=${exec_path} -n "${world_name}" -p "${port}"
Restart=on-failure
RestartSec=5
StandardOutput=append:${LOG_DIR}/server.log
StandardError=append:${LOG_DIR}/server.err
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

  chmod 644 "$unit_path"
  info "Recargando systemd..."
  systemctl daemon-reload
  info "Habilitando servicio para inicio automático..."
  systemctl enable "${svc_name}.service"
  info "Servicio creado: ${svc_name}.service"
}

# ---------------------------
# Start/Stop/Status helpers
# ---------------------------
service_start() {
  local svc_name="$1"
  if [ -n "$SYSTEMCTL_BIN" ] && command -v systemctl >/dev/null 2>&1; then
    info "Iniciando servicio systemd ${svc_name}..."
    systemctl start "${svc_name}.service"
    systemctl status "${svc_name}.service" --no-pager || true
  else
    fatal "systemd no disponible. Usa start-directo."
  fi
}

service_stop() {
  local svc_name="$1"
  if [ -n "$SYSTEMCTL_BIN" ] && command -v systemctl >/dev/null 2>&1; then
    info "Deteniendo servicio systemd ${svc_name}..."
    systemctl stop "${svc_name}.service"
    systemctl status "${svc_name}.service" --no-pager || true
  else
    fatal "systemd no disponible. Usa stop-directo."
  fi
}

service_status() {
  local svc_name="$1"
  if [ -n "$SYSTEMCTL_BIN" ] && command -v systemctl >/dev/null 2>&1; then
    systemctl status "${svc_name}.service" --no-pager || true
  else
    fatal "systemd no disponible."
  fi
}

# ---------------------------
# Update / Uninstall
# ---------------------------
do_update() {
  local src="$1" checksum="$2"
  require_root
  detect_pkg_mgr_and_tools
  ensure_commands || warn "Algunas dependencias no pudieron instalarse automáticamente."

  if [ ! -d "$INSTALL_DIR" ]; then
    fatal "No hay instalación previa en $INSTALL_DIR. Usa install."
  fi

  local tmp_archive="$TEMP_DIR/update_archive.tar.gz"
  info "Preparando update..."
  mktempdir
  # Si src es URL
  if [[ "$src" =~ ^https?:// ]]; then
    if [ -z "$DOWNLOAD_CMD" ]; then
      fatal "No hay wget/curl para descargar la URL."
    fi
    info "Descargando $src ..."
    if command -v curl >/dev/null 2>&1; then
      curl -fL -o "$tmp_archive" "$src"
    else
      wget -qO "$tmp_archive" "$src"
    fi
  else
    # archivo local
    if [ ! -f "$src" ]; then
      fatal "Archivo local $src no encontrado."
    fi
    cp "$src" "$tmp_archive"
  fi

  if [ -n "$checksum" ]; then
    if ! sha256sum -c <<<"${checksum}  ${tmp_archive}" >/dev/null 2>&1; then
      fatal "Checksum no coincide para la actualización. Abortando."
    fi
  fi

  # backup ya lo maneja install_from_archive
  install_from_archive "$tmp_archive" "" "$INSTALL_DIR" "$SERVICE_USER" "$SERVICE_GROUP"
  info "Update completado."
  # reiniciar servicio si existe
  if command -v systemctl >/dev/null 2>&1 && systemctl is-enabled --quiet "${SERVICE_NAME}.service"; then
    info "Reiniciando servicio..."
    systemctl restart "${SERVICE_NAME}.service"
  fi
}

do_uninstall() {
  require_root
  read -rp "¿Estás seguro de que quieres desinstalar y eliminar $INSTALL_DIR y unidad systemd? (yes/[no]) " ans
  if [ "$ans" != "yes" ]; then
    info "Aborting uninstall."
    return 0
  fi

  if systemctl list-units --full -all | grep -q "${SERVICE_NAME}.service"; then
    info "Deteniendo servicio..."
    systemctl stop "${SERVICE_NAME}.service" || true
    systemctl disable "${SERVICE_NAME}.service" || true
    rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
    systemctl daemon-reload || true
  fi

  read -rp "¿Eliminar directorio de instalación $INSTALL_DIR ? (yes/[no]) " ans2
  if [ "$ans2" = "yes" ]; then
    rm -rf "$INSTALL_DIR"
    info "Eliminado $INSTALL_DIR"
  else
    info "No se eliminó $INSTALL_DIR"
  fi

  read -rp "¿Eliminar logs en $LOG_DIR ? (yes/[no]) " ans3
  if [ "$ans3" = "yes" ]; then
    rm -rf "$LOG_DIR"
    info "Logs eliminados."
  else
    info "Logs preservados."
  fi

  info "Uninstall finalizado."
}

# ---------------------------
# Argument parsing simple
# ---------------------------
if [ $# -lt 1 ]; then
  usage
  exit 0
fi

CMD="$1"; shift || true

# Parse global-ish flags for commands that accept them
# We'll use a simple parser: options like --binary-url, --local-file, --checksum, --install-dir, --user, --service-name, --port, --world-name
while (( "$#" )); do
  case "$1" in
    --binary-url) BINARY_URL="$2"; shift 2;;
    --local-file) LOCAL_FILE="$2"; shift 2;;
    --checksum) CHECKSUM="$2"; shift 2;;
    --install-dir) INSTALL_DIR="$2"; shift 2;;
    --user) SERVICE_USER="$2"; SERVICE_GROUP="$2"; shift 2;;
    --service-name) SERVICE_NAME="$2"; shift 2;;
    --port) DEFAULT_PORT="$2"; shift 2;;
    --world-name) WORLD_NAME="$2"; shift 2;;
    --help|-h) usage; exit 0;;
    *) # unknown option assumed as positional remainder
       shift
       ;;
  esac
done

# Ejecutar comando solicitado
case "$CMD" in
  install)
    require_root
    detect_pkg_mgr_and_tools
    ensure_commands || warn "Algunas utilidades requeridas no pudieron instalarse automáticamente; instala manualmente tar, sha256sum, rsync, useradd, systemctl..."

    mkdir -p "$LOG_DIR"
    mkdir -p "$BACKUP_DIR"

    # Validar fuente (local o remote)
    if [ -n "${LOCAL_FILE:-}" ]; then
      if [ ! -f "$LOCAL_FILE" ]; then
        fatal "Archivo local $LOCAL_FILE no encontrado."
      fi
      ARCHIVE_PATH="$LOCAL_FILE"
    elif [ -n "${BINARY_URL:-}" ]; then
      mktempdir
      ARCHIVE_PATH="${TEMP_DIR}/download.tar.gz"
      info "Descargando desde $BINARY_URL ..."
      if command -v curl >/dev/null 2>&1; then
        curl -fL -o "$ARCHIVE_PATH" "$BINARY_URL"
      else
        wget -qO "$ARCHIVE_PATH" "$BINARY_URL"
      fi
      info "Descarga completada: $ARCHIVE_PATH"
    else
      fatal "Provee --binary-url <URL> o --local-file <archivo.tar.gz>"
    fi

    # Llamar al instalador
    install_from_archive "$ARCHIVE_PATH" "${CHECKSUM:-}" "$INSTALL_DIR" "$SERVICE_USER" "$SERVICE_GROUP"

    # Crear unidad systemd si systemd está disponible
    if command -v systemctl >/dev/null 2>&1; then
      if [ -z "$WORLD_NAME" ]; then
        warn "No se proporcionó --world-name. La unidad systemd se creará, pero debes editar /etc/systemd/system/${SERVICE_NAME}.service para añadir -n <NOMBRE_MUNDO> o reiniciarla con parámetros."
      fi
      install_systemd_unit "$INSTALL_DIR" "$SERVICE_NAME" "$SERVICE_USER" "$DEFAULT_PORT" "${WORLD_NAME:-MyWorld}"
      info "Inicio automático configurado. Usa: systemctl start ${SERVICE_NAME}.service"
    else
      warn "systemd no disponible en este sistema; no se creó unidad. Usa ./setup.sh start para iniciar manualmente."
    fi

    info "Instalación finalizada. Revisa logs en $LOG_DIR"
    ;;

  start)
    # start: si existe systemd service, usa systemd; si no, arranca en foreground como user service_user
    if command -v systemctl >/dev/null 2>&1 && systemctl list-units --full -all | grep -q "${SERVICE_NAME}.service"; then
      service_start "$SERVICE_NAME"
    else
      # arranque directo (no-recomendado para producción)
      info "Iniciando en modo directo (sin systemd)."
      if [ -f "${INSTALL_DIR}/.bin_path" ]; then
        bin_rel="$(cat "${INSTALL_DIR}/.bin_path")"
        exec_path="${INSTALL_DIR%/}/${bin_rel}"
        if [ ! -x "$exec_path" ]; then
          fatal "Ejecutable no encontrado o no tiene permiso de ejecución: $exec_path"
        fi
        if [ -z "${WORLD_NAME}" ]; then
          fatal "Para start directo, pasa --world-name NOMBRE con el comando start."
        fi
        info "Ejecutando: sudo -u ${SERVICE_USER} ${exec_path} -n \"${WORLD_NAME}\" -p \"${DEFAULT_PORT}\" &"
        mkdir -p "$LOG_DIR"
        sudo -u "${SERVICE_USER}" bash -c "nohup \"${exec_path}\" -n \"${WORLD_NAME}\" -p \"${DEFAULT_PORT}\" >> \"${LOG_DIR}/server.log\" 2>>\"${LOG_DIR}/server.err\" & echo \$! > \"${LOG_DIR}/server.pid\""
        info "Servidor iniciado (modo directo). PID guardado en ${LOG_DIR}/server.pid"
      else
        fatal "No se encuentra ${INSTALL_DIR}/.bin_path. Haz install primero."
      fi
    fi
    ;;

  stop)
    if command -v systemctl >/dev/null 2>&1 && systemctl list-units --full -all | grep -q "${SERVICE_NAME}.service"; then
      service_stop "$SERVICE_NAME"
    else
      info "Deteniendo proceso directo (usando PID en ${LOG_DIR}/server.pid)"
      if [ -f "${LOG_DIR}/server.pid" ]; then
        pid="$(cat "${LOG_DIR}/server.pid")"
        if kill -0 "$pid" >/dev/null 2>&1; then
          kill "$pid"
          sleep 2
          if kill -0 "$pid" >/dev/null 2>&1; then
            kill -9 "$pid" || true
          fi
          info "Proceso $pid detenido."
          rm -f "${LOG_DIR}/server.pid"
        else
          warn "PID $pid no existe. Eliminando archivo pid."
          rm -f "${LOG_DIR}/server.pid"
        fi
      else
        warn "No se encontró ${LOG_DIR}/server.pid"
      fi
    fi
    ;;

  restart)
    "$0" stop
    sleep 1
    "$0" start
    ;;

  status)
    if command -v systemctl >/dev/null 2>&1 && systemctl list-units --full -all | grep -q "${SERVICE_NAME}.service"; then
      service_status "$SERVICE_NAME"
    else
      if [ -f "${LOG_DIR}/server.pid" ]; then
        pid="$(cat "${LOG_DIR}/server.pid")"
        if kill -0 "$pid" >/dev/null 2>&1; then
          info "Proceso en ejecución. PID: $pid"
        else
          warn "Archivo PID existe pero proceso no está en ejecución."
        fi
      else
        info "No hay servicio systemd ni PID directo."
      fi
    fi
    ;;

  update)
    # Uso: ./setup.sh update --binary-url URL [--checksum SHA256]  (o --local-file)
    if [ -n "${LOCAL_FILE:-}" ]; then
      if [ ! -f "$LOCAL_FILE" ]; then fatal "Archivo local $LOCAL_FILE no encontrado."; fi
      mktempdir
      do_update "$LOCAL_FILE" "${CHECKSUM:-}"
    elif [ -n "${BINARY_URL:-}" ]; then
      mktempdir
      do_update "$BINARY_URL" "${CHECKSUM:-}"
    else
      fatal "Provee --binary-url o --local-file para update."
    fi
    ;;

  uninstall)
    do_uninstall
    ;;

  help|--help|-h)
    usage
    ;;

  *)
    fatal "Comando desconocido: $CMD"
    ;;
esac

exit 0
