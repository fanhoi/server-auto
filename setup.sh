#!/usr/bin/env bash

# ==============================================================================
# ubuntu-auto: Скрипт автоматической первоначальной настройки серверов на Ubuntu и Debian.
# Использование: Выполняет локализацию, настройку таймзоны, автологин LXC,
# установку Docker, Node.js и базового ПО через TUI-меню.
# ==============================================================================

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

# Определение операционной системы (для универсальности скрипта)
OS_ID="ubuntu" # Значение по умолчанию
if [ -f /etc/os-release ]; then
    OS_ID=$(. /etc/os-release && echo "$ID")
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
    if ! $SUDO apt-get update >/dev/null 2>&1; then
        log_error "Не удалось обновить списки пакетов apt-get update перед установкой зависимостей."
        return 1
    fi
    
    local -a deps_needed=()
    for pkg in curl jq whiptail; do
        if ! dpkg -s "$pkg" >/dev/null 2>&1; then
            deps_needed+=("$pkg")
        fi
    done

    if [ ${#deps_needed[@]} -gt 0 ]; then
        if ! $SUDO apt-get install -y "${deps_needed[@]}" >/dev/null 2>&1; then
            log_error "Не удалось установить базовые зависимости скрипта: ${deps_needed[*]}."
            exit 1
        fi
    fi
}

# Показывает окно выполнения процесса (информационное сообщение)
show_progress() {
    local message="$1"
    whiptail --title "Пожалуйста, подождите" --infobox "$message" 8 50
}

# Показывает информационный дашборд при входе в систему
show_system_dashboard() {
    local os_info
    os_info=$(. /etc/os-release && echo "$PRETTY_NAME" 2>/dev/null || echo "Ubuntu")
    
    local uptime_info
    uptime_info=$(uptime -p 2>/dev/null | sed 's/up //' || uptime 2>/dev/null)
    
    local disk_info
    disk_info=$(df -h / 2>/dev/null | awk 'NR==2 {print $4 " свободно из " $2 " (использовано " $5 ")"}')
    
    local ram_info
    ram_info=$(free -h 2>/dev/null | awk 'NR==2 {print $3 " из " $2}')
    
    local local_ip
    local_ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "Не определен")
    
    local public_ip
    public_ip=$(curl -s --connect-timeout 2 ifconfig.me 2>/dev/null || echo "Не удалось определить")
    
    local msg="Сведения о вашей системе:
---------------------------------------------
ОС:             $os_info
Uptime:         $uptime_info
Диск (/):       $disk_info
ОЗУ:            $ram_info
Локальный IP:   $local_ip
Внешний IP:     $public_ip
---------------------------------------------"
    
    whiptail --title "Дашборд системы" --msgbox "$msg" 15 60
}

# ==============================================================================
# МОДУЛИ НАСТРОЙКИ СИСТЕМЫ И УСТАНОВКИ ПО
# ==============================================================================

# Установка русского языка (локали ru_RU.UTF-8)
setup_russian_locale() {
    show_progress "Настройка русской локали (ru_RU.UTF-8)..."
    
    if [ "$OS_ID" = "ubuntu" ]; then
        # Для Ubuntu ставим готовый языковой пакет
        if ! $SUDO apt-get update >/dev/null 2>&1 || ! $SUDO apt-get install -y language-pack-ru >/dev/null 2>&1; then
            whiptail --title "Ошибка локализации" --msgbox "Не удалось установить пакет локализации language-pack-ru. Проверьте интернет-соединение." 10 60
            return 1
        fi
    elif [ "$OS_ID" = "debian" ]; then
        # Для Debian устанавливаем locales и генерируем локаль вручную
        if ! $SUDO apt-get update >/dev/null 2>&1 || ! $SUDO apt-get install -y locales >/dev/null 2>&1; then
            whiptail --title "Ошибка локализации" --msgbox "Не удалось установить пакет locales. Проверьте интернет-соединение." 10 60
            return 1
        fi
        
        # Раскомментируем русскую локаль в файле locale.gen
        if [ -f /etc/locale.gen ]; then
            $SUDO sed -i 's/# ru_RU.UTF-8 UTF-8/ru_RU.UTF-8 UTF-8/' /etc/locale.gen
        fi
        
        # Запускаем генерацию локали
        if ! $SUDO locale-gen >/dev/null 2>&1; then
            whiptail --title "Ошибка локализации" --msgbox "Не удалось сгенерировать локаль ru_RU.UTF-8." 10 60
            return 1
        fi
    fi
    
    # Обновляем локаль системы (универсально для обеих систем)
    if ! $SUDO update-locale LANG=ru_RU.UTF-8 >/dev/null 2>&1; then
        whiptail --title "Ошибка локализации" --msgbox "Не удалось обновить локаль системы через update-locale." 10 60
        return 1
    fi
    
    whiptail --title "Настройка локали" --msgbox "Русский язык успешно установлен!\nИзменения вступят в силу после перезагрузки сервера или нового входа по SSH." 10 60
}

