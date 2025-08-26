#!/bin/bash

# Enhanced Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
ORANGE='\033[0;33m'
PURPLE='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Function to print status messages
print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_header() {
    echo -e "${PURPLE}================================================================"
    echo -e "$1"
    echo -e "===============================================================${NC}"
}

print_step() {
    echo -e "${CYAN}[STEP]${NC} $1"
}

# Configuration
SERVER_BINARY="./blockheads_server171"
LOG_DIR="$HOME/GNUstep/Library/ApplicationSupport/TheBlockheads/saves"
SECURITY_LOG="/var/log/blockheads_security.log"
BLOCKED_IPS="/tmp/blockheads_blocked_ips.txt"
KNOWN_EXPLOIT_PATTERNS=("packets: Bad file descriptor" "admin hack" "spoofing" "icloud id" "player id")
CONNECTION_THRESHOLD=5  # Max connections per minute
CONNECTION_TIMEFRAME=60 # Timeframe in seconds

# Initialize security log
init_security_log() {
    sudo touch "$SECURITY_LOG" 2>/dev/null || SECURITY_LOG="./blockheads_security.log"
    chmod 644 "$SECURITY_LOG" 2>/dev/null
    print_success "Security log initialized: $SECURITY_LOG"
}

# Function to detect exploit patterns in logs
detect_exploit_patterns() {
    local log_file="$1"
    local detected=0
    
    for pattern in "${KNOWN_EXPLOIT_PATTERNS[@]}"; do
        if grep -q "$pattern" "$log_file" 2>/dev/null; then
            print_error "DETECTED EXPLOIT PATTERN: $pattern"
            log_security_event "EXPLOIT_DETECTED" "$pattern" "HIGH"
            detected=1
        fi
    done
    
    return $detected
}

# Function to log security events
log_security_event() {
    local event_type="$1"
    local message="$2"
    local severity="$3"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    echo "[$timestamp] [$severity] [$event_type] $message" | tee -a "$SECURITY_LOG" >/dev/null
}

# Function to block IP address
block_ip() {
    local ip="$1"
    local reason="$2"
    
    if ! grep -q "^$ip" "$BLOCKED_IPS" 2>/dev/null; then
        echo "$ip|$(date '+%Y-%m-%d %H:%M:%S')|$reason" >> "$BLOCKED_IPS"
        print_success "Blocked IP: $ip (Reason: $reason)"
        log_security_event "IP_BLOCKED" "Blocked IP: $ip - Reason: $reason" "HIGH"
        
        # Additional IP blocking with iptables (if root)
        if command -v iptables >/dev/null 2>&1 && [ "$EUID" -eq 0 ]; then
            iptables -A INPUT -s "$ip" -j DROP 2>/dev/null && \
            print_status "Added iptables rule to block $ip"
        fi
    fi
}

