#!/bin/bash
# ==============================================================================
#   Docker Compose Manager (DCM) v5.2
#   A streamlined CLI for managing Docker Compose projects.
# ==============================================================================

set -e

# --- Configuration ---
readonly SCRIPT_VERSION="5.2"
readonly INSTALL_PATH="/usr/local/bin/dcm"
readonly COMPOSE_FILES=("compose.yaml" "compose.yml" "docker-compose.yml" "docker-compose.yaml")
readonly HINT_COLUMN=30

# --- UI Colors ---
readonly C_RESET='\033[0m'
readonly C_RED='\033[0;31m'
readonly C_GREEN='\033[0;32m'
readonly C_YELLOW='\033[0;33m'
readonly C_CYAN='\033[1;96m'
readonly C_GRAY='\033[0;90m'

# --- Runtime State ---
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
PROJECT_NAME=""
PROJECT_ROOT_FOUND="false"
SUDO_PREFIX=""
COMPOSE_CMD=()

# ==============================================================================
#   Utility Functions
# ==============================================================================

log_msg() {
    local level="$1" msg="$2"
    case "$level" in
        INFO)   echo -e "${C_GREEN}INFO: ${msg}${C_RESET}" ;;
        WARN)   echo -e "${C_YELLOW}WARN: ${msg}${C_RESET}" ;;
        ERROR)  echo -e "${C_RED}ERROR: ${msg}${C_RESET}" ;;
        HEADER) echo -e "${C_CYAN}${msg}${C_RESET}" ;;
        *)      echo -e "${msg}" ;;
    esac
}

find_project_root() {
    local dir="$1"
    for ((i = 0; i < 10; i++)); do
        for file in "${COMPOSE_FILES[@]}"; do
            [[ -f "$dir/$file" ]] && { echo "$dir"; return 0; }
        done
        [[ "$dir" == "/" ]] && break
        dir=$(dirname "$dir")
    done
    return 1
}

run_compose() {
    ${SUDO_PREFIX:+$SUDO_PREFIX} "${COMPOSE_CMD[@]}" "$@"
}

get_inode() {
    local file="$1"
    if [[ "$(uname)" == "Darwin" ]]; then
        stat -f %i "$file" 2>/dev/null
    else
        stat -c %i "$file" 2>/dev/null
    fi
}

# ==============================================================================
#   Initialization
# ==============================================================================

init_environment() {
    local target_dir
    target_dir=$(find_project_root "$(pwd)") || true

    if [[ -z "$target_dir" && "$SCRIPT_DIR" != "/usr/local/bin" && "$SCRIPT_DIR" != "/usr/bin" ]]; then
        target_dir=$(find_project_root "$SCRIPT_DIR") || true
    fi

    if [[ -n "$target_dir" ]]; then
        cd "$target_dir" || exit 1
        PROJECT_ROOT_FOUND="true"
        PROJECT_NAME=$(basename "$(pwd)")
    else
        PROJECT_ROOT_FOUND="false"
        PROJECT_NAME="<No Config>"
    fi

    if ! command -v docker &>/dev/null; then
        [[ "$PROJECT_ROOT_FOUND" == "true" ]] && { log_msg "ERROR" "Docker is not installed."; exit 1; }
        return
    fi

    [[ "$PROJECT_ROOT_FOUND" != "true" ]] && return

    if ! timeout 5 docker ps &>/dev/null 2>&1; then
        if command -v sudo &>/dev/null; then
            SUDO_PREFIX="sudo"
            if ! timeout 5 sudo docker ps &>/dev/null 2>&1; then
                log_msg "ERROR" "Cannot connect to Docker daemon."
                exit 1
            fi
        else
            log_msg "ERROR" "No Docker permissions and 'sudo' not found."
            exit 1
        fi
    fi

    if ${SUDO_PREFIX:+$SUDO_PREFIX} docker compose version &>/dev/null; then
        COMPOSE_CMD=("docker" "compose")
    elif ${SUDO_PREFIX:+$SUDO_PREFIX} docker-compose version &>/dev/null; then
        COMPOSE_CMD=("docker-compose")
    else
        log_msg "ERROR" "Docker Compose not found."
        exit 1
    fi

    log_msg "HEADER" ">> Working Project: ${C_GRAY}$(pwd)${C_RESET}"
}

