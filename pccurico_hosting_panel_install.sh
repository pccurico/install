#!/usr/bin/env bash

# ============================================================
# PCCURICO HOSTING PANEL
# Instalador inicial del panel de administración de hosting
# Ubuntu Server 24.04+
# ============================================================

set -Eeuo pipefail

SCRIPT_NAME="pccurico_hosting_panel_install.sh"
VERSION="1.0.0"

# ------------------------------------------------------------
# Rutas
# ------------------------------------------------------------

PCCURICO_ROOT="/etc/pccurico"
PANEL_CONFIG_DIR="${PCCURICO_ROOT}/hosting-panel"

STATE_DIR="/var/lib/pccurico-hosting"
STATE_FILE="${STATE_DIR}/state"

LOG_DIR="/var/log/pccurico"
LOG_FILE="${LOG_DIR}/hosting_panel_install.log"

BACKUP_DIR="/var/backups/pccurico-hosting"

PANEL_ROOT="/var/www/pccurico-hosting-panel"
PANEL_PUBLIC="${PANEL_ROOT}/public"
PANEL_STORAGE="${PANEL_ROOT}/storage"

LOCK_FILE="/run/pccurico-hosting-panel-install.lock"

DATABASE_CONFIG="/etc/pccurico/database.conf"

PANEL_DB_NAME="pccurico_hosting"
PANEL_DB_USER="pccurico_hosting"

MYSQL_ROOT_PASSWORD=""

TMP_FILES=()

# ------------------------------------------------------------
# Colores
# ------------------------------------------------------------

RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
BLUE="\033[0;34m"
CYAN="\033[0;36m"
RESET="\033[0m"

# ------------------------------------------------------------
# Funciones de salida
# ------------------------------------------------------------

info() {
    printf "${BLUE}[INFO]${RESET} %s\n" "$*"
}

ok() {
    printf "${GREEN}[OK]${RESET} %s\n" "$*"
}

warn() {
    printf "${YELLOW}[WARN]${RESET} %s\n" "$*"
}

error() {
    printf "${RED}[ERROR]${RESET} %s\n" "$*" >&2
}

title() {
    printf "\n"
    printf "${CYAN}============================================================${RESET}\n"
    printf "${CYAN}%s${RESET}\n" "$*"
    printf "${CYAN}============================================================${RESET}\n"
}

# ------------------------------------------------------------
# Limpieza
# ------------------------------------------------------------

cleanup() {
    unset MYSQL_ROOT_PASSWORD || true

    local file
    for file in "${TMP_FILES[@]:-}"; do
        if [[ -n "${file:-}" && -f "$file" ]]; then
            rm -f "$file" || true
        fi
    done

    rm -f "$LOCK_FILE" || true
}

trap cleanup EXIT

on_error() {
    local exit_code=$?
    local line="${1:-unknown}"
    local command="${2:-unknown}"

    error "El instalador se detuvo."
    error "Línea: ${line}"
    error "Comando: ${command}"
    error "El estado anterior se conserva."
    error "Revise: ${LOG_FILE}"

    exit "$exit_code"
}

trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

# ------------------------------------------------------------
# Logging
# ------------------------------------------------------------

prepare_logging() {
    mkdir -p "$LOG_DIR"
    touch "$LOG_FILE"
    chmod 640 "$LOG_FILE"

    exec > >(tee -a "$LOG_FILE") 2>&1
}

# ------------------------------------------------------------
# Root
# ------------------------------------------------------------

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        error "Este instalador debe ejecutarse como root."
        error "Ejemplo:"
        error "curl -fsSL URL | sudo bash"
        exit 1
    fi
}

# ------------------------------------------------------------
# Lock
# ------------------------------------------------------------

acquire_lock() {
    if [[ -e "$LOCK_FILE" ]]; then
        local old_pid

        old_pid="$(cat "$LOCK_FILE" 2>/dev/null || true)"

        if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null; then
            error "Ya existe otra ejecución del instalador."
            error "PID: $old_pid"
            exit 1
        fi

        rm -f "$LOCK_FILE"
    fi

    echo "$$" > "$LOCK_FILE"
}

# ------------------------------------------------------------
# Estado
# ------------------------------------------------------------

prepare_state() {
    mkdir -p "$STATE_DIR"
    chmod 700 "$STATE_DIR"

    touch "$STATE_FILE"
    chmod 600 "$STATE_FILE"
}

