#!/usr/bin/env bash

# ============================================================
# IA-SERVER
# PCCURICO SPA
# Ubuntu Server 24.04 LTS
#
# Instalador LAMP + IA
#
# Componentes:
#   Apache2
#   PHP 8.3
#   PHP-FPM
#   MySQL
#   phpMyAdmin
#   Node.js 24 LTS
#   OmniRoute
#   Ollama
#   llmfit
#   UFW
#   SSH
#
# Compatible con:
#   curl ... | sudo bash
#   sudo bash ia-server_lamp_ollama.sh
#   sudo bash ia-server_lamp_ollama.sh --install
#
# ============================================================

set -Eeuo pipefail

SCRIPT_NAME="ia-server_lamp_ollama.sh"
SCRIPT_VERSION="2.0.0"

LOG_FILE="/var/log/ia-server/install.log"
STATE_DIR="/var/lib/ia-server"
CONFIG_DIR="/etc/ia-server"

PHP_VERSION="8.3"
NODE_MAJOR="24"

OMNI_PORT="20128"
OLLAMA_PORT="11434"

OLLAMA_HOST_DEFAULT="127.0.0.1"
OLLAMA_CONTEXT_LENGTH="32768"
OLLAMA_KEEP_ALIVE="10m"

OMNI_USER="omniroute"
OMNI_GROUP="omniroute"
OMNI_HOME="/var/lib/omniroute"

TIMEZONE="America/Santiago"

TTY_FD=0

# ============================================================
# COLORES
# ============================================================

if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    WHITE='\033[1;37m'
    GRAY='\033[0;90m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    CYAN=''
    WHITE=''
    GRAY=''
    NC=''
fi

# ============================================================
# LOG
# ============================================================

prepare_logging() {
    mkdir -p "$(dirname "$LOG_FILE")"
    touch "$LOG_FILE"
    chmod 640 "$LOG_FILE"
}

log() {
    local message="$*"

    printf '[%s] %s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" \
        "$message" >> "$LOG_FILE"
}

info() {
    echo -e "${CYAN}[INFO]${NC} $*"
    log "[INFO] $*"
}

success() {
    echo -e "${GREEN}[OK]${NC} $*"
    log "[OK] $*"
}

warning() {
    echo -e "${YELLOW}[AVISO]${NC} $*"
    log "[AVISO] $*"
}

error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
    log "[ERROR] $*"
}

# ============================================================
# ERROR HANDLER
# ============================================================

on_error() {
    local line="${1:-unknown}"
    local code="${2:-1}"
    local command="${3:-unknown}"

    echo
    echo -e "${RED}============================================================${NC}"
    echo -e "${RED}ERROR EN IA-SERVER${NC}"
    echo -e "${RED}============================================================${NC}"
    echo
    echo "Línea      : $line"
    echo "Código     : $code"
    echo "Comando    : $command"
    echo "Log        : $LOG_FILE"
    echo

    log "ERROR line=$line code=$code command=$command"

    return "$code"
}

trap 'on_error "$LINENO" "$?" "$BASH_COMMAND"' ERR

# ============================================================
# TERMINAL INTERACTIVA
# ============================================================

setup_terminal() {

    # IMPORTANTE:
    # Cuando se ejecuta:
    #
    # curl URL | sudo bash
    #
    # stdin pertenece a curl.
    #
    # Por eso todas las lecturas interactivas deben utilizar
    # /dev/tty y no stdin.

    if [[ -r /dev/tty ]]; then
        exec 3</dev/tty
        TTY_FD=3
    else
        TTY_FD=0
    fi
}

read_input() {
    local prompt="$1"
    local result_var="$2"
    local value=""

    if ! read -r -u "$TTY_FD" -p "$prompt" value; then
        return 1
    fi

    printf -v "$result_var" '%s' "$value"
}

read_secret() {
    local prompt="$1"
    local result_var="$2"
    local value=""

    if ! read -r -u "$TTY_FD" -s -p "$prompt" value; then
        echo
        return 1
    fi

    echo
    printf -v "$result_var" '%s' "$value"
}

pause_screen() {
    local dummy=""
    echo
    read -r -u "$TTY_FD" -p "Presiona ENTER para continuar..." dummy || true
}

confirm() {
    local question="$1"
    local answer=""

    read -r -u "$TTY_FD" -p "$question [s/N]: " answer || return 1

    case "${answer,,}" in
        s|si|sí|y|yes)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# ============================================================
# ROOT
# ============================================================

require_root() {

    if [[ "${EUID}" -ne 0 ]]; then
        echo -e "${RED}Este instalador debe ejecutarse como root.${NC}"
        echo
        echo "Ejemplo:"
        echo
        echo "  curl -fsSL https://raw.githubusercontent.com/pccurico/install/refs/heads/master/ia-server_lamp_ollama.sh | sudo bash"
        echo
        exit 1
    fi
}

