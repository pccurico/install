#!/usr/bin/env bash

# ============================================================
# PCCURICO HOSTING
# Instalador / Preparador del servidor de hosting
#
# Compatible con:
# Ubuntu Server 24.04.x
#
# IMPORTANTE:
# Este instalador está diseñado para servidores que YA tienen
# servicios instalados.
#
# NO elimina:
#   Apache
#   PHP
#   MySQL
#   Node.js
#   Ollama
#   Cloudflare Tunnel
#   Fail2ban
#   n8n
#   Open WebUI
#   OmniRoute
#   Samba
#   dnsmasq
#   XRDP
#   VirtualHosts existentes
#   Bases de datos existentes
#
# VERSION: 3.0.0
# ============================================================

set -Eeuo pipefail

SCRIPT_NAME="pccurico_hosting_install.sh"
VERSION="3.0.0"

# ------------------------------------------------------------
# RUTAS PCCURICO
# ------------------------------------------------------------

PCCURICO_ETC="/etc/pccurico"
PCCURICO_STATE_DIR="/var/lib/pccurico-hosting"
PCCURICO_LOG_DIR="/var/log/pccurico"
PCCURICO_BACKUP_DIR="/var/backups/pccurico-hosting"

STATE_FILE="${PCCURICO_STATE_DIR}/state"
LOG_FILE="${PCCURICO_LOG_DIR}/hosting_install.log"
LOCK_FILE="/run/pccurico-hosting-install.lock"

# ------------------------------------------------------------
# VARIABLES
# ------------------------------------------------------------

MYSQL_CLIENT=""
MYSQL_SERVICE=""
PHP_VERSION=""
PHP_FPM_SERVICE=""

DB_HOST=""
DB_NAME=""
DB_USER=""
DB_PASSWORD=""

MYSQL_ROOT_PASSWORD=""

ERROR_LINE=""
ERROR_COMMAND=""

# ------------------------------------------------------------
# COLORES
# ------------------------------------------------------------

if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    WHITE='\033[1;37m'
    RESET='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    CYAN=''
    WHITE=''
    RESET=''
fi

# ------------------------------------------------------------
# FUNCIONES DE SALIDA
# ------------------------------------------------------------

print_line() {
    printf '%s\n' "============================================================"
}

title() {
    printf '\n'
    print_line
    printf '%b%s%b\n' "$CYAN" "$1" "$RESET"
    print_line
}

info() {
    printf '%b[INFO]%b %s\n' "$BLUE" "$RESET" "$1"
}

ok() {
    printf '%b[OK]%b %s\n' "$GREEN" "$RESET" "$1"
}

warn() {
    printf '%b[WARN]%b %s\n' "$YELLOW" "$RESET" "$1"
}

error() {
    printf '%b[ERROR]%b %s\n' "$RED" "$RESET" "$1"
}

die() {
    error "$1"
    exit 1
}

# ------------------------------------------------------------
# LOG SEGURO
# ------------------------------------------------------------

log_safe() {
    local message="$*"
    local root_password="${MYSQL_ROOT_PASSWORD:-}"
    local db_password="${DB_PASSWORD:-}"

    if [[ -n "$root_password" ]]; then
        message="${message//$root_password/[REDACTED]}"
    fi

    if [[ -n "$db_password" ]]; then
        message="${message//$db_password/[REDACTED]}"
    fi

    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$message" >> "$LOG_FILE"
}

# ------------------------------------------------------------
# LIMPIEZA
# ------------------------------------------------------------

cleanup() {
    MYSQL_ROOT_PASSWORD=""
    DB_PASSWORD=""

    rm -f "$LOCK_FILE" 2>/dev/null || true
}

trap cleanup EXIT

# ------------------------------------------------------------
# ERRORES
# ------------------------------------------------------------