require_project() {
    if [[ "$PROJECT_ROOT_FOUND" != "true" ]]; then
        log_msg "ERROR" "No project configuration found. Command '$1' requires a valid project."
        exit 1
    fi
}

# ==============================================================================
#   Action Functions
# ==============================================================================

# --- Observability ---
show_status() {
    log_msg "HEADER" "Container Status:"
    run_compose ps
}

show_logs() {
    log_msg "HEADER" "Logs (Ctrl+C to exit):"
    run_compose logs -f --tail="100" || true
}

# --- Lifecycle ---
start_project() {
    log_msg "INFO" "Starting project '${PROJECT_NAME}'..."
    [[ -n "$(run_compose ps --filter "status=running" -q 2>/dev/null)" ]] && log_msg "WARN" "Some services are already running."
    run_compose up -d
    log_msg "INFO" "Project started."
}

stop_project() {
    log_msg "WARN" "Stopping project '${PROJECT_NAME}'..."
    run_compose down
    log_msg "INFO" "Project stopped."
}

restart_containers() {
    log_msg "HEADER" "Quick Restarting containers..."
    run_compose restart
    log_msg "INFO" "Containers restarted."
}

reload_project() {
    log_msg "HEADER" "Applying configuration..."
    run_compose up -d --remove-orphans
    log_msg "INFO" "Configuration applied."
}

# --- Maintenance ---
update_project() {
    log_msg "HEADER" "Updating project '${PROJECT_NAME}'..."
    log_msg "INFO" "1/2: Pulling new images..."
    run_compose pull
    log_msg "INFO" "2/2: Applying changes..."
    run_compose up -d --remove-orphans
    log_msg "INFO" "Project updated successfully!"
}

rebuild_project() {
    log_msg "HEADER" "Full recreation of containers..."
    run_compose up -d --force-recreate --build
    log_msg "INFO" "Containers rebuilt and started."
}

