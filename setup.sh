#!/usr/bin/env bash
set -euo pipefail

# INSTALLER SEGURO para The Blockheads server en Ubuntu 22.04
# Crea usuario 'blockheads', descarga y verifica binario, prepara directorios y permisos.

EXPECTED_SHA256=""   # <-- Pega aquí el SHA256 esperado del archivo .tar.gz (obligatorio para instalar)
SERVER_URL="https://web.archive.org/web/20240309015235if_/https://majicdave.com/share/blockheads_server171.tar.gz"
TEMP_FILE="/tmp/blockheads_server171.tar.gz"
EXTRACT_DIR="/tmp/blockheads_extract_$$"
INSTALL_DIR="/opt/blockheads"
SERVICE_USER="blockheads"
SERVICE_GROUP="blockheads"
SERVER_BINARY_NAME="blockheads_server171"

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: Este instalador debe correr como root (sudo)."
  exit 1
fi

if [ -z "$EXPECTED_SHA256" ]; then
  echo "ERROR: Debes fijar EXPECTED_SHA256 en el script con el SHA256 del archivo que confías."
  echo "Esto evita que se instale un binario manipulado."
  exit 1
fi

# 1) Dependencias
apt-get update -y
DEPS=(libgnustep-base1.28 libdispatch0 patchelf wget jq screen ss lsof)
apt-get install -y "${DEPS[@]}"

# 2) Crear usuario de servicio (si no existe)
if ! id -u "$SERVICE_USER" >/dev/null 2>&1; then
  useradd --system --create-home --home-dir /home/"$SERVICE_USER" --shell /usr/sbin/nologin "$SERVICE_USER"
  echo "Usuario $SERVICE_USER creado."
fi

mkdir -p "$INSTALL_DIR"
chown "$SERVICE_USER":"$SERVICE_GROUP" "$INSTALL_DIR"
chmod 750 "$INSTALL_DIR"

# 3) Descargar en /tmp y verificar SHA256
rm -f "$TEMP_FILE"
echo "Descargando servidor..."
wget --https-only -q -O "$TEMP_FILE" "$SERVER_URL"

echo "Verificando SHA256..."
calc_sha256=$(sha256sum "$TEMP_FILE" | awk '{print $1}')
if [ "$calc_sha256" != "$EXPECTED_SHA256" ]; then
  echo "ERROR: SHA256 mismatch. Esperado: $EXPECTED_SHA256  Obtenido: $calc_sha256"
  rm -f "$TEMP_FILE"
  exit 1
fi
echo "SHA256 verificado."

# 4) Extraer a directorio temporal
rm -rf "$EXTRACT_DIR"
mkdir -p "$EXTRACT_DIR"
tar xzf "$TEMP_FILE" -C "$EXTRACT_DIR"

# 5) Mover archivos al INSTALL_DIR de forma segura
# Usa modo seguro para evitar sobrescribir archivos críticos.
shopt -s dotglob
for f in "$EXTRACT_DIR"/*; do
  if [ -e "$f" ]; then
    # Copiar y ajustar permisos
    cp -r "$f" "$INSTALL_DIR/"
  fi
done
shopt -u dotglob

# 6) Buscar binario, renombrar si es necesario
cd "$INSTALL_DIR"
if [ ! -x "$SERVER_BINARY_NAME" ]; then
  alt=$(find . -maxdepth 2 -type f -executable -iname "*blockheads*" | head -n1 || true)
  if [ -n "$alt" ]; then
    mv "$alt" "$SERVER_BINARY_NAME"
  else
    echo "ERROR: No se encontró el binario del servidor en el paquete."
    exit 1
  fi
fi
chmod 750 "$SERVER_BINARY_NAME"
chown "$SERVICE_USER":"$SERVICE_GROUP" "$SERVER_BINARY_NAME"

# 7) Instalar helper scripts (si vienen en el paquete) con permisos restringidos
for s in start_server.sh bot_server.sh stop_server.sh; do
  if [ -f "$s" ]; then
    chmod 750 "$s"
    chown "$SERVICE_USER":"$SERVICE_GROUP" "$s"
  fi
done

# 8) Crear directorios runtime seguros
mkdir -p /var/lib/blockheads
chown "$SERVICE_USER":"$SERVICE_GROUP" /var/lib/blockheads
chmod 750 /var/lib/blockheads

mkdir -p /var/log/blockheads
chown "$SERVICE_USER":"$SERVICE_GROUP" /var/log/blockheads
chmod 750 /var/log/blockheads

# 9) Limpiar
rm -rf "$EXTRACT_DIR"
rm -f "$TEMP_FILE"

cat <<EOF
INSTALACIÓN COMPLETA.
Archivos instalados en: $INSTALL_DIR
Usuario servicio: $SERVICE_USER

Siguientes pasos recomendados:
  - Revisar y completar EXPECTED_SHA256 en este script para futuras instalaciones.
  - Revisar systemd unit opcional (blockheads.service) y habilitarlo.
  - No ejecutar el servidor como root: use el usuario '$SERVICE_USER'.
EOF

exit 0
