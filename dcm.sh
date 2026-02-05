#!/bin/bash

# ==============================================================================
#   Docker Compose Manager
# ==============================================================================

# --- I. Configuration & Constants ---
set -e
SCRIPT_VERSION="5.1"
HINT_COLUMN=30

# Colors (Standard UI Palette)
C_RESET='\033[0m'
C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[0;33m'
C_CYAN='\033[1;96m'
C_GRAY='\033[0;90m'

# Discovery targets
COMPOSE_FILES=("compose.yaml" "compose.yml" "docker-compose.yml" "docker-compose.yaml")

# Internal State (Will be populated by discovery/detection)
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
PROJECT_NAME=""
PROJECT_ROOT_FOUND="false"
SUDO_PREFIX=""
COMPOSE_CMD=()

INSTALL_PATH="/usr/local/bin/dcm"

# --- II. Core Utilities ---

# Unified logging helper
log_msg() {
	local level=$1
	local msg=$2
	case "$level" in
	"INFO") echo -e "${C_GREEN}INFO: ${msg}${C_RESET}" ;;
	"WARN") echo -e "${C_YELLOW}WARN: ${msg}${C_RESET}" ;;
	"ERROR") echo -e "${C_RED}ERROR: ${msg}${C_RESET}" ;;
	"HEADER") echo -e "${C_CYAN}${msg}${C_RESET}" ;;
	*) echo -e "${msg}" ;;
	esac
}

# Recursive project root discovery
find_project_root() {
	local current_dir="$1"
	# Max depth for safety (e.g. 10 levels up)
	for ((i = 0; i < 10; i++)); do
		for file in "${COMPOSE_FILES[@]}"; do
			if [[ -f "$current_dir/$file" ]]; then
				echo "$current_dir"
				return 0
			fi
		done
		# Stop at root
		if [[ "$current_dir" == "/" ]]; then break; fi
		current_dir=$(dirname "$current_dir")
	done
	return 1
}

# Wrapper for Docker Compose commands
run_compose() {
	${SUDO_PREFIX:+$SUDO_PREFIX} "${COMPOSE_CMD[@]}" "$@"
}

# Cross-platform inode getter (Linux/macOS)
get_inode() {
	local file="$1"
	if [[ "$(uname)" == "Darwin" ]]; then
		stat -f %i "$file" 2>/dev/null
	else
		stat -c %i "$file" 2>/dev/null
	fi
}

# --- III. Initialization & Environment Detection ---

init_environment() {
	# 1. Discover Working Directory
	local target_dir
	target_dir=$(find_project_root "$(pwd)") || true

	if [[ -z "$target_dir" ]]; then
		# Try script directory as fallback (only if not running globally)
		if [[ "$SCRIPT_DIR" != "/usr/local/bin" && "$SCRIPT_DIR" != "/usr/bin" ]]; then
			target_dir=$(find_project_root "$SCRIPT_DIR") || true
		fi
	fi

	if [[ -n "$target_dir" ]]; then
		cd "$target_dir" || exit 1
		PROJECT_ROOT_FOUND="true"
		PROJECT_NAME=$(basename "$(pwd)")
	else
		PROJECT_ROOT_FOUND="false"
		PROJECT_NAME="<No Config>"
	fi

	# 2. Check Docker Presence (Critical)
	if ! command -v docker &>/dev/null; then
		# If we are just installing/uninstalling or have no config, missing docker might be okay for now,
		# but for any project action it's fatal.
		if [[ "$PROJECT_ROOT_FOUND" == "true" ]]; then
			log_msg "ERROR" "Docker is not installed."
			exit 1
		fi
		# If no project, we just warn or ignore until an action is required
	fi

	# 3. Handle sudo/permissions & 4. Detect Compose Command
	# ONLY do this if we actually have a project to work with.
	# Avoiding 'docker ps' checks prevents hanging if Docker is present but unresponsive
	# in a directory without a config.
	if [[ "$PROJECT_ROOT_FOUND" == "true" ]]; then
		if [[ -n "$(command -v docker)" ]]; then
			if ! timeout 5 docker ps &>/dev/null 2>&1; then
				if command -v sudo &>/dev/null; then
					SUDO_PREFIX="sudo"
					if ! timeout 5 sudo docker ps &>/dev/null 2>&1; then
						log_msg "ERROR" "No Docker permissions or Docker daemon not running."
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
		fi
	fi

	# 5. Log working directory
	log_msg "HEADER" ">> Working Project: ${C_GRAY}$(pwd)${C_RESET}"
}