state_done() {
    local key="$1"

    grep -qxF "$key" "$STATE_FILE" 2>/dev/null
}

state_mark() {
    local key="$1"

    if ! state_done "$key"; then
        printf '%s\n' "$key" >> "$STATE_FILE"
    fi
}

# ------------------------------------------------------------
# Preguntas seguras
# ------------------------------------------------------------

tty_read() {
    local prompt="$1"
    local variable="$2"
    local default_value="${3:-}"

    local value=""

    if [[ ! -r /dev/tty ]]; then
        error "No existe una terminal interactiva disponible."
        error "Ejecute el instalador directamente por SSH."
        return 1
    fi

    if [[ -n "$default_value" ]]; then
        printf "%s [%s]: " "$prompt" "$default_value" > /dev/tty
    else
        printf "%s: " "$prompt" > /dev/tty
    fi

    IFS= read -r value < /dev/tty || true

    if [[ -z "$value" && -n "$default_value" ]]; then
        value="$default_value"
    fi

    printf -v "$variable" '%s' "$value"
}

tty_read_password() {
    local prompt="$1"
    local variable="$2"

    local value=""

    if [[ ! -r /dev/tty ]]; then
        error "No existe una terminal interactiva disponible."
        return 1
    fi

    printf "%s: " "$prompt" > /dev/tty
    IFS= read -r -s value < /dev/tty || true
    printf "\n" > /dev/tty

    printf -v "$variable" '%s' "$value"
}

# ------------------------------------------------------------
# Validación identificadores MySQL
# ------------------------------------------------------------

valid_mysql_identifier() {
    local value="$1"

    [[ "$value" =~ ^[a-zA-Z0-9_]+$ ]]
}

# ------------------------------------------------------------
# Escapar contraseña SQL
# ------------------------------------------------------------

mysql_escape_string() {
    local value="$1"

    value="${value//\\/\\\\}"
    value="${value//\'/\\\'}"

    printf '%s' "$value"
}

# ------------------------------------------------------------
# Generar contraseña
# ------------------------------------------------------------

generate_password() {
    local generated=""
    local chunk=""

    while [[ "${#generated}" -lt 40 ]]; do
        chunk="$(openssl rand -base64 64 | tr -dc 'A-Za-z0-9')"
        generated="${generated}${chunk}"
    done

    printf '%s' "${generated:0:40}"
}

# ------------------------------------------------------------
# Ejecutar MySQL con contraseña temporal
# ------------------------------------------------------------

mysql_root() {
    MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql \
        --protocol=TCP \
        -h 127.0.0.1 \
        -u root \
        "$@"
}

mysql_app() {
    MYSQL_PWD="$DB_PASSWORD" mysql \
        -h "$DB_HOST" \
        -u "$DB_USER" \
        "$@"
}

# ------------------------------------------------------------
# Cargar configuración existente
# ------------------------------------------------------------

load_database_config() {

    DB_HOST=""
    DB_NAME=""
    DB_USER=""
    DB_PASSWORD=""

    if [[ ! -f "$DATABASE_CONFIG" ]]; then
        return 1
    fi

    # shellcheck disable=SC1090
    source "$DATABASE_CONFIG"

    if [[ -z "${DB_HOST:-}" ]]; then
        return 1
    fi

    if [[ -z "${DB_NAME:-}" ]]; then
        return 1
    fi

    if [[ -z "${DB_USER:-}" ]]; then
        return 1
    fi

    if [[ -z "${DB_PASSWORD:-}" ]]; then
        return 1
    fi

    return 0
}

# ------------------------------------------------------------
# Probar conexión aplicación
# ------------------------------------------------------------

test_database_config() {

    if ! load_database_config; then
        return 1
    fi

    if ! valid_mysql_identifier "$DB_NAME"; then
        return 1
    fi

    if ! valid_mysql_identifier "$DB_USER"; then
        return 1
    fi

    if mysql_app "$DB_NAME" \
        -Nse "SELECT 1;" >/dev/null 2>&1; then
        return 0
    fi

    return 1
}

# ------------------------------------------------------------
# Instalar paquetes faltantes
# ------------------------------------------------------------

APT_UPDATED=0