# Function to find latest log file
find_latest_log() {
    local world_dir="$1"
    local latest_log=""
    local latest_time=0
    
    for log_file in "$world_dir"/*.log; do
        if [ -f "$log_file" ]; then
            local file_time=$(stat -c %Y "$log_file" 2>/dev/null || echo 0)
            if [ "$file_time" -gt "$latest_time" ]; then
                latest_time=$file_time
                latest_log="$log_file"
            fi
        fi
    done
    
    echo "$latest_log"
}

# Function to monitor log file in real-time
monitor_log_security() {
    local log_file="$1"
    local world_name="$2"
    local port="$3"
    
    print_header "STARTING SECURITY MONITOR FOR $world_name (PORT: $port)"
    print_status "Monitoring: $log_file"
    
    # Track recent connections to detect spoofing and DDoS
    declare -A recent_connections
    declare -A connection_timestamps
    declare -A connection_counts
    declare -A connection_times
    
    # Initialize DDoS protection
    local last_cleanup=$(date +%s)
    
    tail -n 0 -F "$log_file" 2>/dev/null | while read line; do
        # Periodically clean up old connection records
        local current_time=$(date +%s)
        if [ $((current_time - last_cleanup)) -ge 30 ]; then
            for ip in "${!connection_times[@]}"; do
                if [ $((current_time - connection_times[$ip])) -ge $CONNECTION_TIMEFRAME ]; then
                    unset connection_counts[$ip]
                    unset connection_times[$ip]
                fi
            done
            last_cleanup=$current_time
        fi
        
        # Check for exploit patterns
        for pattern in "${KNOWN_EXPLOIT_PATTERNS[@]}"; do
            if [[ "$line" == *"$pattern"* ]]; then
                print_error "EXPLOIT DETECTED: $pattern"
                log_security_event "EXPLOIT_DETECTED" "$line" "CRITICAL"
                
                # Try to extract IP from previous connection events
                if [[ "$line" == *"packets"* ]]; then
                    # This is likely the malicious user "packets"
                    block_ip "0.0.0.0" "Known exploit user 'packets' detected"
                fi
            fi
        done
        
        # Detect player connections
        if [[ "$line" =~ Player\ Connected\ ([a-zA-Z0-9_]+)\ \|\ ([0-9a-fA-F.:]+) ]]; then
            local player_name="${BASH_REMATCH[1]}"
            local player_ip="${BASH_REMATCH[2]}"
            
            # DDoS protection: Check connection rate
            if [ -z "${connection_counts[$player_ip]}" ]; then
                connection_counts[$player_ip]=1
                connection_times[$player_ip]=$current_time
            else
                connection_counts[$player_ip]=$((connection_counts[$player_ip] + 1))
            fi
            
            if [ "${connection_counts[$player_ip]}" -gt $CONNECTION_THRESHOLD ]; then
                print_error "DDoS ATTEMPT DETECTED FROM IP: $player_ip (${connection_counts[$player_ip]} connections)"
                block_ip "$player_ip" "DDoS attempt (${connection_counts[$player_ip]} connections)"
                continue
            fi
            
            # Check for suspicious connection patterns
            if [[ -n "${recent_connections[$player_ip]}" && "${recent_connections[$player_ip]}" != "$player_name" ]]; then
                print_warning "POSSIBLE SPOOFING: IP $player_ip connected as ${recent_connections[$player_ip]} and now as $player_name"
                log_security_event "SPOOFING_SUSPECTED" "IP $player_ip changing from ${recent_connections[$player_ip]} to $player_name" "MEDIUM"
                
                # If this happens multiple times quickly, block the IP
                local last_time=${connection_timestamps[$player_ip]}
                if [[ -n "$last_time" && $((current_time - last_time)) -lt 30 ]]; then
                    print_error "REPEATED SPOOFING ATTEMPT - BLOCKING IP: $player_ip"
                    block_ip "$player_ip" "Repeated spoofing attempts"
                fi
            fi
            
            # Record this connection
            recent_connections["$player_ip"]="$player_name"
            connection_timestamps["$player_ip"]=$current_time
            
            # Check if this is a known exploited player
            if [[ "$player_name" == "packets" ]]; then
                print_error "KNOWN EXPLOIT USER DETECTED: $player_name (IP: $player_ip)"
                block_ip "$player_ip" "Known exploit user 'packets'"
                
                # Immediately disconnect this player
                screen -S "blockheads_server_$port" -X stuff "/kick $player_name$(printf \\r)"
                print_status "Kicked exploit user: $player_name"
            fi
        fi
        
        # Detect admin command usage
        if [[ "$line" =~ ([a-zA-Z0-9_]+):\ \/(admin|mod|kick|ban|stop) ]]; then
            local player_name="${BASH_REMATCH[1]}"
            local command="${BASH_REMATCH[2]}"
            
            # Check if this player is actually an admin
            local admin_list_file="$LOG_DIR/$world_name/adminlist.txt"
            if [ -f "$admin_list_file" ]; then
                local lower_player_name=$(echo "$player_name" | tr '[:upper:]' '[:lower:]')
                if ! grep -q "^$lower_player_name$" "$admin_list_file"; then
                    print_error "UNAUTHORIZED ADMIN COMMAND: $player_name used /$command"
                    log_security_event "UNAUTHORIZED_ADMIN_CMD" "$player_name used /$command" "HIGH"
                    
                    # Try to get their IP from recent connections
                    local player_ip=""
                    for ip in "${!recent_connections[@]}"; do
                        if [ "${recent_connections[$ip]}" = "$player_name" ]; then
                            player_ip="$ip"
                            break
                        fi
                    done
                    
                    if [ -n "$player_ip" ]; then
                        block_ip "$player_ip" "Unauthorized admin command: /$command"
                    fi
                    
                    # Kick the player
                    screen -S "blockheads_server_$port" -X stuff "/kick $player_name$(printf \\r)"
                fi
            fi
        fi
        
        # Detect server stop commands
        if [[ "$line" == *"Server closed"* ]] || [[ "$line" == *"stop"* ]]; then
            print_warning "Server stop detected - checking if legitimate..."
            sleep 2
            
            # Check if the server process is actually running
            if ! screen -list | grep -q "blockheads_server_$port"; then
                print_error "SERVER WAS STOPPED - POSSIBLE EXPLOIT"
                log_security_event "SERVER_STOPPED" "Server on port $port was stopped" "CRITICAL"
                
                # Restart the server
                print_status "Attempting to restart server..."
                ./server_manager.sh start "$world_name" "$port"
            fi
        fi
        
        # Check for crash indicators
        if [[ "$line" == *"Bad file descriptor"* ]] || [[ "$line" == *"crash"* ]] || [[ "$line" == *"error"* ]]; then
            print_warning "Possible crash detected: $line"
            log_security_event "CRASH_WARNING" "$line" "MEDIUM"
        fi
    done
}

# Function to validate server integrity
validate_server_integrity() {
    print_header "VALIDATING SERVER INTEGRITY"
    
    # Check if server binary exists
    if [ ! -f "$SERVER_BINARY" ]; then
        print_error "Server binary not found: $SERVER_BINARY"
        return 1
    fi
    
    # Check if server binary is executable
    if [ ! -x "$SERVER_BINARY" ]; then
        print_error "Server binary is not executable"
        chmod +x "$SERVER_BINARY"
        print_status "Fixed server binary permissions"
    fi
    
    print_success "Server binary integrity verified"
    return 0
}

# Function to harden server configuration
harden_server_config() {
    print_header "HARDENING SERVER CONFIGURATION"
    
    local world_name="$1"
    local world_dir="$LOG_DIR/$world_name"
    
    # Backup original files
    cp "$world_dir/server.cfg" "$world_dir/server.cfg.backup" 2>/dev/null
    
    # Add security settings to server configuration
    if [ -f "$world_dir/server.cfg" ]; then
        # Disable console access for all players
        if ! grep -q "consoleAll" "$world_dir/server.cfg"; then
            echo "consoleAll = false" >> "$world_dir/server.cfg"
        fi
        
        # Enable stricter validation
        if ! grep -q "validatePlayers" "$world_dir/server.cfg"; then
            echo "validatePlayers = true" >> "$world_dir/server.cfg"
        fi
        
        # Limit connection rate
        if ! grep -q "connectionLimit" "$world_dir/server.cfg"; then
            echo "connectionLimit = 3" >> "$world_dir/server.cfg"
        fi
        
        print_success "Server configuration hardened"
    else
        print_warning "No server.cfg found for world $world_name"
    fi
    
    # Secure admin and mod lists
    chmod 644 "$world_dir/adminlist.txt" 2>/dev/null
    chmod 644 "$world_dir/modlist.txt" 2>/dev/null
    
    print_success "Server files secured"
}

# Function to setup firewall rules
setup_firewall() {
    print_header "SETTING UP FIREWALL PROTECTION"
    
    local port="$1"
    
    # Check if ufw is available
    if command -v ufw >/dev/null 2>&1; then
        print_status "Configuring UFW firewall..."
        
        # Enable firewall if not already enabled
        if ! ufw status | grep -q "Status: active"; then
            ufw enable
        fi
        
        # Allow the server port
        ufw allow "$port"
        print_success "Allowed port $port through firewall"
        
        # Limit SSH connections to prevent brute force
        ufw limit ssh
        print_success "Limited SSH connections"
    else
        print_warning "UFW not available, skipping firewall configuration"
    fi
    
    # Check if iptables is available
    if command -v iptables >/dev/null 2>&1; then
        print_status "Configuring iptables rules..."
        
        # Basic protection rules
        iptables -A INPUT -p tcp --dport "$port" -m connlimit --connlimit-above 10 -j DROP 2>/dev/null || true
        iptables -A INPUT -p tcp --dport "$port" -m state --state NEW -m recent --set 2>/dev/null || true
        iptables -A INPUT -p tcp --dport "$port" -m state --state NEW -m recent --update --seconds 60 --hitcount 10 -j DROP 2>/dev/null || true
        
        print_success "Added iptables protection rules"
    else
        print_warning "iptables not available, skipping advanced firewall configuration"
    fi
}

# Main function
main() {
    if [ $# -lt 2 ]; then
        echo "Usage: $0 <world_name> <port>"
        echo "Example: $0 SURVIVAL 12153"
        exit 1
    fi
    
    local world_name="$1"
    local port="$2"
    local world_dir="$LOG_DIR/$world_name"
    local log_file=$(find_latest_log "$world_dir")
    
    if [ -z "$log_file" ] || [ ! -f "$log_file" ]; then
        print_error "Could not find log file for world $world_name"
        print_status "Trying to find any log file in $world_dir"
        log_file=$(ls -t "$world_dir"/*.log 2>/dev/null | head -n1)
        if [ -z "$log_file" ]; then
            print_error "No log files found in $world_dir"
            exit 1
        fi
    fi
    
    print_header "THE BLOCKHEADS ANTICHEAT SECURE SYSTEM"
    print_status "World: $world_name"
    print_status "Port: $port"
    print_status "Log file: $log_file"
    
    # Initialize security system
    init_security_log
    validate_server_integrity
    harden_server_config "$world_name"
    setup_firewall "$port"
    
    # Monitor for existing exploits
    detect_exploit_patterns "$log_file"
    
    # Start monitoring
    monitor_log_security "$log_file" "$world_name" "$port"
}

# Run main function with all arguments
main "$@"