# --- IV. Action Functions ---

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
	if [[ -n "$(run_compose ps --filter "status=running" -q 2>/dev/null)" ]]; then
		log_msg "WARN" "Some services are already running."
	fi
	run_compose up -d
	log_msg "INFO" "Project started."
}

stop_project() {
	log_msg "WARN" "Stopping project '${PROJECT_NAME}'..."
	run_compose down
	log_msg "INFO" "Project stopped."
}

restart_containers() {
	log_msg "HEADER" "Quick Restarting containers for '${PROJECT_NAME}'..."
	run_compose restart
	log_msg "INFO" "Containers restarted."
}

reload_project() {
	log_msg "HEADER" "Applying configuration (Reload) for '${PROJECT_NAME}'..."
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
	local service=$1
	if [[ -z "$service" ]]; then
		# Get list of RUNNING services
		local running_services
		mapfile -t running_services < <(run_compose ps --filter "status=running" --services)

		local count=${#running_services[@]}

		if [[ "$count" -eq 0 ]]; then
			log_msg "ERROR" "No running services found. Use 'Start' (4) first."
			return 1
		elif [[ "$count" -eq 1 ]]; then
			service="${running_services[0]}"
			log_msg "INFO" "Automatically selecting the only running service: ${C_CYAN}${service}${C_RESET}"
		else
			log_msg "INFO" "Running services:"
			for i in "${!running_services[@]}"; do
				printf "  ${C_YELLOW}%d)${C_RESET} %s\n" "$((i + 1))" "${running_services[i]}"
			done
			read -p "Enter service name or number: " choice
			if [[ -z "$choice" ]]; then
				log_msg "WARN" "Cancelled."
				return 1
			fi

			# Check if input is a number
			if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -le "$count" ]] && [[ "$choice" -gt 0 ]]; then
				service="${running_services[$((choice - 1))]}"
			else
				service="$choice"
			fi
		fi
	fi

	# Double check if container is running (validation for manual input)
	if [[ -z "$(run_compose ps --filter "status=running" --services | grep -w "$service" || true)" ]]; then
		log_msg "ERROR" "Service '$service' is not running. Start it first."
		return 1
	fi

	log_msg "INFO" "Entering shell of service '${C_CYAN}$service${C_RESET}'..."
	if ! run_compose exec "$service" /bin/bash; then
		log_msg "WARN" "Bash not found, falling back to sh..."
		run_compose exec "$service" /bin/sh
	fi
}

install_globally() {
	log_msg "HEADER" "Global Installation"
	echo -e "Target path: ${C_CYAN}${INSTALL_PATH}${C_RESET}"

	if [[ -f "$INSTALL_PATH" ]]; then
		log_msg "INFO" "Existing installation found. Will update."
	fi

	read -p "Install/Update 'dcm' globally? [y/N]: " confirmation
	if [[ ! "$confirmation" =~ ^[Yy]$ ]]; then
		log_msg "INFO" "Cancelled."
		return
	fi

	# Check if we are trying to install onto ourselves
	if [[ -f "$INSTALL_PATH" ]] && [[ "$(get_inode "${BASH_SOURCE[0]}")" == "$(get_inode "$INSTALL_PATH")" ]]; then
		log_msg "ERROR" "You are running the installed version."
		log_msg "INFO" "To update, CD into your source directory and run ./dcm.sh install"
		return 1
	fi

	local install_dir
	install_dir=$(dirname "$INSTALL_PATH")

	# Check write permission on target directory AND file (if exists)
	local use_sudo=false

	if [[ ! -w "$install_dir" ]]; then
		use_sudo=true
	elif [[ -f "$INSTALL_PATH" && ! -w "$INSTALL_PATH" ]]; then
		use_sudo=true
	fi

	if [[ "$use_sudo" == "false" ]]; then
		cp "${BASH_SOURCE[0]}" "$INSTALL_PATH" && chmod 755 "$INSTALL_PATH"
		log_msg "INFO" "Successfully installed to $INSTALL_PATH"
	else
		log_msg "WARN" "Need root permissions to install to $INSTALL_PATH"
		if command -v sudo &>/dev/null; then
			sudo cp "${BASH_SOURCE[0]}" "$INSTALL_PATH" && sudo chmod 755 "$INSTALL_PATH"
			log_msg "INFO" "Successfully installed to $INSTALL_PATH (via sudo)"
		else
			log_msg "ERROR" "Cannot write to $INSTALL_PATH and 'sudo' is not available."
			return 1
		fi
	fi
}