# ============================================================
# SISTEMA OPERATIVO
# ============================================================

check_os() {

    if [[ ! -f /etc/os-release ]]; then
        error "No se pudo determinar el sistema operativo."
        exit 1
    fi

    # shellcheck disable=SC1091
    source /etc/os-release

    if [[ "${ID:-}" != "ubuntu" ]]; then
        error "Este instalador requiere Ubuntu."
        error "Sistema detectado: ${PRETTY_NAME:-desconocido}"
        exit 1
    fi

    if [[ "${VERSION_ID:-}" != "24.04" ]]; then
        error "Este instalador está diseñado exclusivamente para Ubuntu Server 24.04 LTS."
        error "Sistema detectado: ${PRETTY_NAME:-desconocido}"
        exit 1
    fi

    success "Sistema operativo: Ubuntu Server 24.04 LTS"
}

# ============================================================
# DIRECTORIOS
# ============================================================

prepare_directories() {

    mkdir -p "$STATE_DIR"
    mkdir -p "$CONFIG_DIR"
    mkdir -p "$(dirname "$LOG_FILE")"

    touch "$LOG_FILE"

    chmod 750 "$STATE_DIR"
    chmod 750 "$CONFIG_DIR"
    chmod 640 "$LOG_FILE"

    success "Directorios del sistema preparados."
}

# ============================================================
# HOSTNAME / TIMEZONE
# ============================================================

configure_system_identity() {

    if [[ "$(hostname)" != "ia-server" ]]; then

        if confirm "¿Configurar hostname como ia-server?"; then
            hostnamectl set-hostname ia-server
            success "Hostname configurado: ia-server"
        fi

    else
        success "Hostname: ia-server"
    fi

    timedatectl set-timezone "$TIMEZONE" 2>/dev/null || true

    success "Zona horaria: $TIMEZONE"
}

# ============================================================
# APT
# ============================================================

apt_update() {

    export DEBIAN_FRONTEND=noninteractive

    apt-get update

    success "Índices APT actualizados."
}

apt_upgrade() {

    export DEBIAN_FRONTEND=noninteractive

    apt-get upgrade -y

    success "Sistema actualizado."
}

# ============================================================
# PREPARACIÓN
# ============================================================

install_base_packages() {

    info "Preparando Ubuntu Server..."

    export DEBIAN_FRONTEND=noninteractive

    apt-get update

    apt-get install -y \
        apt-transport-https \
        ca-certificates \
        curl \
        wget \
        gnupg \
        lsb-release \
        software-properties-common \
        unzip \
        zip \
        tar \
        git \
        rsync \
        jq \
        nano \
        vim \
        htop \
        btop \
        tree \
        net-tools \
        iproute2 \
        dnsutils \
        pciutils \
        usbutils \
        lsof \
        procps \
        openssh-server \
        ufw \
        fail2ban \
        cron \
        curl \
        build-essential \
        pkg-config

    systemctl enable --now ssh
    systemctl enable --now cron

    success "Paquetes base instalados."
}

# ============================================================
# APACHE
# ============================================================

install_apache() {

    info "Instalando Apache2..."

    export DEBIAN_FRONTEND=noninteractive

    apt-get update

    apt-get install -y \
        apache2 \
        apache2-utils

    a2enmod rewrite
    a2enmod headers
    a2enmod ssl
    a2enmod proxy
    a2enmod proxy_http
    a2enmod proxy_fcgi
    a2enmod setenvif
    a2enmod expires
    a2enmod deflate

    systemctl enable apache2
    systemctl restart apache2

    if systemctl is-active --quiet apache2; then
        success "Apache2 activo."
    else
        error "Apache2 no quedó activo."
        return 1
    fi
}

# ============================================================
# PHP 8.3
# ============================================================

install_php_versions() {

    info "Instalando PHP ${PHP_VERSION}..."

    export DEBIAN_FRONTEND=noninteractive

    apt-get update

    apt-get install -y \
        "php${PHP_VERSION}" \
        "php${PHP_VERSION}-cli" \
        "php${PHP_VERSION}-common" \
        "php${PHP_VERSION}-fpm" \
        "php${PHP_VERSION}-mysql" \
        "php${PHP_VERSION}-xml" \
        "php${PHP_VERSION}-curl" \
        "php${PHP_VERSION}-zip" \
        "php${PHP_VERSION}-mbstring" \
        "php${PHP_VERSION}-gd" \
        "php${PHP_VERSION}-intl" \
        "php${PHP_VERSION}-bcmath" \
        "php${PHP_VERSION}-soap" \
        "php${PHP_VERSION}-readline" \
        "php${PHP_VERSION}-opcache"

    systemctl enable --now "php${PHP_VERSION}-fpm"

    a2enmod proxy_fcgi
    a2enconf "php${PHP_VERSION}-fpm"

    update-alternatives \
        --install /usr/bin/php php /usr/bin/php${PHP_VERSION} 83

    update-alternatives \
        --set php "/usr/bin/php${PHP_VERSION}"

    systemctl restart apache2
    systemctl restart "php${PHP_VERSION}-fpm"

    php -v

    success "PHP ${PHP_VERSION} instalado y configurado."
}

