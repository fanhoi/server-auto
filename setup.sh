#!/usr/bin/env bash
# Проверка интерпретатора (требуется bash, а не sh)
[ -z "${BASH_VERSION:-}" ] && echo "Ошибка: скрипт требует bash для выполнения." >&2 && exit 1

# ==============================================================================
# server-auto: Скрипт автоматической первоначальной настройки серверов на Ubuntu и Debian.
# Использование: Выполняет локализацию, настройку таймзоны, автологин LXC,
# установку Docker, Node.js и базового ПО через TUI-меню.
# ==============================================================================

# Принудительная установка UTF-8 локали для корректного отображения кириллицы в whiptail
export LANG=C.UTF-8
export LC_ALL=C.UTF-8

# Отключаем интерактивные запросы (debconf) при установке пакетов apt-get
export DEBIAN_FRONTEND=noninteractive

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

# Флаг однократного обновления индекса APT за одну сессию скрипта
APT_UPDATED=false

# Флаг автоматического выполнения (подавляет промежуточные msgbox-окна успешного завершения шагов)
AUTO_MODE=false

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

# Обновление индекса APT — запускается только один раз за сессию (используйте эту функцию вместо прямого apt-get update)
run_apt_update() {
    if [ "$APT_UPDATED" = true ]; then
        return 0
    fi
    if ! $SUDO apt-get update >/dev/null 2>&1; then
        return 1
    fi
    APT_UPDATED=true
}

# Предварительная проверка и установка зависимостей самого скрипта
install_script_deps() {
    echo "[server-auto] Первоначальная подготовка: обновление списков пакетов APT..."
    if ! run_apt_update; then
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
        echo "[server-auto] Установка базовых зависимостей: ${deps_needed[*]}..."
        if ! $SUDO apt-get install -y "${deps_needed[@]}" >/dev/null 2>&1; then
            log_error "Не удалось установить базовые зависимости скрипта: ${deps_needed[*]}."
            exit 1
        fi
    fi
}

# Показывает окно выполнения процесса (информационное сообщение)
show_progress() {
    local message="$1"
    whiptail --title "Пожалуйста, подождите" --infobox "$message" 8 70
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
    
    whiptail --title "Дашборд системы" --msgbox "$msg" 15 72
}

# ==============================================================================
# МОДУЛИ НАСТРОЙКИ СИСТЕМЫ И УСТАНОВКИ ПО
# ==============================================================================

# Установка русского языка (локали ru_RU.UTF-8)
setup_russian_locale() {
    show_progress "Настройка русской локали (ru_RU.UTF-8)..."
    
    if [ "$OS_ID" = "ubuntu" ]; then
        # Для Ubuntu ставим готовый языковой пакет
        if ! run_apt_update || ! $SUDO apt-get install -y language-pack-ru >/dev/null 2>&1; then
            whiptail --title "Ошибка локализации" --msgbox "Не удалось установить пакет локализации language-pack-ru. Проверьте интернет-соединение." 10 70
            return 1
        fi
    elif [ "$OS_ID" = "debian" ]; then
        # Для Debian устанавливаем locales и генерируем локаль вручную
        if ! run_apt_update || ! $SUDO apt-get install -y locales >/dev/null 2>&1; then
            whiptail --title "Ошибка локализации" --msgbox "Не удалось установить пакет locales. Проверьте интернет-соединение." 10 70
            return 1
        fi
        
        # Раскомментируем русскую локаль в файле locale.gen
        if [ -f /etc/locale.gen ]; then
            $SUDO sed -i 's/# ru_RU.UTF-8 UTF-8/ru_RU.UTF-8 UTF-8/' /etc/locale.gen
        fi
        
        # Запускаем генерацию локали
        if ! $SUDO locale-gen >/dev/null 2>&1; then
            whiptail --title "Ошибка локализации" --msgbox "Не удалось сгенерировать локаль ru_RU.UTF-8." 10 70
            return 1
        fi
    fi
    
    # Обновляем локаль системы (универсально для обеих систем)
    if ! $SUDO update-locale LANG=ru_RU.UTF-8 >/dev/null 2>&1; then
        whiptail --title "Ошибка локализации" --msgbox "Не удалось обновить локаль системы через update-locale." 10 70
        return 1
    fi
    
    if [ "$AUTO_MODE" = false ]; then
        whiptail --title "Настройка локали" --msgbox "Русский язык успешно установлен!\nИзменения вступят в силу после перезагрузки сервера или нового входа по SSH." 10 70
    fi
}