apt_update_once() {

    if [[ "$APT_UPDATED" -eq 1 ]]; then
        return 0
    fi

    info "Actualizando índices APT..."

    apt-get update

    APT_UPDATED=1
}

install_missing_packages() {

    local packages=("$@")
    local missing=()
    local package=""

    for package in "${packages[@]}"; do

        if ! dpkg-query \
            -W \
            -f='${Status}' \
            "$package" 2>/dev/null |
            grep -q "install ok installed"; then

            missing+=("$package")
        fi

    done

    if [[ "${#missing[@]}" -eq 0 ]]; then
        return 0
    fi

    apt_update_once

    info "Instalando paquetes faltantes: ${missing[*]}"

    DEBIAN_FRONTEND=noninteractive \
        apt-get install -y "${missing[@]}"
}

# ------------------------------------------------------------
# Sistema
# ------------------------------------------------------------

step_system() {

    title "1. SISTEMA BASE"

    local os_id=""
    local os_version=""

    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        source /etc/os-release

        os_id="${ID:-}"
        os_version="${VERSION_ID:-}"
    fi

    if [[ "$os_id" != "ubuntu" ]]; then
        error "Este instalador requiere Ubuntu."
        return 1
    fi

    if [[ "${os_version%%.*}" -lt 24 ]]; then
        error "Se requiere Ubuntu 24.04 o superior."
        return 1
    fi

    ok "Ubuntu ${os_version} detectado."

    install_missing_packages \
        curl \
        wget \
        ca-certificates \
        openssl \
        git \
        rsync \
        unzip \
        zip \
        jq \
        acl \
        apache2-utils \
        lsof \
        procps \
        sudo

    mkdir -p "$PCCURICO_ROOT"
    mkdir -p "$PANEL_CONFIG_DIR"
    mkdir -p "$BACKUP_DIR"

    chmod 700 "$PANEL_CONFIG_DIR"
    chmod 700 "$BACKUP_DIR"

    state_mark "01-system"

    ok "Sistema base preparado."
}

# ------------------------------------------------------------
# Apache
# ------------------------------------------------------------

step_apache() {

    title "2. APACHE"

    if ! command -v apache2 >/dev/null 2>&1; then
        install_missing_packages apache2
    fi

    if ! systemctl is-active --quiet apache2; then
        systemctl start apache2
    fi

    if ! systemctl is-enabled --quiet apache2 2>/dev/null; then
        systemctl enable apache2
    fi

    local modules=(
        rewrite
        headers
        expires
        proxy
        proxy_fcgi
        proxy_http
        proxy_wstunnel
        ssl
        setenvif
        socache_shmcb
    )

    local module=""
    local apache_changed=0

    for module in "${modules[@]}"; do

        if ! a2query -m "$module" >/dev/null 2>&1; then

            info "Habilitando módulo Apache: ${module}"

            a2enmod "$module"

            apache_changed=1
        fi
    done

    info "Validando configuración Apache..."

    apache2ctl configtest

    if [[ "$apache_changed" -eq 1 ]]; then
        systemctl reload apache2
    fi

    ok "Apache activo y configuración válida."

    info "Los VirtualHost existentes NO serán modificados."

    state_mark "02-apache"
}

# ------------------------------------------------------------
# PHP
# ------------------------------------------------------------

step_php() {

    title "3. PHP 8.3 + PHP-FPM"

    install_missing_packages \
        php8.3-cli \
        php8.3-fpm \
        php8.3-mysql \
        php8.3-curl \
        php8.3-mbstring \
        php8.3-xml \
        php8.3-zip \
        php8.3-gd \
        php8.3-intl \
        php8.3-bcmath \
        php8.3-opcache \
        php8.3-soap

    if ! command -v php8.3 >/dev/null 2>&1; then
        error "PHP 8.3 no está disponible."
        return 1
    fi

    local php_version

    php_version="$(php8.3 -r 'echo PHP_VERSION;')"

    info "PHP detectado: ${php_version}"

    if ! systemctl is-active --quiet php8.3-fpm; then
        systemctl start php8.3-fpm
    fi

    if ! systemctl is-enabled --quiet php8.3-fpm 2>/dev/null; then
        systemctl enable php8.3-fpm
    fi

    ok "PHP-FPM activo."

    state_mark "03-php"
}

# ------------------------------------------------------------
# MySQL
# ------------------------------------------------------------