on_error() {
    ERROR_LINE="${1:-unknown}"
    ERROR_COMMAND="${2:-unknown}"

    error "Se produjo un error en línea ${ERROR_LINE}."
    error "Comando: ${ERROR_COMMAND}"

    log_safe "ERROR línea=${ERROR_LINE} comando=${ERROR_COMMAND}"

    printf '\n'
    warn "No se eliminará ni revertirá información existente."
    warn "El estado conseguido hasta este punto permanece intacto."
}

trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

# ------------------------------------------------------------
# ROOT
# ------------------------------------------------------------

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        die "Este instalador debe ejecutarse como root."
    fi
}

# ------------------------------------------------------------
# LOCK
# ------------------------------------------------------------

acquire_lock() {

    if [[ -f "$LOCK_FILE" ]]; then

        local old_pid=""

        old_pid="$(cat "$LOCK_FILE" 2>/dev/null || true)"

        if [[ "$old_pid" =~ ^[0-9]+$ ]]; then
            if kill -0 "$old_pid" 2>/dev/null; then
                die "Ya existe otra instalación ejecutándose. PID: $old_pid"
            fi
        fi

        rm -f "$LOCK_FILE"
    fi

    printf '%s\n' "$$" > "$LOCK_FILE"
}

# ------------------------------------------------------------
# DIRECTORIOS
# ------------------------------------------------------------

prepare_directories() {

    mkdir -p "$PCCURICO_ETC"
    mkdir -p "$PCCURICO_STATE_DIR"
    mkdir -p "$PCCURICO_LOG_DIR"
    mkdir -p "$PCCURICO_BACKUP_DIR"

    chmod 700 "$PCCURICO_ETC"
    chmod 750 "$PCCURICO_STATE_DIR"
    chmod 750 "$PCCURICO_LOG_DIR"
    chmod 700 "$PCCURICO_BACKUP_DIR"

    touch "$LOG_FILE"

    chmod 600 "$LOG_FILE"
}

# ------------------------------------------------------------
# ESTADO
# ------------------------------------------------------------

is_done() {
    local stage="$1"

    [[ -f "$STATE_FILE" ]] || return 1

    grep -Fxq -- "$stage" "$STATE_FILE"
}

mark_done() {

    local stage="$1"

    touch "$STATE_FILE"

    if ! grep -Fxq -- "$stage" "$STATE_FILE" 2>/dev/null; then
        printf '%s\n' "$stage" >> "$STATE_FILE"
    fi
}

# ------------------------------------------------------------
# SISTEMA OPERATIVO
# ------------------------------------------------------------

check_os() {

    title "1. COMPROBACIÓN DEL SISTEMA"

    if [[ ! -f /etc/os-release ]]; then
        die "No se pudo determinar el sistema operativo."
    fi

    . /etc/os-release

    printf 'Sistema       : %s\n' "${PRETTY_NAME:-desconocido}"
    printf 'Arquitectura  : %s\n' "$(uname -m)"
    printf 'Kernel        : %s\n' "$(uname -r)"

    if [[ "${ID:-}" != "ubuntu" ]]; then
        die "Este instalador requiere Ubuntu."
    fi

    if [[ "${VERSION_ID:-}" != "24.04" ]]; then
        warn "La versión detectada es ${VERSION_ID:-desconocida}."
        warn "El instalador fue diseñado para Ubuntu 24.04.x."
    else
        ok "Ubuntu 24.04.x detectado."
    fi

    local available_gb

    available_gb="$(
        df -BG / |
        awk 'NR==2 {gsub(/G/,"",$4); print $4}'
    )"

    if [[ "$available_gb" =~ ^[0-9]+$ ]]; then
        printf 'Espacio disponible: %s GB\n' "$available_gb"

        if (( available_gb < 10 )); then
            warn "Hay menos de 10 GB disponibles."
        else
            ok "Espacio disponible suficiente."
        fi
    fi

    mark_done "1-system"
}

# ------------------------------------------------------------
# APACHE
# ------------------------------------------------------------

detect_apache() {

    command -v apache2 >/dev/null 2>&1
}