# Установка часового пояса "Asia/Novokuznetsk"
setup_timezone() {
    show_progress "Установка часового пояса Asia/Novokuznetsk..."
    
    if ! $SUDO timedatectl set-timezone Asia/Novokuznetsk >/dev/null 2>&1; then
        whiptail --title "Ошибка времени" --msgbox "Не удалось сменить часовой пояс через timedatectl." 10 70
        return 1
    fi
    
    local current_time
    current_time=$(date)
    if [ "$AUTO_MODE" = false ]; then
        whiptail --title "Настройка времени" --msgbox "Часовой пояс Asia/Novokuznetsk успешно установлен.\nТекущее системное время:\n$current_time" 10 70
    fi
}

# Настройка автологина root для LXC-контейнеров Proxmox
setup_lxc_autologin() {
    show_progress "Настройка автологина root для LXC..."
    
    local dir="/etc/systemd/system/container-getty@1.service.d"
    local conf="$dir/override.conf"
    
    if ! $SUDO mkdir -p "$dir" >/dev/null 2>&1; then
        whiptail --title "Ошибка" --msgbox "Не удалось создать каталог:\n$dir\nПроверьте права доступа." 10 70
        return 1
    fi
    
    echo "[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear --keep-baud tty%I 115200,38400,9600 \$TERM" | $SUDO tee "$conf" > /dev/null

    if ! $SUDO systemctl daemon-reload >/dev/null 2>&1; then
        whiptail --title "Предупреждение" --msgbox "Автологин настроен, но не удалось перезагрузить демоны systemd (daemon-reload)." 10 70
        return 1
    fi
    
    if [ "$AUTO_MODE" = false ]; then
        whiptail --title "Настройка LXC" --msgbox "Автоматический вход root для контейнера LXC успешно настроен!\nИзменения применятся при следующем запуске контейнера." 10 70
    fi
}

