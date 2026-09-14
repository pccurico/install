#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

# ============================================================
# IA-SERVER
# Instalador y administrador para Ubuntu Server 24.04 LTS
#
# PCCURICO SPA
# www.pccurico.cl
#
# Componentes:
#   - Paquetes base
#   - OpenSSH
#   - Apache2
#   - PHP 8.2 / 8.3 / 8.4
#   - PHP-FPM
#   - MySQL
#   - phpMyAdmin
#   - Node.js
#   - OmniRoute
#   - Ollama
#   - llmfit
#   - Firewall LAN
#
# Uso:
#   sudo bash ia-server_lamp_ollama.sh
#
# Instalación remota:
#   curl -fsSL https://raw.githubusercontent.com/pccurico/install/main/ia-server_lamp_ollama.sh | sudo bash
# ============================================================

readonly APP_NAME="IA-SERVER"
readonly APP_VENDOR="PCCURICO SPA"

readonly LOG_DIR="/var/log/ia-server"
readonly LOG_FILE="${LOG_DIR}/install.log"
readonly BACKUP_DIR="/var/backups/ia-server"

readonly OMNIROUTE_PORT="20128"
readonly OLLAMA_PORT="11434"
readonly LLMFIT_PORT="8787"

readonly NODE_MAJOR="22"

readonly PHP_VERSIONS=("8.2" "8.3" "8.4")
readonly DEFAULT_PHP="8.4"

readonly OLLAMA_INSTALL_URL="https://ollama.com/install.sh"
readonly LLMFIT_INSTALL_URL="https://llmfit.axjns.dev/install.sh"

# ------------------------------------------------------------
# Colores
# ------------------------------------------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

# ------------------------------------------------------------
# Inicialización
# ------------------------------------------------------------

mkdir -p "$LOG_DIR"
mkdir -p "$BACKUP_DIR"

touch "$LOG_FILE"

exec > >(tee -a "$LOG_FILE") 2>&1

# ------------------------------------------------------------
# Manejo de errores
# ------------------------------------------------------------

on_error() {
    local exit_code=$?
    local line="${BASH_LINENO[0]:-unknown}"

    echo
    echo -e "${RED}============================================================${NC}"
    echo -e "${RED}ERROR EN IA-SERVER${NC}"
    echo -e "${RED}Línea: ${line}${NC}"
    echo -e "${RED}Código: ${exit_code}${NC}"
    echo -e "${RED}Log: ${LOG_FILE}${NC}"
    echo -e "${RED}============================================================${NC}"
    echo

    exit "$exit_code"
}

trap on_error ERR

# ------------------------------------------------------------
# Utilidades
# ------------------------------------------------------------

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
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
    echo -e "${RED}[ERROR]${NC} $*"
    log "[ERROR] $*"
}

die() {
    error "$*"
    exit 1
}

separator() {
    echo
    printf '%*s\n' 72 '' | tr ' ' '='
    echo
}

pause_menu() {
    echo
    read -r -p "Presiona ENTER para continuar..." _
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

service_exists() {
    systemctl list-unit-files "$1.service" >/dev/null 2>&1
}

is_service_active() {
    systemctl is-active --quiet "$1" 2>/dev/null
}

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        die "Ejecuta el instalador como root: sudo bash $0"
    fi
}

check_os() {

    [[ -f /etc/os-release ]] || die "No se encontró /etc/os-release."

    # shellcheck disable=SC1091
    source /etc/os-release

    if [[ "${ID}" != "ubuntu" ]]; then
        die "Este instalador requiere Ubuntu."
    fi

    if [[ "${VERSION_ID:-}" != "24.04" ]]; then
        warning "Sistema detectado: ${PRETTY_NAME}"
        warning "La plataforma objetivo es Ubuntu Server 24.04 LTS."
        echo

        read -r -p "¿Continuar de todas formas? [s/N]: " answer

        if [[ "${answer,,}" != "s" ]]; then
            exit 0
        fi
    fi
}

get_lan_ip() {

    local ip

    ip="$(ip route get 1.1.1.1 2>/dev/null \
        | awk '/src/ {for(i=1;i<=NF;i++) if($i=="src") print $(i+1); exit}')"

    if [[ -z "$ip" ]]; then
        ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    fi

    echo "${ip:-127.0.0.1}"
}

