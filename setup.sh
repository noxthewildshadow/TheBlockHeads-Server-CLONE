#!/bin/bash
set -e

# Check for root privileges
if [ "$EUID" -ne 0 ]; then
    echo "ERROR: This script requires root privileges."
    echo "Please run with: sudo $0"
    exit 1
fi

ORIGINAL_USER=${SUDO_USER:-$USER}
USER_HOME=$(getent passwd "$ORIGINAL_USER" | cut -d: -f6)

# Configuration
SERVER_URL="https://web.archive.org/web/20240309015235if_/https://majicdave.com/share/blockheads_server171.tar.gz"
TEMP_FILE="/tmp/blockheads_server171.tar.gz"
SERVER_BINARY="blockheads_server171"

# Raw URLs for helper scripts
RAW_BASE="https://raw.githubusercontent.com/noxthewildshadow/TheBlockHeads-Server-CLONE/refs/heads/main"
SERVER_MANAGER_URL="$RAW_BASE/server_manager.sh"
BOT_SCRIPT_URL="$RAW_BASE/bot_server.sh"

echo "================================================================"
echo "           The Blockheads Linux Server Installer"
echo "================================================================"

echo "[1/8] Installing required packages..."
{
    add-apt-repository multiverse -y || true
    apt-get update -y
    apt-get install -y libgnustep-base1.28 libdispatch0 patchelf wget jq screen lsof
} > /dev/null 2>&1

echo "[2/8] Downloading helper scripts from GitHub..."
if ! wget -q -O server_manager.sh "$SERVER_MANAGER_URL"; then
    echo "ERROR: Failed to download server_manager.sh from GitHub."
    exit 1
fi
if ! wget -q -O bot_server.sh "$BOT_SCRIPT_URL"; then
    echo "ERROR: Failed to download bot_server.sh from GitHub."
    exit 1
fi

chmod +x server_manager.sh bot_server.sh

echo "[3/8] Downloading server archive..."
if ! wget -q "$SERVER_URL" -O "$TEMP_FILE"; then
    echo "ERROR: Failed to download server file."
    exit 1
fi

echo "[4/8] Extracting files..."
EXTRACT_DIR="/tmp/blockheads_extract_$$"
mkdir -p "$EXTRACT_DIR"

if ! tar xzf "$TEMP_FILE" -C "$EXTRACT_DIR"; then
    echo "ERROR: Failed to extract server files."
    rm -rf "$EXTRACT_DIR"
    exit 1
fi

cp -r "$EXTRACT_DIR"/* ./
rm -rf "$EXTRACT_DIR"

# Find server binary if it wasn't named correctly
if [ ! -f "$SERVER_BINARY" ]; then
    echo "WARNING: $SERVER_BINARY not found. Searching for alternative binary names..."
    ALTERNATIVE_BINARY=$(find . -name "*blockheads*" -type f -executable | head -n 1)
    if [ -n "$ALTERNATIVE_BINARY" ]; then
        echo "Found alternative binary: $ALTERNATIVE_BINARY"
        mv "$ALTERNATIVE_BINARY" "blockheads_server171"
        SERVER_BINARY="blockheads_server171"
        echo "Renamed to: blockheads_server171"
    else
        echo "ERROR: Could not find the server binary."
        tar -tzf "$TEMP_FILE"
        exit 1
    fi
fi

chmod +x "$SERVER_BINARY"

echo "[5/8] Applying patchelf compatibility patches (best-effort)..."
patchelf --replace-needed libgnustep-base.so.1.24 libgnustep-base.so.1.28 "$SERVER_BINARY" || echo "Warning: libgnustep-base patch may have failed"
patchelf --replace-needed libobjc.so.4.6 libobjc.so.4 "$SERVER_BINARY" || true
patchelf --replace-needed libgnutls.so.26 libgnutls.so.30 "$SERVER_BINARY" || true
patchelf --replace-needed libgcrypt.so.11 libgcrypt.so.20 "$SERVER_BINARY" || true
patchelf --replace-needed libffi.so.6 libffi.so.8 "$SERVER_BINARY" || true
patchelf --replace-needed libicui18n.so.48 libicui18n.so.70 "$SERVER_BINARY" || true
patchelf --replace-needed libicuuc.so.48 libicuuc.so.70 "$SERVER_BINARY" || true
patchelf --replace-needed libicudata.so.48 libicudata.so.70 "$SERVER_BINARY" || true
patchelf --replace-needed libdispatch.so libdispatch.so.0 "$SERVER_BINARY" || true

echo "[6/8] Set ownership and permissions for helper scripts and binary"
chown "$ORIGINAL_USER:$ORIGINAL_USER" server_manager.sh bot_server.sh "$SERVER_BINARY" || true
chmod 755 server_manager.sh bot_server.sh "$SERVER_BINARY" || true

echo "[7/8] Create economy data file"
sudo -u "$ORIGINAL_USER" bash -c 'echo "{\"players\": {}, \"transactions\": []}" > economy_data.json' || true
chown "$ORIGINAL_USER:$ORIGINAL_USER" economy_data.json || true

rm -f "$TEMP_FILE"

echo "[8/8] Installation completed successfully"
echo ""
echo "================================================================"
echo "                     USAGE INSTRUCTIONS"
echo "================================================================"
echo "1. FIRST create a world manually with:"
echo "   ./blockheads_server171 -n"
echo ""
echo "   IMPORTANT: After creating the world, press CTRL+C to exit"
echo ""
echo "2. Then start the server and bot with:"
echo "   ./server_manager.sh start WORLD_NAME PORT"
echo ""
echo "3. To stop the server:"
echo "   ./server_manager.sh stop"
echo ""
echo "4. To check status:"
echo "   ./server_manager.sh status"
echo ""
echo "5. For help:"
echo "   ./server_manager.sh help"
echo "   ./blockheads_server171 -h"
echo ""
echo "NOTE: Default port is 12153 if not specified"
echo "================================================================"