# Установка выбранных базовых программ
setup_base_packages() {
    local choices="$1"
    local mode="$2"
    if [ -z "$choices" ]; then
        whiptail --title "Установка ПО" --msgbox "Вы не выбрали ни одной программы для установки." 8 60
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
        if [ "$mode" = "auto" ]; then
            configure_ssh=true
        elif whiptail --title "Настройка SSH" --yesno "Вы выбрали установку SSH.\nХотите применить вашу преднастройку конфигурации?\n\n- Порт: 22\n- Вход для root по паролю: Разрешен\n- Ограничение доступа: Только из локальных сетей (192.168.*, 10.*, 172.*, 127.*)" 14 78; then
            configure_ssh=true
        fi
    fi

    show_progress "Обновление списков пакетов APT..."
    if ! run_apt_update; then
        whiptail --title "Ошибка" --msgbox "Не удалось обновить списки пакетов apt. Проверьте подключение к сети." 10 70
        return 1
    fi

    # Устанавливаем пакеты с отображением прогресс-бара (gauge)
    local total=${#pkgs_to_install[@]}
    local tmpfail
    tmpfail=$(mktemp)

    {
        local i=0
        for pkg in "${pkgs_to_install[@]}"; do
            i=$((i + 1))
            local pct=$(( i * 100 / total ))
            printf "XXX\n%d\n[%d/%d] Устанавливается: %s\nXXX\n" "$pct" "$i" "$total" "$pkg"
            if ! $SUDO apt-get install -y "$pkg" >/dev/null 2>&1; then
                echo "$pkg" >> "$tmpfail"
            fi
        done
    } | whiptail --title "Установка ПО" --gauge "Подготовка..." 8 78 0

    # Читаем список неудавшихся пакетов из временного файла (сабшелл трубы не может изменять переменные родителя)
    local -a failed_pkgs=()
    if [ -s "$tmpfail" ]; then
        while IFS= read -r pkg; do
            failed_pkgs+=("$pkg")
        done < "$tmpfail"
    fi
    rm -f "$tmpfail"

    if [ ${#failed_pkgs[@]} -gt 0 ]; then
        whiptail --title "Ошибка установки" --msgbox "Не удалось установить следующие программы:\n${failed_pkgs[*]}\n\nПопробуйте запустить установку заново." 10 70
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
AllowUsers *@192.168.1.* *@127.0.0.1
Subsystem sftp /usr/lib/openssh/sftp-server" | $SUDO tee /etc/ssh/sshd_config > /dev/null

            # Перезапускаем сервис SSH (пробуем ssh — Ubuntu, при ошибке пробуем sshd — Debian)
            if $SUDO systemctl restart ssh >/dev/null 2>&1 || $SUDO systemctl restart sshd >/dev/null 2>&1; then
                if [ "$AUTO_MODE" = false ]; then
                    whiptail --title "Настройка SSH" --msgbox "Преднастройка конфигурации SSH успешно применена!\nСлужба OpenSSH перезапущена." 10 68
                fi
            else
                if [ "$AUTO_MODE" = false ]; then
                    whiptail --title "Предупреждение" --msgbox "Конфигурация SSH записана, но не удалось перезапустить службу ssh/sshd." 10 70
                fi
            fi
        fi
    fi

    if [ "$AUTO_MODE" = false ]; then
        whiptail --title "Установка ПО" --msgbox "Следующие программы успешно установлены:\n${pkgs_to_install[*]}" 10 70
    fi
}

# Установка Docker, Docker Compose плагина и создание совместимого симлинка
setup_docker() {
    local auto_mode="$1"
    # Проверка, установлен ли уже Docker
    if [ -z "$auto_mode" ] && command -v docker >/dev/null 2>&1; then
        local current_docker_ver
        current_docker_ver=$(docker -v 2>/dev/null | awk '{print $3}' | sed 's/,//')
        if ! whiptail --title "Установка Docker" --yesno "Docker уже установлен (версия: $current_docker_ver).\nХотите переустановить или обновить его?" 10 70; then
            return 0
        fi
    fi

    # Определяем URL репозитория и кодовое имя дистрибутива ДО запуска gauge
    local repo_url="https://download.docker.com/linux/ubuntu"
    local codename=""
    if [ -f /etc/os-release ]; then
        codename=$(. /etc/os-release && echo "$VERSION_CODENAME")
    fi
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

    # Временный файл для передачи ошибок из сабшелла gauge
    local tmpfail
    tmpfail=$(mktemp)

    # Поэтапная установка Docker с прогресс-баром
    {
        # Шаг 1/6: Удаление старых пакетов
        printf "XXX\n10\n[1/6] Удаление конфликтующих пакетов...\nXXX\n"
        for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
            $SUDO apt-get remove -y "$pkg" >/dev/null 2>&1 || true
        done

        # Шаг 2/6: Обновление индекса APT и базовые зависимости
        printf "XXX\n25\n[2/6] Установка ca-certificates и curl...\nXXX\n"
        run_apt_update
        if ! $SUDO apt-get install -y ca-certificates curl >/dev/null 2>&1; then
            echo "ERR_CACERT" >> "$tmpfail"
            exit 0
        fi
        $SUDO install -m 0755 -d /etc/apt/keyrings >/dev/null 2>&1

        # Шаг 3/6: Скачивание GPG ключа Docker
        printf "XXX\n40\n[3/6] Загрузка GPG ключа Docker...\nXXX\n"
        if ! $SUDO curl -fsSL "${repo_url}/gpg" -o /etc/apt/keyrings/docker.asc >/dev/null 2>&1; then
            echo "ERR_GPG" >> "$tmpfail"
            exit 0
        fi
        $SUDO chmod a+r /etc/apt/keyrings/docker.asc >/dev/null 2>&1

        # Шаг 4/6: Добавление репозитория Docker в APT
        printf "XXX\n55\n[4/6] Подключение репозитория Docker...\nXXX\n"
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] ${repo_url} ${codename} stable" \
            | $SUDO tee /etc/apt/sources.list.d/docker.list > /dev/null
        if ! $SUDO apt-get update >/dev/null 2>&1; then
            echo "ERR_UPDATE" >> "$tmpfail"
            exit 0
        fi

        # Шаг 5/6: Установка Docker Engine
        printf "XXX\n70\n[5/6] Установка Docker Engine (может занять несколько минут)...\nXXX\n"
        if ! $SUDO apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null 2>&1; then
            echo "ERR_INSTALL" >> "$tmpfail"
            exit 0
        fi

        # Шаг 6/6: Запуск и автозагрузка демона
        printf "XXX\n90\n[6/6] Запуск службы Docker...\nXXX\n"
        $SUDO systemctl enable docker >/dev/null 2>&1 || true
        $SUDO systemctl start docker >/dev/null 2>&1 || true

        printf "XXX\n100\n[6/6] Готово!\nXXX\n"

    } | whiptail --title "Установка Docker" --gauge "Подготовка..." 8 78 0

    # Проверяем наличие ошибок из сабшелла
    if [ -s "$tmpfail" ]; then
        local docker_err
        docker_err=$(cat "$tmpfail")
        rm -f "$tmpfail"
        case "$docker_err" in
            ERR_CACERT)
                whiptail --title "Ошибка" --msgbox "Не удалось установить ca-certificates и curl." 10 70
                return 1 ;;
            ERR_GPG)
                whiptail --title "Ошибка" --msgbox "Не удалось скачать GPG ключ репозитория Docker." 10 70
                return 1 ;;
            ERR_UPDATE)
                whiptail --title "Ошибка" --msgbox "Не удалось обновить списки пакетов после подключения репозитория Docker." 10 70
                return 1 ;;
            ERR_INSTALL)
                whiptail --title "Ошибка установки" --msgbox "Не удалось установить пакеты Docker Engine." 10 70
                return 1 ;;
        esac
    fi
    rm -f "$tmpfail"

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

    # Создание символической ссылки docker-compose для обратной совместимости (ищем в двух возможных путях)
    for _compose_path in /usr/libexec/docker/cli-plugins/docker-compose /usr/lib/docker/cli-plugins/docker-compose; do
        if [ -f "$_compose_path" ]; then
            $SUDO ln -sf "$_compose_path" /usr/local/bin/docker-compose >/dev/null 2>&1
            break
        fi
    done

    local docker_ver
    docker_ver=$(docker --version 2>/dev/null || echo "Неизвестно")
    local compose_ver
    compose_ver=$(docker compose version 2>/dev/null || echo "Неизвестно")

    if [ "$AUTO_MODE" = false ]; then
        whiptail --title "Установка Docker" --msgbox "Docker и Docker Compose успешно установлены!\n\nВерсия Docker: $docker_ver\nВерсия Compose: $compose_ver\n\n$docker_group_msg" 14 78
    fi
}