step_apache() {

    title "2. APACHE"

    if ! detect_apache; then

        warn "Apache no está instalado."

        info "Instalando Apache..."

        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y apache2

    else
        ok "Apache ya está instalado."
    fi

    if ! systemctl is-active --quiet apache2; then

        info "Apache no está activo. Iniciándolo..."

        systemctl start apache2

    else
        ok "Apache está activo."
    fi

    systemctl enable apache2 >/dev/null 2>&1 || true

    if apache2ctl configtest >/dev/null 2>&1; then
        ok "Configuración Apache válida."
    else
        die "La configuración actual de Apache contiene errores."
    fi

    info "VirtualHosts existentes detectados:"

    apache2ctl -S 2>&1 || true

    ok "Los VirtualHosts existentes NO serán modificados."

    mark_done "2-apache"
}

# ------------------------------------------------------------
# PHP
# ------------------------------------------------------------

detect_php() {

    command -v php >/dev/null 2>&1
}

detect_php_version() {

    if detect_php; then
        PHP_VERSION="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || true)"
    fi
}

step_php() {

    title "3. PHP"

    if ! detect_php; then

        warn "PHP no está instalado."

        apt-get update

        DEBIAN_FRONTEND=noninteractive apt-get install -y \
            php \
            php-cli \
            php-fpm \
            php-mysql \
            php-curl \
            php-gd \
            php-mbstring \
            php-xml \
            php-zip \
            php-bcmath \
            php-intl \
            php-soap \
            php-opcache

    else
        ok "PHP ya está instalado."
    fi

    detect_php_version

    printf 'PHP detectado: %s\n' "${PHP_VERSION:-desconocido}"

    if [[ -n "$PHP_VERSION" ]]; then

        if [[ "$PHP_VERSION" == "8.3" ]]; then
            ok "PHP 8.3 detectado."
        else
            warn "PHP detectado: $PHP_VERSION"
        fi

    fi

    local fpm_candidate=""

    for candidate in \
        php8.3-fpm \
        php8.2-fpm \
        php8.1-fpm
    do
        if systemctl cat "$candidate.service" >/dev/null 2>&1; then
            fpm_candidate="$candidate"
            break
        fi
    done

    if [[ -n "$fpm_candidate" ]]; then

        PHP_FPM_SERVICE="$fpm_candidate"

        if systemctl is-active --quiet "$PHP_FPM_SERVICE"; then
            ok "PHP-FPM activo: $PHP_FPM_SERVICE"
        else
            info "Iniciando $PHP_FPM_SERVICE..."
            systemctl start "$PHP_FPM_SERVICE"
        fi

        systemctl enable "$PHP_FPM_SERVICE" >/dev/null 2>&1 || true

    else
        warn "No se encontró un servicio PHP-FPM."
    fi

    required_extensions=(
        mysqli
        pdo_mysql
        curl
        gd
        mbstring
        intl
        xml
        zip
        bcmath
        soap
        opcache
    )

    for extension in "${required_extensions[@]}"; do

        if php -m 2>/dev/null | grep -Fxqi "$extension"; then
            ok "PHP extension: $extension"
        else
            warn "Falta extensión PHP: $extension"
        fi

    done

    mark_done "3-php"
}

# ------------------------------------------------------------
# MYSQL
# ------------------------------------------------------------

detect_mysql() {

    MYSQL_CLIENT=""

    for candidate in \
        /usr/bin/mysql \
        /usr/local/bin/mysql \
        /usr/bin/mariadb \
        /usr/local/bin/mariadb
    do
        if [[ -x "$candidate" ]]; then
            MYSQL_CLIENT="$candidate"
            break
        fi
    done

    [[ -n "$MYSQL_CLIENT" ]]
}

detect_mysql_service() {

    MYSQL_SERVICE=""

    for service in mysql mariadb mysqld; do

        if systemctl cat "$service.service" >/dev/null 2>&1; then
            MYSQL_SERVICE="$service"
            return 0
        fi

    done

    return 1
}