uninstall_globally() {
	log_msg "HEADER" "Global Uninstallation"

	if [[ ! -f "$INSTALL_PATH" ]]; then
		log_msg "WARN" "No installation found at $INSTALL_PATH"
		return
	fi

	echo -e "Will remove: ${C_CYAN}${INSTALL_PATH}${C_RESET}"
	read -p "Uninstall 'dcm'? [y/N]: " confirmation
	if [[ ! "$confirmation" =~ ^[Yy]$ ]]; then
		log_msg "INFO" "Cancelled."
		return
	fi

	local install_dir
	install_dir=$(dirname "$INSTALL_PATH")

	if [[ -w "$install_dir" ]]; then
		rm -f "$INSTALL_PATH"
		log_msg "INFO" "Successfully uninstalled from $INSTALL_PATH"
	else
		log_msg "WARN" "Need root permissions to remove $INSTALL_PATH"
		if command -v sudo &>/dev/null; then
			sudo rm -f "$INSTALL_PATH"
			log_msg "INFO" "Successfully uninstalled from $INSTALL_PATH (via sudo)"
		else
			log_msg "ERROR" "Cannot remove $INSTALL_PATH and 'sudo' is not available."
			return 1
		fi
	fi
}

# --- Cleanup ---
prune_system() {
	if ! command -v docker &>/dev/null; then
		log_msg "ERROR" "Docker is not installed."
		return 1
	fi
	log_msg "ERROR" "WARNING: Cleaning WHOLE Docker system (not just this project)."
	read -p "Remove stopped containers, networks, and dangling images? [y/N]: " confirmation
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
	read -p "Are you sure? [y/N]: " confirmation
	if [[ "$confirmation" =~ ^[Yy]$ ]]; then
		log_msg "WARN" "Destroying..."
		run_compose down -v --rmi local
		log_msg "INFO" "Project destroyed."
	else
		log_msg "INFO" "Cancelled."
	fi
}

# --- V. Interactive Menu ---

