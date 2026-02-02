#!/bin/bash
set -e

#===============================================================================
# Constants
#===============================================================================
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

readonly PLIST_LABEL="com.robfz.ssh-tunnel"
readonly PLIST_PATH="$HOME/Library/LaunchAgents/${PLIST_LABEL}.plist"
readonly LOG_FILE="/tmp/ssh-tunnel.log"
readonly ERR_FILE="/tmp/ssh-tunnel.err"

# Global config (set by parse_args)
REMOTE_HOST=""
REMOTE_USER=""
TUNNEL_PORT="2222"
CLIENTS=""
KEY_PATH="$HOME/.ssh/tunnel-clients"

#===============================================================================
# Utility Functions
#===============================================================================
log_step() {
    local step_num="$1"
    local total="$2"
    local message="$3"
    echo -e "${GREEN}[${step_num}/${total}] ${message}${NC}"
}

log_info() {
    echo -e "  $1"
}

log_success() {
    echo -e "  ${GREEN}✓ $1${NC}"
}

log_warn() {
    echo -e "  ${YELLOW}⚠ $1${NC}"
}

log_error() {
    echo -e "${RED}Error: $1${NC}"
    exit 1
}

print_usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Configure a Mac to establish a persistent reverse SSH tunnel.

Required:
  -H, --host HOST          Linux server hostname or IP
  -u, --user USER          Username on the Linux server
  -c, --clients NAMES      Comma-separated client names (e.g., m4,s23,laptop)

Optional:
  -p, --tunnel-port PORT   Tunnel port on server (default: 2222)
  -k, --key-path PATH      Path to store client keys (default: ~/.ssh/tunnel-clients)
  -h, --help               Show this help message

Example:
  $(basename "$0") --host server.example.com --user admin --clients m4,s23
  $(basename "$0") -H 192.168.1.100 -u admin -p 2222 -c laptop,phone,tablet
EOF
}

#===============================================================================
# Argument Parsing
#===============================================================================
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -H|--host)
                REMOTE_HOST="$2"
                shift 2
                ;;
            -u|--user)
                REMOTE_USER="$2"
                shift 2
                ;;
            -p|--tunnel-port)
                TUNNEL_PORT="$2"
                shift 2
                ;;
            -c|--clients)
                CLIENTS="$2"
                shift 2
                ;;
            -k|--key-path)
                KEY_PATH="$2"
                shift 2
                ;;
            -h|--help)
                print_usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1\nUse --help for usage information."
                ;;
        esac
    done
    
    # Expand ~ in key path
    KEY_PATH=$(eval echo "$KEY_PATH")
    
    # Validate required arguments
    if [ -z "$REMOTE_HOST" ]; then
        log_error "Missing required argument: --host\nUse --help for usage information."
    fi
    if [ -z "$REMOTE_USER" ]; then
        log_error "Missing required argument: --user\nUse --help for usage information."
    fi
    if [ -z "$CLIENTS" ]; then
        log_error "Missing required argument: --clients\nUse --help for usage information."
    fi
}

print_configuration() {
    echo -e "${GREEN}=== SSH Tunnel Mac Setup ===${NC}"
    echo ""
    echo -e "${YELLOW}Configuration:${NC}"
    echo "  Server: ${REMOTE_USER}@${REMOTE_HOST}"
    echo "  Tunnel port: $TUNNEL_PORT"
    echo "  Clients: $CLIENTS"
    echo "  Key storage: $KEY_PATH"
    echo ""
}

#===============================================================================
# Setup Functions
#===============================================================================
check_homebrew() {
    log_step 1 6 "Checking for Homebrew..."
    
    if ! command -v brew &> /dev/null; then
        log_error "Homebrew not found. Install from https://brew.sh"
    fi
    log_info "Homebrew found"
}

install_dependencies() {
    log_step 2 6 "Installing autossh and mosh..."
    
    brew install autossh mosh 2>/dev/null || brew upgrade autossh mosh 2>/dev/null || true
    log_info "autossh and mosh installed"
}

verify_ssh_access() {
    log_step 3 6 "Verifying SSH access to server..."
    
    if ! ssh -o BatchMode=yes -o ConnectTimeout=10 "${REMOTE_USER}@${REMOTE_HOST}" "echo 'SSH OK'" 2>/dev/null; then
        log_error "Cannot SSH to ${REMOTE_USER}@${REMOTE_HOST}. Please ensure you have SSH key access configured first."
    fi
    log_info "SSH access verified"
}

generate_client_keys() {
    log_step 4 6 "Generating client SSH keys..."
    
    mkdir -p "$KEY_PATH"
    chmod 700 "$KEY_PATH"
    
    echo ""
    echo -e "${YELLOW}You will be prompted for a passphrase for each client key.${NC}"
    echo -e "${YELLOW}Press Enter for no passphrase (less secure).${NC}"
    echo ""
    
    # Split clients by comma
    IFS=',' read -ra CLIENT_ARRAY <<< "$CLIENTS"
    
    for client_name in "${CLIENT_ARRAY[@]}"; do
        local key_file="${KEY_PATH}/${client_name}_ed25519"
        if [ -f "$key_file" ]; then
            log_info "Skipping ${client_name} (key already exists)"
        else
            echo -e "${BLUE}Generating key for ${client_name}:${NC}"
            ssh-keygen -t ed25519 -C "${client_name}@tunnel-$(date +%Y%m%d)" -f "$key_file"
            log_info "Generated: ${client_name}_ed25519"
        fi
    done
}

