#!/bin/bash
# installer.sh - Verbose installer for The Blockheads server and helpers
# Run as root: sudo ./installer.sh
set -euo pipefail

echo "=== Installer: inicio ==="

if [ "$EUID" -ne 0 ]; then
  echo "ERROR: Este script requiere privilegios de root. Ejecuta: sudo $0"
  exit 1
fi

ORIGINAL_USER=${SUDO_USER:-$USER}
USER_HOME=$(getent passwd "$ORIGINAL_USER" | cut -d: -f6)
echo "Usuario original detectado: $ORIGINAL_USER (home: $USER_HOME)"

SERVER_URL="https://web.archive.org/web/20240309015235if_/https://majicdave.com/share/blockheads_server171.tar.gz"
TEMP_FILE="/tmp/blockheads_server171.tar.gz"
SERVER_BINARY="blockheads_server171"

RAW_BASE="https://raw.githubusercontent.com/noxthewildshadow/TheBlockHeads-Server-CLONE/refs/heads/main"
START_SCRIPT_URL="$RAW_BASE/start_server.sh"
BOT_SCRIPT_URL="$RAW_BASE/bot_server.sh"

echo ""
echo "[1/6] Actualizando y preparando paquetes..."
if command -v apt-get >/dev/null 2>&1; then
  echo "Usando apt-get para instalar dependencias..."
  apt-get update -y
  apt-get install -y wget jq screen lsof patchelf libgnustep-base1.28 libdispatch0 || {
    echo "Algunos paquetes no pudieron instalarse con apt-get. Continuando de todas formas."
  }
else
  echo "apt-get no disponible. Asegúrate manualmente de instalar: wget, jq, screen, lsof, patchelf (si es necesario)."
fi
echo "[1/6] Hecho."

echo ""
echo "[2/6] Descargando helper scripts (start_server.sh y bot_server.sh) si no existen localmente..."
if [ ! -f ./start_server.sh ]; then
  echo "Descargando start_server.sh..."
  if wget -q -O start_server.sh "$START_SCRIPT_URL"; then
    echo "start_server.sh descargado."
  else
    echo "Fallo al descargar start_server.sh desde $START_SCRIPT_URL"
  fi
else
  echo "start_server.sh ya existe localmente; no se sobrescribe."
fi

if [ ! -f ./bot_server.sh ]; then
  echo "Descargando bot_server.sh..."
  if wget -q -O bot_server.sh "$BOT_SCRIPT_URL"; then
    echo "bot_server.sh descargado."
  else
    echo "Fallo al descargar bot_server.sh desde $BOT_SCRIPT_URL"
  fi
else
  echo "bot_server.sh ya existe localmente; no se sobrescribe."
fi
chmod +x start_server.sh bot_server.sh || true
echo "[2/6] Hecho."

echo ""
echo "[3/6] Intentando descargar y extraer el servidor (si la URL está disponible)..."
if command -v wget >/dev/null 2>&1; then
  echo "Descargando: $SERVER_URL ..."
  if wget -q "$SERVER_URL" -O "$TEMP_FILE"; then
    echo "Archivo descargado en $TEMP_FILE"
    EXTRACT_DIR="/tmp/blockheads_extract_$$"
    mkdir -p "$EXTRACT_DIR"
    if tar xzf "$TEMP_FILE" -C "$EXTRACT_DIR"; then
      echo "Extraído en $EXTRACT_DIR"
      cp -r "$EXTRACT_DIR"/* ./
      rm -rf "$EXTRACT_DIR"
      echo "Archivos del servidor copiados al directorio actual."
    else
      echo "ERROR: No se pudo extraer el archivo tar.gz."
    fi
    rm -f "$TEMP_FILE"
  else
    echo "No se pudo descargar el archivo del servidor. Si ya tienes el binario en este directorio, continúa."
  fi
else
  echo "wget no disponible; saltando descarga del servidor."
fi
echo "[3/6] Hecho."

echo ""
echo "[4/6] Buscando binary del servidor y aplicando parches (si corresponde)..."
if [ -f "$SERVER_BINARY" ]; then
  echo "Binary encontrado: $SERVER_BINARY"
else
  ALTERNATIVE=$(find . -type f -executable -name "*blockheads*" | head -n1 || true)
  if [ -n "$ALTERNATIVE" ]; then
    echo "Encontrado binario alternativo: $ALTERNATIVE -> renombrando a $SERVER_BINARY"
    mv "$ALTERNATIVE" "$SERVER_BINARY" || true
  else
    echo "No se encontró binario del servidor en el directorio actual. Deberás colocarlo manualmente."
  fi
fi

if command -v patchelf >/dev/null 2>&1 && [ -f "$SERVER_BINARY" ]; then
  echo "Aplicando patchelf (reemplazos de librerías si es necesario)..."
  patchelf --replace-needed libgnustep-base.so.1.24 libgnustep-base.so.1.28 "$SERVER_BINARY" 2>/dev/null || true
  patchelf --replace-needed libobjc.so.4.6 libobjc.so.4 "$SERVER_BINARY" 2>/dev/null || true
  patchelf --replace-needed libgnutls.so.26 libgnutls.so.30 "$SERVER_BINARY" 2>/dev/null || true
  patchelf --replace-needed libgcrypt.so.11 libgcrypt.so.20 "$SERVER_BINARY" 2>/dev/null || true
  echo "Parches aplicados (si fueron necesarios)."
else
  echo "patchelf no disponible o $SERVER_BINARY no existe; saltando parcheo."
fi
chmod +x "$SERVER_BINARY" 2>/dev/null || true
echo "[4/6] Hecho."

echo ""
echo "[5/6] Creando economy_data.json si no existe..."
if [ ! -f economy_data.json ]; then
  cat > economy_data.json <<'JSON'
{
  "players": {},
  "transactions": [],
  "accounts": {
    "SERVER": {
      "balance": 0,
      "last_daily": 0
    }
  },
  "bankers": [],
  "settings": {
    "currency_name": "coins",
    "daily_amount": 50,
    "daily_cooldown": 86400,
    "max_balance": null
  }
}
JSON
  chown "$ORIGINAL_USER:$ORIGINAL_USER" economy_data.json 2>/dev/null || true
  echo "economy_data.json creado."
else
  echo "economy_data.json ya existe; no se modifica."
fi
echo "[5/6] Hecho."

echo ""
echo "[6/6] Ajustando permisos finales y limpieza..."
chmod +x start_server.sh bot_server.sh installer.sh 2>/dev/null || true
chown "$ORIGINAL_USER:$ORIGINAL_USER" start_server.sh bot_server.sh economy_data.json "$SERVER_BINARY" 2>/dev/null || true
echo "[6/6] Hecho."

echo ""
echo "=== Installer: terminado ==="
echo "Siguientes pasos (resumido):"
echo " 1) Si no tienes el binario del servidor, colócalo como ./${SERVER_BINARY} y chmod +x."
echo " 2) Crear un mundo (si no existe): ./blockheads_server171 -n  (ejecutar como usuario no root si es necesario)."
echo " 3) Iniciar servidor: ./start_server.sh start NOMBRE_DEL_MUNDO 12153"
echo ""
exit 0