# Установка часового пояса "Asia/Novokuznetsk"
setup_timezone() {
    show_progress "Установка часового пояса Asia/Novokuznetsk..."
    
    if ! $SUDO timedatectl set-timezone Asia/Novokuznetsk >/dev/null 2>&1; then
        whiptail --title "Ошибка времени" --msgbox "Не удалось сменить часовой пояс через timedatectl." 10 60
        return 1
    fi
    
    local current_time
    current_time=$(date)
    whiptail --title "Настройка времени" --msgbox "Часовой пояс Asia/Novokuznetsk успешно установлен.\nТекущее системное время:\n$current_time" 10 60
}

# Настройка автологина root для LXC-контейнеров Proxmox
setup_lxc_autologin() {
    show_progress "Настройка автологина root для LXC..."
    
    local dir="/etc/systemd/system/container-getty@1.service.d"
    local conf="$dir/override.conf"
    
    if ! $SUDO mkdir -p "$dir" >/dev/null 2>&1; then
        whiptail --title "Ошибка" --msgbox "Не удалось создать каталог:\n$dir\nПроверьте права доступа." 10 60
        return 1
    fi
    
    echo "[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear --keep-baud tty%I 115200,38400,9600 \$TERM" | $SUDO tee "$conf" > /dev/null

    if ! $SUDO systemctl daemon-reload >/dev/null 2>&1; then
        whiptail --title "Предупреждение" --msgbox "Автологин настроен, но не удалось перезагрузить демоны systemd (daemon-reload)." 10 60
        return 1
    fi
    
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
    if ! $SUDO apt-get update >/dev/null 2>&1; then
        whiptail --title "Ошибка" --msgbox "Не удалось обновить списки пакетов apt. Проверьте подключение к сети." 10 60
        return 1
    fi
    
    local -a failed_pkgs=()
    for pkg in "${pkgs_to_install[@]}"; do
        if ! $SUDO apt-get install -y "$pkg" >/dev/null 2>&1; then
            failed_pkgs+=("$pkg")
        fi
    done

    if [ ${#failed_pkgs[@]} -gt 0 ]; then
        whiptail --title "Ошибка установки" --msgbox "Не удалось установить следующие программы:\n${failed_pkgs[*]}\n\nПопробуйте запустить установку заново." 10 60
        return 1
    fi

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
            if ! $SUDO systemctl restart ssh >/dev/null 2>&1 && ! $SUDO systemctl restart sshd >/dev/null 2>&1; then
                whiptail --title "Предупреждение" --msgbox "Конфигурация SSH записана, но не удалось перезапустить службу ssh/sshd." 10 60
            else
                whiptail --title "Настройка SSH" --msgbox "Преднастройка конфигурации SSH успешно применена!\nСлужба OpenSSH перезапущена." 10 55
            fi
        fi
    fi

    whiptail --title "Установка ПО" --msgbox "Следующие программы успешно установлены:\n${pkgs_to_install[*]}" 10 60
}

# Установка Docker, Docker Compose плагина и создание совместимого симлинка
setup_docker() {
    show_progress "Установка Docker и Docker Compose..."

    # Удаляем потенциально конфликтующие старые пакеты
    for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
        $SUDO apt-get remove -y "$pkg" >/dev/null 2>&1 || true
    done

    # Установка базовых утилит для репозиториев apt
    if ! $SUDO apt-get install -y ca-certificates curl >/dev/null 2>&1; then
        whiptail --title "Ошибка" --msgbox "Не удалось установить вспомогательные утилиты ca-certificates и curl." 10 60
        return 1
    fi
    
    $SUDO install -m 0755 -d /etc/apt/keyrings >/dev/null 2>&1

    # Динамически определяем URL репозитория и кодовое имя дистрибутива (для Debian или Ubuntu)
    local repo_url="https://download.docker.com/linux/ubuntu"
    local codename
    if [ -f /etc/os-release ]; then
        codename=$(. /etc/os-release && echo "$VERSION_CODENAME")
    fi
    
    # Если не удалось получить из /etc/os-release, пробуем lsb_release
    if [ -z "$codename" ] && command -v lsb_release >/dev/null 2>&1; then
        codename=$(lsb_release -cs 2>/dev/null)
    fi
    
    if [ "$OS_ID" = "debian" ]; then
        repo_url="https://download.docker.com/linux/debian"
    fi

    if [ -z "$codename" ]; then
        whiptail --title "Ошибка" --msgbox \
            "Не удалось определить codename Linux-дистрибутива через /etc/os-release или lsb_release." 10 70
        return 1
    fi

    # Добавление официального GPG ключа Docker
    if ! $SUDO curl -fsSL "${repo_url}/gpg" -o /etc/apt/keyrings/docker.asc >/dev/null 2>&1; then
        whiptail --title "Ошибка" --msgbox "Не удалось скачать GPG ключ репозитория Docker." 10 60
        return 1
    fi
    $SUDO chmod a+r /etc/apt/keyrings/docker.asc >/dev/null 2>&1

    # Добавление репозитория в APT
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] ${repo_url} \
      ${codename} stable" | $SUDO tee /etc/apt/sources.list.d/docker.list > /dev/null

    if ! $SUDO apt-get update >/dev/null 2>&1; then
        whiptail --title "Ошибка" --msgbox "Не удалось обновить списки пакетов после подключения репозитория Docker." 10 60
        return 1
    fi
    
    # Установка пакетов Docker Engine
    if ! $SUDO apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null 2>&1; then
        whiptail --title "Ошибка установки" --msgbox "Не удалось установить пакеты Docker Engine." 10 60
        return 1
    fi

    # Запуск и добавление демона в автозагрузку
    $SUDO systemctl enable docker >/dev/null 2>&1 || true
    $SUDO systemctl start docker >/dev/null 2>&1 || true

    # Добавление пользователя в группу docker для работы без sudo (берем SUDO_USER, если запуск под sudo)
    local real_user="$USER"
    if [ -n "$SUDO_USER" ]; then
        real_user="$SUDO_USER"
    fi

    if [ "$EUID" -ne 0 ] || [ "$real_user" != "root" ]; then
        $SUDO usermod -aG docker "$real_user" >/dev/null 2>&1
        local docker_group_msg="Пользователь $real_user добавлен в группу docker.\nПерезайдите в сессию для применения прав."
    else
        local docker_group_msg="Docker установлен для пользователя root."
    fi

    # Создание символической ссылки docker-compose для обратной совместимости
    if [ -f /usr/libexec/docker/cli-plugins/docker-compose ]; then
        $SUDO ln -sf /usr/libexec/docker/cli-plugins/docker-compose /usr/local/bin/docker-compose >/dev/null 2>&1
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

    # Скачиваем список версий в формате JSON, берем Current (последний) и LTS релизы
    local -a node_versions=()
    local api_response
    api_response=$(curl -s https://nodejs.org/dist/index.json 2>/dev/null || echo "")
    
    if [ -n "$api_response" ] && command -v jq >/dev/null 2>&1; then
        # Получаем самую последнюю мажорную версию (Current)
        local current_major
        current_major=$(echo "$api_response" | jq -r '.[0].version' | cut -d'.' -f1 | sed 's/v//')
        
        # Получаем мажорные версии LTS релизов
        local lts_majors
        lts_majors=$(echo "$api_response" | jq -r '.[] | select(.lts != false) | .version' | cut -d'.' -f1 | uniq | sed 's/v//')
        
        # Объединяем их (Current + LTS)
        local is_first=true
        while read -r ver; do
            if [ -n "$ver" ]; then
                local status="OFF"
                if [ "$is_first" = true ]; then
                    status="ON"
                    is_first=false
                fi
                
                local desc="Node.js v$ver LTS"
                if [ "$ver" = "$current_major" ]; then
                    desc="Node.js v$ver (Current)"
                fi
                node_versions+=("$ver" "$desc" "$status")
            fi
        done < <(printf "%s\n%s" "$current_major" "$lts_majors" | uniq | head -n 5)
    fi

    if [ ${#node_versions[@]} -eq 0 ]; then
        node_versions=(
            "26" "Node.js v26 (Current)" "ON"
            "24" "Node.js v24 (LTS)" "OFF"
            "22" "Node.js v22 (LTS)" "OFF"
            "20" "Node.js v20 (LTS)" "OFF"
            "18" "Node.js v18 (LTS)" "OFF"
        )
    fi

    # Показываем TUI-меню выбора версии Node.js
    local node_choice
    node_choice=$(whiptail --title "Выбор версии Node.js" --radiolist \
        "Выберите мажорную версию Node.js для установки через репозиторий NodeSource:" 16 65 5 \
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
    local setup_status
    if [ "$EUID" -ne 0 ]; then
        curl -fsSL "https://deb.nodesource.com/setup_${node_choice}.x" | $SUDO -E bash - >/dev/null 2>&1
        setup_status=$?
    else
        curl -fsSL "https://deb.nodesource.com/setup_${node_choice}.x" | bash - >/dev/null 2>&1
        setup_status=$?
    fi

    if [ $setup_status -ne 0 ]; then
        whiptail --title "Ошибка" --msgbox "Не удалось подключить репозиторий NodeSource для Node.js v${node_choice}.x." 10 60
        return 1
    fi

    show_progress "Установка Node.js v${node_choice}.x..."
    if ! $SUDO apt-get install -y nodejs >/dev/null 2>&1; then
        whiptail --title "Ошибка установки" --msgbox "Не удалось установить пакет nodejs из репозитория NodeSource." 10 60
        return 1
    fi

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

# Меню раздела: Установка базовых программ
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

# Показываем информационный дашборд при входе
show_system_dashboard

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
