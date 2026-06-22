#!/usr/bin/env bash

# ==============================================================================
# ubuntu-auto: Скрипт автоматической первоначальной настройки серверов на Ubuntu.
# Использование: Выполняет локализацию, настройку таймзоны, автологин LXC,
# установку Docker, Node.js и базового ПО через TUI-меню.
# ==============================================================================

# Строгий режим обработки ошибок
set -e
set -o pipefail

# Принудительная установка UTF-8 локали для корректного отображения кириллицы в whiptail
export LANG=C.UTF-8
export LC_ALL=C.UTF-8

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

# ==============================================================================
# ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
# ==============================================================================

# Функция для вывода информационных сообщений (на случай вывода вне TUI)
log_info() {
    echo -e "\e[32m[INFO]\e[0m $1"
}

# Функция для вывода ошибок
log_error() {
    echo -e "\e[31m[ERROR]\e[0m $1" >&2
}

# Предварительная проверка и установка зависимостей самого скрипта
install_script_deps() {
    $SUDO apt-get update >/dev/null 2>&1
    
    local -a deps_needed=()
    for pkg in curl jq whiptail; do
        if ! dpkg -s "$pkg" >/dev/null 2>&1; then
            deps_needed+=("$pkg")
        fi
    done

    if [ ${#deps_needed[@]} -gt 0 ]; then
        $SUDO apt-get install -y "${deps_needed[@]}" >/dev/null 2>&1
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
    
    $SUDO apt-get update >/dev/null 2>&1
    $SUDO apt-get install -y language-pack-ru >/dev/null 2>&1
    $SUDO update-locale LANG=ru_RU.UTF-8 >/dev/null 2>&1
    
    whiptail --title "Настройка локали" --msgbox "Русский язык успешно установлен!\nИзменения вступят в силу после перезагрузки сервера или нового входа по SSH." 10 60
}

# Установка часового пояса "Asia/Novokuznetsk"
setup_timezone() {
    show_progress "Установка часового пояса Asia/Novokuznetsk..."
    $SUDO timedatectl set-timezone Asia/Novokuznetsk >/dev/null 2>&1
    
    local current_time
    current_time=$(date)
    whiptail --title "Настройка времени" --msgbox "Часовой пояс Asia/Novokuznetsk успешно установлен.\nТекущее системное время:\n$current_time" 10 60
}

# Настройка автологина root для LXC-контейнеров Proxmox
setup_lxc_autologin() {
    show_progress "Настройка автологина root для LXC..."
    
    local dir="/etc/systemd/system/container-getty@1.service.d"
    local conf="$dir/override.conf"
    
    $SUDO mkdir -p "$dir" >/dev/null 2>&1
    
    echo "[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear --keep-baud tty%I 115200,38400,9600 \$TERM" | $SUDO tee "$conf" > /dev/null

    $SUDO systemctl daemon-reload >/dev/null 2>&1 || true
    
    whiptail --title "Настройка LXC" --msgbox "Автоматический вход root для контейнера LXC успешно настроен!\nИзменения применятся при следующем запуске контейнера." 10 60
}

# Установка выбранных базовых программ
setup_base_packages() {
    local choices="$1"
    if [ -z "$choices" ]; then
        whiptail --title "Установка ПО" --msgbox "Вы не выбрали ни одной программы для установки." 8 50
        return
    fi

    # Преобразуем выбор в массив
    local -a pkgs_to_install=()
    if [[ "$choices" =~ "NANO" ]]; then pkgs_to_install+=("nano"); fi
    if [[ "$choices" =~ "ZIP" ]]; then pkgs_to_install+=("zip" "unzip"); fi
    if [[ "$choices" =~ "GIT" ]]; then pkgs_to_install+=("git"); fi
    if [[ "$choices" =~ "SSH" ]]; then pkgs_to_install+=("openssh-server"); fi
    if [[ "$choices" =~ "SPEEDTEST" ]]; then pkgs_to_install+=("speedtest-cli"); fi
    if [[ "$choices" =~ "IPERF" ]]; then pkgs_to_install+=("iperf3"); fi

    if [ ${#pkgs_to_install[@]} -eq 0 ]; then
        return
    fi

    # Спрашиваем про преднастройку SSH до начала установки
    local configure_ssh=false
    if [[ "$choices" =~ "SSH" ]]; then
        if whiptail --title "Настройка SSH" --yesno "Вы выбрали установку SSH.\nХотите применить вашу преднастройку конфигурации?\n\n- Порт: 22\n- Вход для root по паролю: Разрешен\n- Ограничение доступа: Только из локальных сетей (192.168.*, 10.*, 172.*, 127.*)" 14 65; then
            configure_ssh=true
        fi
    fi

    show_progress "Установка выбранных пакетов: ${pkgs_to_install[*]}..."
    $SUDO apt-get update >/dev/null 2>&1
    
    for pkg in "${pkgs_to_install[@]}"; do
        $SUDO apt-get install -y "$pkg" >/dev/null 2>&1
    done

    # Дополнительная настройка для SSH, если он устанавливался
    if [[ "$choices" =~ "SSH" ]]; then
        $SUDO systemctl enable ssh >/dev/null 2>&1 || true
        $SUDO systemctl start ssh >/dev/null 2>&1 || true
        
        if [ "$configure_ssh" = true ]; then
            # Делаем резервную копию оригинального конфига
            if [ -f /etc/ssh/sshd_config ]; then
                $SUDO cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
            fi
            
            # Записываем новую конфигурацию
            echo "Port 22
PermitRootLogin yes
PasswordAuthentication yes
ListenAddress 0.0.0.0
AllowUsers *@192.168.*.* *@127.0.0.1 *@10.*.*.* *@172.*.*.*
Subsystem sftp /usr/lib/openssh/sftp-server" | $SUDO tee /etc/ssh/sshd_config > /dev/null

            # Перезапускаем сервис SSH
            $SUDO systemctl restart ssh >/dev/null 2>&1 || $SUDO systemctl restart sshd >/dev/null 2>&1 || true
            whiptail --title "Настройка SSH" --msgbox "Преднастройка конфигурации SSH успешно применена!\nСлужба OpenSSH перезапущена." 10 55
        fi
    fi

    whiptail --title "Установка ПО" --msgbox "Следующие программы успешно установлены:\n${pkgs_to_install[*]}" 10 60
}

# Установка Docker, Docker Compose плагина и создание совместимого симлинка
setup_docker() {
    show_progress "Установка Docker и Docker Compose..."

    # ... удаляем потенциально конфликтующие старые пакеты
    for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
        $SUDO apt-get remove -y "$pkg" >/dev/null 2>&1 || true
    done

    # Установка базовых утилит для репозиториев apt
    $SUDO apt-get install -y ca-certificates curl >/dev/null 2>&1
    $SUDO install -m 0755 -d /etc/apt/keyrings >/dev/null 2>&1

    # Добавление официального GPG ключа Docker
    $SUDO curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc >/dev/null 2>&1
    $SUDO chmod a+r /etc/apt/keyrings/docker.asc >/dev/null 2>&1

    # Определение кодового имени Ubuntu (например, focal, jammy, noble)
    local ubuntu_codename
    ubuntu_codename=$(. /etc/os-release && echo "$VERSION_CODENAME" 2>/dev/null || . /etc/os-release && echo "$VERSION_CODENODE")
    
    if [ -z "$ubuntu_codename" ]; then
        ubuntu_codename="jammy"
    fi

    # Добавление репозитория в APT
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
      $ubuntu_codename stable" | $SUDO tee /etc/apt/sources.list.d/docker.list > /dev/null

    $SUDO apt-get update >/dev/null 2>&1
    
    # Установка пакетов Docker Engine
    $SUDO apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null 2>&1

    # Запуск и добавление демона в автозагрузку
    $SUDO systemctl enable docker >/dev/null 2>&1
    $SUDO systemctl start docker >/dev/null 2>&1

    # Добавление пользователя в группу docker для работы без sudo
    if [ "$EUID" -ne 0 ] && [ -n "$USER" ]; then
        $SUDO usermod -aG docker "$USER" >/dev/null 2>&1
        local docker_group_msg="Пользователь $USER добавлен в группу docker.\nПерезайдите в сессию для применения прав."
    else
        local docker_group_msg="Docker установлен для пользователя root."
    fi

    # Создание символической ссылки docker-compose для обратной совместимости
    if [ -f /usr/libexec/docker/cli-plugins/docker-compose ]; then
        $SUDO ln -sf /usr/libexec/docker/cli-plugins/docker-compose /usr/local/bin/docker-compose
    fi

    local docker_ver
    docker_ver=$(docker --version 2>/dev/null || echo "Неизвестно")
    local compose_ver
    compose_ver=$(docker compose version 2>/dev/null || echo "Неизвестно")

    whiptail --title "Установка Docker" --msgbox "Docker и Docker Compose успешно установлены!\n\nВерсия Docker: $docker_ver\nВерсия Compose: $compose_ver\n\n$docker_group_msg" 14 65
}

# Динамический опрос версий Node.js и их установка
setup_nodejs() {
    show_progress "Получение списка актуальных версий Node.js..."

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

    if [ ${#node_versions[@]} -eq 0 ]; then
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

    if [ $? -ne 0 ] || [ -z "$node_choice" ]; then
        return
    fi

    show_progress "Очистка старой версии Node.js..."
    $SUDO apt-get remove -y nodejs npm >/dev/null 2>&1 || true
    $SUDO apt-get purge -y nodejs npm >/dev/null 2>&1 || true
    $SUDO rm -f /etc/apt/sources.list.d/nodesource.list >/dev/null 2>&1 || true
    $SUDO apt-get autoremove -y >/dev/null 2>&1 || true

    show_progress "Подключение репозитория NodeSource v${node_choice}.x..."
    if [ "$EUID" -ne 0 ]; then
        curl -fsSL "https://deb.nodesource.com/setup_${node_choice}.x" | $SUDO -E bash - >/dev/null 2>&1
    else
        curl -fsSL "https://deb.nodesource.com/setup_${node_choice}.x" | bash - >/dev/null 2>&1
    fi

    show_progress "Установка Node.js v${node_choice}.x..."
    $SUDO apt-get install -y nodejs >/dev/null 2>&1

    local installed_node_ver
    installed_node_ver=$(node -v 2>/dev/null || echo "Неизвестно")
    local installed_npm_ver
    installed_npm_ver=$(npm -v 2>/dev/null || echo "Неизвестно")

    whiptail --title "Установка Node.js" --msgbox "Node.js успешно установлен!\n\nВерсия Node.js: $installed_node_ver\nВерсия npm: $installed_npm_ver" 12 60
}

# ==============================================================================
# ИНТЕРАКТИВНОЕ МЕНЮ (TUI)
# ==============================================================================

# Меню раздела: Настройка сервера
menu_server_settings() {
    while true; do
        local server_choice
        server_choice=$(whiptail --title "Настройка сервера" --checklist \
            "Выберите действия по настройке системы (клавиша Пробел для выбора):" 16 65 3 \
            "LOCALE" "Установить русскую локаль (ru_RU.UTF-8)" ON \
            "TIMEZONE" "Установить часовой пояс Asia/Novokuznetsk" ON \
            "LXC_AUTO" "Настроить автологин root для LXC Proxmox" OFF 3>&1 1>&2 2>&3)

        if [ $? -ne 0 ]; then
            break # Возврат в главное меню
        fi

        if [[ "$server_choice" =~ "LOCALE" ]]; then
            setup_russian_locale
        fi
        if [[ "$server_choice" =~ "TIMEZONE" ]]; then
            setup_timezone
        fi
        if [[ "$server_choice" =~ "LXC_AUTO" ]]; then
            setup_lxc_autologin
        fi
        
        whiptail --title "Настройка сервера" --msgbox "Выбранные настройки применены." 8 50
        break
    done
}

# ... Меню раздела: Установка базовых программ
menu_base_apps() {
    while true; do
        local app_choices
        app_choices=$(whiptail --title "Установка базового ПО" --checklist \
            "Выберите программы для установки (клавиша Пробел для выбора):" 17 65 6 \
            "NANO" "Удобный текстовый редактор Nano" ON \
            "ZIP" "Архиваторы zip и unzip" ON \
            "GIT" "Система контроля версий Git" ON \
            "SSH" "SSH-сервер openssh-server" ON \
            "SPEEDTEST" "Консольный тест скорости Speedtest CLI" ON \
            "IPERF" "Утилита измерения сети iperf3" ON 3>&1 1>&2 2>&3)

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
            "Выберите раздел для продолжения настройки:" 15 65 5 \
            "1" "Настройка сервера (Локаль, Таймзона, LXC Автологин)" \
            "2" "Установка базового ПО (Nano, Zip, Git, SSH, Сетевые утилиты)" \
            "3" "Установка Docker и Docker Compose" \
            "4" "Установка Node.js (динамический выбор версии)" \
            "5" "Выйти из скрипта" 3>&1 1>&2 2>&3)

        if [ $? -ne 0 ] || [ "$menu_choice" = "5" ]; then
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
            *)
                break
                ;;
        esac
    done
}

# ==============================================================================
# ТОЧКА ВХОДА В СКРИПТ
# ==============================================================================

# Очищаем экран перед запуском
clear

# Сначала устанавливаем curl, jq, whiptail
install_script_deps

# Переходим в главное TUI-меню
main_menu

# Завершающее сообщение
clear
echo "========================================================"
echo "        Настройка завершена! Спасибо за использование.   "
echo "========================================================"
echo "Рекомендуется перезапустить терминал / переподключиться к SSH"
echo "для корректного применения языковых настроек и прав Docker."
echo "========================================================"