open_shell() {
    local service="$1"

    if [[ -z "$service" ]]; then
        local running_services
        mapfile -t running_services < <(run_compose ps --filter "status=running" --services)
        local count=${#running_services[@]}

        if [[ "$count" -eq 0 ]]; then
            log_msg "ERROR" "No running services. Use 'Start' first."
            return 1
        elif [[ "$count" -eq 1 ]]; then
            service="${running_services[0]}"
            log_msg "INFO" "Auto-selecting service: ${C_CYAN}${service}${C_RESET}"
        else
            log_msg "INFO" "Running services:"
            for i in "${!running_services[@]}"; do
                printf "  ${C_YELLOW}%d)${C_RESET} %s\n" "$((i + 1))" "${running_services[i]}"
            done
            read -rp "Enter service name or number: " choice
            [[ -z "$choice" ]] && { log_msg "WARN" "Cancelled."; return 1; }

            if [[ "$choice" =~ ^[0-9]+$ && "$choice" -le "$count" && "$choice" -gt 0 ]]; then
                service="${running_services[$((choice - 1))]}"
            else
                service="$choice"
            fi
        fi
    fi

    if [[ -z "$(run_compose ps --filter "status=running" --services | grep -w "$service" || true)" ]]; then
        log_msg "ERROR" "Service '$service' is not running."
        return 1
    fi

    log_msg "INFO" "Entering shell: ${C_CYAN}${service}${C_RESET}..."
    run_compose exec "$service" /bin/bash 2>/dev/null || run_compose exec "$service" /bin/sh
}

# --- Cleanup ---
prune_system() {
    command -v docker &>/dev/null || { log_msg "ERROR" "Docker is not installed."; return 1; }
    log_msg "WARN" "WARNING: This cleans your ENTIRE Docker system!"
    read -rp "Remove stopped containers, networks, and dangling images? [y/N]: " confirmation
    if [[ "$confirmation" =~ ^[Yy]$ ]]; then
        ${SUDO_PREFIX:+$SUDO_PREFIX} docker system prune -f
        log_msg "INFO" "System cleaned."
    else
        log_msg "INFO" "Cancelled."
    fi
}

destroy_project() {
    log_msg "ERROR" "!!! WARNING: DESTROYING PROJECT !!!"
    log_msg "WARN" "Containers, networks, and ALL DATA IN VOLUMES will be deleted."
    read -rp "Are you sure? [y/N]: " confirmation
    if [[ "$confirmation" =~ ^[Yy]$ ]]; then
        run_compose down -v --rmi local
        log_msg "INFO" "Project destroyed."
    else
        log_msg "INFO" "Cancelled."
    fi
}

# --- Installation ---
install_globally() {
    log_msg "HEADER" "Global Installation"
    echo -e "Target: ${C_CYAN}${INSTALL_PATH}${C_RESET}"
    [[ -f "$INSTALL_PATH" ]] && log_msg "INFO" "Existing installation found. Will update."

    read -rp "Install/Update 'dcm' globally? [y/N]: " confirmation
    [[ ! "$confirmation" =~ ^[Yy]$ ]] && { log_msg "INFO" "Cancelled."; return; }

    if [[ -f "$INSTALL_PATH" && "$(get_inode "${BASH_SOURCE[0]}")" == "$(get_inode "$INSTALL_PATH")" ]]; then
        log_msg "ERROR" "You are running the installed version. Run from source directory to update."
        return 1
    fi

    local install_dir use_sudo=false
    install_dir=$(dirname "$INSTALL_PATH")
    [[ ! -w "$install_dir" || (-f "$INSTALL_PATH" && ! -w "$INSTALL_PATH") ]] && use_sudo=true

    if [[ "$use_sudo" == "false" ]]; then
        cp "${BASH_SOURCE[0]}" "$INSTALL_PATH" && chmod 755 "$INSTALL_PATH"
        log_msg "INFO" "Installed to $INSTALL_PATH"
    elif command -v sudo &>/dev/null; then
        log_msg "WARN" "Requesting root permissions..."
        sudo cp "${BASH_SOURCE[0]}" "$INSTALL_PATH" && sudo chmod 755 "$INSTALL_PATH"
        log_msg "INFO" "Installed to $INSTALL_PATH (via sudo)"
    else
        log_msg "ERROR" "Cannot write to $INSTALL_PATH and 'sudo' is not available."
        return 1
    fi
}

uninstall_globally() {
    log_msg "HEADER" "Global Uninstallation"
    [[ ! -f "$INSTALL_PATH" ]] && { log_msg "WARN" "No installation found at $INSTALL_PATH"; return; }

    echo -e "Will remove: ${C_CYAN}${INSTALL_PATH}${C_RESET}"
    read -rp "Uninstall 'dcm'? [y/N]: " confirmation
    [[ ! "$confirmation" =~ ^[Yy]$ ]] && { log_msg "INFO" "Cancelled."; return; }

    local install_dir
    install_dir=$(dirname "$INSTALL_PATH")

    if [[ -w "$install_dir" ]]; then
        rm -f "$INSTALL_PATH"
        log_msg "INFO" "Uninstalled from $INSTALL_PATH"
    elif command -v sudo &>/dev/null; then
        sudo rm -f "$INSTALL_PATH"
        log_msg "INFO" "Uninstalled from $INSTALL_PATH (via sudo)"
    else
        log_msg "ERROR" "Cannot remove $INSTALL_PATH and 'sudo' is not available."
        return 1
    fi
}

# ==============================================================================
#   Interactive Menu
# ==============================================================================

show_interactive_menu() {
    trap 'return' SIGINT

    while true; do
        local TOTAL_SVCS UP_SVCS STATUS_LINE

        if [[ "$PROJECT_ROOT_FOUND" == "true" ]]; then
            TOTAL_SVCS=$(run_compose config --services 2>/dev/null | grep -c . || true)
            UP_SVCS=$(run_compose ps -q 2>/dev/null | grep -c . || true)

            if [[ "$UP_SVCS" -eq 0 ]]; then
                STATUS_LINE="${C_RED}STOPPED${C_RESET}"
            elif [[ "$UP_SVCS" -ge "$TOTAL_SVCS" && "$TOTAL_SVCS" -gt 0 ]]; then
                STATUS_LINE="${C_GREEN}RUNNING (${UP_SVCS}/${TOTAL_SVCS})${C_RESET}"
            else
                STATUS_LINE="${C_YELLOW}PARTIAL (${UP_SVCS}/${TOTAL_SVCS})${C_RESET}"
            fi
        else
            STATUS_LINE="${C_YELLOW}NO CONFIG FOUND${C_RESET}"
        fi

        local fmt_val=" [${C_YELLOW}%s${C_RESET}] %s\033[${HINT_COLUMN}G${C_GRAY}%s${C_RESET}\n"
        local fmt_danger=" [${C_YELLOW}%s${C_RESET}] %s\033[${HINT_COLUMN}G${C_RED}%s${C_RESET}\n"

        clear
        echo -e "${C_CYAN}======================================================================${C_RESET}"
        echo -e "   DCM:     ${C_GREEN}v${SCRIPT_VERSION}${C_RESET}"
        echo -e "   Project: ${C_CYAN}${PROJECT_NAME}${C_RESET}"
        echo -e "   Path:    ${C_GRAY}$(pwd)${C_RESET}"
        echo -e "   Status:  ${STATUS_LINE}"
        [[ -n "$SUDO_PREFIX" ]] && echo -e "   Mode:    ${C_RED}SUDO (Privileged)${C_RESET}"
        echo -e "${C_CYAN}======================================================================${C_RESET}"

        if [[ "$PROJECT_ROOT_FOUND" == "true" ]]; then
            echo -e "${C_GRAY}--- Project Actions ---${C_RESET}"
            printf "$fmt_val" "1" "Status (PS)" "Show processes"
            printf "$fmt_val" "2" "Logs" "Follow output"
            printf "$fmt_val" "3" "Shell" "Enter container"
            echo ""
            printf "$fmt_val" "4" "Start" "up -d"
            printf "$fmt_val" "5" "Stop" "down"
            printf "$fmt_val" "6" "Restart" "Quick restart"
            printf "$fmt_val" "7" "Reload" "Apply config"
            printf "$fmt_val" "8" "Update" "pull + up"
            printf "$fmt_val" "9" "Rebuild" "force-recreate"
            echo ""
            printf "$fmt_danger" "10" "DESTROY" "down -v --rmi"
            echo ""
        fi

        echo -e "${C_GRAY}--- System Actions ---${C_RESET}"
        printf "$fmt_danger" "11" "System Prune" "docker system prune"
        echo ""
        echo -e "${C_GRAY}--- Global Actions ---${C_RESET}"
        printf "$fmt_val" "i" "Install" "Install to $INSTALL_PATH"
        printf "$fmt_val" "u" "Uninstall" "Remove from $INSTALL_PATH"
        printf "$fmt_val" "0" "Exit" ""
        echo -e "${C_CYAN}======================================================================${C_RESET}"

        read -rp "Selection: " choice

        case "$choice" in
            11|i|I|u|U|0) ;;
            *)
                if [[ "$PROJECT_ROOT_FOUND" != "true" ]]; then
                    log_msg "ERROR" "No project configuration found."
                    read -rp "Press Enter to continue..."
                    continue
                fi
                ;;
        esac

        case "$choice" in
            1)  show_status ;;
            2)  show_logs ;;
            3)  open_shell ;;
            4)  start_project ;;
            5)  stop_project ;;
            6)  restart_containers ;;
            7)  reload_project ;;
            8)  update_project ;;
            9)  rebuild_project ;;
            10) destroy_project ;;
            11) prune_system ;;
            i|I) install_globally ;;
            u|U) uninstall_globally ;;
            0)  exit 0 ;;
            *)  log_msg "ERROR" "Unknown option." ;;
        esac

        echo ""
        read -rp "Press Enter to continue..."
    done
}

# ==============================================================================
#   Main Entry Point
# ==============================================================================

case "${1:-}" in
    install)   install_globally; exit $? ;;
    uninstall) uninstall_globally; exit $? ;;
    prune)     init_environment; prune_system ;;
    "")        init_environment; show_interactive_menu ;;
    *)
        init_environment
        require_project "$1"
        case "$1" in
            start)   start_project ;;
            stop)    stop_project ;;
            restart) restart_containers ;;
            reload)  reload_project ;;
            update)  update_project ;;
            rebuild) rebuild_project ;;
            status)  show_status ;;
            logs)    show_logs ;;
            shell)   open_shell "$2" ;;
            destroy) destroy_project ;;
            *)
                log_msg "ERROR" "Unknown command: $1"
                echo "Usage: $0 {start|stop|restart|reload|update|rebuild|status|logs|shell|prune|destroy|install|uninstall}"
                exit 1
                ;;
        esac
        ;;
esac
