#!/usr/bin/env bash
# install_server.sh - Installer for TheBlockheads server on Ubuntu 22.04
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ORIGINAL_USER="${SUDO_USER:-$USER}"
USER_HOME="$(getent passwd "$ORIGINAL_USER" | cut -d: -f6 || echo "$HOME")"
SERVER_URL="${SERVER_URL:-https://web.archive.org/web/20240309015235if_/https://majicdave.com/share/blockheads_server171.tar.gz}"
TEMP_FILE="/tmp/blockheads_server171.tar.gz"
SERVER_BINARY="blockheads_server171"
RAW_BASE="https://raw.githubusercontent.com/noxthewildshadow/TheBlockHeads-Server-CLONE/refs/heads/main"
START_SCRIPT_URL="${START_SCRIPT_URL:-$RAW_BASE/start_server.sh}"
BOT_SCRIPT_URL="${BOT_SCRIPT_URL:-$RAW_BASE/bot_server.sh}"

echo "================================================================"
echo "The Blockheads Linux Server Installer (Ubuntu/Debian 22.04)"
echo "================================================================"

# ensure running as root (installer modifies /usr and installs packages)
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root: sudo $0"
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive

echo "[1/6] Installing required packages..."
apt-get update -y
apt-get install -y --no-install-recommends \
    wget curl gnupg lsb-release software-properties-common \
    libgnustep-base1.28 libdispatch0 patchelf jq screen lsof

echo "[2/6] Downloading helper scripts..."
cd "$SCRIPT_DIR"
if ! wget -q -O start_server.sh "$START_SCRIPT_URL"; then
    echo "WARNING: Could not download start_server.sh from $START_SCRIPT_URL. If you have a local copy, place it in $SCRIPT_DIR"
fi
if ! wget -q -O bot_server.sh "$BOT_SCRIPT_URL"; then
    echo "WARNING: Could not download bot_server.sh from $BOT_SCRIPT_URL. If you have a local copy, place it in $SCRIPT_DIR"
fi
chmod +x start_server.sh bot_server.sh || true

echo "[3/6] Downloading server archive..."
if ! wget -q -O "$TEMP_FILE" "$SERVER_URL"; then
    echo "ERROR: Failed to download server archive from $SERVER_URL"
    exit 1
fi

echo "[4/6] Extracting server files..."
EXTRACT_DIR="/tmp/blockheads_extract_$$"
mkdir -p "$EXTRACT_DIR"
if ! tar xzf "$TEMP_FILE" -C "$EXTRACT_DIR"; then
    echo "ERROR: Failed to extract server archive"
    rm -rf "$EXTRACT_DIR"
    exit 1
fi

# copy extracted files to current directory
cp -r "$EXTRACT_DIR"/* "$SCRIPT_DIR"/ || true
rm -rf "$EXTRACT_DIR"
rm -f "$TEMP_FILE"

# find server binary
if [ ! -f "$SCRIPT_DIR/$SERVER_BINARY" ]; then
    ALTERNATIVE_BINARY="$(find "$SCRIPT_DIR" -maxdepth 2 -type f -name "*blockheads*" -executable | head -n 1 || true)"
    if [ -n "$ALTERNATIVE_BINARY" ]; then
        echo "Found alternative binary: $ALTERNATIVE_BINARY"
        mv "$ALTERNATIVE_BINARY" "$SCRIPT_DIR/$SERVER_BINARY"
    else
        echo "ERROR: Could not find server binary in extracted files."
        echo "Please place the server binary named '$SERVER_BINARY' in $SCRIPT_DIR"
        exit 1
    fi
fi

chmod +x "$SCRIPT_DIR/$SERVER_BINARY" || true

echo "[5/6] Applying compatibility patches (best-effort)..."
patchelf --replace-needed libgnustep-base.so.1.24 libgnustep-base.so.1.28 "$SCRIPT_DIR/$SERVER_BINARY" 2>/dev/null || true
patchelf --replace-needed libobjc.so.4.6 libobjc.so.4 "$SCRIPT_DIR/$SERVER_BINARY" 2>/dev/null || true

echo "[6/6] Setting permissions and creating economy file..."
chown "$ORIGINAL_USER:$ORIGINAL_USER" "$SCRIPT_DIR/start_server.sh" "$SCRIPT_DIR/bot_server.sh" "$SCRIPT_DIR/$SERVER_BINARY" 2>/dev/null || true
# create economy file owned by original user
su - "$ORIGINAL_USER" -c "mkdir -p \"$SCRIPT_DIR\" && printf '%s' '{\"players\": {}, \"transactions\": []}' > \"$SCRIPT_DIR/economy_data.json\"" || true
chown "$ORIGINAL_USER:$ORIGINAL_USER" "$SCRIPT_DIR/economy_data.json" 2>/dev/null || true
chmod 600 "$SCRIPT_DIR/economy_data.json" || true

echo "Installation completed successfully."
cat <<EOF

NEXT STEPS:
1) Create a world (as $ORIGINAL_USER):
   cd $SCRIPT_DIR
   ./blockheads_server171 -n
   (use Ctrl+C after world creation)

2) Start the server and bot:
   ./start_server.sh start WORLD_NAME PORT

3) To check status:
   ./start_server.sh status

Notes:
- The saves directory is: $HOME/GNUstep/Library/ApplicationSupport/TheBlockheads/saves
- If the server fails to run due to missing libraries, try installing the matching library versions or run the server on a compatible distribution.
EOF
