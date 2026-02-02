#!/bin/bash

#===============================================================================
# Constants
#===============================================================================
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m'

# Defaults (can be overridden by flags)
PLIST_LABEL="com.robfz.mole"
PLIST_PATH="$HOME/Library/LaunchAgents/${PLIST_LABEL}.plist"
LOG_FILE="/tmp/ssh-tunnel.log"
ERR_FILE="/tmp/ssh-tunnel.err"
LOG_LINES=10
QUIET=false

#===============================================================================
# Utility Functions
#===============================================================================
print_header() {
    if [ "$QUIET" = false ]; then
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${CYAN}  SSH Tunnel Status (Mac)${NC}"
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
    fi
}

status_ok() {
    echo -e "  ${GREEN}✓${NC} $1"
}

status_warn() {
    echo -e "  ${YELLOW}⚠${NC} $1"
}

status_fail() {
    echo -e "  ${RED}✗${NC} $1"
}

status_info() {
    echo -e "  ${BLUE}ℹ${NC} $1"
}

print_usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Check the status of the SSH tunnel service.

Options:
  -l, --log-lines NUM      Number of log lines to show (default: 10)
  -q, --quiet              Only show status, no headers or troubleshooting
  --log-file PATH          Custom log file path
  --err-file PATH          Custom error log file path
  -h, --help               Show this help message

Example:
  $(basename "$0")
  $(basename "$0") --log-lines 20
  $(basename "$0") -q
EOF
}

#===============================================================================
# Argument Parsing
#===============================================================================
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -l|--log-lines)
                LOG_LINES="$2"
                shift 2
                ;;
            -q|--quiet)
                QUIET=true
                shift
                ;;
            --log-file)
                LOG_FILE="$2"
                shift 2
                ;;
            --err-file)
                ERR_FILE="$2"
                shift 2
                ;;
            -h|--help)
                print_usage
                exit 0
                ;;
            *)
                echo -e "${RED}Error: Unknown option: $1${NC}" >&2
                echo "Use --help for usage information." >&2
                exit 1
                ;;
        esac
    done
}

#===============================================================================
# Check Functions
#===============================================================================
check_launchd_service() {
    echo -e "${BLUE}Launchd Service:${NC}"
    
    # Check if plist exists
    if [ -f "$PLIST_PATH" ]; then
        status_ok "Plist file exists: $PLIST_PATH"
    else
        status_fail "Plist file not found: $PLIST_PATH"
        return
    fi
    
    # Check if service is loaded
    if launchctl list | grep -q "$PLIST_LABEL"; then
        status_ok "Service is loaded in launchd"
        
        # Get detailed status
        local exit_status
        exit_status=$(launchctl list | grep "$PLIST_LABEL" | awk '{print $1}')
        if [ "$exit_status" = "-" ]; then
            status_ok "Service is running (no exit code)"
        elif [ "$exit_status" = "0" ]; then
            status_warn "Service exited with code 0 (may have stopped)"
        else
            status_fail "Service exited with code: $exit_status"
        fi
    else
        status_fail "Service is not loaded in launchd"
    fi
    echo ""
}

check_processes() {
    echo -e "${BLUE}Running Processes:${NC}"
    
    # Check autossh
    local autossh_pid
    autossh_pid=$(pgrep -f "autossh" 2>/dev/null || true)
    if [ -n "$autossh_pid" ]; then
        status_ok "autossh is running (PID: $autossh_pid)"
    else
        status_fail "autossh is not running"
    fi
    
    # Check caffeinate
    local caffeinate_pid
    caffeinate_pid=$(pgrep -f "caffeinate.*autossh" 2>/dev/null || true)
    if [ -n "$caffeinate_pid" ]; then
        status_ok "caffeinate wrapper is running (PID: $caffeinate_pid)"
    else
        status_warn "caffeinate wrapper not found (sleep prevention may not be active)"
    fi
    
    # Check SSH tunnel connection
    local ssh_pid
    ssh_pid=$(pgrep -f "ssh.*-R.*localhost:22" 2>/dev/null || true)
    if [ -n "$ssh_pid" ]; then
        status_ok "SSH tunnel connection is active (PID: $ssh_pid)"
    else
        status_warn "SSH tunnel connection not detected (may still be establishing)"
    fi
    echo ""
}

