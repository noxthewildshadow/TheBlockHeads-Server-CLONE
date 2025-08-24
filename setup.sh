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
TEMP_FILE=$(mktemp /tmp/blockheads_server.XXXXXX)
SERVER_BINARY="blockheads_server171"

# Raw URLs for helper scripts
RAW_BASE="https://raw.githubusercontent.com/noxthewildshadow/TheBlockHeads-Server-CLONE/refs/heads/main"
SERVER_MANAGER_URL="$RAW_BASE/server_manager.sh"
BOT_SCRIPT_URL="$RAW_BASE/bot_server.sh"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Cleanup function
cleanup() {
    rm -f "$TEMP_FILE"
    echo -e "${YELLOW}Installation interrupted. Cleaning up...${NC}"
    exit 1
}

# Set trap for interrupts
trap cleanup INT TERM

echo -e "${BLUE}================================================================"
echo -e "           The Blockheads Linux Server Installer"
echo -e "================================================================"
echo -e "${NC}"

# Check and install dependencies
install_dependencies() {
    echo -e "${YELLOW}[1/8] Installing required packages...${NC}"
    
    # Update package list
    if ! apt-get update -y > /dev/null 2>&1; then
        echo -e "${RED}ERROR: Failed to update package list.${NC}"
        exit 1
    fi
    
    # Install required packages
    local packages=("libgnustep-base1.28" "libdispatch0" "patchelf" "wget" "jq" "screen" "lsof")
    for pkg in "${packages[@]}"; do
        if ! dpkg -s "$pkg" > /dev/null 2>&1; then
            echo -e "${YELLOW}Installing $pkg...${NC}"
            if ! apt-get install -y "$pkg" > /dev/null 2>&1; then
                echo -e "${RED}ERROR: Failed to install $pkg${NC}"
                exit 1
            fi
        fi
    done
    
    # Add multiverse repository if not already added
    if ! grep -q "multiverse" /etc/apt/sources.list /etc/apt/sources.list.d/* 2>/dev/null; then
        echo -e "${YELLOW}Adding multiverse repository...${NC}"
        add-apt-repository multiverse -y > /dev/null 2>&1 || \
        echo -e "${YELLOW}Multiverse repository might already be available.${NC}"
    fi
}

# Download helper scripts
download_scripts() {
    echo -e "${YELLOW}[2/8] Downloading helper scripts from GitHub...${NC}"
    
    if ! wget --timeout=30 -q -O server_manager.sh "$SERVER_MANAGER_URL"; then
        echo -e "${RED}ERROR: Failed to download server_manager.sh from GitHub.${NC}"
        exit 1
    fi
    
    if ! wget --timeout=30 -q -O bot_server.sh "$BOT_SCRIPT_URL"; then
        echo -e "${RED}ERROR: Failed to download bot_server.sh from GitHub.${NC}"
        exit 1
    fi
    
    chmod +x server_manager.sh bot_server.sh
}

# Download server archive
download_server() {
    echo -e "${YELLOW}[3/8] Downloading server archive...${NC}"
    
    if ! wget --progress=bar:force --timeout=60 -O "$TEMP_FILE" "$SERVER_URL"; then
        echo -e "${RED}ERROR: Failed to download server file.${NC}"
        echo -e "${YELLOW}Please check your internet connection and try again.${NC}"
        exit 1
    fi
    
    # Verify download integrity
    local file_size=$(stat -c%s "$TEMP_FILE")
    if [ "$file_size" -lt 1000000 ]; then  # Less than 1MB indicates a failed download
        echo -e "${RED}ERROR: Downloaded file is too small. likely a failed download.${NC}"
        exit 1
    fi
}

# Extract files
extract_files() {
    echo -e "${YELLOW}[4/8] Extracting files...${NC}"
    
    EXTRACT_DIR=$(mktemp -d)
    if ! tar xzf "$TEMP_FILE" -C "$EXTRACT_DIR"; then
        echo -e "${RED}ERROR: Failed to extract server files.${NC}"
        rm -rf "$EXTRACT_DIR"
        exit 1
    fi
    
    # Copy files
    if ! cp -r "$EXTRACT_DIR"/* ./; then
        echo -e "${RED}ERROR: Failed to copy extracted files.${NC}"
        rm -rf "$EXTRACT_DIR"
        exit 1
    fi
    
    rm -rf "$EXTRACT_DIR"
    
    # Find server binary if it wasn't named correctly
    if [ ! -f "$SERVER_BINARY" ]; then
        echo -e "${YELLOW}Searching for server binary...${NC}"
        local alternative_binary=$(find . -name "*blockheads*" -type f -executable | head -n 1)
        if [ -n "$alternative_binary" ]; then
            echo -e "${YELLOW}Found alternative binary: $alternative_binary${NC}"
            mv "$alternative_binary" "$SERVER_BINARY"
            echo -e "${YELLOW}Renamed to: $SERVER_BINARY${NC}"
        else
            echo -e "${RED}ERROR: Could not find the server binary.${NC}"
            exit 1
        fi
    fi
    
    chmod +x "$SERVER_BINARY"
}

# Apply compatibility patches
apply_patches() {
    echo -e "${YELLOW}[5/8] Applying compatibility patches...${NC}"
    
    # Best-effort patches - they might fail on some systems
    local patches=(
        "--replace-needed libgnustep-base.so.1.24 libgnustep-base.so.1.28"
        "--replace-needed libobjc.so.4.6 libobjc.so.4"
        "--replace-needed libgnutls.so.26 libgnutls.so.30"
        "--replace-needed libgcrypt.so.11 libgcrypt.so.20"
        "--replace-needed libffi.so.6 libffi.so.8"
        "--replace-needed libicui18n.so.48 libicui18n.so.70"
        "--replace-needed libicuuc.so.48 libicuuc.so.70"
        "--replace-needed libicudata.so.48 libicudata.so.70"
        "--replace-needed libdispatch.so libdispatch.so.0"
    )
    
    for patch in "${patches[@]}"; do
        if patchelf $patch "$SERVER_BINARY" 2>/dev/null; then
            echo -e "${GREEN}Applied patch: $patch${NC}"
        else
            echo -e "${YELLOW}Patch failed (may be expected): $patch${NC}"
        fi
    done
}

# Set permissions
set_permissions() {
    echo -e "${YELLOW}[6/8] Setting permissions...${NC}"
    
    # Set ownership for all files
    if ! chown -R "$ORIGINAL_USER:$ORIGINAL_USER" .; then
        echo -e "${RED}ERROR: Failed to set ownership.${NC}"
        exit 1
    fi
    
    # Set executable permissions
    if ! chmod 755 server_manager.sh bot_server.sh "$SERVER_BINARY"; then
        echo -e "${RED}ERROR: Failed to set executable permissions.${NC}"
        exit 1
    fi
}

# Create data files
create_data_files() {
    echo -e "${YELLOW}[7/8] Creating data files...${NC}"
    
    # Create economy data file
    if ! sudo -u "$ORIGINAL_USER" bash -c 'echo "{\"players\": {}, \"transactions\": []}" > economy_data.json'; then
        echo -e "${RED}ERROR: Failed to create economy_data.json${NC}"
        exit 1
    fi
    
    # Create IP ranks file (TXT format)
    if ! sudo -u "$ORIGINAL_USER" bash -c 'echo "# IP Ranks File - Format: rank:player:ip" > ip_ranks.txt'; then
        echo -e "${RED}ERROR: Failed to create ip_ranks.txt${NC}"
        exit 1
    fi
    
    # Set restrictive permissions on data files
    chmod 600 economy_data.json ip_ranks.txt
    chown "$ORIGINAL_USER:$ORIGINAL_USER" economy_data.json ip_ranks.txt
}

# Final cleanup
final_cleanup() {
    echo -e "${YELLOW}[8/8] Performing final cleanup...${NC}"
    rm -f "$TEMP_FILE"
}

# Display completion message
display_completion() {
    echo -e "${YELLOW}Installation completed!${NC}"
    
    echo -e "${GREEN}"
    echo "================================================================"
    echo "                     USAGE INSTRUCTIONS"
    echo "================================================================"
    echo -e "${NC}"
    echo "1. FIRST create a world manually with:"
    echo -e "   ${CYAN}./blockheads_server171 -n${NC}"
    echo ""
    echo "   IMPORTANT: After creating the world, press CTRL+C to exit"
    echo ""
    echo "2. Then start the server and bot with:"
    echo -e "   ${CYAN}./server_manager.sh start WORLD_NAME PORT${NC}"
    echo ""
    echo "3. To stop the server:"
    echo -e "   ${CYAN}./server_manager.sh stop${NC}"
    echo ""
    echo "4. To check status:"
    echo -e "   ${CYAN}./server_manager.sh status${NC}"
    echo ""
    echo "5. For help:"
    echo -e "   ${CYAN}./server_manager.sh help${NC}"
    echo -e "   ${CYAN}./blockheads_server171 -h${NC}"
    echo ""
    echo -e "${YELLOW}NOTE:${NC} Default port is 12153 if not specified"
    echo -e "${YELLOW}NOTE:${NC} World files are located at:"
    echo -e "   ${CYAN}~/GNUstep/Library/ApplicationSupport/TheBlockheads/saves/${NC}"
    echo -e "${GREEN}================================================================"
}

# Main installation process
main() {
    install_dependencies
    download_scripts
    download_server
    extract_files
    apply_patches
    set_permissions
    create_data_files
    final_cleanup
    display_completion
}

# Run main function
main