# Динамический опрос версий Node.js и их установка
setup_nodejs() {
    local target_version="$1"
    # Проверка, установлен ли уже Node.js
    if [ -z "$target_version" ] && command -v node >/dev/null 2>&1; then
        local current_node_ver
        current_node_ver=$(node -v 2>/dev/null)
        if ! whiptail --title "Установка Node.js" --yesno "Node.js уже установлен (версия: $current_node_ver).\nХотите переустановить или сменить версию?" 10 70; then
            return 0
        fi
    fi

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

    # Показываем TUI-меню выбора версии Node.js или выбираем автоматически
    local node_choice
    if [ -n "$target_version" ]; then
        # Определение последней версии
        local latest_ver="26" # Дефолтный фолбек
        if [ -n "$api_response" ] && command -v jq >/dev/null 2>&1; then
            latest_ver=$(echo "$api_response" | jq -r '.[0].version' | cut -d'.' -f1 | sed 's/v//')
        fi
        
        if [ "$target_version" = "latest" ]; then
            node_choice="$latest_ver"
        else
            node_choice="$target_version"
        fi
    else
        node_choice=$(whiptail --title "Выбор версии Node.js" --radiolist \
            "Выберите мажорную версию Node.js для установки через репозиторий NodeSource:" 16 75 5 \
            "${node_versions[@]}" 3>&1 1>&2 2>&3)
    fi

    if [ -z "$node_choice" ]; then
        return
    fi

    show_progress "Очистка старой версии Node.js..."
    $SUDO apt-get remove -y nodejs npm >/dev/null 2>&1 || true
    $SUDO apt-get purge -y nodejs npm >/dev/null 2>&1 || true
    $SUDO rm -f /etc/apt/sources.list.d/nodesource.list >/dev/null 2>&1 || true
    $SUDO apt-get autoremove -y >/dev/null 2>&1 || true

    # Временный файл для передачи ошибок из сабшелла gauge
    local tmpfail
    tmpfail=$(mktemp)

    # Поэтапная установка Node.js с прогресс-баром
    {
        # Шаг 1/3: Подключение репозитория NodeSource
        printf "XXX\n20\n[1/3] Подключение репозитория NodeSource v%s.x...\nXXX\n" "$node_choice"
        local setup_status=0
        if [ "$EUID" -ne 0 ]; then
            curl -fsSL "https://deb.nodesource.com/setup_${node_choice}.x" | $SUDO -E bash - >/dev/null 2>&1
            setup_status=$?
        else
            curl -fsSL "https://deb.nodesource.com/setup_${node_choice}.x" | bash - >/dev/null 2>&1
            setup_status=$?
        fi
        if [ $setup_status -ne 0 ]; then
            echo "ERR_NODESOURCE" >> "$tmpfail"
            exit 0
        fi

        # Шаг 2/3: Установка nodejs
        printf "XXX\n60\n[2/3] Установка Node.js v%s.x (может занять несколько минут)...\nXXX\n" "$node_choice"
        if ! $SUDO apt-get install -y nodejs >/dev/null 2>&1; then
            echo "ERR_INSTALL" >> "$tmpfail"
            exit 0
        fi

        # Шаг 3/3: Готово
        printf "XXX\n100\n[3/3] Готово!\nXXX\n"

    } | whiptail --title "Установка Node.js" --gauge "Подготовка..." 8 78 0

    # Проверяем ошибки из сабшелла
    if [ -s "$tmpfail" ]; then
        local node_err
        node_err=$(cat "$tmpfail")
        rm -f "$tmpfail"
        case "$node_err" in
            ERR_NODESOURCE)
                whiptail --title "Ошибка" --msgbox "Не удалось подключить репозиторий NodeSource для Node.js v${node_choice}.x." 10 72
                return 1 ;;
            ERR_INSTALL)
                whiptail --title "Ошибка установки" --msgbox "Не удалось установить пакет nodejs из репозитория NodeSource." 10 70
                return 1 ;;
        esac
    fi
    rm -f "$tmpfail"

    local installed_node_ver
    installed_node_ver=$(node -v 2>/dev/null || echo "Неизвестно")
    local installed_npm_ver
    installed_npm_ver=$(npm -v 2>/dev/null || echo "Неизвестно")

    if [ "$AUTO_MODE" = false ]; then
        whiptail --title "Установка Node.js" --msgbox "Node.js успешно установлен!\n\nВерсия Node.js: $installed_node_ver\nВерсия npm: $installed_npm_ver" 12 70
    fi
}

