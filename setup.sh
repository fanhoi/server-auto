#!/usr/bin/env bash

# ==============================================================================
# ubuntu-auto: Скрипт автоматической первоначальной настройки серверов на Ubuntu.
# Использование: Выполняет локализацию, настройку таймзоны, установку Docker,
# Node.js (с динамическим выбором версии) и базового ПО через TUI-меню.
# ==============================================================================

# Строгий режим обработки ошибок
set -e
set -o pipefail

# Принудительная установка UTF-8 локали для корректного отображения кириллицы в whiptail
export LANG=C.UTF-8
export LC_ALL=C.UTF-8

# Файл лога выполнения скрипта
LOG_FILE="/var/log/ubuntu-setup.log"

# Определяем, нужен ли sudo для системных команд
SUDO=""
if [ "$EUID" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
        SUDO="sudo"
    else
        echo "Ошибка: Этот скрипт требует прав root или утилиты sudo для выполнения." >&2
        exit 1
    fi
fi

# Инициализация файла лога (в /var/log/ или в текущей директории при нехватке прав)
if ! $SUDO touch "$LOG_FILE" 2>/dev/null; then
    LOG_FILE="./ubuntu-setup.log"
    touch "$LOG_FILE"
fi

# ==============================================================================
# ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ (ЛОГИРОВАНИЕ И ЗАВИСИМОСТИ)
# ==============================================================================

# Функция для вывода информационных сообщений
log_info() {
    echo -e "\e[32m[INFO]\e[0m $1"
    echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

# Функция для вывода ошибок
log_error() {
    echo -e "\e[31m[ERROR]\e[0m $1" >&2
    echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

# Предварительная проверка и установка зависимостей самого скрипта
install_script_deps() {
    log_info "Проверка необходимых зависимостей для работы скрипта (curl, jq, whiptail)..."
    $SUDO apt-get update >> "$LOG_FILE" 2>&1
    
    local -a deps_needed=()
    for pkg in curl jq whiptail; do
        if ! dpkg -s "$pkg" >/dev/null 2>&1; then
            deps_needed+=("$pkg")
        fi
    done

    if [ ${#deps_needed[@]} -gt 0 ]; then
        log_info "Установка недостающих зависимостей: ${deps_needed[*]}..."
        $SUDO apt-get install -y "${deps_needed[@]}" >> "$LOG_FILE" 2>&1
    else
        log_info "Все базовые зависимости уже установлены."
    fi
}

# Показывает окно выполнения процесса (информационное сообщение)
show_progress() {
    local message="$1"
    whiptail --title "Пожалуйста, подождите" --infobox "$message" 8 50
}

# ==============================================================================
# МОДУЛИ НАСТРОЙКИ СИСТЕМЫ И УСТАНОВКИ ПО
# ==============================================================================

# Установка русского языка (локали ru_RU.UTF-8)
setup_russian_locale() {
    show_progress "Настройка русской локали (ru_RU.UTF-8)..."
    log_info "Запуск настройки русской локали..."
    
    # Устанавливаем необходимые пакеты локализации
    $SUDO apt-get install -y locales language-pack-ru language-pack-ru-base >> "$LOG_FILE" 2>&1
    
    # Генерируем локаль
    $SUDO locale-gen ru_RU.UTF-8 >> "$LOG_FILE" 2>&1
    
    # Принудительно настраиваем системные переменные в /etc/default/locale
    echo "LANG=ru_RU.UTF-8" | $SUDO tee /etc/default/locale > /dev/null
    echo "LANGUAGE=ru_RU:ru" | $SUDO tee -a /etc/default/locale > /dev/null
    echo "LC_ALL=ru_RU.UTF-8" | $SUDO tee -a /etc/default/locale > /dev/null
    
    # Обновляем локали через update-locale
    $SUDO update-locale LANG=ru_RU.UTF-8 LANGUAGE=ru_RU:ru LC_ALL=ru_RU.UTF-8 >> "$LOG_FILE" 2>&1
    
    # Прописываем экспорт локали в глобальный bashrc для гарантированного применения в сессиях
    if ! grep -q "ru_RU.UTF-8" /etc/bash.bashrc 2>/dev/null; then
        echo 'export LANG=ru_RU.UTF-8' | $SUDO tee -a /etc/bash.bashrc > /dev/null
        echo 'export LANGUAGE=ru_RU:ru' | $SUDO tee -a /etc/bash.bashrc > /dev/null
        echo 'export LC_ALL=ru_RU.UTF-8' | $SUDO tee -a /etc/bash.bashrc > /dev/null
    fi
    
    log_info "Локаль настроена на ru_RU.UTF-8. Изменения применятся после релогина или перезагрузки."
    whiptail --title "Настройка локали" --msgbox "Локаль ru_RU.UTF-8 успешно установлена на систему!\nПосле завершения настройки рекомендуется перезагрузить сервер или переподключиться по SSH." 10 60
}

# Установка часового пояса "Asia/Novokuznetsk"
setup_timezone() {
    show_progress "Установка часового пояса Asia/Novokuznetsk..."
    log_info "Установка часового пояса Asia/Novokuznetsk..."
    
    $SUDO timedatectl set-timezone Asia/Novokuznetsk >> "$LOG_FILE" 2>&1
    
    local current_time
    current_time=$(date)
    log_info "Часовой пояс успешно изменен. Текущее время на сервере: $current_time"
    whiptail --title "Настройка времени" --msgbox "Часовой пояс Asia/Novokuznetsk успешно установлен.\nТекущее системное время:\n$current_time" 10 60
}

# Установка выбранных базовых программ
setup_base_packages() {
    local choices="$1"
    if [ -z "$choices" ]; then
        whiptail --title "Установка ПО" --msgbox "Вы не выбрали ни одной программы для установки." 8 50
        return
    fi

    log_info "Начало установки базовых пакетов: $choices"
    
    # Преобразуем выбор в массив
    local -a pkgs_to_install=()
    if [[ "$choices" =~ "NANO" ]]; then pkgs_to_install+=("nano"); fi
    if [[ "$choices" =~ "ZIP" ]]; then pkgs_to_install+=("zip" "unzip"); fi
    if [[ "$choices" =~ "GIT" ]]; then pkgs_to_install+=("git"); fi
    if [[ "$choices" =~ "SSH" ]]; then pkgs_to_install+=("openssh-server"); fi

    if [ ${#pkgs_to_install[@]} -eq 0 ]; then
        return
    fi

    show_progress "Установка выбранных пакетов: ${pkgs_to_install[*]}..."
    $SUDO apt-get update >> "$LOG_FILE" 2>&1
    
    for pkg in "${pkgs_to_install[@]}"; do
        log_info "Установка пакета: $pkg"
        $SUDO apt-get install -y "$pkg" >> "$LOG_FILE" 2>&1
    done

    # Дополнительная настройка для SSH, если он устанавливался
    if [[ "$choices" =~ "SSH" ]]; then
        log_info "Запуск и включение автозапуска OpenSSH службы..."
        $SUDO systemctl enable ssh >> "$LOG_FILE" 2>&1 || true
        $SUDO systemctl start ssh >> "$LOG_FILE" 2>&1 || true
    fi

    log_info "Выбранные программы успешно установлены."
    whiptail --title "Установка ПО" --msgbox "Следующие программы успешно установлены:\n${pkgs_to_install[*]}" 10 60
}

# Установка Docker, Docker Compose плагина и создание совместимого симлинка
setup_docker() {
    show_progress "Установка Docker и Docker Compose..."
    log_info "Начало установки Docker..."

    # Удаляем потенциально конфликтующие старые пакеты
    for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
        $SUDO apt-get remove -y "$pkg" >> "$LOG_FILE" 2>&1 || true
    done

    # Установка базовых утилит для репозиториев apt
    $SUDO apt-get install -y ca-certificates curl >> "$LOG_FILE" 2>&1
    $SUDO install -m 0755 -d /etc/apt/keyrings >> "$LOG_FILE" 2>&1

    # Добавление официального GPG ключа Docker
    $SUDO curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc >> "$LOG_FILE" 2>&1
    $SUDO chmod a+r /etc/apt/keyrings/docker.asc >> "$LOG_FILE" 2>&1

    # Определение кодового имени Ubuntu (например, focal, jammy, noble)
    local ubuntu_codename
    ubuntu_codename=$(. /etc/os-release && echo "$VERSION_CODENAME" 2>/dev/null || . /etc/os-release && echo "$VERSION_CODENODE")
    
    # Резервный вариант на случай, если codename не определился
    if [ -z "$ubuntu_codename" ]; then
        ubuntu_codename="jammy"
    fi

    # Добавление репозитория в APT
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
      $ubuntu_codename stable" | $SUDO tee /etc/apt/sources.list.d/docker.list > /dev/null

    $SUDO apt-get update >> "$LOG_FILE" 2>&1
    
    # Установка пакетов Docker Engine
    $SUDO apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >> "$LOG_FILE" 2>&1

    # Запуск и добавление демона в автозагрузку
    $SUDO systemctl enable docker >> "$LOG_FILE" 2>&1
    $SUDO systemctl start docker >> "$LOG_FILE" 2>&1

    # Добавление пользователя в группу docker для работы без sudo
    if [ "$EUID" -ne 0 ] && [ -n "$USER" ]; then
        $SUDO usermod -aG docker "$USER" >> "$LOG_FILE" 2>&1
        log_info "Пользователь $USER добавлен в группу docker."
        local docker_group_msg="Пользователь $USER добавлен в группу docker.\nПерезайдите в сессию для применения прав."
    else
        local docker_group_msg="Docker установлен для пользователя root."
    fi

    # Создание символической ссылки docker-compose для обратной совместимости
    if [ -f /usr/libexec/docker/cli-plugins/docker-compose ]; then
        $SUDO ln -sf /usr/libexec/docker/cli-plugins/docker-compose /usr/local/bin/docker-compose
        log_info "Создана символическая ссылка /usr/local/bin/docker-compose для обратной совместимости."
    fi

    local docker_ver
    docker_ver=$(docker --version 2>/dev/null || echo "Неизвестно")
    local compose_ver
    compose_ver=$(docker compose version 2>/dev/null || echo "Неизвестно")

    log_info "Docker успешно установлен. Версия: $docker_ver"
    whiptail --title "Установка Docker" --msgbox "Docker и Docker Compose успешно установлены!\n\nВерсия Docker: $docker_ver\nВерсия Compose: $compose_ver\n\n$docker_group_msg" 14 65
}

# Динамический опрос версий Node.js и их установка
setup_nodejs() {
    show_progress "Получение списка актуальных версий Node.js..."
    log_info "Опрос официального API Node.js для поиска LTS-версий..."

    # Скачиваем список версий в формате JSON, фильтруем LTS-релизы, берем уникальные мажорные номера
    local -a node_versions=()
    local api_response
    api_response=$(curl -s https://nodejs.org/dist/index.json 2>/dev/null || echo "")
    
    if [ -n "$api_response" ] && command -v jq >/dev/null 2>&1; then
        # Читаем мажорные версии LTS релизов
        local is_first=true
        while read -r ver; do
            if [ -n "$ver" ]; then
                local status="OFF"
                if [ "$is_first" = true ]; then
                    status="ON"
                    is_first=false
                fi
                node_versions+=("$ver" "Node.js v$ver LTS" "$status")
            fi
        done < <(echo "$api_response" | jq -r '.[] | select(.lts != false) | .version' | cut -d'.' -f1 | uniq | sed 's/v//' | head -n 4)
    fi

    # Резервный жесткий список версий, если API недоступно
    if [ ${#node_versions[@]} -eq 0 ]; then
        log_info "Не удалось получить версии через API, используем резервный список."
        node_versions=(
            "22" "Node.js v22 (Текущая LTS)" "ON"
            "20" "Node.js v20 (Предыдущая LTS)" "OFF"
            "18" "Node.js v18 (Старая LTS)" "OFF"
        )
    fi

    # Показываем TUI-меню выбора версии Node.js
    local node_choice
    node_choice=$(whiptail --title "Выбор версии Node.js" --radiolist \
        "Выберите мажорную версию Node.js для установки через репозиторий NodeSource:" 15 65 4 \
        "${node_versions[@]}" 3>&1 1>&2 2>&3)

    # Если пользователь нажал Cancel
    if [ $? -ne 0 ] || [ -z "$node_choice" ]; then
        log_info "Установка Node.js отменена пользователем."
        return
    fi

    show_progress "Настройка NodeSource для Node.js v${node_choice}.x..."
    log_info "Настройка NodeSource репозитория для Node.js v${node_choice}.x"

    $SUDO apt-get update >> "$LOG_FILE" 2>&1
    $SUDO apt-get install -y ca-certificates curl gnupg >> "$LOG_FILE" 2>&1
    
    # Добавление ключа NodeSource GPG
    $SUDO mkdir -p /etc/apt/keyrings >> "$LOG_FILE" 2>&1
    $SUDO curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | $SUDO gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg --yes >> "$LOG_FILE" 2>&1

    # Добавление репозитория NodeSource
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${node_choice}.x nodistro main" | $SUDO tee /etc/apt/sources.list.d/nodesource.list > /dev/null

    show_progress "Установка Node.js v${node_choice}.x..."
    $SUDO apt-get update >> "$LOG_FILE" 2>&1
    $SUDO apt-get install -y nodejs >> "$LOG_FILE" 2>&1

    local installed_node_ver
    installed_node_ver=$(node -v 2>/dev/null || echo "Неизвестно")
    local installed_npm_ver
    installed_npm_ver=$(npm -v 2>/dev/null || echo "Неизвестно")

    log_info "Node.js успешно установлен. Версия: $installed_node_ver, NPM: $installed_npm_ver"
    whiptail --title "Установка Node.js" --msgbox "Node.js успешно установлен!\n\nВерсия Node.js: $installed_node_ver\nВерсия npm: $installed_npm_ver" 12 60
}

# ==============================================================================
# ИНТЕРАКТИВНОЕ МЕНЮ (TUI)
# ==============================================================================

# Меню раздела: Настройка сервера (Локаль и Таймзона)
menu_server_settings() {
    while true; do
        local server_choice
        server_choice=$(whiptail --title "Настройка сервера" --checklist \
            "Выберите действия по настройке системы (клавиша Пробел для выбора):" 15 65 2 \
            "LOCALE" "Установить русскую локаль (ru_RU.UTF-8)" ON \
            "TIMEZONE" "Установить часовой пояс Asia/Novokuznetsk" ON 3>&1 1>&2 2>&3)

        if [ $? -ne 0 ]; then
            break # Возврат в главное меню
        fi

        if [[ "$server_choice" =~ "LOCALE" ]]; then
            setup_russian_locale
        fi
        if [[ "$server_choice" =~ "TIMEZONE" ]]; then
            setup_timezone
        fi
        
        whiptail --title "Настройка сервера" --msgbox "Выбранные настройки применены." 8 50
        break
    done
}

# Меню раздела: Установка базовых программ
menu_base_apps() {
    while true; do
        local app_choices
        app_choices=$(whiptail --title "Установка базового ПО" --checklist \
            "Выберите программы для установки (клавиша Пробел для выбора):" 15 65 4 \
            "NANO" "Удобный текстовый редактор Nano" ON \
            "ZIP" "Архиваторы zip и unzip" ON \
            "GIT" "Система контроля версий Git" ON \
            "SSH" "SSH-сервер openssh-server" ON 3>&1 1>&2 2>&3)

        if [ $? -ne 0 ]; then
            break # Возврат в главное меню
        fi

        setup_base_packages "$app_choices"
        break
    done
}

# Главное меню скрипта автонастройки
main_menu() {
    while true; do
        local menu_choice
        menu_choice=$(whiptail --title "Ubuntu Auto Setup Script v1.0" --menu \
            "Выберите раздел для продолжения настройки:" 16 65 6 \
            "1" "Настройка сервера (Язык, Часовой пояс)" \
            "2" "Установка базового ПО (Nano, Zip, Git, SSH)" \
            "3" "Установка Docker и Docker Compose" \
            "4" "Установка Node.js (динамический выбор версии)" \
            "5" "Посмотреть лог-файл установки" \
            "6" "Выйти из скрипта" 3>&1 1>&2 2>&3)

        if [ $? -ne 0 ] || [ "$menu_choice" = "6" ]; then
            log_info "Завершение работы скрипта пользователем."
            break
        fi

        case "$menu_choice" in
            "1")
                menu_server_settings
                ;;
            "2")
                menu_base_apps
                ;;
            "3")
                setup_docker
                ;;
            "4")
                setup_nodejs
                ;;
            "5")
                # Просмотр лог-файла в whiptail
                if [ -f "$LOG_FILE" ]; then
                    whiptail --title "Лог установки: $LOG_FILE" --textbox "$LOG_FILE" 20 75 --scrolltext
                else
                    whiptail --title "Лог установки" --msgbox "Лог-файл еще не создан." 8 50
                fi
                ;;
            *)
                whiptail --title "Ошибка" --msgbox "Неизвестный выбор меню." 8 50
                ;;
        esac
    done
}

# ==============================================================================
# ТОЧКА ВХОДА В СКРИПТ
# ==============================================================================

# Очищаем экран перед запуском
clear

echo "========================================================"
echo "      Запуск скрипта автонастройки Ubuntu Auto Setup     "
echo "========================================================"
echo "Лог-файл процесса: $LOG_FILE"
echo "========================================================"

# Сначала устанавливаем curl, jq, whiptail
install_script_deps

# Переходим в главное TUI-меню
main_menu

# Завершающее сообщение
clear
echo "========================================================"
echo "        Настройка завершена! Спасибо за использование.   "
echo "========================================================"
echo "Лог-файл сохранен в: $LOG_FILE"
echo "Рекомендуется перезапустить терминал / переподключиться к SSH"
echo "для корректного применения языковых настроек и прав Docker."
echo "========================================================"
