#!/bin/bash
set -e

# Installer script for Ubuntu 22.04 (and similar)
# Run with: curl -sSL <url>/setup.sh | sudo bash

ORIGINAL_USER=${SUDO_USER:-$USER}
USER_HOME=$(getent passwd "$ORIGINAL_USER" | cut -d: -f6)

# Configuration
SERVER_URL="https://web.archive.org/web/20240309015235if_/https://majicdave.com/share/blockheads_server171.tar.gz"
TEMP_FILE="/tmp/blockheads_server171.tar.gz"
SERVER_BINARY="blockheads_server171"
RAW_BASE="https://raw.githubusercontent.com/noxthewildshadow/TheBlockHeads-Server-CLONE/refs/heads/main"
START_SCRIPT_URL="$RAW_BASE/start_server.sh"
BOT_SCRIPT_URL="$RAW_BASE/bot_server.sh"

echo "================================================================"
echo "The Blockheads Linux Server Installer (Ubuntu 22.04 compatible)"
echo "================================================================"

export DEBIAN_FRONTEND=noninteractive

echo "[1/6] Updating package lists and installing packages..."
apt-get update -y >/dev/null 2>&1 || true
# Install packages; don't fail if some packages are missing — we use patchelf to adapt
apt-get install -y wget curl patchelf jq screen lsof ca-certificates >/dev/null 2>&1 || true

# Additional compatibility packages (may not exist on all distros)
apt-get install -y libgnustep-base1.28 libdispatch0 || true

# Ensure we have a working downloader
if command -v wget >/dev/null 2>&1; then
    DL="wget -q -O"
elif command -v curl >/dev/null 2>&1; then
    DL="curl -sL -o"
else
    echo "ERROR: Please install wget or curl and re-run installer." >&2
    exit 1
fi

echo "[2/6] Downloading helper scripts..."
if ! $DL start_server.sh "$START_SCRIPT_URL"; then
    echo "ERROR: Failed to download start_server.sh" >&2
    exit 1
fi
if ! $DL bot_server.sh "$BOT_SCRIPT_URL"; then
    echo "ERROR: Failed to download bot_server.sh" >&2
    exit 1
fi
chmod +x start_server.sh bot_server.sh || true
chown "$ORIGINAL_USER:$ORIGINAL_USER" start_server.sh bot_server.sh || true

echo "[3/6] Downloading server archive..."
if ! $DL "$TEMP_FILE" "$SERVER_URL"; then
    echo "WARNING: Could not download server archive from $SERVER_URL" >&2
    echo "If you have a local server tar.gz, place it here and re-run the script." >&2
else
    echo "[4/6] Extracting server files..."
    TMPDIR=$(mktemp -d)
    if tar xzf "$TEMP_FILE" -C "$TMPDIR" 2>/dev/null; then
        cp -r "$TMPDIR"/* ./ || true
        rm -rf "$TMPDIR"
    else
        echo "WARNING: Could not extract server archive cleanly. Trying to find binary inside archive..."
        rm -rf "$TMPDIR" || true
    fi
fi

# Ensure server binary exists or try to find a matching executable
if [ ! -f "$SERVER_BINARY" ]; then
    ALTERNATIVE_BINARY=$(find . -type f -executable -iname "*blockheads*" | head -n 1 || true)
    if [ -n "$ALTERNATIVE_BINARY" ]; then
        echo "Found alternative binary: $ALTERNATIVE_BINARY"
        mv "$ALTERNATIVE_BINARY" "$SERVER_BINARY" || true
    fi
fi

if [ -f "$SERVER_BINARY" ]; then
    chmod +x "$SERVER_BINARY" || true
    chown "$ORIGINAL_USER:$ORIGINAL_USER" "$SERVER_BINARY" || true
else
    echo "WARNING: Server binary not found after extraction. You will need to place the server binary named '$SERVER_BINARY' in this directory." >&2
fi

# Apply common patchelf replacements (best-effort; ignore failures)
echo "[5/6] Applying compatibility patches (best-effort)"
patchelf --replace-needed libgnustep-base.so.1.24 libgnustep-base.so.1.28 "$SERVER_BINARY" 2>/dev/null || true
patchelf --replace-needed libobjc.so.4.6 libobjc.so.4 "$SERVER_BINARY" 2>/dev/null || true
patchelf --replace-needed libgnutls.so.26 libgnutls.so.30 "$SERVER_BINARY" 2>/dev/null || true
patchelf --replace-needed libgcrypt.so.11 libgcrypt.so.20 "$SERVER_BINARY" 2>/dev/null || true
patchelf --replace-needed libffi.so.6 libffi.so.8 "$SERVER_BINARY" 2>/dev/null || true
patchelf --replace-needed libicui18n.so.48 libicui18n.so.70 "$SERVER_BINARY" 2>/dev/null || true
patchelf --replace-needed libicuuc.so.48 libicuuc.so.70 "$SERVER_BINARY" 2>/dev/null || true
patchelf --replace-needed libicudata.so.48 libicudata.so.70 "$SERVER_BINARY" 2>/dev/null || true
patchelf --replace-needed libdispatch.so libdispatch.so.0 "$SERVER_BINARY" 2>/dev/null || true

# Create an empty economy file as the installing user
echo "[6/6] Creating economy file and finishing up..."
if [ -n "$ORIGINAL_USER" ]; then
    sudo -u "$ORIGINAL_USER" bash -c 'echo "{\"players\": {}, \"transactions\": []}" > economy_data.json' 2>/dev/null || true
else
    echo '{"players": {}, "transactions": []}' > economy_data.json || true
fi
chown "$ORIGINAL_USER:$ORIGINAL_USER" economy_data.json 2>/dev/null || true
rm -f "$TEMP_FILE" || true

echo "Installation completed successfully (best-effort)."
echo "Next steps:"
echo " 1) Create a world: ./blockheads_server171 -n  (press Ctrl+C to finish world creation)"
echo " 2) Start the server: ./start_server.sh start WORLD_NAME PORT"
echo " 3) To manage the bot and server: screen -r blockheads_server or screen -r blockheads_bot"

exit 0