authorize_client_keys() {
    log_step 5 6 "Adding client keys to authorized_keys..."
    
    mkdir -p ~/.ssh
    chmod 700 ~/.ssh
    touch ~/.ssh/authorized_keys
    chmod 600 ~/.ssh/authorized_keys
    
    # Split clients by comma
    IFS=',' read -ra CLIENT_ARRAY <<< "$CLIENTS"
    
    for client_name in "${CLIENT_ARRAY[@]}"; do
        local pub_key="${KEY_PATH}/${client_name}_ed25519.pub"
        if [ -f "$pub_key" ]; then
            local key_content
            key_content=$(cat "$pub_key")
            if ! grep -qF "$key_content" ~/.ssh/authorized_keys 2>/dev/null; then
                echo "$key_content" >> ~/.ssh/authorized_keys
                log_info "Added ${client_name} to authorized_keys"
            else
                log_info "${client_name} already in authorized_keys"
            fi
        fi
    done
}

create_launchd_service() {
    log_step 6 6 "Creating launchd service for persistent tunnel..."
    
    local autossh_path
    autossh_path=$(which autossh)
    
    mkdir -p "$HOME/Library/LaunchAgents"
    
    # Build the autossh command with caffeinate wrapper to prevent sleep
    local autossh_cmd="caffeinate -s ${autossh_path} -M 0 -N -o 'ServerAliveInterval 30' -o 'ServerAliveCountMax 3' -o 'ExitOnForwardFailure yes' -o 'StrictHostKeyChecking accept-new' -R ${TUNNEL_PORT}:localhost:22 ${REMOTE_USER}@${REMOTE_HOST}"
    
    cat > "$PLIST_PATH" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${PLIST_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/sh</string>
        <string>-c</string>
        <string>${autossh_cmd}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>NetworkState</key>
        <true/>
    </dict>
    <key>StandardOutPath</key>
    <string>${LOG_FILE}</string>
    <key>StandardErrorPath</key>
    <string>${ERR_FILE}</string>
    <key>ThrottleInterval</key>
    <integer>30</integer>
</dict>
</plist>
EOF
    
    log_info "Created plist at $PLIST_PATH"
    log_info "Using caffeinate to prevent Mac sleep while tunnel is active"
}

start_tunnel_service() {
    # Unload if already loaded, then load
    launchctl unload "$PLIST_PATH" 2>/dev/null || true
    launchctl load "$PLIST_PATH"
    log_info "Tunnel service started"
}

print_tunnel_status() {
    echo ""
    echo -e "${BLUE}Tunnel Status:${NC}"
    sleep 2
    
    if pgrep -f "autossh.*${REMOTE_HOST}" > /dev/null; then
        log_success "Tunnel is running"
    else
        log_warn "Tunnel may still be starting. Check: $LOG_FILE"
    fi
}

print_client_keys_info() {
    echo ""
    echo -e "${BLUE}Client Keys Generated:${NC}"
    echo "  Location: $KEY_PATH"
    ls -la "$KEY_PATH"/*.pub 2>/dev/null | awk '{print "  " $NF}'
}

print_connection_instructions() {
    local mac_user
    mac_user=$(whoami)
    
    # Get first client name for example
    local first_client
    first_client=$(echo "$CLIENTS" | cut -d',' -f1)
    
    echo ""
    echo -e "${BLUE}Client Connection Instructions:${NC}"
    echo "  Distribute the private key files (*_ed25519) to clients."
    echo "  Clients should:"
    echo ""
    echo "  # Option 1: Mosh + SSH (recommended for reliability)"
    echo "  mosh ${REMOTE_USER}@${REMOTE_HOST}"
    echo "  ssh -p ${TUNNEL_PORT} -i ~/.ssh/${first_client}_ed25519 ${mac_user}@localhost"
    echo ""
    echo "  # Option 2: Direct SSH with ProxyJump"
    echo "  ssh -J ${REMOTE_USER}@${REMOTE_HOST} -p ${TUNNEL_PORT} -i ~/.ssh/${first_client}_ed25519 ${mac_user}@localhost"
}

print_management_commands() {
    echo ""
    echo -e "${BLUE}Management Commands:${NC}"
    echo "  Start tunnel:   ./tunnel-control-mac.sh start"
    echo "  Stop tunnel:    ./tunnel-control-mac.sh stop"
    echo "  Restart tunnel: ./tunnel-control-mac.sh restart"
    echo "  Check status:   ./tunnel-status-mac.sh"
    echo "  View logs:      tail -f $LOG_FILE"
    echo ""
}

print_completion_message() {
    echo ""
    echo -e "${GREEN}=== Mac Setup Complete ===${NC}"
    
    print_tunnel_status
    print_client_keys_info
    print_connection_instructions
    print_management_commands
}

#===============================================================================
# Main
#===============================================================================
main() {
    parse_args "$@"
    print_configuration
    check_homebrew
    install_dependencies
    verify_ssh_access
    generate_client_keys
    authorize_client_keys
    create_launchd_service
    start_tunnel_service
    print_completion_message
}

main "$@"