check_tunnel_config() {
    echo -e "${BLUE}Tunnel Configuration:${NC}"
    
    if [ -f "$PLIST_PATH" ]; then
        # Extract remote host from plist
        local remote_info
        remote_info=$(grep -A1 "<string>-R</string>" "$PLIST_PATH" 2>/dev/null | tail -1 | sed 's/<[^>]*>//g' | tr -d ' ' || true)
        if [ -n "$remote_info" ]; then
            status_info "Tunnel binding: $remote_info"
        fi
        
        # Try to extract from the shell command version
        local cmd_line
        cmd_line=$(grep "caffeinate" "$PLIST_PATH" 2>/dev/null | sed 's/<[^>]*>//g' | tr -d ' ' || true)
        if [ -n "$cmd_line" ]; then
            local tunnel_port
            tunnel_port=$(echo "$cmd_line" | grep -oE '\-R [0-9]+:' | grep -oE '[0-9]+' || true)
            local remote_host
            remote_host=$(echo "$cmd_line" | grep -oE '[a-zA-Z0-9._-]+@[a-zA-Z0-9._-]+$' || true)
            
            if [ -n "$tunnel_port" ]; then
                status_info "Tunnel port: $tunnel_port"
            fi
            if [ -n "$remote_host" ]; then
                status_info "Remote server: $remote_host"
            fi
        fi
    else
        status_warn "Cannot read configuration (plist not found)"
    fi
    echo ""
}

check_network() {
    echo -e "${BLUE}Network Status:${NC}"
    
    # Check if we have network connectivity
    if ping -c 1 -W 2 8.8.8.8 &>/dev/null; then
        status_ok "Internet connectivity: OK"
    else
        status_fail "Internet connectivity: FAILED"
    fi
    
    # Try to get remote host from plist and check connectivity
    if [ -f "$PLIST_PATH" ]; then
        local remote_host
        remote_host=$(grep -oE '[a-zA-Z0-9._-]+@[a-zA-Z0-9._-]+' "$PLIST_PATH" 2>/dev/null | head -1 | cut -d'@' -f2 || true)
        if [ -n "$remote_host" ]; then
            if ping -c 1 -W 3 "$remote_host" &>/dev/null; then
                status_ok "Server reachable: $remote_host"
            else
                status_warn "Server ping failed: $remote_host (may be blocking ICMP)"
            fi
        fi
    fi
    echo ""
}

check_logs() {
    echo -e "${BLUE}Recent Logs:${NC}"
    
    if [ -f "$LOG_FILE" ]; then
        local log_lines
        log_lines=$(wc -l < "$LOG_FILE" | tr -d ' ')
        status_info "Log file: $LOG_FILE ($log_lines lines)"
        
        echo ""
        echo -e "  ${CYAN}Last $LOG_LINES lines of stdout:${NC}"
        tail -"$LOG_LINES" "$LOG_FILE" 2>/dev/null | sed 's/^/    /'
    else
        status_warn "No log file found at $LOG_FILE"
    fi
    
    echo ""
    
    if [ -f "$ERR_FILE" ]; then
        local err_lines
        err_lines=$(wc -l < "$ERR_FILE" | tr -d ' ')
        if [ "$err_lines" -gt 0 ]; then
            status_warn "Error log: $ERR_FILE ($err_lines lines)"
            echo ""
            echo -e "  ${CYAN}Last $LOG_LINES lines of stderr:${NC}"
            tail -"$LOG_LINES" "$ERR_FILE" 2>/dev/null | sed 's/^/    /'
        else
            status_ok "Error log is empty"
        fi
    else
        status_info "No error log file found"
    fi
    echo ""
}

print_troubleshooting() {
    if [ "$QUIET" = true ]; then
        return
    fi
    
    echo -e "${BLUE}Troubleshooting Commands:${NC}"
    echo ""
    echo "  Restart tunnel:"
    echo "    launchctl unload $PLIST_PATH"
    echo "    launchctl load $PLIST_PATH"
    echo ""
    echo "  Watch logs in real-time:"
    echo "    tail -f $LOG_FILE"
    echo ""
    echo "  Manual test (in foreground):"
    echo "    launchctl unload $PLIST_PATH 2>/dev/null"
    echo "    # Then run the autossh command from plist manually"
    echo ""
    echo "  Check SSH connectivity to server:"
    echo "    ssh -v user@server 'echo OK'"
    echo ""
}

#===============================================================================
# Main
#===============================================================================
main() {
    parse_args "$@"
    print_header
    check_launchd_service
    check_processes
    check_tunnel_config
    check_network
    check_logs
    print_troubleshooting
}

main "$@"