step_mysql() {

    title "4. MYSQL"

    if ! detect_mysql; then

        warn "No se encontró cliente MySQL/MariaDB."

        info "Instalando MySQL..."

        apt-get update

        DEBIAN_FRONTEND=noninteractive apt-get install -y \
            mysql-server \
            mysql-client

    else
        ok "Cliente MySQL existente: $MYSQL_CLIENT"
    fi

    detect_mysql

    if ! detect_mysql; then
        die "No fue posible detectar el cliente MySQL después de la comprobación."
    fi

    detect_mysql_service || true

    if [[ -n "$MYSQL_SERVICE" ]]; then

        printf 'Servicio MySQL: %s\n' "$MYSQL_SERVICE"

        if systemctl is-active --quiet "$MYSQL_SERVICE"; then
            ok "MySQL está activo."
        else
            warn "MySQL está instalado pero detenido."
            info "Iniciando MySQL..."
            systemctl start "$MYSQL_SERVICE"
        fi

        systemctl enable "$MYSQL_SERVICE" >/dev/null 2>&1 || true

    else
        warn "No se identificó el servicio systemd de MySQL."
    fi

    "$MYSQL_CLIENT" --version 2>&1 || true

    if [[ -S /run/mysqld/mysqld.sock ]]; then
        ok "Socket MySQL detectado."
    fi

    if [[ -d /var/lib/mysql ]]; then
        ok "Directorio de datos MySQL existente."
    fi

    if ss -lnt 2>/dev/null | grep -Eq '(^|[[:space:]])0\.0\.0\.0:3306[[:space:]]'; then
        warn "MySQL está escuchando en 0.0.0.0:3306."
        warn "El instalador NO modificará bind-address automáticamente."
    fi

    ok "No se modificarán usuarios ni contraseñas MySQL."

    mark_done "4-mysql"
}

# ------------------------------------------------------------
# CONFIGURACIÓN BASE DE PCCURICO
# ------------------------------------------------------------

step_pccurico_config() {

    title "5. CONFIGURACIÓN PCCURICO"

    mkdir -p "$PCCURICO_ETC"
    chmod 700 "$PCCURICO_ETC"

    if [[ -f "$PCCURICO_ETC/database.conf" ]]; then

        ok "Existe configuración de base de datos PCCURICO."

        DB_HOST="$(grep -E '^DB_HOST=' "$PCCURICO_ETC/database.conf" |
            head -n 1 |
            cut -d '=' -f2- || true)"

        DB_NAME="$(grep -E '^DB_NAME=' "$PCCURICO_ETC/database.conf" |
            head -n 1 |
            cut -d '=' -f2- || true)"

        DB_USER="$(grep -E '^DB_USER=' "$PCCURICO_ETC/database.conf" |
            head -n 1 |
            cut -d '=' -f2- || true)"

        if [[ -n "$DB_HOST" && -n "$DB_NAME" && -n "$DB_USER" ]]; then
            ok "Configuración existente válida estructuralmente."
            printf 'DB_HOST : %s\n' "$DB_HOST"
            printf 'DB_NAME : %s\n' "$DB_NAME"
            printf 'DB_USER : %s\n' "$DB_USER"
        else
            warn "database.conf existe pero está incompleto."
        fi

    else

        warn "No existe database.conf."

        info "No se creará automáticamente una nueva base de datos."
        info "La configuración de aplicación se realizará cuando se instale el panel."

    fi

    mark_done "5-pccurico-config"
}

# ------------------------------------------------------------
# COMPOSER
# ------------------------------------------------------------

