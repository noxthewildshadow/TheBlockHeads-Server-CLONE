#!/bin/bash
# installer.sh - installs prerequisites, places server binary and scripts
# Must be run as root (sudo)

set -e

if [ "$EUID" -ne 0 ]; then
    echo "ERROR: This script requires root privileges."
    echo "Please run with: sudo $0"
    exit 1
fi

ORIGINAL_USER=${SUDO_USER:-$USER}
USER_HOME=$(getent passwd "$ORIGINAL_USER" | cut -d: -f6)

# Configuration - remote archive (fallback)
SERVER_URL="https://web.archive.org/web/20240309015235if_/https://majicdave.com/share/blockheads_server171.tar.gz"
TEMP_FILE="/tmp/blockheads_server171.tar.gz"
SERVER_BINARY="blockheads_server171"

# Helper scripts raw urls (only used if no local start_server.sh/bot_server.sh present)
RAW_BASE="https://raw.githubusercontent.com/noxthewildshadow/TheBlockHeads-Server-CLONE/refs/heads/main"
START_SCRIPT_URL="$RAW_BASE/start_server.sh"
BOT_SCRIPT_URL="$RAW_BASE/bot_server.sh"

echo "================================================================"
echo "The Blockheads Linux Server Installer"
echo "================================================================"

echo "[1/6] Installing required packages..."
# attempt to install apt packages quietly but show failure message if apt missing
if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y libgnustep-base1.28 libdispatch0 patchelf wget jq screen lsof || apt-get install -y wget jq screen lsof || true
else
    echo "Warning: apt-get not found. Please ensure the following packages are installed: jq, screen, lsof, patchelf (if needed)."
fi

echo "[2/6] Obtaining helper scripts..."
# If user already has local versions (recommended), do not overwrite
if [ ! -f "./start_server.sh" ]; then
    if command -v wget >/dev/null 2>&1; then
        if ! wget -q -O start_server.sh "$START_SCRIPT_URL"; then
            echo "Could not download start_server.sh, installer will require a local start_server.sh"
        fi
    fi
else
    echo "Using local start_server.sh (will not overwrite)."
fi

if [ ! -f "./bot_server.sh" ]; then
    if command -v wget >/dev/null 2>&1; then
        if ! wget -q -O bot_server.sh "$BOT_SCRIPT_URL"; then
            echo "Could not download bot_server.sh, installer will place a default placeholder."
        fi
    fi
else
    echo "Using local bot_server.sh (will not overwrite)."
fi

chmod +x start_server.sh bot_server.sh 2>/dev/null || true

echo "[3/6] Downloading server archive (if reachable)..."
if command -v wget >/dev/null 2>&1; then
    if wget -q "$SERVER_URL" -O "$TEMP_FILE"; then
        echo "Downloaded server archive."
        EXTRACT_DIR="/tmp/blockheads_extract_$$"
        mkdir -p "$EXTRACT_DIR"
        if tar xzf "$TEMP_FILE" -C "$EXTRACT_DIR"; then
            cp -r "$EXTRACT_DIR"/* ./
            rm -rf "$EXTRACT_DIR"
            echo "Extracted server files into current directory."
        else
            echo "Failed to extract server archive (continuing)."
            rm -rf "$EXTRACT_DIR"
        fi
    else
        echo "Could not download server archive. If you already have the binary, installer will continue."
    fi
else
    echo "wget not available; skipping server archive download."
fi

# If server binary not found, warn user
if [ ! -f "$SERVER_BINARY" ]; then
    ALTERNATIVE_BINARY=$(find . -name "*blockheads*" -type f -executable | head -n 1 || true)
    if [ -n "$ALTERNATIVE_BINARY" ]; then
        echo "Found alternative binary: $ALTERNATIVE_BINARY"
        mv "$ALTERNATIVE_BINARY" "$SERVER_BINARY" || true
        echo "Renamed to: $SERVER_BINARY"
    else
        echo "WARNING: Could not find server binary ($SERVER_BINARY) in current directory."
        echo "Please place the server binary in this directory and set it executable (chmod +x)."
    fi
fi

chmod +x "$SERVER_BINARY" 2>/dev/null || true

echo "[4/6] Applying compatibility patches to binary (best-effort)..."
if command -v patchelf >/dev/null 2>&1 && [ -f "$SERVER_BINARY" ]; then
    patchelf --replace-needed libgnustep-base.so.1.24 libgnustep-base.so.1.28 "$SERVER_BINARY" 2>/dev/null || true
    patchelf --replace-needed libobjc.so.4.6 libobjc.so.4 "$SERVER_BINARY" 2>/dev/null || true
    patchelf --replace-needed libgnutls.so.26 libgnutls.so.30 "$SERVER_BINARY" 2>/dev/null || true
    patchelf --replace-needed libgcrypt.so.11 libgcrypt.so.20 "$SERVER_BINARY" 2>/dev/null || true
    patchelf --replace-needed libffi.so.6 libffi.so.8 "$SERVER_BINARY" 2>/dev/null || true
    patchelf --replace-needed libicui18n.so.48 libicui18n.so.70 "$SERVER_BINARY" 2>/dev/null || true
    patchelf --replace-needed libicuuc.so.48 libicuuc.so.70 "$SERVER_BINARY" 2>/dev/null || true
    patchelf --replace-needed libicudata.so.48 libicudata.so.70 "$SERVER_BINARY" 2>/dev/null || true
    patchelf --replace-needed libdispatch.so libdispatch.so.0 "$SERVER_BINARY" 2>/dev/null || true
else
    echo "patchelf not available or server binary missing; skipping binary patching."
fi

echo "[5/6] Set ownership and create default economy file (if missing)..."
chown "$ORIGINAL_USER:$ORIGINAL_USER" start_server.sh bot_server.sh "$SERVER_BINARY" 2>/dev/null || true

if [ ! -f "economy_data.json" ]; then
    sudo -u "$ORIGINAL_USER" bash -c 'echo "{\"players\": {}, \"transactions\": [], \"accounts\": {\"SERVER\": {\"balance\": 0, \"last_daily\": 0}}, \"bankers\": [], \"settings\": {\"currency_name\":\"coins\",\"daily_amount\":50,\"daily_cooldown\":86400,\"max_balance\":null}}" > economy_data.json' 2>/dev/null || true
    chown "$ORIGINAL_USER:$ORIGINAL_USER" economy_data.json 2>/dev/null || true
fi

echo "[6/6] Installation completed (best-effort)."
echo ""
echo "NEXT STEPS:"
echo "1. If you haven't, place the server binary (blockheads_server171) in this directory and chmod +x it."
echo "2. Create a world: ./blockheads_server171 -n  (then Ctrl+C)"
echo "3. Start server and bot: ./start_server.sh start WORLD_NAME PORT"
echo "4. To manage economy use the installer terminal (the bot terminal): type admin commands like:"
echo "   !addfund <player> <amount>  !removefund <player> <amount>  !send_ticket <player> <amount>"
echo ""
echo "If jq or screen are missing, install them: apt-get install jq screen lsof"
echo "================================================================"