# ==============================================================================
# ИНТЕРАКТИВНОЕ МЕНЮ (TUI)
# ==============================================================================

# Меню раздела: Настройка сервера
menu_server_settings() {
    while true; do
        local locale_desc="Установить русскую локаль (ru_RU.UTF-8)"
        local locale_state="ON"
        if grep -q "ru_RU.UTF-8" /etc/default/locale 2>/dev/null; then
            locale_desc="Установить русскую локаль (ru_RU.UTF-8) (уже установлена)"
            locale_state="OFF"
        fi

        local tz_desc="Установить часовой пояс Asia/Novokuznetsk"
        local tz_state="ON"
        if timedatectl show --property=Timezone 2>/dev/null | grep -q "Asia/Novokuznetsk"; then
            tz_desc="Установить часовой пояс Asia/Novokuznetsk (уже установлен)"
            tz_state="OFF"
        fi

        local lxc_desc="Настроить автологин root для LXC Proxmox"
        local lxc_state="OFF"
        if [ -f /etc/systemd/system/container-getty@1.service.d/override.conf ] && \
           grep -q "agetty --autologin root" /etc/systemd/system/container-getty@1.service.d/override.conf 2>/dev/null; then
            lxc_desc="Настроить автологин root для LXC Proxmox (уже настроен)"
            lxc_state="OFF"
        fi

        local server_choice
        server_choice=$(whiptail --title "Настройка сервера" --checklist \
            "Выберите действия по настройке системы (клавиша Пробел для выбора):" 16 75 3 \
            "LOCALE" "$locale_desc" "$locale_state" \
            "TIMEZONE" "$tz_desc" "$tz_state" \
            "LXC_AUTO" "$lxc_desc" "$lxc_state" 3>&1 1>&2 2>&3)

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
        
        whiptail --title "Настройка сервера" --msgbox "Выбранные настройки применены." 8 60
        break
    done
}

