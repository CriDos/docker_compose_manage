#!/usr/bin/env bash
# ==============================================================================
#   Docker Compose Manager (DCM) v6.0
#   A small CLI for managing Docker Compose projects.
# ==============================================================================

set -Eeuo pipefail

# --- Configuration ---
readonly SCRIPT_VERSION="6.0"
readonly INSTALL_PATH="/usr/local/bin/dcm"
readonly REMOTE_SCRIPT_URL="https://raw.githubusercontent.com/CriDos/docker_compose_manage/main/dcm.sh"
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
PROJECT_ROOT=""
COMPOSE_CMD=()
INSTALL_SOURCE=""
INSTALL_SOURCE_TEMP=""

# ==============================================================================
#   Utilities
# ==============================================================================

log_msg() {
    local level="$1" msg="$2"
    case "$level" in
        INFO)   printf "${C_GREEN}INFO: %s${C_RESET}\n" "$msg" ;;
        WARN)   printf "${C_YELLOW}WARN: %s${C_RESET}\n" "$msg" ;;
        ERROR)  printf "${C_RED}ERROR: %s${C_RESET}\n" "$msg" >&2 ;;
        HEADER) printf "${C_CYAN}%s${C_RESET}\n" "$msg" ;;
        *)      printf "%s\n" "$msg" ;;
    esac
}

die() {
    log_msg "ERROR" "$1"
    exit "${2:-1}"
}

has_cmd() {
    command -v "$1" &>/dev/null
}

confirm() {
    local prompt="$1" answer
    read -rp "$prompt [y/N]: " answer
    [[ "$answer" =~ ^[Yy]$ ]]
}

run_with_timeout() {
    local seconds="$1"
    shift

    if has_cmd timeout; then
        timeout "$seconds" "$@"
    else
        "$@"
    fi
}

warn_if_sudo() {
    if [[ "${EUID:-$(id -u)}" -eq 0 && -n "${SUDO_USER:-}" ]]; then
        log_msg "WARN" "Running DCM through sudo is usually unnecessary. Prefer fixing Docker permissions for '${SUDO_USER}'."
    fi
}

refuse_unwanted_root() {
    local command="$1"

    if [[ "${EUID:-$(id -u)}" -eq 0 && -n "${SUDO_USER:-}" && "${DCM_ALLOW_ROOT:-}" != "1" ]]; then
        log_msg "ERROR" "Refusing to run '$command' through sudo."
        log_msg "WARN" "Run DCM as your normal user and fix Docker access instead:"
        log_msg "WARN" "  sudo usermod -aG docker ${SUDO_USER}"
        log_msg "WARN" "  newgrp docker"
        log_msg "WARN" "If you really need root, rerun with DCM_ALLOW_ROOT=1."
        exit 1
    fi
}

docker_permission_hint() {
    local user_name="${USER:-your-user}"
    [[ -n "${SUDO_USER:-}" ]] && user_name="$SUDO_USER"

    log_msg "ERROR" "Cannot access the Docker daemon as '${user_name}'."
    log_msg "WARN" "DCM no longer auto-runs Docker through sudo. This avoids root-owned files and surprise privileged sessions."
    log_msg "WARN" "Typical fix: sudo usermod -aG docker ${user_name}"
    log_msg "WARN" "Then log out/in, or run: newgrp docker"
}

find_project_root() {
    local dir="$1" parent file

    while [[ -n "$dir" ]]; do
        for file in "${COMPOSE_FILES[@]}"; do
            [[ -f "$dir/$file" ]] && { printf "%s\n" "$dir"; return 0; }
        done

        parent=$(dirname "$dir")
        [[ "$parent" == "$dir" ]] && break
        dir="$parent"
    done

    return 1
}

get_inode() {
    local file="$1"
    if [[ "$(uname)" == "Darwin" ]]; then
        stat -f %i "$file" 2>/dev/null
    else
        stat -c %i "$file" 2>/dev/null
    fi
}