step_composer() {

    title "6. COMPOSER"

    if command -v composer >/dev/null 2>&1; then

        ok "Composer ya está disponible."

        composer --version 2>&1 || true

        mark_done "6-composer"
        return

    fi

    local composer_path="/usr/local/bin/composer"

    if [[ -x "$composer_path" ]]; then

        ok "Composer encontrado en $composer_path."

        if ! command -v composer >/dev/null 2>&1; then
            ln -sf "$composer_path" /usr/bin/composer
        fi

        mark_done "6-composer"
        return

    fi

    info "Composer no está instalado."
    info "Instalando Composer oficial..."

    local installer
    installer="$(mktemp)"

    curl -fsSL https://getcomposer.org/installer -o "$installer"

    if ! php "$installer" --install-dir=/usr/local/bin --filename=composer; then
        rm -f "$installer"
        die "No fue posible instalar Composer."
    fi

    rm -f "$installer"

    chmod 755 /usr/local/bin/composer

    if command -v composer >/dev/null 2>&1; then
        ok "Composer instalado correctamente."
        composer --version 2>&1 || true
    else
        die "Composer fue instalado pero no está disponible en PATH."
    fi

    mark_done "6-composer"
}

# ------------------------------------------------------------
# HERRAMIENTAS
# ------------------------------------------------------------

step_tools() {

    title "7. HERRAMIENTAS DEL HOSTING"

    local packages=(
        curl
        wget
        git
        unzip
        zip
        rsync
        acl
        openssl
        jq
        ca-certificates
        lsof
        tree
        cron
    )

    info "Comprobando herramientas necesarias..."

    apt-get update

    DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"

    ok "Herramientas base disponibles."

    mark_done "7-tools"
}

# ------------------------------------------------------------
# NODE
# ------------------------------------------------------------

step_node() {

    title "8. NODE.JS"

    if command -v node >/dev/null 2>&1; then

        ok "Node.js ya está instalado."

        printf 'Node.js: '
        node --version

    else

        warn "Node.js no está instalado."

        apt-get update

        DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs npm

    fi

    if command -v npm >/dev/null 2>&1; then
        printf 'npm: '
        npm --version
    fi

    mark_done "8-node"
}

# ------------------------------------------------------------
# SEGURIDAD
# ------------------------------------------------------------

step_security() {

    title "9. SEGURIDAD"

    if command -v fail2ban-client >/dev/null 2>&1; then

        ok "Fail2ban ya está instalado."

        if systemctl is-active --quiet fail2ban; then
            ok "Fail2ban está activo."
        else
            warn "Fail2ban está instalado pero detenido."
            systemctl start fail2ban
        fi

        systemctl enable fail2ban >/dev/null 2>&1 || true

    else

        info "Fail2ban no está instalado."

        apt-get update

        DEBIAN_FRONTEND=noninteractive apt-get install -y fail2ban

        systemctl enable --now fail2ban

    fi

    if command -v ufw >/dev/null 2>&1; then

        if ufw status 2>/dev/null | grep -qi "inactive"; then
            warn "UFW está instalado pero INACTIVO."
            warn "No será activado automáticamente."
        else
            ok "UFW está activo."
        fi

    fi

    mark_done "9-security"
}

# ------------------------------------------------------------
# CLOUDFLARE
# ------------------------------------------------------------

step_cloudflare() {

    title "10. CLOUDFLARE TUNNEL"

    if command -v cloudflared >/dev/null 2>&1; then

        ok "cloudflared ya está instalado."

        cloudflared --version 2>&1 || true

        if systemctl cat cloudflared.service >/dev/null 2>&1; then

            if systemctl is-active --quiet cloudflared; then
                ok "Cloudflare Tunnel está activo."
            else
                warn "Cloudflare Tunnel está instalado pero detenido."
            fi

        fi

        if [[ -f /etc/cloudflared/config.yml ]]; then
            ok "Existe /etc/cloudflared/config.yml."
        fi

    else

        warn "cloudflared no está instalado."
        warn "No se instalará automáticamente en esta etapa."

    fi

    ok "La configuración existente de Cloudflare NO será modificada."

    mark_done "10-cloudflare"
}

# ------------------------------------------------------------
# SERVICIOS EXISTENTES
# ------------------------------------------------------------