show_interactive_menu() {
	# Reset trap on exit
	trap 'return' SIGINT

	while true; do
		# --- Live Metrics ---
		local TOTAL_SVCS UP_SVCS STATUS_LINE

		if [[ "$PROJECT_ROOT_FOUND" == "true" ]]; then
			TOTAL_SVCS=$(run_compose config --services 2>/dev/null | grep -c . || true)
			UP_SVCS=$(run_compose ps -q 2>/dev/null | grep -c . || true)

			if [[ "$UP_SVCS" -eq "0" ]]; then
				STATUS_LINE="${C_RED}STOPPED${C_RESET}"
			elif [[ "$UP_SVCS" -ge "$TOTAL_SVCS" ]] && [[ "$TOTAL_SVCS" -gt "0" ]]; then
				STATUS_LINE="${C_GREEN}RUNNING (${UP_SVCS}/${TOTAL_SVCS})${C_RESET}"
			else
				STATUS_LINE="${C_YELLOW}PARTIAL (${UP_SVCS}/${TOTAL_SVCS})${C_RESET}"
			fi
		else
			STATUS_LINE="${C_YELLOW}NO CONFIG FOUND${C_RESET}"
		fi

		local format="${C_GRAY} [%s] %s\033[${HINT_COLUMN}G%s${C_RESET}\n"
		local format_val=" [${C_YELLOW}%s${C_RESET}] %s\033[${HINT_COLUMN}G${C_GRAY}%s${C_RESET}\n"
		local format_danger=" [${C_YELLOW}%s${C_RESET}] %s\033[${HINT_COLUMN}G${C_RED}%s${C_RESET}\n"

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
			printf "$format_val" "1" "Status (PS)" "Show processes"
			printf "$format_val" "2" "Logs" "Follow output"
			printf "$format_val" "3" "Shell" "Enter container"
			echo ""
			printf "$format_val" "4" "Start" "up -d"
			printf "$format_val" "5" "Stop" "down"
			printf "$format_val" "6" "Restart" "Quick container restart"
			printf "$format_val" "7" "Reload" "Apply config (up -d)"
			printf "$format_val" "8" "Update" "pull + up"
			printf "$format_val" "9" "Rebuild" "force-recreate --build"
			echo ""
			printf "$format_danger" "10" "DESTROY" "down -v --rmi local"
			echo ""
		fi

		echo -e "${C_GRAY}--- System Actions ---${C_RESET}"
		printf "$format_danger" "11" "System Prune" "docker system prune"
		echo ""
		echo -e "${C_GRAY}--- Global Actions ---${C_RESET}"
		printf "$format_val" "i" "Install" "Install to $INSTALL_PATH"
		printf "$format_val" "u" "Uninstall" "Remove from $INSTALL_PATH"
		printf "$format_val" "0" "Exit" ""
		echo -e "${C_CYAN}======================================================================${C_RESET}"

		read -p "Selection: " choice

		# Validate: allow only system/global actions without config
		case "$choice" in
		11 | i | I | u | U | 0) ;; # Always allowed
		*)
			if [[ "$PROJECT_ROOT_FOUND" != "true" ]]; then
				log_msg "ERROR" "No project configuration found. Cannot perform this action."
				read -p "Press Enter to continue..."
				continue
			fi
			;;
		esac

		case "$choice" in
		1) show_status ;;
		2) show_logs ;;
		3) open_shell ;;
		4) start_project ;;
		5) stop_project ;;
		6) restart_containers ;;
		7) reload_project ;;
		8) update_project ;;
		9) rebuild_project ;;
		10) destroy_project ;;
		11) prune_system ;;
		i | I) install_globally ;;
		u | U) uninstall_globally ;;
		0) exit 0 ;;
		*) log_msg "ERROR" "Unknown option." ;;
		esac

		echo ""
		read -p "Press Enter to continue..."
	done
}

# --- VI. Main Execution ---

require_project() {
	if [[ "$PROJECT_ROOT_FOUND" != "true" ]]; then
		log_msg "ERROR" "No project configuration found. Command '$1' requires a valid project."
		exit 1
	fi
}

case "$1" in
# --- Commands that DON'T need Docker or project ---
install)
	install_globally
	exit $?
	;;
uninstall)
	uninstall_globally
	exit $?
	;;

# --- Commands that need Docker but NOT a project ---
prune)
	init_environment
	prune_system
	;;

# --- Interactive menu ---
"")
	init_environment
	show_interactive_menu
	;;

# --- Project-dependent commands ---
*)
	init_environment
	require_project "$1"

	case "$1" in
	start) start_project ;;
	stop) stop_project ;;
	restart) restart_containers ;;
	reload) reload_project ;;
	update) update_project ;;
	rebuild) rebuild_project ;;
	status) show_status ;;
	logs) show_logs ;;
	shell) open_shell "$2" ;;
	destroy) destroy_project ;;
	*)
		log_msg "ERROR" "Unknown command: $1"
		echo "Usage: $0 {start|stop|restart|reload|update|rebuild|status|logs|shell [service]|prune|destroy|install|uninstall}"
		exit 1
		;;
	esac
	;;
esac