get_lan_cidr() {

    local ip="$1"

    ip -o -f inet addr show 2>/dev/null \
        | awk -v ip="$ip" '$4 ~ "^" ip "/" {print $4; exit}'
}

get_default_interface() {

    ip route get 1.1.1.1 2>/dev/null \
        | awk '/dev/ {for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}'
}

get_memory_mb() {

    awk '/MemTotal/ {printf "%d\n", $2/1024}' /proc/meminfo
}

get_cpu_count() {

    nproc
}

get_disk_free_gb() {

    df -BG / | awk 'NR==2 {gsub("G","",$4); print $4}'
}

backup_file() {

    local file="$1"

    [[ -e "$file" ]] || return 0

    local timestamp
    timestamp="$(date '+%Y%m%d-%H%M%S')"

    local destination
    destination="${BACKUP_DIR}/$(basename "$file").${timestamp}.bak"

    cp -a "$file" "$destination"

    info "Backup creado: $destination"
}

apt_install() {

    DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
}

apt_update() {

    apt-get update
}

enable_service() {

    local service="$1"

    systemctl enable "$service" >/dev/null 2>&1 || true
}

restart_service() {

    local service="$1"

    systemctl daemon-reload
    systemctl restart "$service"
}

# ------------------------------------------------------------
# Encabezado
# ------------------------------------------------------------

show_header() {

    clear

    echo -e "${CYAN}"
    cat <<'EOF'
██╗ █████╗       ███████╗███████╗██████╗ ██╗   ██╗███████╗██████╗
██║██╔══██╗      ██╔════╝██╔════╝██╔══██╗██║   ██║██╔════╝██╔══██╗
██║███████║█████╗███████╗█████╗  ██████╔╝██║   ██║█████╗  ██████╔╝
██║██╔══██║╚════╝╚════██║██╔══╝  ██╔═══╝ ██║   ██║██╔══╝  ██╔══██╗
██║██║  ██║      ███████║███████╗██║     ╚██████╔╝███████╗██║  ██║
╚═╝╚═╝  ╚═╝      ╚══════╝╚══════╝╚═╝      ╚═════╝ ╚══════╝╚═╝  ╚═╝
EOF
    echo -e "${NC}"

    echo
    echo -e "${WHITE}${APP_NAME}${NC}"
    echo "${APP_VENDOR}"
    echo "Ubuntu Server 24.04 LTS"
    echo
}

# ------------------------------------------------------------
# Información
# ------------------------------------------------------------

show_system_info() {

    separator

    echo -e "${WHITE}INFORMACIÓN DEL SERVIDOR${NC}"
    echo

    echo "Hostname:"
    hostname

    echo
    echo "IP LAN:"
    get_lan_ip

    echo
    echo "Interfaz:"
    get_default_interface

    echo
    echo "Red:"
    get_lan_cidr "$(get_lan_ip)" || true

    echo
    echo "CPU:"
    echo "$(get_cpu_count) CPUs"

    echo
    echo "RAM:"
    free -h

    echo
    echo "Disco:"
    df -h /

    echo
    echo "Kernel:"
    uname -r

    pause_menu
}

# ============================================================
# 1. PREPARACIÓN
# ============================================================

install_base_packages() {

    separator

    echo -e "${WHITE}PREPARACIÓN DEL SERVIDOR${NC}"
    echo

    info "Actualizando índices APT..."

    apt_update

    info "Instalando paquetes base..."

    apt_install \
        apt-transport-https \
        ca-certificates \
        curl \
        wget \
        gnupg \
        lsb-release \
        software-properties-common \
        unzip \
        zip \
        git \
        jq \
        vim \
        nano \
        htop \
        tree \
        rsync \
        net-tools \
        dnsutils \
        lsof \
        procps \
        openssl \
        ufw \
        build-essential \
        python3 \
        python3-pip \
        python3-venv

    success "Paquetes base instalados."

    configure_timezone

    configure_ssh

    pause_menu
}