prepare_install_source() {
    local source="${BASH_SOURCE[0]}" temp

    if [[ -f "$source" && -r "$source" && "$source" != /dev/fd/* && "$source" != /proc/*/fd/* ]]; then
        INSTALL_SOURCE="$source"
        return 0
    fi

    temp=$(mktemp "${TMPDIR:-/tmp}/dcm-install.XXXXXX") || return
    INSTALL_SOURCE="$temp"
    INSTALL_SOURCE_TEMP="$temp"

    if has_cmd curl; then
        curl -fsSL "$REMOTE_SCRIPT_URL" -o "$temp" || return
    elif has_cmd wget; then
        wget -qO "$temp" "$REMOTE_SCRIPT_URL" || return
    else
        log_msg "ERROR" "Cannot prepare install source. Install curl or wget, or run from a local dcm.sh file."
        return 1
    fi

    chmod 755 "$temp" || return
}

cleanup_install_source() {
    if [[ -n "$INSTALL_SOURCE_TEMP" && -f "$INSTALL_SOURCE_TEMP" ]]; then
        rm -f "$INSTALL_SOURCE_TEMP"
        INSTALL_SOURCE_TEMP=""
    fi
}

usage() {
    cat <<USAGE
Docker Compose Manager v${SCRIPT_VERSION}

Usage:
  dcm [command] [args]

Commands:
  start       Start the project
  stop        Stop the project
  restart     Restart running containers
  reload      Apply compose config changes
  update      Pull images and apply changes
  rebuild     Rebuild and recreate containers
  status      Show compose status
  logs        Follow logs
  shell [svc] Open a shell in a running service
  prune       Prune unused Docker objects
  destroy     Remove project containers, volumes, and local images
  install     Install this script to ${INSTALL_PATH}
  uninstall   Remove ${INSTALL_PATH}
  help        Show this help
USAGE
}

# ==============================================================================
#   Initialization
# ==============================================================================

load_project() {
    local target_dir=""

    target_dir=$(find_project_root "$(pwd)") || true
    if [[ -z "$target_dir" && "$SCRIPT_DIR" != "/usr/local/bin" && "$SCRIPT_DIR" != "/usr/bin" ]]; then
        target_dir=$(find_project_root "$SCRIPT_DIR") || true
    fi

    if [[ -n "$target_dir" ]]; then
        cd "$target_dir" || die "Cannot enter project directory: $target_dir"
        PROJECT_ROOT="$target_dir"
        PROJECT_NAME=$(basename "$target_dir")
    else
        PROJECT_ROOT=""
        PROJECT_NAME="<No Config>"
    fi
}

require_project() {
    if [[ -z "$PROJECT_ROOT" ]]; then
        log_msg "ERROR" "No compose file found. Command '$1' requires a project."
        return 1
    fi
}

require_docker() {
    has_cmd docker || die "Docker is not installed or not in PATH."
    warn_if_sudo

    if ! run_with_timeout 5 docker info &>/dev/null; then
        docker_permission_hint
        exit 1
    fi
}

detect_compose() {
    if docker compose version &>/dev/null; then
        COMPOSE_CMD=("docker" "compose")
    elif has_cmd docker-compose && docker-compose version &>/dev/null; then
        COMPOSE_CMD=("docker-compose")
    else
        die "Docker Compose not found. Install the Docker Compose plugin or docker-compose."
    fi
}

init_project_environment() {
    load_project
    require_project "$1" || exit 1
    require_docker
    detect_compose
    log_msg "HEADER" ">> Working Project: ${C_GRAY}${PROJECT_ROOT}${C_RESET}"
}

init_system_environment() {
    load_project
    require_docker
}

run_compose() {
    "${COMPOSE_CMD[@]}" "$@"
}

run_docker() {
    docker "$@"
}

# ==============================================================================
#   Actions
# ==============================================================================

show_status() {
    log_msg "HEADER" "Container Status:"
    run_compose ps || return
}

show_logs() {
    local rc

    log_msg "HEADER" "Logs (Ctrl+C to exit):"
    run_compose logs -f --tail=100
    rc=$?
    [[ "$rc" -eq 130 ]] && return 0
    return "$rc"
}

start_project() {
    log_msg "INFO" "Starting project '${PROJECT_NAME}'..."
    if [[ -n "$(run_compose ps --filter status=running -q 2>/dev/null)" ]]; then
        log_msg "WARN" "Some services are already running."
    fi
    run_compose up -d || return
    log_msg "INFO" "Project started."
}

stop_project() {
    log_msg "WARN" "Stopping project '${PROJECT_NAME}'..."
    run_compose down || return
    log_msg "INFO" "Project stopped."
}

restart_containers() {
    log_msg "HEADER" "Restarting containers..."
    run_compose restart || return
    log_msg "INFO" "Containers restarted."
}

reload_project() {
    log_msg "HEADER" "Applying configuration..."
    run_compose up -d --remove-orphans || return
    log_msg "INFO" "Configuration applied."
}

update_project() {
    log_msg "HEADER" "Updating project '${PROJECT_NAME}'..."
    log_msg "INFO" "1/2: Pulling new images..."
    run_compose pull || return
    log_msg "INFO" "2/2: Applying changes..."
    run_compose up -d --remove-orphans || return
    log_msg "INFO" "Project updated successfully."
}

rebuild_project() {
    log_msg "HEADER" "Rebuilding containers..."
    run_compose up -d --force-recreate --build || return
    log_msg "INFO" "Containers rebuilt and started."
}

open_shell() {
    local service="${1:-}" choice service_name
    local running_services=()

    while IFS= read -r service_name; do
        [[ -n "$service_name" ]] && running_services+=("$service_name")
    done < <(run_compose ps --filter status=running --services)

    if [[ -z "$service" ]]; then
        case "${#running_services[@]}" in
            0)
                log_msg "ERROR" "No running services. Start the project first."
                return 1
                ;;
            1)
                service="${running_services[0]}"
                log_msg "INFO" "Auto-selecting service: ${service}"
                ;;
            *)
                log_msg "INFO" "Running services:"
                for i in "${!running_services[@]}"; do
                    printf "  ${C_YELLOW}%d)${C_RESET} %s\n" "$((i + 1))" "${running_services[i]}"
                done
                read -rp "Enter service name or number: " choice
                [[ -n "$choice" ]] || { log_msg "WARN" "Cancelled."; return 1; }

                if [[ "$choice" =~ ^[0-9]+$ && "$choice" -gt 0 && "$choice" -le "${#running_services[@]}" ]]; then
                    service="${running_services[$((choice - 1))]}"
                else
                    service="$choice"
                fi
                ;;
        esac
    fi

    if ! printf "%s\n" "${running_services[@]}" | grep -Fxq -- "$service"; then
        log_msg "ERROR" "Service '$service' is not running."
        return 1
    fi

    log_msg "INFO" "Entering shell: ${service}..."
    run_compose exec "$service" /bin/bash 2>/dev/null || run_compose exec "$service" /bin/sh || return
}

prune_system() {
    log_msg "WARN" "This cleans unused Docker objects across the whole host."
    if confirm "Remove stopped containers, unused networks, and dangling images?"; then
        run_docker system prune -f || return
        log_msg "INFO" "System cleaned."
    else
        log_msg "INFO" "Cancelled."
    fi
}

destroy_project() {
    log_msg "ERROR" "!!! WARNING: DESTROYING PROJECT !!!"
    log_msg "WARN" "Containers, networks, and all data in volumes will be deleted."
    if confirm "Are you sure?"; then
        run_compose down -v --rmi local || return
        log_msg "INFO" "Project destroyed."
    else
        log_msg "INFO" "Cancelled."
    fi
}

# ==============================================================================
#   Installation
# ==============================================================================

install_globally() {
    local install_dir use_sudo=false

    log_msg "HEADER" "Global Installation"
    printf "Target: ${C_CYAN}%s${C_RESET}\n" "$INSTALL_PATH"
    [[ -f "$INSTALL_PATH" ]] && log_msg "INFO" "Existing installation found. Will update."

    confirm "Install/Update 'dcm' globally?" || { log_msg "INFO" "Cancelled."; return 0; }

    prepare_install_source || return

    if [[ -z "$INSTALL_SOURCE_TEMP" && -f "$INSTALL_PATH" && "$(get_inode "$INSTALL_SOURCE")" == "$(get_inode "$INSTALL_PATH")" ]]; then
        log_msg "ERROR" "You are running the installed version. Run from the source directory to update."
        cleanup_install_source
        return 1
    fi

    install_dir=$(dirname "$INSTALL_PATH")
    [[ ! -w "$install_dir" || (-f "$INSTALL_PATH" && ! -w "$INSTALL_PATH") ]] && use_sudo=true

    if [[ "$use_sudo" == "false" ]]; then
        cp "$INSTALL_SOURCE" "$INSTALL_PATH" || { cleanup_install_source; return 1; }
        chmod 755 "$INSTALL_PATH" || { cleanup_install_source; return 1; }
        log_msg "INFO" "Installed to $INSTALL_PATH"
    elif has_cmd sudo; then
        log_msg "WARN" "Requesting root permissions for installation only..."
        sudo install -m 755 "$INSTALL_SOURCE" "$INSTALL_PATH" || { cleanup_install_source; return 1; }
        log_msg "INFO" "Installed to $INSTALL_PATH"
    else
        log_msg "ERROR" "Cannot write to $INSTALL_PATH and 'sudo' is not available."
        cleanup_install_source
        return 1
    fi

    cleanup_install_source
}

uninstall_globally() {
    local install_dir

    log_msg "HEADER" "Global Uninstallation"
    [[ -f "$INSTALL_PATH" ]] || { log_msg "WARN" "No installation found at $INSTALL_PATH"; return 0; }

    printf "Will remove: ${C_CYAN}%s${C_RESET}\n" "$INSTALL_PATH"
    confirm "Uninstall 'dcm'?" || { log_msg "INFO" "Cancelled."; return 0; }

    install_dir=$(dirname "$INSTALL_PATH")
    if [[ -w "$install_dir" ]]; then
        rm -f "$INSTALL_PATH" || return
    elif has_cmd sudo; then
        log_msg "WARN" "Requesting root permissions for uninstallation only..."
        sudo rm -f "$INSTALL_PATH" || return
    else
        log_msg "ERROR" "Cannot remove $INSTALL_PATH and 'sudo' is not available."
        return 1
    fi

    log_msg "INFO" "Uninstalled from $INSTALL_PATH"
}

# ==============================================================================
#   Interactive Menu
# ==============================================================================

project_status_line() {
    local total_svcs=0 up_svcs=0

    if [[ -z "$PROJECT_ROOT" ]]; then
        printf "${C_YELLOW}NO CONFIG FOUND${C_RESET}"
        return
    fi

    if [[ "${#COMPOSE_CMD[@]}" -eq 0 ]]; then
        printf "${C_YELLOW}DOCKER UNAVAILABLE${C_RESET}"
        return
    fi

    total_svcs=$(run_compose config --services 2>/dev/null | grep -c . || true)
    up_svcs=$(run_compose ps -q 2>/dev/null | grep -c . || true)

    if [[ "$up_svcs" -eq 0 ]]; then
        printf "${C_RED}STOPPED${C_RESET}"
    elif [[ "$up_svcs" -ge "$total_svcs" && "$total_svcs" -gt 0 ]]; then
        printf "${C_GREEN}RUNNING (%s/%s)${C_RESET}" "$up_svcs" "$total_svcs"
    else
        printf "${C_YELLOW}PARTIAL (%s/%s)${C_RESET}" "$up_svcs" "$total_svcs"
    fi
}

show_interactive_menu() {
    local choice status_line
    local fmt_val=" [${C_YELLOW}%s${C_RESET}] %s\033[${HINT_COLUMN}G${C_GRAY}%s${C_RESET}\n"
    local fmt_danger=" [${C_YELLOW}%s${C_RESET}] %s\033[${HINT_COLUMN}G${C_RED}%s${C_RESET}\n"

    trap 'return' INT

    while true; do
        status_line=$(project_status_line)

        clear
        printf "${C_CYAN}======================================================================${C_RESET}\n"
        printf "   DCM:     ${C_GREEN}v%s${C_RESET}\n" "$SCRIPT_VERSION"
        printf "   Project: ${C_CYAN}%s${C_RESET}\n" "$PROJECT_NAME"
        printf "   Path:    ${C_GRAY}%s${C_RESET}\n" "${PROJECT_ROOT:-$(pwd)}"
        printf "   Status:  %b\n" "$status_line"
        printf "${C_CYAN}======================================================================${C_RESET}\n"

        if [[ -n "$PROJECT_ROOT" ]]; then
            printf "${C_GRAY}--- Project Actions ---${C_RESET}\n"
            printf "$fmt_val" "1" "Start" "up -d"
            printf "$fmt_val" "2" "Stop" "down"
            printf "$fmt_val" "3" "Restart" "restart"
            printf "$fmt_val" "4" "Reload" "up -d --remove-orphans"
            printf "$fmt_val" "5" "Update" "pull + up"
            printf "$fmt_val" "6" "Rebuild" "force recreate"
            printf "\n"
            printf "$fmt_val" "7" "Status" "ps"
            printf "$fmt_val" "8" "Logs" "follow output"
            printf "$fmt_val" "9" "Shell" "enter container"
            printf "\n"
            printf "$fmt_danger" "10" "DESTROY" "down -v --rmi"
            printf "\n"
        fi

        printf "${C_GRAY}--- System Actions ---${C_RESET}\n"
        printf "$fmt_danger" "11" "System Prune" "docker system prune"
        printf "\n"
        printf "${C_GRAY}--- Global Actions ---${C_RESET}\n"
        printf "$fmt_val" "i" "Install" "Install to $INSTALL_PATH"
        printf "$fmt_val" "u" "Uninstall" "Remove from $INSTALL_PATH"
        printf "$fmt_val" "h" "Help" "Show commands"
        printf "$fmt_val" "0" "Exit" ""
        printf "${C_CYAN}======================================================================${C_RESET}\n"

        read -rp "Selection: " choice

        run_menu_choice "$choice" || true

        printf "\n"
        read -rp "Press Enter to continue..."
    done
}

run_menu_choice() {
    local choice="$1" rc=0

    case "$choice" in
        1)  require_project start && start_project || rc=$? ;;
        2)  require_project stop && stop_project || rc=$? ;;
        3)  require_project restart && restart_containers || rc=$? ;;
        4)  require_project reload && reload_project || rc=$? ;;
        5)  require_project update && update_project || rc=$? ;;
        6)  require_project rebuild && rebuild_project || rc=$? ;;
        7)  require_project status && show_status || rc=$? ;;
        8)  require_project logs && show_logs || rc=$? ;;
        9)  require_project shell && open_shell || rc=$? ;;
        10) require_project destroy && destroy_project || rc=$? ;;
        11) require_docker && prune_system || rc=$? ;;
        i|I) install_globally || rc=$? ;;
        u|U) uninstall_globally || rc=$? ;;
        h|H) usage ;;
        0)  exit 0 ;;
        *)  log_msg "ERROR" "Unknown option."; rc=1 ;;
    esac

    if [[ "$rc" -ne 0 ]]; then
        log_msg "ERROR" "Action failed."
    fi

    return "$rc"
}

# ==============================================================================
#   Main
# ==============================================================================

main() {
    local command="${1:-}"

    case "$command" in
        install)   install_globally ;;
        uninstall) uninstall_globally ;;
        help|-h|--help) usage ;;
        "")
            refuse_unwanted_root menu
            load_project
            if [[ -n "$PROJECT_ROOT" ]]; then
                require_docker
                detect_compose
            fi
            show_interactive_menu
            ;;
        prune)
            refuse_unwanted_root prune
            init_system_environment
            prune_system
            ;;
        start|stop|restart|reload|update|rebuild|status|logs|shell|destroy)
            refuse_unwanted_root "$command"
            init_project_environment "$command"
            case "$command" in
                start)   start_project ;;
                stop)    stop_project ;;
                restart) restart_containers ;;
                reload)  reload_project ;;
                update)  update_project ;;
                rebuild) rebuild_project ;;
                status)  show_status ;;
                logs)    show_logs ;;
                shell)   open_shell "${2:-}" ;;
                destroy) destroy_project ;;
            esac
            ;;
        *)
            log_msg "ERROR" "Unknown command: $command"
            usage
            exit 1
            ;;
    esac
}

main "$@"
