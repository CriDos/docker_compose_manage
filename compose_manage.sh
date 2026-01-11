#!/bin/bash

# ==============================================================================
#   Версия 4.0: Универсальный скрипт (Smart Sudo, Auto-Discovery)
# ==============================================================================

# --- Настройки ---
set -e
HINT_COLUMN=30

# Цвета
C_RESET='\033[0m'
C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[0;33m'
C_CYAN='\033[1;96m'
C_GRAY='\033[0;90m'

# Определяем, где лежит скрипт
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

# --- Логика определения рабочей директории ---
# Поиск файла конфигурации (приоритет по стандартам Docker)
COMPOSE_FILES=("compose.yaml" "compose.yml" "docker-compose.yml" "docker-compose.yaml")
PROJECT_ROOT=""

check_files() {
    local dir=$1
    for file in "${COMPOSE_FILES[@]}"; do
        if [ -f "$dir/$file" ]; then
            echo "$dir"
            return 0
        fi
    done
    return 1
}

if check_files "." > /dev/null; then
    PROJECT_ROOT="."
elif check_files "$SCRIPT_DIR" > /dev/null; then
    cd "$SCRIPT_DIR" || exit 1
    PROJECT_ROOT="$SCRIPT_DIR"
else
    echo -e "${C_RED}Ошибка: Файл конфигурации (compose.yaml, docker-compose.yml и т.д.) не найден.${C_RESET}"
    echo -e "${C_GRAY}Поиск выполнялся в:${C_RESET}"
    echo -e "  - $(pwd)"
    echo -e "  - $SCRIPT_DIR"
    exit 1
fi

PROJECT_NAME=$(basename "$(pwd)")
echo -e "${C_CYAN}>> Working Project Root: ${C_GRAY}$(pwd)${C_RESET}"

# --- Определение команды Docker и прав доступа (Smart Sudo) ---
DOCKER_CMD="docker"
COMPOSE_CMD=""
SUDO_PREFIX=""

# Проверяем, нужен ли sudo для docker
if ! command -v docker &> /dev/null; then
    echo -e "${C_RED}Docker не установлен.${C_RESET}"
    exit 1
fi

if ! docker ps &> /dev/null; then
    if command -v sudo &> /dev/null; then
        SUDO_PREFIX="sudo"
        # Проверка, работает ли sudo с docker (попросит пароль, если нужно)
        if ! sudo docker ps &> /dev/null; then
             echo -e "${C_RED}Ошибка: Нет прав на выполнение Docker команд (даже через sudo).${C_RESET}"
             exit 1
        fi
    else
        echo -e "${C_RED}Ошибка: У пользователя нет прав на Docker и sudo не найден.${C_RESET}"
        exit 1
    fi
fi

# Определение версии Compose (V2 plugin или V1 standalone)
# ВАЖНО: Проверяем доступность именно через SUDO_PREFIX, так как sudo может не видеть пользовательские плагины
if $SUDO_PREFIX docker compose version &> /dev/null; then
    COMPOSE_CMD="$SUDO_PREFIX docker compose"
elif $SUDO_PREFIX docker-compose version &> /dev/null; then
    COMPOSE_CMD="$SUDO_PREFIX docker-compose"
else
    echo -e "${C_RED}Ошибка: docker compose не найден (или недоступен через $SUDO_PREFIX).${C_RESET}"
    exit 1
fi

# Обертка для выполнения команд
run_compose() {
    $COMPOSE_CMD "$@"
}

# --- Функции управления ---

start_project() {
    echo -e "${C_GREEN}✅ Запуск проекта '${PROJECT_NAME}'...${C_RESET}"
    
    # Проверка состояния перед запуском
    if run_compose ps -q &>/dev/null; then
         echo -e "${C_YELLOW}Контейнеры проекта уже существуют.${C_RESET}"
    fi

    run_compose up -d
    echo -e "${C_GREEN}Проект запущен.${C_RESET}"
}

stop_project() {
    echo -e "${C_YELLOW} Остановка проекта '${PROJECT_NAME}'...${C_RESET}"
    run_compose down
    echo -e "${C_YELLOW}Проект остановлен.${C_RESET}"
}

restart_project() {
    echo -e "${C_CYAN} Быстрый перезапуск (Native Restart) '${PROJECT_NAME}'...${C_RESET}"
    run_compose restart
    echo -e "${C_GREEN}Сервисы перезапущены.${C_RESET}"
}

update_project() {
    echo -e "${C_CYAN} Обновление проекта '${PROJECT_NAME}'...${C_RESET}"
    
    echo -e "${C_GRAY}1/3: Скачивание новых образов...${C_RESET}"
    run_compose pull
    
    echo -e "${C_GRAY}2/3: Применение изменений...${C_RESET}"
    run_compose up -d --remove-orphans
    
    echo -e "${C_GRAY}3/3: Очистка старых версий образов (dangling)...${C_RESET}"
    # Удаляем только висячие образы, чтобы не забивать диск после обновлений
    $SUDO_PREFIX docker image prune -f
    
    echo -e "${C_GREEN} Проект успешно обновлен!${C_RESET}"
}

rebuild_project() {
    echo -e "${C_CYAN}️ Полное пересоздание контейнеров...${C_RESET}"
    run_compose up -d --force-recreate --build
    echo -e "${C_GREEN}Контейнеры пересобраны и запущены.${C_RESET}"
}

show_status() {
    echo -e "${C_CYAN} Статус контейнеров:${C_RESET}"
    run_compose ps
}

show_logs() {
    echo -e "${C_GRAY} Логи (Ctrl+C для выхода)...${C_RESET}"
    # Используем subshell и trap для корректного выхода, но set +e здесь важен
    (set +e; run_compose logs -f --tail="100")
}

open_shell() {
    local service=$1
    if [ -z "$service" ]; then
        echo -e "${C_YELLOW}Доступные сервисы:${C_RESET}"
        run_compose ps --services
        read -p "Введите имя сервиса: " service
        if [ -z "$service" ]; then echo -e "${C_RED}Отмена.${C_RESET}"; return 1; fi
    fi
    echo -e "${C_GREEN}Вход в shell сервиса '$service'...${C_RESET}"
    # Пытаемся запустить bash, если нет - sh
    (set +e; 
     if ! run_compose exec "$service" /bin/bash; then
        echo -e "${C_GRAY}Bash не найден, переключаюсь на sh...${C_RESET}"
        run_compose exec "$service" /bin/sh
     fi
    )
}

prune_system() {
    echo -e "${C_RED}ВНИМАНИЕ: Очистка ВСЕЙ системы Docker (не только этого проекта).${C_RESET}"
    read -p "Удалить остановленные контейнеры, сети и висячие образы? [y/N]: " confirmation
    if [[ "$confirmation" =~ ^[Yy]$ ]]; then
        # Убрали флаг -a для безопасности (удалять только dangling)
        $SUDO_PREFIX docker system prune -f
        echo -e "${C_GREEN}Система очищена (dangling images и stopped containers).${C_RESET}"
    else
        echo "Отменено."
    fi
}

destroy_project() {
    echo -e "${C_RED}!!! ВНИМАНИЕ: УДАЛЕНИЕ ПРОЕКТА !!!${C_RESET}"
    echo -e "${C_YELLOW}Будут удалены контейнеры, сети и ВСЕ ДАННЫЕ В ТОМАХ (Volumes).${C_RESET}"
    read -p "Вы действительно хотите уничтожить проект? [y/N]: " confirmation

    if [[ "$confirmation" =~ ^[Yy]$ ]]; then
        echo -e "${C_YELLOW}Удаление...${C_RESET}"
        run_compose down -v --rmi all
        echo -e "${C_GREEN}Проект уничтожен.${C_RESET}"
    else
        echo "Отменено."
    fi
}

# --- Интерактивное меню ---
show_interactive_menu() {
    # Обработка прерывания Ctrl+C: не выходим, а просто обновляем строку ввода
    trap 'echo -e "\n${C_GRAY}Используйте пункт 0 для выхода.${C_RESET}"' SIGINT

    while true; do
        local format_default=" [${C_YELLOW}%s${C_RESET}] %s\033[${HINT_COLUMN}G${C_GRAY}%s${C_RESET}\n"
        local format_danger=" [${C_YELLOW}%s${C_RESET}] %s\033[${HINT_COLUMN}G${C_RED}%s${C_RESET}\n"

        clear
        echo -e "${C_CYAN}======================================================================${C_RESET}"
        echo -e "   Проект: ${C_GREEN}${PROJECT_NAME}${C_RESET} | Путь: ${C_GRAY}$(pwd)${C_RESET}"
        if [ -n "$SUDO_PREFIX" ]; then echo -e "   Режим:  ${C_RED}SUDO${C_RESET}"; fi
        echo -e "${C_CYAN}======================================================================${C_RESET}"
        
        printf "$format_default" "1" "Запустить (Start)" "up -d"
        printf "$format_default" "2" "Остановить (Stop)" "down"
        printf "$format_default" "3" "Рестарт (Restart)" "native restart"
        printf "$format_default" "4" "Обновить (Update)" "pull + up + clean images"
        printf "$format_default" "5" "Статус (PS)" "Показать контейнеры"
        printf "$format_default" "6" "Логи (Logs)" "Просмотр логов"
        echo ""
        printf "$format_default" "7" "Консоль (Shell)" "Вход в контейнер"
        printf "$format_default" "8" "Пересобрать (Rebuild)" "force-recreate --build"
        printf "$format_danger"  "9" "Очистка системы" "docker system prune"
        printf "$format_danger"  "10" "УДАЛИТЬ (Destroy)" "down -v (удалит данные!)"
        echo ""
        printf "$format_default" "0" "Выход" ""
        echo -e "${C_CYAN}======================================================================${C_RESET}"

        read -p "Ваш выбор: " choice
        
        # В интерактивном режиме ошибки команд не должны ломать скрипт
        set +e
        case "$choice" in
            1) start_project ;; 2) stop_project ;; 3) restart_project ;;
            4) update_project ;; 5) show_status ;; 6) show_logs ;;
            7) open_shell ;; 8) rebuild_project ;; 9) prune_system ;;
            10) destroy_project ;;
            0) exit 0 ;;
            *) echo -e "${C_RED}Неверный ввод.${C_RESET}" ;;
        esac
        # Возвращаем строгий режим, но только если не выходим
        set -e

        if [[ "$choice" != "0" ]]; then
            echo ""
            read -p "Нажмите Enter для продолжения..."
        fi
    done
}

# --- Запуск ---
# Если скрипт запущен с аргументами, выполняем их
if [ -n "$1" ]; then
    case "$1" in
        start) start_project ;;
        stop) stop_project ;;
        restart) restart_project ;;
        update) update_project ;;
        rebuild) rebuild_project ;;
        status) show_status ;;
        logs) show_logs ;;
        shell) open_shell "$2" ;;
        prune) prune_system ;;
        destroy) destroy_project ;;
        *)
            echo -e "${C_RED}Неизвестная команда: $1${C_RESET}"
            echo "Доступные команды: start, stop, restart, update, rebuild, status, logs, shell [service], prune, destroy"
            exit 1
            ;;
    esac
else
    show_interactive_menu
fi