configure_timezone() {

    echo
    echo "Zona horaria actual:"
    timedatectl show --property=Timezone --value 2>/dev/null || true

    echo

    read -r -p "¿Configurar zona horaria America/Santiago? [S/n]: " answer

    if [[ "${answer,,}" != "n" ]]; then

        timedatectl set-timezone America/Santiago

        success "Zona horaria configurada: America/Santiago."

    fi
}

configure_ssh() {

    if ! command_exists sshd; then

        info "Instalando OpenSSH Server..."

        apt_install openssh-server

    fi

    systemctl enable --now ssh

    success "OpenSSH Server activo."
}

# ============================================================
# 2. APACHE
# ============================================================

install_apache() {

    separator

    echo -e "${WHITE}APACHE2${NC}"
    echo

    apt_update

    apt_install apache2

    a2enmod rewrite
    a2enmod headers
    a2enmod expires
    a2enmod proxy
    a2enmod proxy_fcgi
    a2enmod setenvif
    a2enmod ssl

    systemctl enable --now apache2

    if apache2ctl configtest; then
        success "Apache configurado correctamente."
    else
        die "La configuración de Apache contiene errores."
    fi

    pause_menu
}

# ============================================================
# 3. PHP
# ============================================================

install_php_versions() {

    separator

    echo -e "${WHITE}PHP 8.2 / 8.3 / 8.4${NC}"
    echo

    info "Agregando repositorio PHP..."

    apt_install software-properties-common ca-certificates lsb-release apt-transport-https

    if ! grep -Rqs "ondrej/php" /etc/apt/sources.list.d/ 2>/dev/null; then

        add-apt-repository -y ppa:ondrej/php

    fi

    apt_update

    local version

    for version in "${PHP_VERSIONS[@]}"; do

        info "Instalando PHP ${version}..."

        apt_install \
            "php${version}" \
            "php${version}-cli" \
            "php${version}-common" \
            "php${version}-fpm" \
            "php${version}-mysql" \
            "php${version}-curl" \
            "php${version}-mbstring" \
            "php${version}-xml" \
            "php${version}-zip" \
            "php${version}-gd" \
            "php${version}-intl" \
            "php${version}-bcmath" \
            "php${version}-soap" \
            "php${version}-readline" \
            "php${version}-opcache"

        systemctl enable --now "php${version}-fpm"

    done

    configure_default_php

    pause_menu
}

configure_default_php() {

    if command_exists update-alternatives; then

        local php_binary="/usr/bin/php${DEFAULT_PHP}"

        if [[ -x "$php_binary" ]]; then

            update-alternatives --install \
                /usr/bin/php php "$php_binary" 84

            update-alternatives --set php "$php_binary" || true

            success "PHP ${DEFAULT_PHP} seleccionado como versión CLI."

        fi

    fi

    if [[ -x "/etc/apache2/mods-enabled/proxy_fcgi.load" ]]; then
        :
    fi
}

show_php_versions() {

    separator

    echo -e "${WHITE}VERSIONES PHP INSTALADAS${NC}"
    echo

    php -v | head -n 1

    echo

    local version

    for version in "${PHP_VERSIONS[@]}"; do

        if command_exists "php${version}"; then
            echo "PHP ${version}:"
            "php${version}" -v | head -n 1

            if systemctl is-active --quiet "php${version}-fpm"; then
                echo "  FPM: ACTIVO"
            else
                echo "  FPM: INACTIVO"
            fi

            echo
        fi

    done

    pause_menu
}

# ============================================================
# 4. MYSQL
# ============================================================

install_mysql() {

    separator

    echo -e "${WHITE}MYSQL${NC}"
    echo

    apt_update

    apt_install mysql-server mysql-client

    systemctl enable --now mysql

    if systemctl is-active --quiet mysql; then
        success "MySQL activo."
    else
        die "MySQL no pudo iniciar."
    fi

    echo
    echo "Ejecutando comprobación de seguridad básica..."

    mysql --protocol=socket -e "SELECT VERSION();" || true

    pause_menu
}

