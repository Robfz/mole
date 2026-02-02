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
KEY_PATH="$HOME/.ssh/tunnel-clients"
REMOVE_KEYS=false
REMOVE_AUTH=false
UNINSTALL_TOOLS=false

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
    echo -e "${YELLOW}  Warning: $1${NC}"
}

log_error() {
    echo -e "${RED}Error: $1${NC}"
    exit 1
}

print_usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Remove SSH tunnel configuration from Mac.

Options:
  -k, --key-path PATH      Path to client keys (default: ~/.ssh/tunnel-clients)
  --remove-keys            Remove client keys directory
  --remove-auth            Remove tunnel keys from authorized_keys
  --uninstall-tools        Uninstall autossh and mosh via Homebrew
  -h, --help               Show this help message

Example:
  $(basename "$0")
  $(basename "$0") --remove-keys --remove-auth
  $(basename "$0") -k ~/my-keys --remove-keys --uninstall-tools
EOF
}

#===============================================================================
# Argument Parsing
#===============================================================================
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -k|--key-path)
                KEY_PATH="$2"
                shift 2
                ;;
            --remove-keys)
                REMOVE_KEYS=true
                shift
                ;;
            --remove-auth)
                REMOVE_AUTH=true
                shift
                ;;
            --uninstall-tools)
                UNINSTALL_TOOLS=true
                shift
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
}

print_configuration() {
    echo -e "${YELLOW}=== SSH Tunnel Mac Uninstall ===${NC}"
    echo ""
    echo "This will:"
    echo "  - Stop and remove the tunnel launchd service"
    echo "  - Remove log files"
    if [ "$REMOVE_KEYS" = true ]; then
        echo "  - Remove client keys from $KEY_PATH"
    fi
    if [ "$REMOVE_AUTH" = true ]; then
        echo "  - Remove tunnel keys from authorized_keys"
    fi
    if [ "$UNINSTALL_TOOLS" = true ]; then
        echo "  - Uninstall autossh and mosh"
    fi
    echo ""
}

#===============================================================================
# Uninstall Functions
#===============================================================================
stop_tunnel_service() {
    log_step 1 5 "Stopping tunnel service..."
    
    # Kill any running autossh processes
    if pgrep -f "autossh" > /dev/null; then
        pkill -f "autossh" 2>/dev/null || true
        log_info "Stopped autossh processes"
    fi
    
    # Kill any caffeinate processes associated with autossh
    if pgrep -f "caffeinate.*autossh" > /dev/null; then
        pkill -f "caffeinate.*autossh" 2>/dev/null || true
        log_info "Stopped caffeinate wrapper"
    fi
    
    # Unload launchd service
    if [ -f "$PLIST_PATH" ]; then
        launchctl unload "$PLIST_PATH" 2>/dev/null || true
        log_info "Unloaded launchd service"
    else
        log_info "No launchd service found"
    fi
}

remove_plist() {
    log_step 2 5 "Removing launchd plist..."
    
    if [ -f "$PLIST_PATH" ]; then
        rm -f "$PLIST_PATH"
        log_info "Removed $PLIST_PATH"
    else
        log_info "Plist already removed"
    fi
}

remove_log_files() {
    log_step 3 5 "Removing log files..."
    
    if [ -f "$LOG_FILE" ]; then
        rm -f "$LOG_FILE"
        log_info "Removed $LOG_FILE"
    fi
    
    if [ -f "$ERR_FILE" ]; then
        rm -f "$ERR_FILE"
        log_info "Removed $ERR_FILE"
    fi
}

remove_client_keys() {
    log_step 4 5 "Processing client keys..."
    
    if [ "$REMOVE_KEYS" = true ]; then
        if [ -d "$KEY_PATH" ]; then
            rm -rf "$KEY_PATH"
            log_info "Removed client keys directory: $KEY_PATH"
        else
            log_info "No client keys directory found at $KEY_PATH"
        fi
    else
        if [ -d "$KEY_PATH" ]; then
            log_info "Client keys kept at $KEY_PATH (use --remove-keys to delete)"
        else
            log_info "No client keys directory found"
        fi
    fi
}

clean_authorized_keys() {
    log_step 5 5 "Processing authorized_keys..."
    
    if [ "$REMOVE_AUTH" = true ]; then
        if [ -f ~/.ssh/authorized_keys ]; then
            local tunnel_keys
            tunnel_keys=$(grep -c "@tunnel-" ~/.ssh/authorized_keys 2>/dev/null || echo "0")
            
            if [ "$tunnel_keys" -gt 0 ]; then
                # Remove lines containing @tunnel- comment
                sed -i.bak '/@tunnel-/d' ~/.ssh/authorized_keys
                rm -f ~/.ssh/authorized_keys.bak
                log_info "Removed $tunnel_keys tunnel key(s) from authorized_keys"
            else
                log_info "No tunnel keys found in authorized_keys"
            fi
        else
            log_info "No authorized_keys file found"
        fi
    else
        if [ -f ~/.ssh/authorized_keys ]; then
            local tunnel_keys
            tunnel_keys=$(grep -c "@tunnel-" ~/.ssh/authorized_keys 2>/dev/null || echo "0")
            if [ "$tunnel_keys" -gt 0 ]; then
                log_info "Kept $tunnel_keys tunnel key(s) in authorized_keys (use --remove-auth to delete)"
            fi
        fi
    fi
}

uninstall_tools() {
    if [ "$UNINSTALL_TOOLS" = true ]; then
        echo ""
        log_info "Uninstalling autossh and mosh..."
        brew uninstall autossh mosh 2>/dev/null || log_warn "Could not uninstall tools"
        log_info "Uninstalled autossh and mosh"
    fi
}

print_completion_message() {
    echo ""
    echo -e "${GREEN}=== Mac Uninstall Complete ===${NC}"
    echo ""
    echo "The SSH tunnel has been removed from this Mac."
    echo ""
}

#===============================================================================
# Main
#===============================================================================
main() {
    parse_args "$@"
    print_configuration
    stop_tunnel_service
    remove_plist
    remove_log_files
    remove_client_keys
    clean_authorized_keys
    uninstall_tools
    print_completion_message
}

main "$@"