step_mysql() {

    title "4. MYSQL"

    if ! command -v mysql >/dev/null 2>&1; then
        install_missing_packages mysql-client
    fi

    if ! systemctl list-unit-files \
        --type=service \
        2>/dev/null |
        grep -q '^mysql.service'; then

        install_missing_packages mysql-server
    fi

    if ! systemctl is-active --quiet mysql; then
        systemctl start mysql
    fi

    if ! systemctl is-enabled --quiet mysql 2>/dev/null; then
        systemctl enable mysql
    fi

    local mysql_version

    mysql_version="$(mysql --version)"

    info "$mysql_version"

    ok "MySQL activo."

    info "No se modificará bind-address ni la configuración existente de MySQL."

    state_mark "04-mysql"
}

# ------------------------------------------------------------
# Base de datos del panel
# ------------------------------------------------------------

step_panel_database() {

    title "5. BASE DE DATOS DEL PANEL"

    if test_database_config; then

        ok "Configuración PCCURICO existente válida."
        info "Base de datos: ${DB_NAME}"
        info "Usuario: ${DB_USER}"
        info "La contraseña no será mostrada."

        state_mark "05-database"

        return 0
    fi

    warn "No fue posible validar la configuración existente:"
    warn "$DATABASE_CONFIG"

    echo ""
    echo "Se necesita acceso administrativo a MySQL."
    echo "La contraseña de root NO será guardada."
    echo "La contraseña de root NO será escrita en el log."
    echo ""

    tty_read_password \
        "Contraseña root de MySQL" \
        MYSQL_ROOT_PASSWORD

    if [[ -z "$MYSQL_ROOT_PASSWORD" ]]; then
        error "No se ingresó contraseña de root."
        return 1
    fi

    if ! mysql_root -Nse "SELECT 1;" >/dev/null 2>&1; then
        error "No fue posible autenticar root de MySQL."
        unset MYSQL_ROOT_PASSWORD
        return 1
    fi

    ok "Autenticación administrativa MySQL validada."

    local db_name="$PANEL_DB_NAME"
    local db_user="$PANEL_DB_USER"
    local db_password=""

    tty_read \
        "Base de datos del Hosting Panel" \
        db_name \
        "$PANEL_DB_NAME"

    tty_read \
        "Usuario MySQL del Hosting Panel" \
        db_user \
        "$PANEL_DB_USER"

    if ! valid_mysql_identifier "$db_name"; then
        error "Nombre de base de datos inválido."
        return 1
    fi

    if ! valid_mysql_identifier "$db_user"; then
        error "Nombre de usuario MySQL inválido."
        return 1
    fi

    echo ""
    echo "Puede ingresar una contraseña para el usuario ${db_user}."
    echo "Si se deja vacía, se generará automáticamente."
    echo ""

    tty_read_password \
        "Contraseña de ${db_user}" \
        db_password

    if [[ -z "$db_password" ]]; then
        db_password="$(generate_password)"
        info "Se generó automáticamente la contraseña de aplicación."
    fi

    local sql_file

    sql_file="$(mktemp)"
    TMP_FILES+=("$sql_file")

    local escaped_password

    escaped_password="$(mysql_escape_string "$db_password")"

    cat > "$sql_file" <<SQL
CREATE DATABASE IF NOT EXISTS \`${db_name}\`
    CHARACTER SET utf8mb4
    COLLATE utf8mb4_unicode_ci;

CREATE USER IF NOT EXISTS '${db_user}'@'localhost'
    IDENTIFIED BY '${escaped_password}';

ALTER USER '${db_user}'@'localhost'
    IDENTIFIED BY '${escaped_password}';

CREATE USER IF NOT EXISTS '${db_user}'@'127.0.0.1'
    IDENTIFIED BY '${escaped_password}';

ALTER USER '${db_user}'@'127.0.0.1'
    IDENTIFIED BY '${escaped_password}';

GRANT ALL PRIVILEGES
    ON \`${db_name}\`.*
    TO '${db_user}'@'localhost';

GRANT ALL PRIVILEGES
    ON \`${db_name}\`.*
    TO '${db_user}'@'127.0.0.1';

FLUSH PRIVILEGES;
SQL

    info "Creando/verificando base de datos del panel..."

    mysql_root < "$sql_file"

    mkdir -p "$PCCURICO_ROOT"

    umask 077

    cat > "$DATABASE_CONFIG" <<EOF
DB_HOST=127.0.0.1
DB_NAME=${db_name}
DB_USER=${db_user}
DB_PASSWORD=${db_password}
EOF

    chmod 600 "$DATABASE_CONFIG"

    DB_HOST="127.0.0.1"
    DB_NAME="$db_name"
    DB_USER="$db_user"
    DB_PASSWORD="$db_password"

    unset MYSQL_ROOT_PASSWORD

    if ! mysql_app "$DB_NAME" -Nse "SELECT 1;" >/dev/null 2>&1; then
        error "La conexión del usuario de aplicación falló."
        return 1
    fi

    ok "Base de datos del panel preparada."
    ok "Configuración guardada en ${DATABASE_CONFIG}"

    unset db_password
    unset escaped_password

    state_mark "05-database"
}

# ------------------------------------------------------------
# Composer
# ------------------------------------------------------------

step_composer() {

    title "6. COMPOSER"

    if command -v composer >/dev/null 2>&1; then

        local composer_version

        composer_version="$(composer --version 2>/dev/null | head -n 1)"

        ok "Composer disponible."
        info "$composer_version"

        state_mark "06-composer"

        return 0
    fi

    info "Composer no está disponible."
    info "Instalando versión oficial..."

    local installer
    local expected_signature
    local actual_signature

    installer="$(mktemp)"
    TMP_FILES+=("$installer")

    curl -fsSL \
        https://getcomposer.org/installer \
        -o "$installer"

    expected_signature="$(
        curl -fsSL \
        https://composer.github.io/installer.sig
    )"

    actual_signature="$(
        php8.3 -r \
        "echo hash_file('sha384', '$installer');"
    )"

    if [[ "$expected_signature" != "$actual_signature" ]]; then
        error "La firma del instalador de Composer no coincide."
        return 1
    fi

    php8.3 "$installer" \
        --install-dir=/usr/local/bin \
        --filename=composer

    chmod 755 /usr/local/bin/composer

    if ! command -v composer >/dev/null 2>&1; then
        error "Composer no quedó disponible."
        return 1
    fi

    ok "Composer instalado correctamente."

    composer --version 2>/dev/null || true

    state_mark "06-composer"
}

# ------------------------------------------------------------
# Node + Git
# ------------------------------------------------------------

step_node_git() {

    title "7. NODE.JS + NPM + GIT"

    if ! command -v node >/dev/null 2>&1; then
        install_missing_packages nodejs
    fi

    if ! command -v npm >/dev/null 2>&1; then
        install_missing_packages npm
    fi

    if ! command -v git >/dev/null 2>&1; then
        install_missing_packages git
    fi

    if command -v node >/dev/null 2>&1; then
        ok "Node.js: $(node --version)"
    fi

    if command -v npm >/dev/null 2>&1; then
        ok "npm: $(npm --version)"
    fi

    if command -v git >/dev/null 2>&1; then
        ok "Git: $(git --version)"
    fi

    state_mark "07-node-git"
}

# ------------------------------------------------------------
# Seguridad
# ------------------------------------------------------------

step_security() {

    title "8. SEGURIDAD DEL SERVIDOR"

    if command -v fail2ban-client >/dev/null 2>&1; then

        if systemctl is-active --quiet fail2ban; then
            ok "Fail2ban activo."
        else
            warn "Fail2ban instalado pero detenido."
            systemctl start fail2ban
        fi

        if ! systemctl is-enabled --quiet fail2ban 2>/dev/null; then
            systemctl enable fail2ban
        fi

    else

        info "Fail2ban no está instalado."
        install_missing_packages fail2ban

        systemctl enable --now fail2ban

        ok "Fail2ban instalado y activo."
    fi

    if command -v ufw >/dev/null 2>&1; then

        if ufw status 2>/dev/null | grep -q "Status: active"; then
            info "UFW está activo."
        else
            info "UFW está instalado pero permanece inactivo."
            info "No se habilitará automáticamente para evitar perder acceso SSH."
        fi

    else
        info "UFW no está instalado."
        info "El instalador no lo habilitará automáticamente."
    fi

    if systemctl is-active --quiet ssh || \
       systemctl is-active --quiet sshd; then

        ok "SSH activo."

    else

        warn "No se detectó SSH activo."
    fi

    state_mark "08-security"
}

# ------------------------------------------------------------
# Servicios existentes
# ------------------------------------------------------------

service_status() {

    local service="$1"
    local label="$2"

    if systemctl list-unit-files \
        --type=service \
        2>/dev/null |
        grep -q "^${service}.service"; then

        if systemctl is-active --quiet "$service"; then
            ok "${label}: ACTIVO"
        else
            warn "${label}: instalado pero detenido"
        fi

    else
        info "${label}: no instalado"
    fi
}

step_existing_services() {

    title "9. SERVICIOS EXISTENTES"

    service_status cloudflared "Cloudflare Tunnel"
    service_status ollama "Ollama"
    service_status n8n "n8n"
    service_status open-webui "Open WebUI"
    service_status omniroute "OmniRoute"

    info "Los servicios existentes no serán reinstalados ni reconfigurados."

    if systemctl is-active --quiet cloudflared; then
        ok "Cloudflare Tunnel permanece operativo."
    fi

    if systemctl is-active --quiet ollama; then
        ok "Ollama permanece operativo."
    fi

    state_mark "09-services"
}

# ------------------------------------------------------------
# Estructura del panel
# ------------------------------------------------------------

step_panel_structure() {

    title "10. ESTRUCTURA PCCURICO HOSTING PANEL"

    mkdir -p "$PANEL_ROOT"
    mkdir -p "$PANEL_PUBLIC"
    mkdir -p "$PANEL_STORAGE"

    mkdir -p "${PANEL_STORAGE}/logs"
    mkdir -p "${PANEL_STORAGE}/cache"
    mkdir -p "${PANEL_STORAGE}/sessions"
    mkdir -p "${PANEL_STORAGE}/backups"
    mkdir -p "${PANEL_STORAGE}/tmp"

    mkdir -p "${STATE_DIR}/runtime"
    mkdir -p "${STATE_DIR}/backups"

    # Código legible por Apache.
    chown -R root:www-data "$PANEL_ROOT"

    find "$PANEL_ROOT" \
        -type d \
        -exec chmod 2755 {} \;

    find "$PANEL_ROOT" \
        -type f \
        -exec chmod 0644 {} \;

    # Storage escribible por Apache.
    chown -R www-data:www-data "$PANEL_STORAGE"

    find "$PANEL_STORAGE" \
        -type d \
        -exec chmod 2770 {} \;

    find "$PANEL_STORAGE" \
        -type f \
        -exec chmod 0660 {} \;

    chmod 700 "$PANEL_CONFIG_DIR"
    chmod 700 "$STATE_DIR"
    chmod 700 "$BACKUP_DIR"

    # Configuración básica del panel.
    umask 077

    cat > "${PANEL_CONFIG_DIR}/panel.conf" <<EOF
PANEL_NAME=PCCURICO Hosting Panel
PANEL_VERSION=${VERSION}
PANEL_ROOT=${PANEL_ROOT}
PANEL_PUBLIC=${PANEL_PUBLIC}
PANEL_STORAGE=${PANEL_STORAGE}
DATABASE_CONFIG=${DATABASE_CONFIG}
EOF

    chmod 600 "${PANEL_CONFIG_DIR}/panel.conf"

    ok "Estructura del panel creada."

    info "Raíz:"
    info "  ${PANEL_ROOT}"

    info "Configuración:"
    info "  ${PANEL_CONFIG_DIR}"

    info "Estado:"
    info "  ${STATE_DIR}"

    info "Backups:"
    info "  ${BACKUP_DIR}"

    state_mark "10-structure"
}

# ------------------------------------------------------------
# Validación final
# ------------------------------------------------------------

final_validation() {

    title "VALIDACIÓN FINAL"

    local failures=0

    if systemctl is-active --quiet apache2; then
        ok "Apache: ACTIVO"
    else
        error "Apache: INACTIVO"
        failures=$((failures + 1))
    fi

    if apache2ctl configtest >/dev/null 2>&1; then
        ok "Apache configtest: OK"
    else
        error "Apache configtest: ERROR"
        failures=$((failures + 1))
    fi

    if command -v php8.3 >/dev/null 2>&1; then
        ok "PHP: $(php8.3 -r 'echo PHP_VERSION;')"
    else
        error "PHP 8.3: NO DISPONIBLE"
        failures=$((failures + 1))
    fi

    if systemctl is-active --quiet php8.3-fpm; then
        ok "PHP-FPM: ACTIVO"
    else
        error "PHP-FPM: INACTIVO"
        failures=$((failures + 1))
    fi

    if command -v mysql >/dev/null 2>&1; then
        ok "MySQL: CLIENTE DISPONIBLE"
    else
        error "MySQL: CLIENTE NO DISPONIBLE"
        failures=$((failures + 1))
    fi

    if systemctl is-active --quiet mysql; then
        ok "MySQL: SERVICIO ACTIVO"
    else
        error "MySQL: SERVICIO INACTIVO"
        failures=$((failures + 1))
    fi

    if command -v composer >/dev/null 2>&1; then
        ok "Composer: DISPONIBLE"
    else
        error "Composer: NO DISPONIBLE"
        failures=$((failures + 1))
    fi

    if command -v node >/dev/null 2>&1; then
        ok "Node.js: $(node --version)"
    else
        error "Node.js: NO DISPONIBLE"
        failures=$((failures + 1))
    fi

    if command -v npm >/dev/null 2>&1; then
        ok "npm: $(npm --version)"
    else
        error "npm: NO DISPONIBLE"
        failures=$((failures + 1))
    fi

    if command -v git >/dev/null 2>&1; then
        ok "Git: DISPONIBLE"
    else
        error "Git: NO DISPONIBLE"
        failures=$((failures + 1))
    fi

    if systemctl is-active --quiet fail2ban; then
        ok "Fail2ban: ACTIVO"
    else
        warn "Fail2ban: NO ACTIVO"
    fi

    if systemctl is-active --quiet cloudflared; then
        ok "Cloudflare Tunnel: ACTIVO"
    else
        warn "Cloudflare Tunnel: NO ACTIVO"
    fi

    if systemctl is-active --quiet ollama; then
        ok "Ollama: ACTIVO"
    else
        warn "Ollama: NO ACTIVO"
    fi

    if test_database_config; then
        ok "Base de datos PCCURICO: CONEXIÓN OK"
    else
        warn "Base de datos PCCURICO: NO VALIDADA"
    fi

    if [[ -d "$PANEL_ROOT" ]]; then
        ok "PCCURICO Hosting Panel: ESTRUCTURA OK"
    else
        error "PCCURICO Hosting Panel: ESTRUCTURA FALTANTE"
        failures=$((failures + 1))
    fi

    echo ""

    if ss -lnt 2>/dev/null | grep -q ':3306 '; then
        warn "MySQL está escuchando en TCP 3306."
        warn "El instalador NO modificó esta configuración."
    fi

    if command -v ufw >/dev/null 2>&1; then
        if ufw status 2>/dev/null | grep -q "Status: inactive"; then
            info "UFW permanece inactivo. No se modificaron reglas de firewall."
        fi
    fi

    echo ""

    if [[ "$failures" -gt 0 ]]; then
        error "Validación final encontró ${failures} problema(s)."
        return 1
    fi

    ok "Todas las comprobaciones críticas están correctas."

    state_mark "final"

    return 0
}

# ------------------------------------------------------------
# Estado
# ------------------------------------------------------------

show_status() {

    title "ESTADO PCCURICO HOSTING PANEL"

    echo "Versión: ${VERSION}"
    echo "Estado: ${STATE_FILE}"
    echo "Log: ${LOG_FILE}"
    echo ""

    if [[ -f "$STATE_FILE" ]]; then

        echo "Etapas completadas:"

        while IFS= read -r line; do
            [[ -n "$line" ]] && echo "  [OK] $line"
        done < "$STATE_FILE"

    else

        echo "No existe estado de instalación."
    fi

    echo ""

    if [[ -f "$DATABASE_CONFIG" ]]; then
        ok "Existe configuración de base de datos: ${DATABASE_CONFIG}"
    else
        warn "No existe ${DATABASE_CONFIG}"
    fi

    if [[ -d "$PANEL_ROOT" ]]; then
        ok "Existe ${PANEL_ROOT}"
    else
        warn "No existe ${PANEL_ROOT}"
    fi
}

# ------------------------------------------------------------
# Diagnóstico
# ------------------------------------------------------------

show_diagnostic() {

    title "DIAGNÓSTICO PCCURICO HOSTING PANEL"

    echo "Hostname:"
    hostname

    echo ""
    echo "Sistema:"
    grep -E '^(PRETTY_NAME|VERSION_ID)=' /etc/os-release || true

    echo ""
    echo "Apache:"
    apache2 -v 2>/dev/null || true
    systemctl is-active apache2 || true

    echo ""
    echo "PHP:"
    php8.3 -v 2>/dev/null | head -n 2 || true

    echo ""
    echo "PHP-FPM:"
    systemctl is-active php8.3-fpm || true

    echo ""
    echo "MySQL:"
    mysql --version 2>/dev/null || true
    systemctl is-active mysql || true

    echo ""
    echo "Node:"
    node --version 2>/dev/null || true

    echo ""
    echo "npm:"
    npm --version 2>/dev/null || true

    echo ""
    echo "Composer:"
    composer --version 2>/dev/null || true

    echo ""
    echo "Git:"
    git --version 2>/dev/null || true

    echo ""
    echo "Cloudflare:"
    systemctl is-active cloudflared 2>/dev/null || true

    echo ""
    echo "Ollama:"
    systemctl is-active ollama 2>/dev/null || true

    echo ""
    echo "Fail2ban:"
    systemctl is-active fail2ban 2>/dev/null || true

    echo ""
    echo "Puertos:"
    ss -lnt 2>/dev/null | grep -E ':(22|80|443|3306|8080|11434)\b' || true

    echo ""
    echo "VirtualHosts:"
    apache2ctl -S 2>/dev/null || true
}

# ------------------------------------------------------------
# Ayuda
# ------------------------------------------------------------

show_help() {

    cat <<EOF

PCCURICO HOSTING PANEL
Instalador ${VERSION}

Uso:

  curl -fsSL https://raw.githubusercontent.com/pccurico/install/refs/heads/master/${SCRIPT_NAME} | sudo bash

Opciones:

  --install
      Ejecuta la instalación completa.

  --status
      Muestra el estado actual.

  --diagnostic
      Muestra diagnóstico del servidor.

  --help
      Muestra esta ayuda.

El instalador es idempotente:
puede ejecutarse nuevamente sin reinstalar innecesariamente
los componentes existentes.

No modifica automáticamente:

  - VirtualHosts existentes
  - Bases de datos existentes
  - Cloudflare Tunnel
  - Ollama
  - Node.js existente
  - PHP existente
  - Configuración existente de MySQL
  - Firewall existente

EOF
}

# ------------------------------------------------------------
# Instalación
# ------------------------------------------------------------

run_install() {

    title "PCCURICO HOSTING PANEL ${VERSION}"

    info "Servidor: $(hostname)"
    info "Usuario efectivo: $(id -un)"
    info "Arquitectura: $(uname -m)"
    info "Sistema: $(grep '^PRETTY_NAME=' /etc/os-release | cut -d= -f2- | tr -d '"')"

    echo ""

    step_system
    step_apache
    step_php
    step_mysql
    step_panel_database
    step_composer
    step_node_git
    step_security
    step_existing_services
    step_panel_structure

    final_validation

    echo ""

    title "PCCURICO HOSTING PANEL PREPARADO"

    ok "Servidor preparado correctamente."

    echo ""
    echo "Configuración:"
    echo "  ${PANEL_CONFIG_DIR}"

    echo ""
    echo "Panel:"
    echo "  ${PANEL_ROOT}"

    echo ""
    echo "Estado:"
    echo "  ${STATE_DIR}"

    echo ""
    echo "Log:"
    echo "  ${LOG_FILE}"

    echo ""
    echo "Backups:"
    echo "  ${BACKUP_DIR}"

    echo ""

    info "No se modificaron los VirtualHosts existentes."
    info "No se eliminaron bases de datos existentes."
    info "No se modificó Cloudflare."
    info "No se modificó Ollama."
    info "No se modificó la configuración existente de MySQL."
}

# ------------------------------------------------------------
# Main
# ------------------------------------------------------------

main() {

    require_root
    prepare_logging
    acquire_lock
    prepare_state

    local action="${1:-}"

    case "$action" in

        --status)
            show_status
            ;;

        --diagnostic)
            show_diagnostic
            ;;

        --help|-h)
            show_help
            ;;

        --install|"")
            run_install
            ;;

        *)
            error "Opción desconocida: ${action}"
            show_help
            exit 1
            ;;

    esac
}

main "$@"