create_mysql_database_user() {

    separator

    echo -e "${WHITE}CREAR BASE DE DATOS Y USUARIO MYSQL${NC}"
    echo

    command_exists mysql || {
        error "MySQL no está instalado."
        pause_menu
        return
    }

    read -r -p "Nombre de base de datos: " db_name
    read -r -p "Nombre de usuario MySQL: " db_user

    [[ -n "$db_name" ]] || {
        error "La base de datos no puede estar vacía."
        pause_menu
        return
    }

    [[ -n "$db_user" ]] || {
        error "El usuario no puede estar vacío."
        pause_menu
        return
    }

    read -r -s -p "Contraseña para ${db_user}: " db_password
    echo

    read -r -s -p "Confirmar contraseña: " db_password_confirm
    echo

    if [[ "$db_password" != "$db_password_confirm" ]]; then
        error "Las contraseñas no coinciden."
        pause_menu
        return
    fi

    if [[ -z "$db_password" ]]; then
        error "La contraseña no puede estar vacía."
        pause_menu
        return
    fi

    info "Creando base de datos y usuario..."

    mysql --protocol=socket <<SQL
CREATE DATABASE IF NOT EXISTS \`${db_name}\`
CHARACTER SET utf8mb4
COLLATE utf8mb4_unicode_ci;

CREATE USER IF NOT EXISTS '${db_user}'@'localhost'
IDENTIFIED BY '${db_password}';

ALTER USER '${db_user}'@'localhost'
IDENTIFIED BY '${db_password}';

GRANT ALL PRIVILEGES ON \`${db_name}\`.*
TO '${db_user}'@'localhost';

FLUSH PRIVILEGES;
SQL

    unset db_password
    unset db_password_confirm

    success "Base de datos y usuario creados."

    pause_menu
}

# ============================================================
# 5. PHPMYADMIN
# ============================================================

install_phpmyadmin() {

    separator

    echo -e "${WHITE}PHPMYADMIN${NC}"
    echo

    if dpkg -l phpmyadmin >/dev/null 2>&1; then

        success "phpMyAdmin ya está instalado."

    else

        info "Instalando phpMyAdmin..."

        echo
        warning "Si aparece el instalador interactivo:"
        echo "  - Servidor web: Apache2"
        echo "  - Configuración automática de base de datos: Sí"
        echo

        apt_install phpmyadmin

    fi

    if [[ ! -e /etc/apache2/conf-enabled/phpmyadmin.conf ]]; then

        if [[ -f /etc/phpmyadmin/apache.conf ]]; then

            ln -sf /etc/phpmyadmin/apache.conf \
                /etc/apache2/conf-available/phpmyadmin.conf

            a2enconf phpmyadmin

        fi

    fi

    systemctl reload apache2

    success "phpMyAdmin configurado."

    echo
    echo "Acceso:"
    echo "http://$(get_lan_ip)/phpmyadmin"

    pause_menu
}

# ============================================================
# 6. APACHE VIRTUAL HOST
# ============================================================

create_vhost() {

    separator

    echo -e "${WHITE}CREAR VIRTUAL HOST APACHE${NC}"
    echo

    read -r -p "Dominio: " domain

    if [[ -z "$domain" ]]; then
        error "Dominio vacío."
        pause_menu
        return
    fi

    local web_root="/var/www/${domain}"
    local config="/etc/apache2/sites-available/${domain}.conf"

    mkdir -p "$web_root"

    chown -R www-data:www-data "$web_root"

    chmod -R 755 "$web_root"

    if [[ ! -f "${web_root}/index.php" ]]; then

        cat > "${web_root}/index.php" <<'PHP'
<?php
phpinfo();
PHP

    fi

    if [[ -f "$config" ]]; then
        backup_file "$config"
    fi

    cat > "$config" <<EOF
<VirtualHost *:80>

    ServerName ${domain}

    DocumentRoot ${web_root}

    <Directory ${web_root}>
        AllowOverride All
        Options FollowSymLinks
        Require all granted
        DirectoryIndex index.php index.html
    </Directory>

    <FilesMatch \.php$>
        SetHandler "proxy:unix:/run/php/php${DEFAULT_PHP}-fpm.sock|fcgi://localhost/"
    </FilesMatch>

    ErrorLog \${APACHE_LOG_DIR}/${domain}-error.log
    CustomLog \${APACHE_LOG_DIR}/${domain}-access.log combined

</VirtualHost>
EOF

    a2ensite "${domain}.conf"

    a2dissite 000-default.conf >/dev/null 2>&1 || true

    apache2ctl configtest

    systemctl reload apache2

    success "Virtual Host creado."

    echo
    echo "URL:"
    echo "http://${domain}"
    echo
    echo "Directorio:"
    echo "$web_root"
    echo
    echo "IP del servidor:"
    echo "$(get_lan_ip)"
    echo

    warning "Los demás equipos necesitarán DNS o una entrada en hosts."

    pause_menu
}

# ============================================================
# 7. NODE.JS
# ============================================================

install_nodejs() {

    separator

    echo -e "${WHITE}NODE.JS${NC}"
    echo

    apt_install ca-certificates curl gnupg

    local keyring="/etc/apt/keyrings/nodesource.gpg"

    mkdir -p /etc/apt/keyrings

    if [[ ! -f "$keyring" ]]; then

        curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
            | gpg --dearmor -o "$keyring"

    fi

    cat > /etc/apt/sources.list.d/nodesource.list <<EOF
deb [signed-by=${keyring}] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main
EOF

    apt_update

    apt_install nodejs

    echo
    node --version
    npm --version

    success "Node.js instalado."

    pause_menu
}

# ============================================================
# 8. OMNIROUTE
# ============================================================

install_omniroute() {

    separator

    echo -e "${WHITE}OMNIROUTE${NC}"
    echo

    if ! command_exists node; then
        install_nodejs >/dev/null
    fi

    if ! command_exists npm; then
        die "npm no está disponible."
    fi

    info "Instalando/actualizando OmniRoute..."

    npm install -g omniroute

    if ! command_exists omniroute; then
        die "OmniRoute no quedó disponible en PATH."
    fi

    success "OmniRoute instalado."

    echo
    echo "Versión:"
    omniroute --version 2>/dev/null || true

    configure_omniroute_service

    pause_menu
}

configure_omniroute_service() {

    local omni_bin

    omni_bin="$(command -v omniroute)"

    [[ -n "$omni_bin" ]] || die "No se encontró el binario OmniRoute."

    local service="/etc/systemd/system/omniroute.service"

    if [[ -f "$service" ]]; then
        backup_file "$service"
    fi

    cat > "$service" <<EOF
[Unit]
Description=OmniRoute AI Gateway
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Group=root

Environment=NODE_ENV=production
Environment=HOST=0.0.0.0
Environment=PORT=${OMNIROUTE_PORT}

ExecStart=${omni_bin} serve --port ${OMNIROUTE_PORT} --no-open

Restart=on-failure
RestartSec=5

LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable omniroute

    if systemctl restart omniroute; then

        sleep 3

        if is_service_active omniroute; then
            success "OmniRoute activo en puerto ${OMNIROUTE_PORT}."
        else
            warning "OmniRoute no está activo."
            systemctl status omniroute --no-pager -l || true
        fi

    else

        warning "No se pudo iniciar OmniRoute automáticamente."

    fi
}

show_omniroute_status() {

    separator

    echo -e "${WHITE}OMNIROUTE${NC}"
    echo

    if command_exists omniroute; then
        echo "Versión:"
        omniroute --version 2>/dev/null || true
    fi

    echo
    systemctl status omniroute --no-pager -l 2>/dev/null || true

    echo
    echo "Endpoints:"
    echo
    echo "Dashboard:"
    echo "http://$(get_lan_ip):${OMNIROUTE_PORT}"
    echo
    echo "OpenAI API:"
    echo "http://$(get_lan_ip):${OMNIROUTE_PORT}/v1"
    echo

    echo "Modelos:"
    curl -fsS --max-time 10 \
        "http://127.0.0.1:${OMNIROUTE_PORT}/v1/models" \
        | jq . 2>/dev/null || true

    pause_menu
}

# ============================================================
# 9. OLLAMA
# ============================================================

install_ollama() {

    separator

    echo -e "${WHITE}OLLAMA${NC}"
    echo

    if command_exists ollama; then

        success "Ollama ya está instalado."

    else

        info "Instalando Ollama..."

        curl -fsSL "$OLLAMA_INSTALL_URL" | sh

    fi

    if ! command_exists ollama; then
        die "Ollama no quedó instalado."
    fi

    systemctl enable ollama

    configure_ollama

    success "Ollama instalado y configurado."

    echo
    ollama --version 2>/dev/null || true

    pause_menu
}

configure_ollama() {

    local override_dir="/etc/systemd/system/ollama.service.d"
    local override_file="${override_dir}/override.conf"

    mkdir -p "$override_dir"

    if [[ -f "$override_file" ]]; then
        backup_file "$override_file"
    fi

    cat > "$override_file" <<EOF
[Service]

Environment="OLLAMA_HOST=0.0.0.0:${OLLAMA_PORT}"
Environment="OLLAMA_KEEP_ALIVE=10m"
Environment="OLLAMA_CONTEXT_LENGTH=32768"
EOF

    systemctl daemon-reload
    systemctl restart ollama

    sleep 3

    if is_service_active ollama; then
        success "Ollama activo."
    else
        warning "Ollama no quedó activo."
        systemctl status ollama --no-pager -l || true
    fi
}

show_ollama_status() {

    separator

    echo -e "${WHITE}OLLAMA${NC}"
    echo

    systemctl status ollama --no-pager -l 2>/dev/null || true

    echo
    echo "API:"
    echo "http://$(get_lan_ip):${OLLAMA_PORT}"

    echo
    echo "Modelos:"
    ollama list 2>/dev/null || true

    echo
    echo "Modelos cargados:"
    ollama ps 2>/dev/null || true

    pause_menu
}

pull_ollama_model() {

    separator

    echo -e "${WHITE}DESCARGAR MODELO OLLAMA${NC}"
    echo

    read -r -p "Nombre exacto del modelo Ollama: " model

    [[ -n "$model" ]] || return

    info "Descargando ${model}..."

    ollama pull "$model"

    success "Modelo procesado."

    pause_menu
}

# ============================================================
# 10. LLMFIT
# ============================================================

install_llmfit() {

    separator

    echo -e "${WHITE}LLMFIT${NC}"
    echo

    if command_exists llmfit; then

        success "llmfit ya está instalado."

    else

        info "Instalando llmfit..."

        curl -fsSL "$LLMFIT_INSTALL_URL" | sh

    fi

    if command_exists llmfit; then
        success "llmfit disponible."
    else
        warning "llmfit no quedó disponible en PATH."
    fi

    pause_menu
}

run_llmfit_system() {

    separator

    echo -e "${WHITE}HARDWARE SEGÚN LLMFIT${NC}"
    echo

    if ! command_exists llmfit; then
        error "llmfit no está instalado."
        pause_menu
        return
    fi

    llmfit --json system | jq . 2>/dev/null || llmfit --json system

    pause_menu
}

run_llmfit_recommend() {

    separator

    echo -e "${WHITE}RECOMENDACIONES LLMFIT${NC}"
    echo

    if ! command_exists llmfit; then
        error "llmfit no está instalado."
        pause_menu
        return
    fi

    llmfit recommend --limit 10

    pause_menu
}

run_llmfit_coding() {

    separator

    echo -e "${WHITE}MODELOS PARA PROGRAMACIÓN${NC}"
    echo

    if ! command_exists llmfit; then
        error "llmfit no está instalado."
        pause_menu
        return
    fi

    llmfit recommend \
        --use-case coding \
        --limit 10

    pause_menu
}

run_llmfit_benchmark() {

    separator

    echo -e "${WHITE}BENCHMARK LLMFIT / OLLAMA${NC}"
    echo

    if ! command_exists llmfit; then
        error "llmfit no está instalado."
        pause_menu
        return
    fi

    llmfit bench --provider ollama

    pause_menu
}

# ============================================================
# 11. FIREWALL
# ============================================================

configure_firewall() {

    separator

    echo -e "${WHITE}FIREWALL LAN${NC}"
    echo

    if ! command_exists ufw; then
        apt_install ufw
    fi

    local ip
    local cidr

    ip="$(get_lan_ip)"
    cidr="$(get_lan_cidr "$ip" || true)"

    if [[ -z "$cidr" ]]; then

        warning "No se pudo detectar automáticamente la red LAN."

        read -r -p \
            "CIDR LAN, ejemplo 192.168.1.0/24: " cidr

    fi

    [[ -n "$cidr" ]] || {
        error "CIDR LAN no definido."
        pause_menu
        return
    }

    echo
    echo "Red LAN:"
    echo "$cidr"
    echo

    # SSH
    ufw allow 22/tcp

    # Web
    ufw allow 80/tcp
    ufw allow 443/tcp

    # IA solamente desde LAN
    ufw allow from "$cidr" to any port "$OMNIROUTE_PORT" proto tcp
    ufw allow from "$cidr" to any port "$OLLAMA_PORT" proto tcp

    # Dashboard llmfit solamente LAN
    ufw allow from "$cidr" to any port "$LLMFIT_PORT" proto tcp

    # Política
    ufw default deny incoming
    ufw default allow outgoing

    echo
    warning "UFW se habilitará."
    echo

    read -r -p "¿Habilitar UFW ahora? [S/n]: " answer

    if [[ "${answer,,}" != "n" ]]; then

        ufw --force enable

        success "Firewall habilitado."

    else

        warning "Reglas creadas pero UFW permanece sin activar."

    fi

    echo
    ufw status verbose

    pause_menu
}

# ============================================================
# 12. SWAP
# ============================================================

configure_swap() {

    separator

    echo -e "${WHITE}SWAP${NC}"
    echo

    if swapon --show | grep -q '^'; then

        success "El servidor ya tiene Swap."

        swapon --show

        pause_menu
        return

    fi

    local ram_mb
    ram_mb="$(get_memory_mb)"

    echo "RAM detectada: ${ram_mb} MB"
    echo

    warning "La Swap ayuda a evitar OOM, pero no sustituye RAM."
    echo

    read -r -p "Crear Swap de 16 GB? [s/N]: " answer

    if [[ "${answer,,}" != "s" ]]; then
        return
    fi

    if [[ -e /swapfile ]]; then
        warning "/swapfile ya existe."
        pause_menu
        return
    fi

    fallocate -l 16G /swapfile

    chmod 600 /swapfile

    mkswap /swapfile

    swapon /swapfile

    if ! grep -q '^/swapfile ' /etc/fstab; then
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi

    success "Swap de 16 GB configurada."

    swapon --show

    pause_menu
}

# ============================================================
# 13. OPTIMIZACIÓN SISTEMA
# ============================================================

configure_system() {

    separator

    echo -e "${WHITE}OPTIMIZACIÓN DEL SISTEMA${NC}"
    echo

    # Menor tendencia a utilizar swap antes de tiempo.
    cat > /etc/sysctl.d/99-ia-server.conf <<'EOF'
vm.swappiness=10
vm.vfs_cache_pressure=50
fs.inotify.max_user_watches=524288
fs.inotify.max_user_instances=1024
EOF

    sysctl --system >/dev/null

    success "Parámetros del sistema configurados."

    pause_menu
}

# ============================================================
# 14. ESTADO GENERAL
# ============================================================

show_services_status() {

    separator

    echo -e "${WHITE}SERVICIOS IA-SERVER${NC}"
    echo

    local services=(
        apache2
        mysql
        ollama
        omniroute
    )

    local service

    for service in "${services[@]}"; do

        printf "%-15s : " "$service"

        if is_service_active "$service"; then
            echo -e "${GREEN}ACTIVO${NC}"
        else
            echo -e "${RED}INACTIVO${NC}"
        fi

    done

    echo
    echo "Puertos:"
    echo

    ss -lntp 2>/dev/null \
        | grep -E ":(${OMNIROUTE_PORT}|${OLLAMA_PORT}|80|443)\b" \
        || true

    pause_menu
}

# ============================================================
# 15. DIAGNÓSTICO
# ============================================================

run_diagnostics() {

    separator

    echo -e "${WHITE}DIAGNÓSTICO IA-SERVER${NC}"
    echo

    echo "=== SISTEMA ==="
    hostnamectl 2>/dev/null || true

    echo
    echo "=== IP ==="
    ip -br addr

    echo
    echo "=== RUTA ==="
    ip route

    echo
    echo "=== MEMORIA ==="
    free -h

    echo
    echo "=== DISCO ==="
    df -h

    echo
    echo "=== SERVICIOS ==="

    systemctl is-active apache2 || true
    systemctl is-active mysql || true
    systemctl is-active ollama || true
    systemctl is-active omniroute || true

    echo
    echo "=== OLLAMA ==="

    curl -fsS --max-time 10 \
        "http://127.0.0.1:${OLLAMA_PORT}/api/tags" \
        | jq '.models[]?.name' 2>/dev/null \
        || true

    echo
    echo "=== OMNIROUTE ==="

    curl -fsS --max-time 10 \
        "http://127.0.0.1:${OMNIROUTE_PORT}/v1/models" \
        | jq '.data[]?.id' 2>/dev/null \
        || true

    echo
    echo "=== APACHE ==="

    apache2ctl configtest

    echo
    echo "=== MYSQL ==="

    mysql --protocol=socket -e "SELECT VERSION();" 2>/dev/null || true

    pause_menu
}

# ============================================================
# 16. INSTALACIÓN COMPLETA
# ============================================================

full_install() {

    separator

    echo -e "${WHITE}INSTALACIÓN COMPLETA IA-SERVER${NC}"
    echo

    warning "Se instalarán/configurarán los componentes principales."
    echo

    echo "Componentes:"
    echo "  - Paquetes base"
    echo "  - OpenSSH"
    echo "  - Apache2"
    echo "  - PHP 8.2"
    echo "  - PHP 8.3"
    echo "  - PHP 8.4"
    echo "  - MySQL"
    echo "  - phpMyAdmin"
    echo "  - Node.js ${NODE_MAJOR}"
    echo "  - OmniRoute"
    echo "  - Ollama"
    echo "  - llmfit"
    echo "  - configuración del sistema"
    echo

    read -r -p "¿Continuar? [s/N]: " answer

    [[ "${answer,,}" == "s" ]] || return

    install_base_packages

    install_apache

    install_php_versions

    install_mysql

    install_phpmyadmin

    install_nodejs

    install_omniroute

    install_ollama

    install_llmfit

    configure_system

    echo
    success "Instalación principal completada."

    echo
    echo "IMPORTANTE:"
    echo
    echo "OmniRoute:"
    echo "  http://$(get_lan_ip):${OMNIROUTE_PORT}"
    echo
    echo "Ollama:"
    echo "  http://$(get_lan_ip):${OLLAMA_PORT}"
    echo
    echo "phpMyAdmin:"
    echo "  http://$(get_lan_ip)/phpmyadmin"
    echo

    pause_menu
}

# ============================================================
# 17. MENÚ PRINCIPAL
# ============================================================

main_menu() {

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
        echo "  4) PHP 8.2 / 8.3 / 8.4"
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

        read -r -p "Selecciona una opción: " option

        case "$option" in

            1)
                full_install
                ;;

            2)
                install_base_packages
                ;;

            3)
                install_apache
                ;;

            4)
                install_php_versions
                ;;

            5)
                install_mysql
                ;;

            6)
                create_mysql_database_user
                ;;

            7)
                install_phpmyadmin
                ;;

            8)
                create_vhost
                ;;

            9)
                install_nodejs
                ;;

            10)
                install_omniroute
                ;;

            11)
                show_omniroute_status
                ;;

            12)
                install_ollama
                ;;

            13)
                show_ollama_status
                ;;

            14)
                pull_ollama_model
                ;;

            15)
                install_llmfit
                ;;

            16)
                run_llmfit_system
                ;;

            17)
                run_llmfit_recommend
                ;;

            18)
                run_llmfit_coding
                ;;

            19)
                run_llmfit_benchmark
                ;;

            20)
                configure_firewall
                ;;

            21)
                configure_swap
                ;;

            22)
                configure_system
                ;;

            23)
                show_services_status
                ;;

            24)
                run_diagnostics
                ;;

            25)
                show_system_info
                ;;

            0)
                echo
                success "IA-SERVER finalizado."
                exit 0
                ;;

            *)
                warning "Opción no válida."
                sleep 1
                ;;

        esac

    done
}

# ============================================================
# INICIO
# ============================================================

require_root
check_os

log "============================================================"
log "INICIO IA-SERVER"
log "Hostname: $(hostname)"
log "IP LAN: $(get_lan_ip)"
log "============================================================"

main_menu