# ============================================================
# MYSQL
# ============================================================

install_mysql() {

    info "Instalando MySQL..."

    export DEBIAN_FRONTEND=noninteractive

    apt-get update

    apt-get install -y \
        mysql-server \
        mysql-client

    systemctl enable mysql
    systemctl restart mysql

    if systemctl is-active --quiet mysql; then
        success "MySQL activo."
    else
        error "MySQL no quedó activo."
        return 1
    fi

    mysql --version
}

# ============================================================
# CREAR BASE DE DATOS / USUARIO
# ============================================================

create_mysql_database() {

    local db_name=""
    local db_user=""
    local db_password=""

    echo
    echo "============================================================"
    echo " CREAR BASE DE DATOS MYSQL"
    echo "============================================================"
    echo

    read_input "Nombre BD: " db_name
    read_input "Usuario MySQL: " db_user
    read_secret "Contraseña MySQL: " db_password

    if [[ -z "$db_name" || -z "$db_user" || -z "$db_password" ]]; then
        error "Todos los valores son obligatorios."
        return 1
    fi

    mysql --protocol=socket -uroot <<SQL
CREATE DATABASE IF NOT EXISTS \`${db_name}\`
CHARACTER SET utf8mb4
COLLATE utf8mb4_unicode_ci;

CREATE USER IF NOT EXISTS '${db_user}'@'localhost'
IDENTIFIED BY '${db_password}';

ALTER USER '${db_user}'@'localhost'
IDENTIFIED BY '${db_password}';

GRANT ALL PRIVILEGES ON \`${db_name}\`.* TO '${db_user}'@'localhost';

FLUSH PRIVILEGES;
SQL

    cat > "${CONFIG_DIR}/mysql.conf" <<EOF
DB_NAME=${db_name}
DB_USER=${db_user}
DB_HOST=127.0.0.1
DB_PORT=3306
EOF

    chmod 640 "${CONFIG_DIR}/mysql.conf"

    success "Base de datos creada: ${db_name}"
    success "Usuario creado: ${db_user}"
}

# ============================================================
# PHPMYADMIN
# ============================================================

install_phpmyadmin() {

    info "Instalando phpMyAdmin..."

    export DEBIAN_FRONTEND=noninteractive

    apt-get update

    echo "phpmyadmin phpmyadmin/reconfigure-webserver multiselect apache2" \
        | debconf-set-selections

    echo "phpmyadmin phpmyadmin/dbconfig-install boolean false" \
        | debconf-set-selections

    apt-get install -y phpmyadmin

    if [[ -d /usr/share/phpmyadmin ]]; then

        if [[ ! -e /var/www/html/phpmyadmin ]]; then
            ln -s /usr/share/phpmyadmin /var/www/html/phpmyadmin
        fi

    fi

    cat > /etc/apache2/conf-available/phpmyadmin-custom.conf <<'EOF'
Alias /phpmyadmin /usr/share/phpmyadmin

<Directory /usr/share/phpmyadmin>
    Options FollowSymLinks
    DirectoryIndex index.php

    AllowOverride All

    Require all granted
</Directory>
EOF

    a2enconf phpmyadmin-custom

    systemctl restart apache2

    if [[ -f /usr/share/phpmyadmin/index.php ]]; then
        success "phpMyAdmin instalado."
        success "URL: http://IP-SERVIDOR/phpmyadmin"
    else
        warning "phpMyAdmin fue instalado pero no se encontró su directorio."
    fi
}

# ============================================================
# VIRTUAL HOST
# ============================================================

create_virtual_host() {

    local domain=""
    local document_root=""
    local conf_name=""

    echo
    echo "============================================================"
    echo " CREAR VIRTUAL HOST APACHE"
    echo "============================================================"
    echo

    read_input "Dominio o hostname: " domain

    if [[ -z "$domain" ]]; then
        error "El dominio es obligatorio."
        return 1
    fi

    read_input \
        "DocumentRoot [/var/www/${domain}]: " \
        document_root

    if [[ -z "$document_root" ]]; then
        document_root="/var/www/${domain}"
    fi

    conf_name="${domain//[^a-zA-Z0-9._-]/_}.conf"

    mkdir -p "$document_root"

    chown -R www-data:www-data "$document_root"

    cat > "/etc/apache2/sites-available/${conf_name}" <<EOF
<VirtualHost *:80>

    ServerName ${domain}

    DocumentRoot ${document_root}

    <Directory ${document_root}>
        Options FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    DirectoryIndex index.php index.html

    ErrorLog \${APACHE_LOG_DIR}/${domain}_error.log
    CustomLog \${APACHE_LOG_DIR}/${domain}_access.log combined

</VirtualHost>
EOF

    a2ensite "$conf_name"

    systemctl reload apache2

    success "Virtual Host creado."
    success "Dominio: ${domain}"
    success "DocumentRoot: ${document_root}"
}

# ============================================================
# NODE.JS
# ============================================================

install_node() {

    info "Instalando Node.js ${NODE_MAJOR} LTS..."

    export DEBIAN_FRONTEND=noninteractive

    apt-get update

    curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" \
        | bash -

    apt-get install -y nodejs

    node --version
    npm --version

    success "Node.js instalado."
}

# ============================================================
# OMNIROUTE USER
# ============================================================

create_omniroute_user() {

    if ! getent group "$OMNI_GROUP" >/dev/null 2>&1; then
        groupadd --system "$OMNI_GROUP"
    fi

    if ! id "$OMNI_USER" >/dev/null 2>&1; then
        useradd \
            --system \
            --gid "$OMNI_GROUP" \
            --home-dir "$OMNI_HOME" \
            --create-home \
            --shell /usr/sbin/nologin \
            "$OMNI_USER"
    fi

    mkdir -p "$OMNI_HOME"
    chown -R "$OMNI_USER:$OMNI_GROUP" "$OMNI_HOME"

    chmod 750 "$OMNI_HOME"
}

# ============================================================
# OMNIROUTE
# ============================================================

install_omniroute() {

    info "Instalando OmniRoute..."

    if ! command -v node >/dev/null 2>&1; then
        install_node
    fi

    local node_version
    node_version="$(node --version)"

    info "Node.js detectado: ${node_version}"

    npm install -g omniroute

    local omni_bin
    omni_bin="$(command -v omniroute || true)"

    if [[ -z "$omni_bin" ]]; then
        error "No se encontró el ejecutable omniroute."
        return 1
    fi

    create_omniroute_user

    cat > /etc/systemd/system/omniroute.service <<EOF
[Unit]
Description=OmniRoute AI Gateway
After=network-online.target
Wants=network-online.target

[Service]
Type=simple

User=${OMNI_USER}
Group=${OMNI_GROUP}

WorkingDirectory=${OMNI_HOME}

Environment=NODE_ENV=production
Environment=HOME=${OMNI_HOME}
Environment=HOST=0.0.0.0
Environment=PORT=${OMNI_PORT}

ExecStart=${omni_bin} serve --port ${OMNI_PORT} --no-open

Restart=always
RestartSec=5

NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable omniroute
    systemctl restart omniroute

    sleep 3

    if systemctl is-active --quiet omniroute; then
        success "OmniRoute activo."
    else
        error "OmniRoute no quedó activo."
        systemctl --no-pager --full status omniroute || true
        return 1
    fi

    success "OmniRoute escuchando en 0.0.0.0:${OMNI_PORT}"
}

# ============================================================
# ESTADO OMNIROUTE
# ============================================================

omniroute_status() {

    echo
    echo "============================================================"
    echo " ESTADO OMNIROUTE"
    echo "============================================================"
    echo

    systemctl --no-pager --full status omniroute || true

    echo
    echo "Puerto:"
    ss -lntp 2>/dev/null | grep ":${OMNI_PORT}" || true

    echo
    echo "Binario:"
    command -v omniroute || true

    echo
    echo "Node:"
    node --version 2>/dev/null || true

    echo
    echo "NPM:"
    npm --version 2>/dev/null || true
}

# ============================================================
# OLLAMA
# ============================================================

install_ollama() {

    info "Instalando Ollama..."

    if command -v ollama >/dev/null 2>&1; then
        success "Ollama ya está instalado."
    else
        curl -fsSL https://ollama.com/install.sh | sh
    fi

    systemctl enable ollama

    mkdir -p /etc/systemd/system/ollama.service.d

    cat > /etc/systemd/system/ollama.service.d/override.conf <<EOF
[Service]
Environment="OLLAMA_HOST=${OLLAMA_HOST_DEFAULT}:${OLLAMA_PORT}"
Environment="OLLAMA_KEEP_ALIVE=${OLLAMA_KEEP_ALIVE}"
Environment="OLLAMA_CONTEXT_LENGTH=${OLLAMA_CONTEXT_LENGTH}"
EOF

    systemctl daemon-reload
    systemctl restart ollama

    sleep 3

    if systemctl is-active --quiet ollama; then
        success "Ollama activo."
    else
        error "Ollama no quedó activo."
        systemctl --no-pager --full status ollama || true
        return 1
    fi

    echo
    ollama --version || true
    echo

    success "Ollama configurado en ${OLLAMA_HOST_DEFAULT}:${OLLAMA_PORT}"
}

# ============================================================
# ESTADO OLLAMA
# ============================================================

ollama_status() {

    echo
    echo "============================================================"
    echo " ESTADO OLLAMA"
    echo "============================================================"
    echo

    systemctl --no-pager --full status ollama || true

    echo
    echo "Puerto:"
    ss -lntp 2>/dev/null | grep ":${OLLAMA_PORT}" || true

    echo
    echo "Versión:"
    ollama --version 2>/dev/null || true

    echo
    echo "Modelos:"
    ollama list 2>/dev/null || true
}

# ============================================================
# DESCARGAR MODELO
# ============================================================

download_ollama_model() {

    local model=""

    echo
    echo "============================================================"
    echo " DESCARGAR MODELO OLLAMA"
    echo "============================================================"
    echo
    echo "Ejemplos:"
    echo "  qwen3:8b"
    echo "  qwen3:14b"
    echo "  qwen3:30b"
    echo "  qwen3-coder:30b"
    echo "  deepseek-coder:33b"
    echo

    read_input "Modelo: " model

    if [[ -z "$model" ]]; then
        error "Debes indicar un modelo."
        return 1
    fi

    ollama pull "$model"

    success "Modelo descargado: $model"
}

# ============================================================
# LLMS / LLMFIT
# ============================================================

install_llmfit() {

    info "Instalando llmfit..."

    if command -v llmfit >/dev/null 2>&1; then
        success "llmfit ya está instalado."
        llmfit --version || true
        return 0
    fi

    curl -fsSL https://llmfit.axjns.dev/install.sh | sh

    if command -v llmfit >/dev/null 2>&1; then
        success "llmfit instalado."
    else
        if [[ -x "$HOME/.local/bin/llmfit" ]]; then
            ln -sf "$HOME/.local/bin/llmfit" /usr/local/bin/llmfit
        fi
    fi

    if command -v llmfit >/dev/null 2>&1; then
        llmfit --version || true
        success "llmfit disponible."
    else
        error "No se pudo localizar llmfit después de la instalación."
        return 1
    fi
}

# ============================================================
# HARDWARE LLMFIT
# ============================================================

llmfit_hardware() {

    install_llmfit

    echo
    echo "============================================================"
    echo " HARDWARE LLMFIT"
    echo "============================================================"
    echo

    llmfit hardware
}

# ============================================================
# RECOMENDACIONES LLMFIT
# ============================================================

llmfit_recommendations() {

    install_llmfit

    echo
    echo "============================================================"
    echo " RECOMENDACIONES LLMFIT"
    echo "============================================================"
    echo

    llmfit recommend
}

# ============================================================
# CODING LLMFIT
# ============================================================

llmfit_coding() {

    install_llmfit

    echo
    echo "============================================================"
    echo " MODELOS CODING LLMFIT"
    echo "============================================================"
    echo

    llmfit recommend --coding
}

# ============================================================
# BENCHMARK LLMFIT
# ============================================================

llmfit_benchmark() {

    install_llmfit

    echo
    echo "============================================================"
    echo " BENCHMARK LLMFIT"
    echo "============================================================"
    echo

    llmfit benchmark
}

# ============================================================
# FIREWALL
# ============================================================

configure_firewall() {

    info "Configurando UFW..."

    apt-get install -y ufw

    ufw --force reset

    ufw default deny incoming
    ufw default allow outgoing

    # SSH
    ufw allow 22/tcp

    # HTTP / HTTPS
    ufw allow 80/tcp
    ufw allow 443/tcp

    # OmniRoute solamente desde LAN 192.168.1.0/24
    ufw allow from 192.168.1.0/24 to any port "${OMNI_PORT}" proto tcp

    # Ollama permanece en localhost por defecto.
    # No se abre 11434 externamente.

    ufw --force enable

    success "Firewall UFW configurado."

    ufw status verbose
}

# ============================================================
# SWAP
# ============================================================

configure_swap() {

    local swap_size="16G"

    echo
    echo "============================================================"
    echo " CONFIGURACIÓN SWAP"
    echo "============================================================"
    echo

    if swapon --show --noheadings | grep -q .; then
        warning "Ya existe una partición/archivo swap."
        swapon --show
        return 0
    fi

    read_input "Tamaño de swap [16G]: " swap_size

    if [[ -z "$swap_size" ]]; then
        swap_size="16G"
    fi

    info "Creando swap de ${swap_size}..."

    fallocate -l "$swap_size" /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile

    if ! grep -q '^/swapfile ' /etc/fstab; then
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi

    success "Swap configurada."

    swapon --show
}

# ============================================================
# OPTIMIZACIÓN
# ============================================================

optimize_system() {

    info "Aplicando optimización del sistema..."

    cat > /etc/sysctl.d/99-ia-server.conf <<'EOF'
vm.swappiness=10
vm.vfs_cache_pressure=50
fs.inotify.max_user_watches=524288
fs.inotify.max_user_instances=1024
net.core.somaxconn=65535
net.ipv4.tcp_fin_timeout=15
net.ipv4.tcp_keepalive_time=600
EOF

    sysctl --system >/dev/null

    mkdir -p /etc/systemd/journald.conf.d

    cat > /etc/systemd/journald.conf.d/ia-server.conf <<'EOF'
[Journal]
SystemMaxUse=1G
RuntimeMaxUse=256M
MaxRetentionSec=14day
EOF

    systemctl restart systemd-journald

    success "Optimización aplicada."
}

# ============================================================
# ESTADO SERVICIOS
# ============================================================

service_status() {

    echo
    echo "============================================================"
    echo " ESTADO DE SERVICIOS"
    echo "============================================================"
    echo

    local services=(
        ssh
        apache2
        mysql
        "php${PHP_VERSION}-fpm"
        omniroute
        ollama
    )

    local service

    for service in "${services[@]}"; do

        if systemctl list-unit-files "${service}.service" \
            --no-legend 2>/dev/null | grep -q "${service}.service"; then

            if systemctl is-active --quiet "$service"; then
                printf "${GREEN}%-25s ACTIVO${NC}\n" "$service"
            else
                printf "${RED}%-25s DETENIDO${NC}\n" "$service"
            fi

        else
            printf "${GRAY}%-25s NO INSTALADO${NC}\n" "$service"
        fi

    done

    echo
}

# ============================================================
# DIAGNÓSTICO
# ============================================================

diagnostics() {

    echo
    echo "============================================================"
    echo " DIAGNÓSTICO IA-SERVER"
    echo "============================================================"
    echo

    echo "Hostname:"
    hostname

    echo
    echo "Sistema:"
    cat /etc/os-release | grep -E '^(PRETTY_NAME|VERSION_ID)='

    echo
    echo "Kernel:"
    uname -a

    echo
    echo "CPU:"
    lscpu | grep -E 'Model name|CPU\(s\)|Thread|Core|Socket' || true

    echo
    echo "RAM:"
    free -h

    echo
    echo "Disco:"
    df -h /

    echo
    echo "IP:"
    get_lan_ip

    echo
    echo "Puertos:"
    ss -lntp 2>/dev/null | grep -E ':(22|80|443|3306|20128|11434)\b' || true

    echo
    echo "Servicios:"
    service_status

    echo
    echo "Firewall:"
    ufw status verbose || true

    echo
    echo "Ollama:"
    ollama list 2>/dev/null || true

    echo
    echo "OmniRoute:"
    systemctl is-active omniroute 2>/dev/null || true
}

# ============================================================
# INFORMACIÓN SERVIDOR
# ============================================================

server_information() {

    local ip
    ip="$(get_lan_ip)"

    echo
    echo "============================================================"
    echo " INFORMACIÓN DEL SERVIDOR"
    echo "============================================================"
    echo

    echo "Nombre:"
    echo "  $(hostname)"

    echo
    echo "IP LAN:"
    echo "  ${ip}"

    echo
    echo "Sistema:"
    echo "  Ubuntu Server 24.04 LTS"

    echo
    echo "Kernel:"
    echo "  $(uname -r)"

    echo
    echo "CPU:"
    lscpu | grep 'Model name' | head -1 | sed 's/^[[:space:]]*//'

    echo
    echo "CPU lógicas:"
    nproc

    echo
    echo "RAM:"
    free -h | awk '/Mem:/ {print $2}'

    echo
    echo "Disco raíz:"
    df -h / | awk 'NR==2 {print $2 " total / " $4 " disponible"}'

    echo
    echo "PHP:"
    php -v 2>/dev/null | head -1 || true

    echo
    echo "Node:"
    node --version 2>/dev/null || true

    echo
    echo "MySQL:"
    mysql --version 2>/dev/null || true

    echo
    echo "Ollama:"
    ollama --version 2>/dev/null || true

    echo
    echo "OmniRoute:"
    omniroute --version 2>/dev/null || true

    echo
    echo "llmfit:"
    llmfit --version 2>/dev/null || true

    echo
    echo "Endpoints:"
    echo "  OmniRoute : http://${ip}:${OMNI_PORT}"
    echo "  Ollama    : http://${OLLAMA_HOST_DEFAULT}:${OLLAMA_PORT}"
    echo "  Apache    : http://${ip}/"
    echo "  phpMyAdmin: http://${ip}/phpmyadmin"
}

# ============================================================
# IP LAN
# ============================================================

get_lan_ip() {

    local ip=""

    ip="$(hostname -I 2>/dev/null | awk '{print $1}')"

    if [[ -z "$ip" ]]; then
        ip="$(ip -4 route get 1.1.1.1 2>/dev/null \
            | awk '/src/ {for(i=1;i<=NF;i++) if($i=="src") print $(i+1); exit}')"
    fi

    if [[ -z "$ip" ]]; then
        ip="N/D"
    fi

    echo "$ip"
}

# ============================================================
# ACTUALIZACIÓN COMPLETA
# ============================================================

full_install() {

    echo
    echo "============================================================"
    echo " INSTALACIÓN COMPLETA IA-SERVER"
    echo "============================================================"
    echo

    if ! confirm "¿Iniciar instalación completa?"; then
        warning "Instalación cancelada."
        return 0
    fi

    log "INICIO INSTALACION COMPLETA"

    prepare_directories

    install_base_packages

    configure_system_identity

    apt_upgrade

    install_apache

    install_php_versions

    install_mysql

    install_phpmyadmin

    install_node

    install_omniroute

    install_ollama

    install_llmfit

    configure_firewall

    optimize_system

    systemctl daemon-reload

    echo
    echo "============================================================"
    echo " INSTALACIÓN COMPLETADA"
    echo "============================================================"
    echo

    success "IA-SERVER fue instalado correctamente."

    server_information

    echo
    echo "IMPORTANTE:"
    echo
    echo "OmniRoute:"
    echo "  http://$(get_lan_ip):${OMNI_PORT}"
    echo
    echo "Ollama:"
    echo "  http://${OLLAMA_HOST_DEFAULT}:${OLLAMA_PORT}"
    echo
    echo "phpMyAdmin:"
    echo "  http://$(get_lan_ip)/phpmyadmin"
    echo

    log "FIN INSTALACION COMPLETA"

    pause_screen
}

# ============================================================
# HEADER
# ============================================================

show_header() {

    clear 2>/dev/null || true

    echo
    echo -e "${CYAN}======================================================================${NC}"
    echo -e "${WHITE}                           IA-SERVER${NC}"
    echo -e "${CYAN}======================================================================${NC}"
    echo
    echo -e "${WHITE}PCCURICO SPA${NC}"
    echo
    echo "Ubuntu Server 24.04 LTS"
    echo "LAMP + OmniRoute + Ollama + llmfit"
    echo
    echo -e "${GRAY}Versión instalador: ${SCRIPT_VERSION}${NC}"
    echo
}

# ============================================================
# MENÚ PRINCIPAL
# ============================================================

main_menu() {

    local option=""

    while true; do

        show_header

        local ip
        ip="$(get_lan_ip)"

        echo "Servidor : $(hostname)"
        echo "IP LAN   : ${ip}"
        echo

        printf '%*s\n' 72 '' | tr ' ' '-'

        echo
        echo "  1) Instalación completa"
        echo
        echo "  2) Preparación del servidor"
        echo "  3) Apache2"
        echo "  4) PHP 8.3"
        echo "  5) MySQL"
        echo "  6) Crear BD + usuario MySQL"
        echo "  7) phpMyAdmin"
        echo "  8) Crear Virtual Host"
        echo
        echo "  9) Node.js"
        echo " 10) OmniRoute"
        echo " 11) Estado OmniRoute"
        echo " 12) Ollama"
        echo " 13) Estado Ollama"
        echo " 14) Descargar modelo Ollama"
        echo
        echo " 15) llmfit"
        echo " 16) Hardware llmfit"
        echo " 17) Recomendaciones llmfit"
        echo " 18) Modelos coding llmfit"
        echo " 19) Benchmark llmfit"
        echo
        echo " 20) Firewall LAN"
        echo " 21) Swap"
        echo " 22) Optimización sistema"
        echo " 23) Estado servicios"
        echo " 24) Diagnóstico"
        echo " 25) Información del servidor"
        echo
        echo "  0) Salir"
        echo

        # ====================================================
        # IMPORTANTE:
        # Se lee desde /dev/tty mediante FD 3.
        #
        # Esto permite:
        #
        # curl URL | sudo bash
        #
        # sin que read reciba EOF del pipe.
        # ====================================================

        if ! read -r -u "$TTY_FD" -p "Selecciona una opción: " option; then
            echo
            warning "No se pudo leer la entrada de la terminal."
            warning "El instalador requiere una terminal interactiva."
            return 1
        fi

        case "$option" in

            1)
                full_install
                ;;

            2)
                install_base_packages
                configure_system_identity
                pause_screen
                ;;

            3)
                install_apache
                pause_screen
                ;;

            4)
                install_php_versions
                pause_screen
                ;;

            5)
                install_mysql
                pause_screen
                ;;

            6)
                create_mysql_database
                pause_screen
                ;;

            7)
                install_phpmyadmin
                pause_screen
                ;;

            8)
                create_virtual_host
                pause_screen
                ;;

            9)
                install_node
                pause_screen
                ;;

            10)
                install_omniroute
                pause_screen
                ;;

            11)
                omniroute_status
                pause_screen
                ;;

            12)
                install_ollama
                pause_screen
                ;;

            13)
                ollama_status
                pause_screen
                ;;

            14)
                download_ollama_model
                pause_screen
                ;;

            15)
                install_llmfit
                pause_screen
                ;;

            16)
                llmfit_hardware
                pause_screen
                ;;

            17)
                llmfit_recommendations
                pause_screen
                ;;

            18)
                llmfit_coding
                pause_screen
                ;;

            19)
                llmfit_benchmark
                pause_screen
                ;;

            20)
                configure_firewall
                pause_screen
                ;;

            21)
                configure_swap
                pause_screen
                ;;

            22)
                optimize_system
                pause_screen
                ;;

            23)
                service_status
                pause_screen
                ;;

            24)
                diagnostics
                pause_screen
                ;;

            25)
                server_information
                pause_screen
                ;;

            0)
                echo
                success "IA-SERVER finalizado."
                exit 0
                ;;

            *)
                warning "Opción no válida: ${option}"
                sleep 1
                ;;

        esac

    done
}

# ============================================================
# INSTALACIÓN NO INTERACTIVA
# ============================================================

noninteractive_install() {

    echo
    echo "============================================================"
    echo " INSTALACIÓN AUTOMÁTICA IA-SERVER"
    echo "============================================================"
    echo

    prepare_directories
    install_base_packages
    configure_system_identity
    apt_upgrade
    install_apache
    install_php_versions
    install_mysql
    install_phpmyadmin
    install_node
    install_omniroute
    install_ollama
    install_llmfit
    configure_firewall
    optimize_system

    echo
    success "Instalación automática completada."

    server_information
}

# ============================================================
# AYUDA
# ============================================================

show_help() {

    cat <<EOF

IA-SERVER
PCCURICO SPA

Uso:

  sudo bash ${SCRIPT_NAME}

  curl -fsSL https://raw.githubusercontent.com/pccurico/install/refs/heads/master/ia-server_lamp_ollama.sh | sudo bash

Instalación automática:

  sudo bash ${SCRIPT_NAME} --install

Opciones:

  --install       Instalación completa sin menú
  --menu          Abrir menú interactivo
  --help          Mostrar esta ayuda
  --version       Mostrar versión

Componentes:

  Apache2
  PHP ${PHP_VERSION}
  PHP-FPM
  MySQL
  phpMyAdmin
  Node.js ${NODE_MAJOR}
  OmniRoute
  Ollama
  llmfit
  UFW
  SSH

Puertos:

  22      SSH
  80      HTTP
  443     HTTPS
  ${OMNI_PORT}    OmniRoute LAN
  ${OLLAMA_PORT}  Ollama localhost

EOF
}

# ============================================================
# VERSIÓN
# ============================================================

show_version() {
    echo "${SCRIPT_NAME} ${SCRIPT_VERSION}"
}

# ============================================================
# INICIO
# ============================================================

main() {

    require_root
    prepare_logging
    setup_terminal
    check_os

    log "============================================================"
    log "INICIO IA-SERVER"
    log "Hostname: $(hostname)"
    log "IP LAN: $(get_lan_ip)"
    log "Script: ${SCRIPT_VERSION}"
    log "============================================================"

    case "${1:-}" in

        --install)
            noninteractive_install
            ;;

        --menu)
            main_menu
            ;;

        --help|-h)
            show_help
            ;;

        --version|-v)
            show_version
            ;;

        "")
            main_menu
            ;;

        *)
            error "Opción desconocida: $1"
            show_help
            exit 1
            ;;

    esac
}

main "$@"