step_existing_services() {

    title "11. SERVICIOS EXISTENTES"

    local services=(
        n8n
        open-webui
        omniroute
        samba
        smbd
        nmbd
        dnsmasq
        xrdp
        xrdp-sesman
        ollama
    )

    for service in "${services[@]}"; do

        if systemctl cat "$service.service" >/dev/null 2>&1; then

            if systemctl is-active --quiet "$service"; then
                ok "$service está activo."
            else
                info "$service existe pero no está activo."
            fi

        fi

    done

    info "Estos servicios pertenecen al servidor existente."
    info "El instalador PCCURICO no los modifica."

    mark_done "11-existing-services"
}

# ------------------------------------------------------------
# ESTRUCTURA PCCURICO
# ------------------------------------------------------------

step_structure() {

    title "12. ESTRUCTURA PCCURICO HOSTING"

    mkdir -p "$PCCURICO_ETC"
    mkdir -p "$PCCURICO_STATE_DIR"
    mkdir -p "$PCCURICO_LOG_DIR"
    mkdir -p "$PCCURICO_BACKUP_DIR"

    chmod 700 "$PCCURICO_ETC"
    chmod 750 "$PCCURICO_STATE_DIR"
    chmod 750 "$PCCURICO_LOG_DIR"
    chmod 700 "$PCCURICO_BACKUP_DIR"

    # No se crea todavía un VirtualHost.
    # No se crea todavía un dominio.
    # No se modifica /var/www existente.

    local structure_file="${PCCURICO_ETC}/server.conf"

    if [[ ! -f "$structure_file" ]]; then

        cat > "$structure_file" <<EOF
# ============================================================
# PCCURICO HOSTING
# CONFIGURACION DEL SERVIDOR
# ============================================================

PCCURICO_HOSTNAME=$(hostname)
PCCURICO_WEB_ROOT=/var/www
PCCURICO_ETC=/etc/pccurico
PCCURICO_STATE=/var/lib/pccurico-hosting
PCCURICO_LOG=/var/log/pccurico

APACHE_CONFIG=/etc/apache2
PHP_VERSION=${PHP_VERSION:-}
PHP_FPM_SERVICE=${PHP_FPM_SERVICE:-}

MYSQL_SERVICE=${MYSQL_SERVICE:-}
MYSQL_CLIENT=${MYSQL_CLIENT:-}

CLOUDFLARED_CONFIG=/etc/cloudflared/config.yml

OLLAMA_URL=http://127.0.0.1:11434
EOF

        chmod 600 "$structure_file"

        ok "Configuración base creada:"
        printf '  %s\n' "$structure_file"

    else

        ok "Configuración base ya existe."

    fi

    mark_done "12-structure"
}

# ------------------------------------------------------------
# BACKUP CONFIGURACIÓN APACHE
# ------------------------------------------------------------

step_backup() {

    title "13. RESPALDO DE CONFIGURACIÓN"

    local timestamp
    timestamp="$(date '+%Y%m%d_%H%M%S')"

    local backup_path="${PCCURICO_BACKUP_DIR}/${timestamp}"

    mkdir -p "$backup_path"

    if [[ -d /etc/apache2 ]]; then
        cp -a /etc/apache2 "$backup_path/apache2"
        ok "Respaldo Apache creado."
    fi

    if [[ -d /etc/php ]]; then
        cp -a /etc/php "$backup_path/php"
        ok "Respaldo PHP creado."
    fi

    if [[ -d /etc/pccurico ]]; then
        cp -a "$PCCURICO_ETC" "$backup_path/pccurico"
        ok "Respaldo PCCURICO creado."
    fi

    if [[ -d /etc/cloudflared ]]; then
        cp -a /etc/cloudflared "$backup_path/cloudflared"
        ok "Respaldo Cloudflare creado."
    fi

    chmod -R go-rwx "$backup_path"

    printf 'Backup: %s\n' "$backup_path"

    mark_done "13-backup"
}

# ------------------------------------------------------------
# VALIDACIÓN FINAL
# ------------------------------------------------------------