# Меню раздела: Установка базовых программ
menu_base_apps() {
    while true; do
        local nano_desc="Удобный текстовый редактор Nano"
        local nano_state="ON"
        if command -v nano >/dev/null 2>&1; then
            nano_desc="Удобный текстовый редактор Nano (уже установлено)"
            nano_state="OFF"
        fi

        local zip_desc="Архиваторы zip и unzip"
        local zip_state="ON"
        if command -v zip >/dev/null 2>&1; then
            zip_desc="Архиваторы zip и unzip (уже установлены)"
            zip_state="OFF"
        fi

        local git_desc="Система контроля версий Git"
        local git_state="ON"
        if command -v git >/dev/null 2>&1; then
            git_desc="Система контроля версий Git (уже установлен)"
            git_state="OFF"
        fi

        local ssh_desc="SSH-сервер openssh-server"
        local ssh_state="ON"
        if dpkg -s openssh-server >/dev/null 2>&1; then
            ssh_desc="SSH-сервер openssh-server (уже установлен)"
            ssh_state="OFF"
        fi

        local speedtest_desc="Консольный тест скорости Speedtest CLI"
        local speedtest_state="ON"
        if command -v speedtest >/dev/null 2>&1 || command -v speedtest-cli >/dev/null 2>&1; then
            speedtest_desc="Консольный тест скорости Speedtest CLI (уже установлен)"
            speedtest_state="OFF"
        fi

        local iperf_desc="Утилита измерения сети iperf3"
        local iperf_state="ON"
        if command -v iperf3 >/dev/null 2>&1; then
            iperf_desc="Утилита измерения сети iperf3 (уже установлена)"
            iperf_state="OFF"
        fi

        local app_choices
        app_choices=$(whiptail --title "Установка базового ПО" --checklist \
            "Выберите программы для установки (клавиша Пробел для выбора):" 17 75 6 \
            "NANO" "$nano_desc" "$nano_state" \
            "ZIP" "$zip_desc" "$zip_state" \
            "GIT" "$git_desc" "$git_state" \
            "SSH" "$ssh_desc" "$ssh_state" \
            "SPEEDTEST" "$speedtest_desc" "$speedtest_state" \
            "IPERF" "$iperf_desc" "$iperf_state" 3>&1 1>&2 2>&3)

        if [ $? -ne 0 ]; then
            break # Возврат в главное меню
        fi

        setup_base_packages "$app_choices"
        break
    done
}

# Выполнить полную автоматическую настройку и установку всего ПО
setup_all() {
    # Включаем глобальный автоматический режим для подавления промежуточных msgbox
    AUTO_MODE=true

    # 1. Применяем настройки сервера
    setup_russian_locale || true
    setup_timezone || true
    setup_lxc_autologin || true

    # 2. Устанавливаем все базовое ПО с автонастройкой SSH
    setup_base_packages "NANO ZIP GIT SSH SPEEDTEST IPERF" "auto"

    # 3. Устанавливаем Docker
    setup_docker "auto"

    # 4. Устанавливаем Node.js последней версии
    setup_nodejs "latest"

    # Выключаем автоматический режим
    AUTO_MODE=false

    whiptail --title "Выполнить всё" --msgbox "Полная автоматическая настройка завершена успешно!\nВсе системные параметры настроены, базовые программы, Docker и Node.js установлены." 10 70
}

# Главное меню скрипта автонастройки
main_menu() {
    while true; do
        local docker_status=""
        if command -v docker >/dev/null 2>&1; then
            local d_ver
            d_ver=$(docker -v 2>/dev/null | awk '{print $3}' | sed 's/,//')
            docker_status=" [Установлен: $d_ver]"
        fi

        local node_status=""
        if command -v node >/dev/null 2>&1; then
            local n_ver
            n_ver=$(node -v 2>/dev/null)
            node_status=" [Установлен: $n_ver]"
        fi

        local menu_choice
        menu_choice=$(whiptail --title "Server Auto Setup Script v1.0" --menu \
            "Выберите раздел для продолжения настройки:" 16 75 6 \
            "1" "Настройка сервера (Локаль, Таймзона, LXC Автологин)" \
            "2" "Установка базового ПО (Nano, Zip, Git, SSH, Сетевые утилиты)" \
            "3" "Установка Docker и Docker Compose$docker_status" \
            "4" "Установка Node.js (динамический выбор версии)$node_status" \
            "5" "Выполнить всё (автоматическая установка всех настроек и программ)" \
            "6" "Выйти из скрипта" 3>&1 1>&2 2>&3)

        if [ $? -ne 0 ] || [ "$menu_choice" = "6" ]; then
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
                setup_all
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
