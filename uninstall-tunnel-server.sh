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

readonly SSHD_CONFIG="/etc/ssh/sshd_config"
readonly MOSH_PORT_START=60000
readonly MOSH_PORT_END=61000

# Global config (set by parse_args)
TUNNEL_PORT="2222"
UNINSTALL_MOSH=false

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

Remove SSH tunnel server configuration.

Options:
  -p, --tunnel-port PORT   Tunnel port to remove from firewall (default: 2222)
  --uninstall-mosh         Also uninstall mosh
  -h, --help               Show this help message

Example:
  $(basename "$0") --tunnel-port 2222
  $(basename "$0") -p 2222 --uninstall-mosh
EOF
}

#===============================================================================
# Argument Parsing
#===============================================================================
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -p|--tunnel-port)
                TUNNEL_PORT="$2"
                shift 2
                ;;
            --uninstall-mosh)
                UNINSTALL_MOSH=true
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
}

print_configuration() {
    echo -e "${YELLOW}=== SSH Tunnel Server Uninstall ===${NC}"
    echo ""
    echo "This will:"
    echo "  - Restore sshd_config from backup (if available)"
    echo "  - Remove firewall rules for port $TUNNEL_PORT"
    if [ "$UNINSTALL_MOSH" = true ]; then
        echo "  - Uninstall mosh"
    fi
    echo ""
}

#===============================================================================
# Uninstall Functions
#===============================================================================
restore_sshd_config() {
    log_step 1 4 "Restoring SSH configuration..."
    
    if [ -f "${SSHD_CONFIG}.backup" ]; then
        sudo cp "${SSHD_CONFIG}.backup" "$SSHD_CONFIG"
        log_info "Restored sshd_config from backup"
    else
        # Just remove the GatewayPorts line we added
        if grep -q "^GatewayPorts clientspecified" "$SSHD_CONFIG"; then
            sudo sed -i '/^GatewayPorts clientspecified/d' "$SSHD_CONFIG"
            log_info "Removed GatewayPorts setting"
        else
            log_info "No GatewayPorts setting found to remove"
        fi
    fi
}

remove_firewall_rules() {
    log_step 2 4 "Removing firewall rules..."
    
    if command -v ufw &> /dev/null; then
        log_info "Using ufw..."
        sudo ufw delete allow "${TUNNEL_PORT}/tcp" 2>/dev/null || log_warn "TCP rule not found"
        sudo ufw delete allow "${MOSH_PORT_START}:${MOSH_PORT_END}/udp" 2>/dev/null || log_warn "UDP rule not found"
        sudo ufw --force reload
    elif command -v firewall-cmd &> /dev/null; then
        log_info "Using firewalld..."
        sudo firewall-cmd --permanent --remove-port="${TUNNEL_PORT}/tcp" 2>/dev/null || log_warn "TCP rule not found"
        sudo firewall-cmd --permanent --remove-port="${MOSH_PORT_START}-${MOSH_PORT_END}/udp" 2>/dev/null || log_warn "UDP rule not found"
        sudo firewall-cmd --reload
    else
        log_warn "No firewall detected. Manually remove rules if needed."
    fi
}

uninstall_mosh() {
    log_step 3 4 "Checking mosh installation..."
    
    if [ "$UNINSTALL_MOSH" = true ]; then
        if command -v mosh &> /dev/null; then
            if command -v apt &> /dev/null; then
                sudo apt remove -y mosh
            elif command -v dnf &> /dev/null; then
                sudo dnf remove -y mosh
            elif command -v yum &> /dev/null; then
                sudo yum remove -y mosh
            fi
            log_info "Mosh uninstalled"
        else
            log_info "Mosh not installed"
        fi
    else
        log_info "Mosh kept installed (use --uninstall-mosh to remove)"
    fi
}

restart_ssh_service() {
    log_step 4 4 "Restarting SSH service..."
    
    if command -v systemctl &> /dev/null; then
        sudo systemctl restart sshd
    else
        sudo service sshd restart
    fi
}

print_completion_message() {
    echo ""
    echo -e "${GREEN}=== Server Uninstall Complete ===${NC}"
    echo ""
    echo "The SSH tunnel server configuration has been removed."
    echo ""
}

#===============================================================================
# Main
#===============================================================================
main() {
    parse_args "$@"
    print_configuration
    restore_sshd_config
    remove_firewall_rules
    uninstall_mosh
    restart_ssh_service
    print_completion_message
}

main "$@"
