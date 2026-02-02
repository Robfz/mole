#!/bin/bash

#===============================================================================
# Constants
#===============================================================================
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

readonly PLIST_LABEL="com.robfz.mole"
readonly PLIST_PATH="$HOME/Library/LaunchAgents/${PLIST_LABEL}.plist"

#===============================================================================
# Utility Functions
#===============================================================================
status_ok() {
    echo -e "${GREEN}✓${NC} $1"
}

status_fail() {
    echo -e "${RED}✗${NC} $1"
}

status_info() {
    echo -e "${BLUE}ℹ${NC} $1"
}

print_usage() {
    cat << EOF
Usage: $(basename "$0") <command>

Control the SSH tunnel service.

Commands:
  start       Start the tunnel
  stop        Stop the tunnel
  restart     Restart the tunnel
  status      Show tunnel status (brief)

Example:
  $(basename "$0") start
  $(basename "$0") stop
  $(basename "$0") restart
EOF
}

#===============================================================================
# Control Functions
#===============================================================================
check_plist() {
    if [ ! -f "$PLIST_PATH" ]; then
        status_fail "Tunnel not configured. Run setup-tunnel-mac.sh first."
        exit 1
    fi
}

is_running() {
    pgrep -f "autossh" > /dev/null 2>&1
}

start_tunnel() {
    check_plist
    
    if is_running; then
        status_info "Tunnel is already running"
        return 0
    fi
    
    launchctl load "$PLIST_PATH" 2>/dev/null
    sleep 2
    
    if is_running; then
        status_ok "Tunnel started"
    else
        status_fail "Failed to start tunnel. Check: tail -f /tmp/ssh-tunnel.log"
        exit 1
    fi
}

stop_tunnel() {
    check_plist
    
    if ! is_running; then
        status_info "Tunnel is not running"
        return 0
    fi
    
    launchctl unload "$PLIST_PATH" 2>/dev/null
    
    # Also kill any lingering processes
    pkill -f "autossh" 2>/dev/null || true
    pkill -f "caffeinate.*autossh" 2>/dev/null || true
    
    sleep 1
    
    if is_running; then
        status_fail "Failed to stop tunnel"
        exit 1
    else
        status_ok "Tunnel stopped"
    fi
}

restart_tunnel() {
    check_plist
    
    status_info "Restarting tunnel..."
    
    # Stop
    launchctl unload "$PLIST_PATH" 2>/dev/null || true
    pkill -f "autossh" 2>/dev/null || true
    pkill -f "caffeinate.*autossh" 2>/dev/null || true
    sleep 1
    
    # Start
    launchctl load "$PLIST_PATH" 2>/dev/null
    sleep 2
    
    if is_running; then
        status_ok "Tunnel restarted"
    else
        status_fail "Failed to restart tunnel. Check: tail -f /tmp/ssh-tunnel.log"
        exit 1
    fi
}

show_status() {
    check_plist
    
    if is_running; then
        status_ok "Tunnel is running"
        
        # Show PIDs
        local autossh_pid
        autossh_pid=$(pgrep -f "autossh" 2>/dev/null || true)
        if [ -n "$autossh_pid" ]; then
            echo "  autossh PID: $autossh_pid"
        fi
    else
        status_fail "Tunnel is not running"
        exit 1
    fi
}

#===============================================================================
# Main
#===============================================================================
main() {
    local command="${1:-}"
    
    case "$command" in
        start)
            start_tunnel
            ;;
        stop)
            stop_tunnel
            ;;
        restart)
            restart_tunnel
            ;;
        status)
            show_status
            ;;
        -h|--help|help)
            print_usage
            ;;
        "")
            print_usage
            exit 1
            ;;
        *)
            echo -e "${RED}Error: Unknown command: $command${NC}" >&2
            echo "Use --help for usage information." >&2
            exit 1
            ;;
    esac
}

main "$@"
