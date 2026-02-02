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

Configure a Linux server for SSH tunnel access with Mosh support.

Options:
  -p, --tunnel-port PORT   Port for reverse tunnel (default: 2222)
  -h, --help               Show this help message

Example:
  $(basename "$0") --tunnel-port 2222
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
    echo -e "${GREEN}=== SSH Tunnel Server Setup ===${NC}"
    echo ""
    echo -e "${YELLOW}Configuration:${NC}"
    echo "  Tunnel port: $TUNNEL_PORT"
    echo "  Mosh UDP ports: ${MOSH_PORT_START}-${MOSH_PORT_END}"
    echo ""
}

#===============================================================================
# Setup Functions
#===============================================================================
detect_package_manager() {
    if command -v apt &> /dev/null; then
        echo "apt"
    elif command -v dnf &> /dev/null; then
        echo "dnf"
    elif command -v yum &> /dev/null; then
        echo "yum"
    else
        log_error "No supported package manager found (apt/dnf/yum)"
    fi
}

install_mosh() {
    log_step 1 4 "Installing mosh..."
    
    local pkg_manager
    pkg_manager=$(detect_package_manager)
    
    case "$pkg_manager" in
        apt)
            sudo apt update && sudo apt install -y mosh
            ;;
        dnf)
            sudo dnf install -y mosh
            ;;
        yum)
            sudo yum install -y mosh
            ;;
    esac
}

configure_sshd() {
    log_step 2 4 "Configuring SSH for gateway ports..."
    
    # Backup original config
    if [ ! -f "${SSHD_CONFIG}.backup" ]; then
        sudo cp "$SSHD_CONFIG" "${SSHD_CONFIG}.backup"
        log_info "Backed up sshd_config"
    fi
    
    # Configure GatewayPorts
    if grep -q "^GatewayPorts" "$SSHD_CONFIG"; then
        sudo sed -i 's/^GatewayPorts.*/GatewayPorts clientspecified/' "$SSHD_CONFIG"
        log_info "Updated existing GatewayPorts setting"
    else
        echo "GatewayPorts clientspecified" | sudo tee -a "$SSHD_CONFIG" > /dev/null
        log_info "Added GatewayPorts setting"
    fi
}

configure_firewall() {
    log_step 3 4 "Configuring firewall..."
    
    if command -v ufw &> /dev/null; then
        log_info "Using ufw..."
        sudo ufw allow "${TUNNEL_PORT}/tcp" comment 'SSH tunnel port'
        sudo ufw allow "${MOSH_PORT_START}:${MOSH_PORT_END}/udp" comment 'Mosh UDP ports'
        sudo ufw --force reload
    elif command -v firewall-cmd &> /dev/null; then
        log_info "Using firewalld..."
        sudo firewall-cmd --permanent --add-port="${TUNNEL_PORT}/tcp"
        sudo firewall-cmd --permanent --add-port="${MOSH_PORT_START}-${MOSH_PORT_END}/udp"
        sudo firewall-cmd --reload
    else
        log_warn "No firewall detected. Manually ensure ports are open:"
        echo "    - TCP: $TUNNEL_PORT"
        echo "    - UDP: ${MOSH_PORT_START}-${MOSH_PORT_END}"
    fi
}

restart_ssh_service() {
    log_step 4 4 "Restarting SSH service..."
    
    if command -v systemctl &> /dev/null; then
        # Debian/Ubuntu use 'ssh', RHEL/CentOS use 'sshd'
        if systemctl list-units --type=service | grep -q 'ssh.service'; then
            sudo systemctl restart ssh
        else
            sudo systemctl restart sshd
        fi
    else
        sudo service ssh restart 2>/dev/null || sudo service sshd restart
    fi
}

print_completion_message() {
    local hostname
    hostname=$(hostname -f 2>/dev/null || hostname)
    
    echo ""
    echo -e "${GREEN}=== Server Setup Complete ===${NC}"
    echo ""
    echo -e "${BLUE}Next steps:${NC}"
    echo "  1. Run setup-tunnel-mac.sh on your Mac"
    echo "  2. The Mac will establish a reverse tunnel to port $TUNNEL_PORT"
    echo "  3. Clients can then:"
    echo "     mosh user@${hostname}"
    echo "     ssh -p $TUNNEL_PORT mac-user@localhost"
    echo ""
}

#===============================================================================
# Main
#===============================================================================
main() {
    parse_args "$@"
    print_configuration
    install_mosh
    configure_sshd
    configure_firewall
    restart_ssh_service
    print_completion_message
}

main "$@"