step_final() {

    title "14. VALIDACIÓN FINAL"

    local failures=0

    # Apache
    if systemctl is-active --quiet apache2; then
        ok "Apache: ACTIVO"
    else
        error "Apache: NO ACTIVO"
        failures=$((failures + 1))
    fi

    # PHP
    if command -v php >/dev/null 2>&1; then
        ok "PHP: $(php -r 'echo PHP_VERSION;')"
    else
        error "PHP: NO DISPONIBLE"
        failures=$((failures + 1))
    fi

    # PHP-FPM
    if [[ -n "$PHP_FPM_SERVICE" ]]; then
        if systemctl is-active --quiet "$PHP_FPM_SERVICE"; then
            ok "PHP-FPM: ACTIVO"
        else
            error "PHP-FPM: NO ACTIVO"
            failures=$((failures + 1))
        fi
    fi

    # MySQL
    if detect_mysql; then
        ok "MySQL: CLIENTE DISPONIBLE"
    else
        error "MySQL: CLIENTE NO DISPONIBLE"
        failures=$((failures + 1))
    fi

    if [[ -n "$MYSQL_SERVICE" ]]; then
        if systemctl is-active --quiet "$MYSQL_SERVICE"; then
            ok "MySQL: SERVICIO ACTIVO"
        else
            error "MySQL: SERVICIO NO ACTIVO"
            failures=$((failures + 1))
        fi
    fi

    # Node
    if command -v node >/dev/null 2>&1; then
        ok "Node.js: $(node --version)"
    else
        error "Node.js: NO DISPONIBLE"
        failures=$((failures + 1))
    fi

    # Composer
    if command -v composer >/dev/null 2>&1; then
        ok "Composer: DISPONIBLE"
    else
        error "Composer: NO DISPONIBLE"
        failures=$((failures + 1))
    fi

    # Ollama
    if systemctl is-active --quiet ollama 2>/dev/null; then
        ok "Ollama: ACTIVO"
    else
        warn "Ollama: no se validó como activo."
    fi

    # Cloudflare
    if systemctl is-active --quiet cloudflared 2>/dev/null; then
        ok "Cloudflare Tunnel: ACTIVO"
    else
        warn "Cloudflare Tunnel: no se validó como activo."
    fi

    # Fail2ban
    if systemctl is-active --quiet fail2ban 2>/dev/null; then
        ok "Fail2ban: ACTIVO"
    else
        warn "Fail2ban: no se validó como activo."
    fi

    # Apache config
    if apache2ctl configtest >/dev/null 2>&1; then
        ok "Apache configtest: OK"
    else
        error "Apache configtest: ERROR"
        failures=$((failures + 1))
    fi

    if (( failures > 0 )); then
        die "La validación final encontró ${failures} problemas."
    fi

    mark_done "14-final"
}

# ------------------------------------------------------------
# ESTADO
# ------------------------------------------------------------

show_status() {

    title "ESTADO PCCURICO HOSTING"

    printf 'Versión instalador : %s\n' "$VERSION"
    printf 'Servidor           : %s\n' "$(hostname)"
    printf 'Estado              : %s\n' "$STATE_FILE"

    printf '\n'

    if [[ -f "$STATE_FILE" ]]; then
        cat "$STATE_FILE"
    else
        printf 'No existe estado.\n'
    fi

    printf '\n'

    if [[ -f "$PCCURICO_ETC/database.conf" ]]; then
        ok "database.conf existe."
    else
        warn "database.conf no existe."
    fi

    if [[ -f "$PCCURICO_ETC/server.conf" ]]; then
        ok "server.conf existe."
    else
        warn "server.conf no existe."
    fi

    if command -v composer >/dev/null 2>&1; then
        ok "Composer disponible."
    else
        warn "Composer no disponible."
    fi
}

# ------------------------------------------------------------
# DIAGNÓSTICO MYSQL
# ------------------------------------------------------------

