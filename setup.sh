#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Check for root privileges
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}ERROR: This script requires root privileges.${NC}"
    echo -e "${YELLOW}Please run with: sudo $0${NC}"
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

echo -e "${BLUE}================================================================"
echo -e "           The Blockheads Linux Server Installer"
echo -e "================================================================"
echo -e "${NC}"

echo -e "${CYAN}[1/8] Installing required packages...${NC}"
{
    add-apt-repository multiverse -y || true
    apt-get update -y
    apt-get install -y libgnustep-base1.28 libdispatch0 patchelf wget jq screen lsof
} > /dev/null 2>&1

echo -e "${CYAN}[2/8] Downloading helper scripts from GitHub...${NC}"
if ! wget -q -O server_manager.sh "$SERVER_MANAGER_URL"; then
    echo -e "${RED}ERROR: Failed to download server_manager.sh from GitHub.${NC}"
    exit 1
fi
if ! wget -q -O bot_server.sh "$BOT_SCRIPT_URL"; then
    echo -e "${RED}ERROR: Failed to download bot_server.sh from GitHub.${NC}"
    exit 1
fi

chmod +x server_manager.sh bot_server.sh

echo -e "${CYAN}[3/8] Downloading server archive...${NC}"
if ! wget -q "$SERVER_URL" -O "$TEMP_FILE"; then
    echo -e "${RED}ERROR: Failed to download server file.${NC}"
    exit 1
fi

echo -e "${CYAN}[4/8] Extracting files...${NC}"
EXTRACT_DIR="/tmp/blockheads_extract_$$"
mkdir -p "$EXTRACT_DIR"

if ! tar xzf "$TEMP_FILE" -C "$EXTRACT_DIR"; then
    echo -e "${RED}ERROR: Failed to extract server files.${NC}"
    rm -rf "$EXTRACT_DIR"
    exit 1
fi

cp -r "$EXTRACT_DIR"/* ./
rm -rf "$EXTRACT_DIR"

# Find server binary if it wasn't named correctly
if [ ! -f "$SERVER_BINARY" ]; then
    echo -e "${YELLOW}WARNING: $SERVER_BINARY not found. Searching for alternative binary names...${NC}"
    ALTERNATIVE_BINARY=$(find . -name "*blockheads*" -type f -executable | head -n 1)
    if [ -n "$ALTERNATIVE_BINARY" ]; then
        echo -e "${GREEN}Found alternative binary: $ALTERNATIVE_BINARY${NC}"
        mv "$ALTERNATIVE_BINARY" "blockheads_server171"
        SERVER_BINARY="blockheads_server171"
        echo -e "${GREEN}Renamed to: blockheads_server171${NC}"
    else
        echo -e "${RED}ERROR: Could not find the server binary.${NC}"
        tar -tzf "$TEMP_FILE"
        exit 1
    fi
fi

chmod +x "$SERVER_BINARY"

echo -e "${CYAN}[5/8] Applying patchelf compatibility patches (best-effort)...${NC}"
patchelf --replace-needed libgnustep-base.so.1.24 libgnustep-base.so.1.28 "$SERVER_BINARY" || echo -e "${YELLOW}Warning: libgnustep-base patch may have failed${NC}"
patchelf --replace-needed libobjc.so.4.6 libobjc.so.4 "$SERVER_BINARY" || true
patchelf --replace-needed libgnutls.so.26 libgnutls.so.30 "$SERVER_BINARY" || true
patchelf --replace-needed libgcrypt.so.11 libgcrypt.so.20 "$SERVER_BINARY" || true
patchelf --replace-needed libffi.so.6 libffi.so.8 "$SERVER_BINARY" || true
patchelf --replace-needed libicui18n.so.48 libicui18n.so.70 "$SERVER_BINARY" || true
patchelf --replace-needed libicuuc.so.48 libicuuc.so.70 "$SERVER_BINARY" || true
patchelf --replace-needed libicudata.so.48 libicudata.so.70 "$SERVER_BINARY" || true
patchelf --replace-needed libdispatch.so libdispatch.so.0 "$SERVER_BINARY" || true

echo -e "${CYAN}[6/8] Set ownership and permissions for helper scripts and binary${NC}"
chown "$ORIGINAL_USER:$ORIGINAL_USER" server_manager.sh bot_server.sh "$SERVER_BINARY" || true
chmod 755 server_manager.sh bot_server.sh "$SERVER_BINARY" || true

echo -e "${CYAN}[7/8] Create economy data file${NC}"
sudo -u "$ORIGINAL_USER" bash -c 'echo "{\"players\": {}, \"transactions\": []}" > economy_data.json' || true
chown "$ORIGINAL_USER:$ORIGINAL_USER" economy_data.json || true

rm -f "$TEMP_FILE"

echo -e "${GREEN}[8/8] Installation completed successfully${NC}"
echo ""
echo -e "${BLUE}================================================================"
echo -e "                     USAGE INSTRUCTIONS"
echo -e "================================================================"
echo -e "${NC}1. ${CYAN}FIRST${NC} create a world manually with:"
echo -e "   ${GREEN}./blockheads_server171 -n${NC}"
echo ""
echo -e "   ${YELLOW}IMPORTANT:${NC} After creating the world, press ${YELLOW}CTRL+C${NC} to exit"
echo ""
echo -e "2. Then start the server and bot with:"
echo -e "   ${GREEN}./server_manager.sh start WORLD_NAME PORT${NC}"
echo ""
echo -e "3. To stop the server:"
echo -e "   ${GREEN}./server_manager.sh stop${NC}"
echo ""
echo -e "4. To check status:"
echo -e "   ${GREEN}./server_manager.sh status${NC}"
echo ""
echo -e "5. For help:"
echo -e "   ${GREEN}./server_manager.sh help${NC}"
echo -e "   ${GREEN}./blockheads_server171 -h${NC}"
echo ""
echo -e "${YELLOW}NOTE:${NC} Default port is 12153 if not specified"
echo -e "${BLUE}================================================================"