mysql_status() {

    title "DIAGNÓSTICO MYSQL"

    if ! detect_mysql; then
        error "No se encontró MySQL."
        return 0
    fi

    printf 'Cliente: %s\n' "$MYSQL_CLIENT"

    "$MYSQL_CLIENT" --version

    detect_mysql_service || true

    printf 'Servicio: %s\n' "${MYSQL_SERVICE:-NO DETECTADO}"

    if [[ -n "$MYSQL_SERVICE" ]]; then
        systemctl status "$MYSQL_SERVICE" --no-pager -l || true
    fi

    printf '\nSockets:\n'
    find /run /var/run -type s 2>/dev/null |
        grep -Ei 'mysql|mariadb' || true

    printf '\nPuertos:\n'
    ss -lntp 2>/dev/null |
        grep -E ':3306|:33060' || true
}

# ------------------------------------------------------------
# LOG
# ------------------------------------------------------------

show_log() {

    if [[ -f "$LOG_FILE" ]]; then
        cat "$LOG_FILE"
    else
        warn "No existe todavía el log."
    fi
}

# ------------------------------------------------------------
# INSTALACIÓN COMPLETA
# ------------------------------------------------------------

install_all() {

    title "PCCURICO HOSTING ${VERSION}"

    printf 'Servidor: %s\n' "$(hostname)"
    printf 'Fecha   : %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"

    printf '\n'
    info "Modo: instalación detectiva y no destructiva."
    info "Se conservarán los servicios existentes."
    info "No se recrearán bases de datos existentes."

    check_os

    step_apache
    step_php
    step_mysql
    step_pccurico_config
    step_composer
    step_tools
    step_node
    step_security
    step_cloudflare
    step_existing_services
    step_structure
    step_backup
    step_final

    printf '\n'
    print_line
    printf '%bINSTALACIÓN PCCURICO HOSTING FINALIZADA%b\n' "$GREEN" "$RESET"
    print_line

    printf '\n'
    ok "Servidor preparado."

    printf '\n'
    printf 'Configuración PCCURICO:\n'
    printf '  %s\n' "$PCCURICO_ETC"

    printf '\n'
    printf 'Estado:\n'
    printf '  %s\n' "$STATE_FILE"

    printf '\n'
    printf 'Log:\n'
    printf '  %s\n' "$LOG_FILE"

    printf '\n'
    printf 'Backups:\n'
    printf '  %s\n' "$PCCURICO_BACKUP_DIR"

    printf '\n'
    info "No se modificaron los VirtualHosts existentes."
    info "No se modificaron las bases de datos existentes."
    info "No se modificó la configuración de Cloudflare."
    info "No se modificó Ollama."
}

# ------------------------------------------------------------
# USO
# ------------------------------------------------------------

usage() {

    cat <<EOF

PCCURICO HOSTING
Instalador detectivo y no destructivo

Uso:

  curl -fsSL https://raw.githubusercontent.com/pccurico/install/refs/heads/master/pccurico_hosting_install.sh | sudo bash

Opciones:

  --install       Ejecutar instalación completa
  --status        Mostrar estado
  --mysql         Diagnóstico MySQL
  --log           Mostrar log
  --version       Mostrar versión
  --help          Mostrar ayuda

El instalador detecta automáticamente los servicios existentes.

EOF
}

# ------------------------------------------------------------
# MAIN
# ------------------------------------------------------------

main() {

    require_root
    prepare_directories
    acquire_lock

    log_safe "Inicio instalador ${VERSION}"

    case "${1:-}" in

        "")
            install_all
            ;;

        --install)
            install_all
            ;;

        --status)
            show_status
            ;;

        --mysql)
            mysql_status
            ;;

        --log)
            show_log
            ;;

        --version)
            printf '%s %s\n' "$SCRIPT_NAME" "$VERSION"
            ;;

        --help|-h)
            usage
            ;;

        *)
            error "Opción desconocida: $1"
            usage
            exit 1
            ;;

    esac

    log_safe "Fin instalador ${VERSION}"
}

main "$@"
