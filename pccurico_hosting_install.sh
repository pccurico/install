#!/usr/bin/env bash
# ============================================================
# PCCURICO HOSTING SERVER
# Instalador profesional LAMP + herramientas
#
# Ubuntu Server 24.04.x
#
# Compatible con:
#   curl -fsSL URL | sudo bash
#
# Características:
#   - Instalación idempotente
#   - Reanudación por etapas
#   - Detección robusta de MySQL/MariaDB
#   - Detección de servicios existentes
#   - Entrada interactiva mediante /dev/tty
#   - Compatible con curl | bash
#   - Protección de bases existentes
#   - No elimina bases de datos
#   - No guarda password root de MySQL
#   - Logs
#   - Diagnóstico
#   - Verificación final
# ============================================================

set -Eeuo pipefail
IFS=$'\n\t'

# ============================================================
# IDENTIDAD
# ============================================================

SCRIPT_NAME="pccurico_hosting_install.sh"
VERSION="2.0.0"

# ============================================================
# RUTAS
# ============================================================

STATE_DIR="/var/lib/pccurico-installer"
STATE_FILE="${STATE_DIR}/state"

LOG_DIR="/var/log/pccurico"
LOG_FILE="${LOG_DIR}/installer.log"

CONFIG_DIR="/etc/pccurico"
DB_CONFIG="${CONFIG_DIR}/database.conf"

LOCK_FILE="/var/run/pccurico-hosting-install.lock"

# ============================================================
# CONFIGURACIÓN
# ============================================================

APP_DB_DEFAULT="pccurico"
APP_DB_USER_DEFAULT="pccurico"

MYSQL_ROOT_PASSWORD=""
MYSQL_AUTH_MODE=""

MYSQL_SERVICE=""
MYSQL_CLIENT=""

# ============================================================
# COLORES
# ============================================================

if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    MAGENTA='\033[0;35m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    CYAN=''
    MAGENTA=''
    NC=''
fi

# ============================================================
# FUNCIONES DE SALIDA
# ============================================================

timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

ok() {
    echo -e "${GREEN}[OK]${NC} $*"
}

warn() {
    echo -e "${YELLOW}[AVISO]${NC} $*"
}

error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

step() {
    echo
    echo -e "${CYAN}============================================================${NC}"
    echo -e "${CYAN}$*${NC}"
    echo -e "${CYAN}============================================================${NC}"
}

die() {
    error "$*"
    exit 1
}

# ============================================================
# LOG
# ============================================================

prepare_directories() {
    mkdir -p "$STATE_DIR"
    mkdir -p "$LOG_DIR"
    mkdir -p "$CONFIG_DIR"

    chmod 700 "$STATE_DIR"
    chmod 750 "$LOG_DIR"
    chmod 700 "$CONFIG_DIR"

    touch "$LOG_FILE"
    chmod 600 "$LOG_FILE"
}

log_message() {
    printf '[%s] %s\n' "$(timestamp)" "$*" >> "$LOG_FILE"
}

# ============================================================
# NO LOGUEAR SECRETOS
# ============================================================

log_safe() {
    local message="$*"

    message="${message//${MYSQL_ROOT_PASSWORD}/[MYSQL_ROOT_PASSWORD]}"

    if [[ -n "${DB_PASSWORD:-}" ]]; then
        message="${message//${DB_PASSWORD}/[DB_PASSWORD]}"
    fi

    log_message "$message"
}

# ============================================================
# TRAPS
# ============================================================

cleanup() {
    unset MYSQL_ROOT_PASSWORD 2>/dev/null || true
}

on_error() {
    local line="$1"
    local command="$2"

    error "Error en línea ${line}."
    error "Comando: ${command}"
    error "La instalación se detuvo para evitar modificaciones incompletas."
    error "El estado anterior se conserva."
    error "Puedes volver a ejecutar el instalador."

    log_safe "ERROR línea=${line}"
    log_safe "ERROR comando=${command}"
}

trap cleanup EXIT
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

# ============================================================
# ROOT
# ============================================================

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        die "Este instalador debe ejecutarse como root."
    fi
}

# ============================================================
# LOCK
# ============================================================

acquire_lock() {

    if [[ -f "$LOCK_FILE" ]]; then
        local old_pid

        old_pid="$(cat "$LOCK_FILE" 2>/dev/null || true)"

        if [[ -n "$old_pid" ]] &&
           kill -0 "$old_pid" 2>/dev/null; then

            die "Ya existe otra instancia del instalador ejecutándose. PID: ${old_pid}"
        fi

        warn "Se encontró un archivo de bloqueo antiguo. Será eliminado."
        rm -f "$LOCK_FILE"
    fi

    echo "$$" > "$LOCK_FILE"

    trap 'rm -f "$LOCK_FILE" 2>/dev/null || true' EXIT
}

# ============================================================
# ENTRADA INTERACTIVA
#
# IMPORTANTE:
# /dev/tty permite que funcione:
#
# curl URL | sudo bash
# ============================================================

read_input() {
    local prompt="$1"
    local variable="$2"
    local default="${3:-}"

    local value=""

    if [[ ! -r /dev/tty ]]; then
        die "No existe una terminal interactiva disponible (/dev/tty)."
    fi

    if [[ -n "$default" ]]; then
        read -r -p "${prompt} [${default}]: " value </dev/tty
        value="${value:-$default}"
    else
        read -r -p "${prompt}: " value </dev/tty
    fi

    printf -v "$variable" '%s' "$value"
}

read_password() {
    local prompt="$1"
    local variable="$2"

    local value=""

    if [[ ! -r /dev/tty ]]; then
        die "No existe una terminal interactiva disponible (/dev/tty)."
    fi

    read -r -s -p "${prompt}: " value </dev/tty
    echo

    printf -v "$variable" '%s' "$value"
}

confirm() {
    local prompt="$1"
    local answer=""

    read -r -p "${prompt} [s/N]: " answer </dev/tty

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
# COMANDOS
# ============================================================

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# ============================================================
# ESTADO
# ============================================================

is_done() {
    local stage="$1"

    [[ -f "$STATE_FILE" ]] &&
        grep -qxF "$stage" "$STATE_FILE"
}

mark_done() {
    local stage="$1"

    touch "$STATE_FILE"

    if ! is_done "$stage"; then
        printf '%s\n' "$stage" >> "$STATE_FILE"
    fi

    log_safe "ETAPA COMPLETADA: ${stage}"
}

# ============================================================
# APT
# ============================================================

apt_update() {
    info "Actualizando índices APT..."
    apt-get update
}

apt_install() {
    DEBIAN_FRONTEND=noninteractive \
        apt-get install -y "$@"
}

package_installed() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null |
        grep -q "install ok installed"
}

# ============================================================
# DETECCIÓN ROBUSTA DE MYSQL / MARIADB
# ============================================================

detect_mysql_client() {

    MYSQL_CLIENT=""

    local candidates=(
        "/usr/bin/mysql"
        "/usr/local/bin/mysql"
        "/usr/bin/mariadb"
        "/usr/local/bin/mariadb"
    )

    local candidate

    for candidate in "${candidates[@]}"; do
        if [[ -x "$candidate" ]]; then
            MYSQL_CLIENT="$candidate"
            return 0
        fi
    done

    if command_exists mysql; then
        MYSQL_CLIENT="$(command -v mysql)"
        return 0
    fi

    if command_exists mariadb; then
        MYSQL_CLIENT="$(command -v mariadb)"
        return 0
    fi

    return 1
}

detect_mysql_service() {

    MYSQL_SERVICE=""

    local candidates=(
        mysql
        mysqld
        mariadb
    )

    local service

    for service in "${candidates[@]}"; do

        if systemctl list-unit-files \
            "${service}.service" \
            --no-legend \
            >/dev/null 2>&1; then

            if systemctl cat "${service}.service" \
                >/dev/null 2>&1; then

                MYSQL_SERVICE="$service"
                return 0
            fi
        fi
    done

    local discovered

    discovered="$(
        systemctl list-unit-files \
            --type=service \
            --no-legend 2>/dev/null |
        awk '{print $1}' |
        grep -Ei '^(mysql|mysqld|mariadb)(@.*)?\.service$' |
        head -n 1 || true
    )"

    if [[ -n "$discovered" ]]; then
        MYSQL_SERVICE="${discovered%.service}"
        return 0
    fi

    return 1
}

detect_mysql_process() {

    pgrep -x mysqld >/dev/null 2>&1 ||
    pgrep -x mariadbd >/dev/null 2>&1
}

detect_mysql_socket() {

    [[ -S /run/mysqld/mysqld.sock ]] ||
    [[ -S /run/mariadb/mariadb.sock ]] ||
    [[ -S /var/run/mysqld/mysqld.sock ]]
}

detect_mysql_datadir() {

    [[ -d /var/lib/mysql ]]
}

mysql_server_detected() {

    detect_mysql_client && return 0
    detect_mysql_service && return 0
    detect_mysql_process && return 0
    detect_mysql_socket && return 0
    detect_mysql_datadir && return 0

    return 1
}

# ============================================================
# INFORMACIÓN MYSQL
# ============================================================

show_mysql_detection() {

    echo
    echo "Detección MySQL/MariaDB:"
    echo

    if detect_mysql_client; then
        echo "  [OK] Cliente : ${MYSQL_CLIENT}"
    else
        echo "  [--] Cliente : no encontrado"
    fi

    if detect_mysql_service; then
        echo "  [OK] Servicio: ${MYSQL_SERVICE}"
    else
        echo "  [--] Servicio: no detectado"
    fi

    if detect_mysql_process; then
        echo "  [OK] Proceso  : servidor activo"
    else
        echo "  [--] Proceso  : no detectado"
    fi

    if detect_mysql_socket; then
        echo "  [OK] Socket   : detectado"
    else
        echo "  [--] Socket   : no detectado"
    fi

    if detect_mysql_datadir; then
        echo "  [OK] Datadir  : /var/lib/mysql"
    else
        echo "  [--] Datadir  : no detectado"
    fi

    echo
}

# ============================================================
# INICIAR MYSQL
# ============================================================

start_mysql_service() {

    if [[ -z "$MYSQL_SERVICE" ]]; then
        detect_mysql_service || true
    fi

    if [[ -n "$MYSQL_SERVICE" ]]; then

        if systemctl is-active --quiet "$MYSQL_SERVICE"; then
            ok "Servicio ${MYSQL_SERVICE} ya está activo."
            return 0
        fi

        info "Iniciando ${MYSQL_SERVICE}..."

        systemctl start "$MYSQL_SERVICE"

        sleep 2

        if systemctl is-active --quiet "$MYSQL_SERVICE"; then
            ok "Servicio ${MYSQL_SERVICE} activo."
            return 0
        fi

        warn "No fue posible confirmar ${MYSQL_SERVICE} como activo."
    fi

    if detect_mysql_process || detect_mysql_socket; then
        ok "El servidor MySQL/MariaDB responde mediante proceso/socket."
        return 0
    fi

    return 1
}

# ============================================================
# ETAPA 1
# ============================================================

step_1_base() {

    if is_done "1-base"; then
        info "Paso 1/10 ya completado."
        return
    fi

    step "[1/10] Preparación del sistema"

    apt_update

    apt_install \
        curl \
        wget \
        git \
        unzip \
        zip \
        ca-certificates \
        gnupg \
        lsb-release \
        software-properties-common \
        apt-transport-https \
        openssl \
        nano \
        vim \
        htop \
        net-tools \
        ufw \
        rsync \
        acl \
        jq \
        tree \
        cron \
        logrotate

    ok "Paquetes base instalados."

    mark_done "1-base"
}

# ============================================================
# ETAPA 2 APACHE
# ============================================================

step_2_apache() {

    if is_done "2-apache"; then
        info "Paso 2/10 ya completado."
        return
    fi

    step "[2/10] Apache2"

    if package_installed apache2 || command_exists apache2; then
        info "Apache2 ya está instalado."
    else
        apt_update
        apt_install apache2
    fi

    systemctl enable apache2 >/dev/null 2>&1 || true
    systemctl start apache2

    if ! systemctl is-active --quiet apache2; then
        die "Apache2 está instalado pero no pudo iniciarse."
    fi

    a2enmod rewrite >/dev/null 2>&1 || true
    a2enmod headers >/dev/null 2>&1 || true
    a2enmod ssl >/dev/null 2>&1 || true

    systemctl restart apache2

    ok "Apache2 activo."

    mark_done "2-apache"
}

# ============================================================
# ETAPA 3 PHP
# ============================================================

step_3_php() {

    if is_done "3-php"; then
        info "Paso 3/10 ya completado."
        return
    fi

    step "[3/10] PHP"

    if command_exists php; then
        info "PHP ya está instalado."
        echo "  $(php -v | head -n 1)"
    else
        apt_update

        apt_install \
            php \
            php-cli \
            php-common \
            php-mysql \
            php-curl \
            php-gd \
            php-mbstring \
            php-xml \
            php-zip \
            php-intl \
            php-bcmath \
            php-soap \
            php-fpm
    fi

    if ! command_exists php; then
        die "PHP no está disponible después de la instalación."
    fi

    ok "PHP disponible: $(php -r 'echo PHP_VERSION;')"

    mark_done "3-php"
}

# ============================================================
# ETAPA 4 MYSQL
# ============================================================

step_4_mysql() {

    if is_done "4-mysql"; then
        info "Paso 4/10 ya completado."
        return
    fi

    step "[4/10] MySQL / MariaDB"

    echo
    info "Analizando instalación existente..."
    show_mysql_detection

    # --------------------------------------------------------
    # Si ya existe, NO instalar nada.
    # --------------------------------------------------------

    if mysql_server_detected; then

        ok "Se detectó una instalación existente de MySQL/MariaDB."
        info "No se reinstalará ni se modificará el servidor existente."

        detect_mysql_client || true
        detect_mysql_service || true

        if ! start_mysql_service; then

            warn "No fue posible iniciar automáticamente el servidor."
            show_mysql_detection

            die "MySQL/MariaDB está detectado pero no está disponible."
        fi

    else

        info "No se encontró una instalación de MySQL/MariaDB."
        info "Se instalará MySQL Server."

        apt_update
        apt_install mysql-server mysql-client

        detect_mysql_client ||
            die "MySQL fue instalado pero no se encontró el cliente."

        detect_mysql_service ||
            warn "No se pudo identificar el nombre del servicio MySQL."

        if ! start_mysql_service; then
            die "MySQL fue instalado pero no pudo iniciarse."
        fi
    fi

    detect_mysql_client || true
    detect_mysql_service || true

    echo
    echo "Cliente: ${MYSQL_CLIENT:-no detectado}"
    echo "Servicio: ${MYSQL_SERVICE:-no detectado}"

    if [[ -n "${MYSQL_CLIENT:-}" ]]; then
        "${MYSQL_CLIENT}" --version || true
    fi

    mark_done "4-mysql"
}

# ============================================================
# MYSQL SOCKET TEST
# ============================================================

mysql_socket_test() {

    [[ -n "${MYSQL_CLIENT:-}" ]] ||
        detect_mysql_client || return 1

    "${MYSQL_CLIENT}" \
        --protocol=socket \
        -uroot \
        -e "SELECT 1;" \
        >/dev/null 2>&1
}

# ============================================================
# MYSQL PASSWORD TEST
# ============================================================

mysql_password_test() {

    local password="$1"

    [[ -n "${MYSQL_CLIENT:-}" ]] ||
        detect_mysql_client || return 1

    MYSQL_PWD="$password" \
        "${MYSQL_CLIENT}" \
        --protocol=socket \
        -uroot \
        -e "SELECT 1;" \
        >/dev/null 2>&1
}

# ============================================================
# SOLICITAR ROOT PASSWORD
# ============================================================

request_mysql_root_password() {

    local attempt=1

    echo
    echo "============================================================"
    echo " AUTENTICACIÓN ADMINISTRATIVA MYSQL"
    echo "============================================================"
    echo
    echo "Se necesita acceso administrativo a MySQL."
    echo "La contraseña NO se guardará en el estado del instalador."
    echo "La contraseña NO se escribirá deliberadamente en el log."
    echo

    while (( attempt <= 3 )); do

        MYSQL_ROOT_PASSWORD=""

        read_password \
            "Contraseña de root de MySQL" \
            MYSQL_ROOT_PASSWORD

        if mysql_password_test "$MYSQL_ROOT_PASSWORD"; then
            MYSQL_AUTH_MODE="password"
            ok "Autenticación root de MySQL validada."
            return 0
        fi

        warn "La contraseña no fue aceptada."

        ((attempt++))
    done

    # --------------------------------------------------------
    # Fallback socket.
    # --------------------------------------------------------

    if mysql_socket_test; then
        warn "MySQL permite autenticación root mediante socket."
        info "Se utilizará autenticación socket."
        MYSQL_ROOT_PASSWORD=""
        MYSQL_AUTH_MODE="socket"
        return 0
    fi

    die "No fue posible autenticar root en MySQL."
}

# ============================================================
# MYSQL EXEC
# ============================================================

mysql_exec() {

    [[ -n "${MYSQL_CLIENT:-}" ]] ||
        detect_mysql_client ||
        die "No se encontró cliente MySQL/MariaDB."

    if [[ "${MYSQL_AUTH_MODE}" == "password" ]]; then

        MYSQL_PWD="$MYSQL_ROOT_PASSWORD" \
            "${MYSQL_CLIENT}" \
            --protocol=socket \
            -uroot \
            "$@"

    else

        "${MYSQL_CLIENT}" \
            --protocol=socket \
            -uroot \
            "$@"
    fi
}

# ============================================================
# SQL ESCAPE
# ============================================================

sql_escape() {

    local value="$1"

    value="${value//\\/\\\\}"
    value="${value//\'/\'\'}"

    printf '%s' "$value"
}

# ============================================================
# PASSWORD GENERATOR
# ============================================================

generate_password() {

    local password=""

    if command_exists openssl; then

        password="$(
            openssl rand -base64 48 |
            tr -dc 'A-Za-z0-9' |
            head -c 32
        )"

    else

        password="$(
            tr -dc 'A-Za-z0-9' </dev/urandom |
            head -c 32
        )"

    fi

    printf '%s' "$password"
}

# ============================================================
# VALIDACIONES
# ============================================================

validate_db_name() {

    [[ "$1" =~ ^[A-Za-z0-9_]+$ ]]
}

validate_db_user() {

    [[ "$1" =~ ^[A-Za-z0-9_]+$ ]]
}

# ============================================================
# CONFIG EXISTENTE
# ============================================================

load_existing_db_config() {

    [[ -f "$DB_CONFIG" ]] || return 1

    unset DB_HOST DB_NAME DB_USER DB_PASSWORD

    # shellcheck disable=SC1090
    source "$DB_CONFIG"

    [[ -n "${DB_NAME:-}" ]] &&
    [[ -n "${DB_USER:-}" ]] &&
    [[ -n "${DB_PASSWORD:-}" ]]
}

# ============================================================
# ETAPA 5 DATABASE
# ============================================================

step_5_database() {

    if is_done "5-database"; then
        info "Paso 5/10 ya completado."
        return
    fi

    step "[5/10] Configuración de base de datos"

    # --------------------------------------------------------
    # Asegurar MySQL
    # --------------------------------------------------------

    detect_mysql_client ||
        die "No existe cliente MySQL/MariaDB."

    if ! start_mysql_service; then
        die "MySQL/MariaDB no está disponible."
    fi

    # --------------------------------------------------------
    # Autenticación
    # --------------------------------------------------------

    if mysql_socket_test; then

        info "Root MySQL permite autenticación mediante socket."

        if confirm "¿Desea utilizar la contraseña de root de MySQL?"; then
            request_mysql_root_password
        else
            MYSQL_AUTH_MODE="socket"
            MYSQL_ROOT_PASSWORD=""
        fi

    else

        request_mysql_root_password
    fi

    # --------------------------------------------------------
    # Variables
    # --------------------------------------------------------

    local existing_config="no"

    if load_existing_db_config; then

        echo
        info "Se encontró configuración existente:"
        echo "  Base de datos : ${DB_NAME}"
        echo "  Usuario       : ${DB_USER}"
        echo

        if confirm "¿Desea conservar esta configuración?"; then
            existing_config="yes"
        fi
    fi

    # --------------------------------------------------------
    # Nueva configuración
    # --------------------------------------------------------

    if [[ "$existing_config" != "yes" ]]; then

        read_input \
            "Nombre de la base de datos" \
            DB_NAME \
            "$APP_DB_DEFAULT"

        validate_db_name "$DB_NAME" ||
            die "Nombre de base de datos inválido: ${DB_NAME}"

        read_input \
            "Usuario de aplicación MySQL" \
            DB_USER \
            "$APP_DB_USER_DEFAULT"

        validate_db_user "$DB_USER" ||
            die "Usuario MySQL inválido: ${DB_USER}"

        echo
        echo "Puede ingresar una contraseña para '${DB_USER}'."
        echo "Si la deja vacía, se generará automáticamente."
        echo

        local entered_password=""

        read_password \
            "Contraseña de ${DB_USER}" \
            entered_password

        if [[ -n "$entered_password" ]]; then
            DB_PASSWORD="$entered_password"
        else
            DB_PASSWORD="$(generate_password)"
            info "Se generó una contraseña segura automáticamente."
        fi

        unset entered_password

    else

        validate_db_name "$DB_NAME" ||
            die "DB_NAME existente inválido."

        validate_db_user "$DB_USER" ||
            die "DB_USER existente inválido."

    fi

    # --------------------------------------------------------
    # Base de datos
    # --------------------------------------------------------

    local escaped_db
    local escaped_user
    local escaped_password

    escaped_db="$(sql_escape "$DB_NAME")"
    escaped_user="$(sql_escape "$DB_USER")"
    escaped_password="$(sql_escape "$DB_PASSWORD")"

    local db_exists

    db_exists="$(
        mysql_exec \
            -N \
            -B \
            -e "
                SELECT SCHEMA_NAME
                FROM INFORMATION_SCHEMA.SCHEMATA
                WHERE SCHEMA_NAME='${escaped_db}';
            "
    )"

    if [[ "$db_exists" == "$DB_NAME" ]]; then

        warn "La base de datos '${DB_NAME}' ya existe."
        warn "NO será eliminada."
        warn "NO será recreada."

    else

        info "Creando base de datos '${DB_NAME}'..."

        mysql_exec \
            -e "
                CREATE DATABASE \`${DB_NAME}\`
                CHARACTER SET utf8mb4
                COLLATE utf8mb4_unicode_ci;
            "

        ok "Base de datos creada."
    fi

    # --------------------------------------------------------
    # Usuario localhost
    # --------------------------------------------------------

    local user_local

    user_local="$(
        mysql_exec \
            -N \
            -B \
            -e "
                SELECT User
                FROM mysql.user
                WHERE User='${escaped_user}'
                AND Host='localhost';
            "
    )"

    if [[ "$user_local" == "$DB_USER" ]]; then

        info "Usuario '${DB_USER}'@'localhost' ya existe."

        mysql_exec \
            -e "
                ALTER USER '${escaped_user}'@'localhost'
                IDENTIFIED BY '${escaped_password}';
            "

    else

        info "Creando usuario '${DB_USER}'@'localhost'..."

        mysql_exec \
            -e "
                CREATE USER '${escaped_user}'@'localhost'
                IDENTIFIED BY '${escaped_password}';
            "
    fi

    # --------------------------------------------------------
    # Usuario 127.0.0.1
    # --------------------------------------------------------

    local user_ip

    user_ip="$(
        mysql_exec \
            -N \
            -B \
            -e "
                SELECT User
                FROM mysql.user
                WHERE User='${escaped_user}'
                AND Host='127.0.0.1';
            "
    )"

    if [[ "$user_ip" == "$DB_USER" ]]; then

        info "Usuario '${DB_USER}'@'127.0.0.1' ya existe."

        mysql_exec \
            -e "
                ALTER USER '${escaped_user}'@'127.0.0.1'
                IDENTIFIED BY '${escaped_password}';
            "

    else

        info "Creando usuario '${DB_USER}'@'127.0.0.1'..."

        mysql_exec \
            -e "
                CREATE USER '${escaped_user}'@'127.0.0.1'
                IDENTIFIED BY '${escaped_password}';
            "
    fi

    # --------------------------------------------------------
    # Privilegios
    # --------------------------------------------------------

    info "Asignando privilegios..."

    mysql_exec \
        -e "
            GRANT ALL PRIVILEGES
            ON \`${DB_NAME}\`.*
            TO '${escaped_user}'@'localhost';
        "

    mysql_exec \
        -e "
            GRANT ALL PRIVILEGES
            ON \`${DB_NAME}\`.*
            TO '${escaped_user}'@'127.0.0.1';
        "

    mysql_exec \
        -e "FLUSH PRIVILEGES;"

    # --------------------------------------------------------
    # Guardar configuración
    # --------------------------------------------------------

    cat > "$DB_CONFIG" <<EOF
# ============================================================
# PCCURICO HOSTING
# Configuración de base de datos
# Generado automáticamente
# ============================================================

DB_HOST=127.0.0.1
DB_NAME=${DB_NAME}
DB_USER=${DB_USER}
DB_PASSWORD=${DB_PASSWORD}
EOF

    chmod 600 "$DB_CONFIG"

    ok "Configuración guardada en:"
    echo "  ${DB_CONFIG}"
    echo
    info "La contraseña de la aplicación no se mostrará."

    # --------------------------------------------------------
    # Limpiar root password de memoria
    # --------------------------------------------------------

    unset MYSQL_ROOT_PASSWORD

    mark_done "5-database"
}

# ============================================================
# ETAPA 6
# ============================================================

step_6_tools() {

    if is_done "6-tools"; then
        info "Paso 6/10 ya completado."
        return
    fi

    step "[6/10] Herramientas adicionales"

    apt_update

    apt_install \
        build-essential \
        pkg-config \
        acl \
        rsync \
        jq \
        tree \
        cron \
        logrotate

    systemctl enable cron >/dev/null 2>&1 || true
    systemctl start cron >/dev/null 2>&1 || true

    ok "Herramientas instaladas."

    mark_done "6-tools"
}

# ============================================================
# ETAPA 7 NODE
# ============================================================

step_7_node() {

    if is_done "7-node"; then
        info "Paso 7/10 ya completado."
        return
    fi

    step "[7/10] Node.js / npm"

    if command_exists node && command_exists npm; then

        info "Node.js ya está instalado."
        echo "  Node: $(node --version)"
        echo "  npm : $(npm --version)"

    else

        apt_update
        apt_install nodejs npm

        if ! command_exists node; then
            die "Node.js no quedó disponible."
        fi

        if ! command_exists npm; then
            warn "npm no está disponible."
        fi
    fi

    mark_done "7-node"
}

# ============================================================
# ETAPA 8 OLLAMA
# ============================================================

step_8_ollama() {

    if is_done "8-ollama"; then
        info "Paso 8/10 ya completado."
        return
    fi

    step "[8/10] Ollama"

    if command_exists ollama; then

        info "Ollama ya está instalado."
        ollama --version || true

    else

        info "Descargando instalador oficial de Ollama..."

        local tmp_file

        tmp_file="$(mktemp)"

        curl -fsSL \
            https://ollama.com/install.sh \
            -o "$tmp_file"

        [[ -s "$tmp_file" ]] ||
            die "El instalador de Ollama se descargó vacío."

        sh "$tmp_file"

        rm -f "$tmp_file"

        if ! command_exists ollama; then
            warn "Ollama fue procesado pero todavía no aparece en PATH."
        fi
    fi

    if systemctl cat ollama.service >/dev/null 2>&1; then

        systemctl enable ollama >/dev/null 2>&1 || true
        systemctl start ollama >/dev/null 2>&1 || true

        if systemctl is-active --quiet ollama; then
            ok "Servicio Ollama activo."
        else
            warn "Ollama instalado pero el servicio no está activo."
        fi
    fi

    mark_done "8-ollama"
}

# ============================================================
# ETAPA 9 SEGURIDAD
# ============================================================

step_9_security() {

    if is_done "9-security"; then
        info "Paso 9/10 ya completado."
        return
    fi

    step "[9/10] Seguridad básica"

    apt_update
    apt_install fail2ban

    systemctl enable fail2ban >/dev/null 2>&1 || true
    systemctl start fail2ban >/dev/null 2>&1 || true

    if systemctl is-active --quiet fail2ban; then
        ok "Fail2ban activo."
    else
        warn "Fail2ban está instalado pero no está activo."
    fi

    # --------------------------------------------------------
    # NO activar UFW automáticamente.
    # --------------------------------------------------------

    info "UFW no será activado automáticamente."
    info "Esto evita bloquear SSH accidentalmente."

    mark_done "9-security"
}

# ============================================================
# PRUEBA DB
# ============================================================

test_application_database() {

    [[ -f "$DB_CONFIG" ]] || return 1

    local db_host
    local db_name
    local db_user
    local db_password

    # shellcheck disable=SC1090
    source "$DB_CONFIG"

    [[ -n "${db_name:-}" ]] || return 1
    [[ -n "${db_user:-}" ]] || return 1
    [[ -n "${db_password:-}" ]] || return 1

    MYSQL_PWD="$db_password" \
        "${MYSQL_CLIENT}" \
        -h "${db_host:-127.0.0.1}" \
        -u "$db_user" \
        -e "SELECT 1;" \
        >/dev/null 2>&1
}

# ============================================================
# ETAPA 10
# ============================================================

step_10_verification() {

    if is_done "10-verification"; then
        info "Paso 10/10 ya completado."
        return
    fi

    step "[10/10] Verificación final"

    local errors=0

    echo
    echo "---- APACHE ----"

    if command_exists apache2 &&
       systemctl is-active --quiet apache2; then

        echo "[OK] Apache2 activo."

    else

        echo "[ERROR] Apache2 no está activo."
        ((errors++))
    fi

    echo
    echo "---- PHP ----"

    if command_exists php; then
        echo "[OK] PHP $(php -r 'echo PHP_VERSION;')"
    else
        echo "[ERROR] PHP no encontrado."
        ((errors++))
    fi

    echo
    echo "---- MYSQL / MARIADB ----"

    if mysql_server_detected; then
        echo "[OK] Servidor MySQL/MariaDB detectado."
    else
        echo "[ERROR] Servidor MySQL/MariaDB no detectado."
        ((errors++))
    fi

    detect_mysql_client || true
    detect_mysql_service || true

    if [[ -n "${MYSQL_CLIENT:-}" ]]; then
        echo "[OK] Cliente: ${MYSQL_CLIENT}"
        "${MYSQL_CLIENT}" --version || true
    else
        echo "[ERROR] Cliente MySQL no encontrado."
        ((errors++))
    fi

    if [[ -n "${MYSQL_SERVICE:-}" ]]; then

        if systemctl is-active --quiet "$MYSQL_SERVICE"; then
            echo "[OK] Servicio: ${MYSQL_SERVICE}"
        else
            echo "[ERROR] Servicio ${MYSQL_SERVICE} inactivo."
            ((errors++))
        fi

    elif detect_mysql_process || detect_mysql_socket; then

        echo "[OK] Servidor detectado mediante proceso/socket."

    else

        echo "[ERROR] No se pudo verificar el servicio MySQL."
        ((errors++))
    fi

    echo
    echo "---- BASE DE DATOS PCCURICO ----"

    if [[ -f "$DB_CONFIG" ]]; then

        echo "[OK] Archivo de configuración presente."

        if test_application_database; then
            echo "[OK] Conexión de aplicación a MySQL correcta."
        else
            echo "[ERROR] La conexión del usuario de aplicación falló."
            ((errors++))
        fi

    else

        echo "[ERROR] Falta ${DB_CONFIG}"
        ((errors++))
    fi

    echo
    echo "---- NODE.JS ----"

    if command_exists node; then
        echo "[OK] Node.js $(node --version)"
    else
        echo "[AVISO] Node.js no disponible."
    fi

    echo
    echo "---- OLLAMA ----"

    if command_exists ollama; then
        echo "[OK] Ollama instalado."
    else
        echo "[AVISO] Ollama no disponible."
    fi

    echo
    echo "---- FAIL2BAN ----"

    if systemctl is-active --quiet fail2ban; then
        echo "[OK] Fail2ban activo."
    else
        echo "[AVISO] Fail2ban inactivo."
    fi

    echo

    if (( errors > 0 )); then
        warn "La verificación terminó con ${errors} problema(s)."
        return 1
    fi

    ok "Todas las comprobaciones principales fueron exitosas."

    mark_done "10-verification"
}

# ============================================================
# INSTALACIÓN COMPLETA
# ============================================================

install_all() {

    step "PCCURICO HOSTING SERVER"

    echo
    echo "Versión: ${VERSION}"
    echo
    echo "Características:"
    echo "  - Instalación reanudable"
    echo "  - Detección de componentes existentes"
    echo "  - Protección de bases de datos"
    echo "  - MySQL/MariaDB detectado automáticamente"
    echo "  - Compatible con curl | sudo bash"
    echo

    step_1_base
    step_2_apache
    step_3_php
    step_4_mysql
    step_5_database
    step_6_tools
    step_7_node
    step_8_ollama
    step_9_security
    step_10_verification

    final_message
}

# ============================================================
# REANUDAR 5/10
# ============================================================

resume_from_5() {

    step "REANUDANDO DESDE 5/10"

    echo
    echo "Los pasos 1 a 4 NO serán reinstalados."
    echo "Se verificará el estado real del servidor."
    echo

    # --------------------------------------------------------
    # Apache
    # --------------------------------------------------------

    if command_exists apache2; then

        ok "Apache2 detectado."

        if ! systemctl is-active --quiet apache2; then
            warn "Apache2 está detenido. Intentando iniciarlo..."
            systemctl start apache2
        fi

    else

        die "Apache2 no está instalado."
    fi

    # --------------------------------------------------------
    # PHP
    # --------------------------------------------------------

    if command_exists php; then
        ok "PHP detectado: $(php -r 'echo PHP_VERSION;')"
    else
        die "PHP no está instalado."
    fi

    # --------------------------------------------------------
    # MySQL
    # --------------------------------------------------------

    info "Detectando MySQL/MariaDB..."
    show_mysql_detection

    if ! mysql_server_detected; then

        die "No se encontró una instalación de MySQL/MariaDB."

    fi

    detect_mysql_client ||
        die "Se detectó servidor MySQL/MariaDB pero no su cliente."

    detect_mysql_service || true

    if ! start_mysql_service; then

        show_mysql_detection

        die "MySQL/MariaDB fue detectado pero no está disponible."
    fi

    # --------------------------------------------------------
    # Marcar 1-4 como existentes
    # --------------------------------------------------------

    mark_done "1-base"
    mark_done "2-apache"
    mark_done "3-php"
    mark_done "4-mysql"

    # --------------------------------------------------------
    # Continuar
    # --------------------------------------------------------

    step_5_database
    step_6_tools
    step_7_node
    step_8_ollama
    step_9_security
    step_10_verification

    final_message
}

# ============================================================
# ESTADO
# ============================================================

show_status() {

    step "ESTADO PCCURICO HOSTING SERVER"

    echo
    echo "Versión : ${VERSION}"
    echo "Estado  : ${STATE_FILE}"
    echo "Log     : ${LOG_FILE}"
    echo

    local stages=(
        "1-base"
        "2-apache"
        "3-php"
        "4-mysql"
        "5-database"
        "6-tools"
        "7-node"
        "8-ollama"
        "9-security"
        "10-verification"
    )

    local number=1
    local stage

    for stage in "${stages[@]}"; do

        if is_done "$stage"; then

            echo -e "  ${GREEN}[OK]${NC} ${number}/10 ${stage}"

        else

            echo -e "  ${YELLOW}[PENDIENTE]${NC} ${number}/10 ${stage}"

        fi

        ((number++))
    done

    echo

    echo "Componentes detectados:"
    echo

    if command_exists apache2; then
        echo "  [OK] Apache2"
    else
        echo "  [--] Apache2"
    fi

    if command_exists php; then
        echo "  [OK] PHP"
    else
        echo "  [--] PHP"
    fi

    if mysql_server_detected; then
        echo "  [OK] MySQL/MariaDB"
    else
        echo "  [--] MySQL/MariaDB"
    fi

    if command_exists node; then
        echo "  [OK] Node.js"
    else
        echo "  [--] Node.js"
    fi

    if command_exists ollama; then
        echo "  [OK] Ollama"
    else
        echo "  [--] Ollama"
    fi

    echo

    if [[ -f "$DB_CONFIG" ]]; then
        echo "[OK] Configuración DB: ${DB_CONFIG}"
    else
        echo "[--] Configuración DB no creada."
    fi
}

# ============================================================
# DIAGNÓSTICO MYSQL
# ============================================================

mysql_diagnostic() {

    step "DIAGNÓSTICO MYSQL / MARIADB"

    echo
    echo "---- CLIENTE ----"

    if detect_mysql_client; then
        echo "[OK] Cliente: ${MYSQL_CLIENT}"
        "${MYSQL_CLIENT}" --version || true
    else
        echo "[--] Cliente MySQL/MariaDB no encontrado."
    fi

    echo
    echo "---- SERVICIO ----"

    if detect_mysql_service; then

        echo "[OK] Servicio detectado: ${MYSQL_SERVICE}"

        systemctl is-active \
            "$MYSQL_SERVICE" \
            2>/dev/null ||
            true

    else

        echo "[--] No se identificó unidad systemd."
    fi

    echo
    echo "---- PROCESOS ----"

    if detect_mysql_process; then
        echo "[OK] Servidor MySQL/MariaDB ejecutándose."
    else
        echo "[--] No se detectó proceso."
    fi

    echo
    echo "---- SOCKETS ----"

    if detect_mysql_socket; then
        echo "[OK] Socket MySQL/MariaDB detectado."
    else
        echo "[--] Socket no detectado."
    fi

    echo
    echo "---- DATADIR ----"

    if detect_mysql_datadir; then
        echo "[OK] /var/lib/mysql existe."
    else
        echo "[--] /var/lib/mysql no existe."
    fi

    echo
    echo "---- ROOT SOCKET AUTH ----"

    if mysql_socket_test; then
        echo "[OK] root puede autenticarse mediante socket."
    else
        echo "[INFO] root no permite autenticación socket sin password."
    fi

    echo
    echo "---- PCCURICO DATABASE CONFIG ----"

    if [[ -f "$DB_CONFIG" ]]; then

        echo "[OK] ${DB_CONFIG}"

        local cfg_name=""
        local cfg_user=""
        local cfg_host=""

        # shellcheck disable=SC1090
        source "$DB_CONFIG"

        cfg_name="${DB_NAME:-}"
        cfg_user="${DB_USER:-}"
        cfg_host="${DB_HOST:-}"

        echo "DB_HOST=${cfg_host}"
        echo "DB_NAME=${cfg_name}"
        echo "DB_USER=${cfg_user}"
        echo "DB_PASSWORD=[OCULTA]"

    else

        echo "[--] No existe ${DB_CONFIG}"

    fi
}

# ============================================================
# LOG
# ============================================================

show_log() {

    step "LOG PCCURICO"

    if [[ ! -f "$LOG_FILE" ]]; then
        warn "El log todavía no existe."
        return
    fi

    tail -n 150 "$LOG_FILE"
}

# ============================================================
# FINAL
# ============================================================

final_message() {

    step "PROCESO FINALIZADO"

    echo
    echo "PCCURICO HOSTING SERVER"
    echo "Versión: ${VERSION}"
    echo

    echo "Estado:"
    echo "  ${STATE_FILE}"

    echo
    echo "Configuración:"
    echo "  ${DB_CONFIG}"

    echo
    echo "Log:"
    echo "  ${LOG_FILE}"

    echo
    ok "Instalador finalizado."
}

# ============================================================
# AYUDA
# ============================================================

usage() {

    cat <<EOF

PCCURICO HOSTING SERVER
Versión ${VERSION}

Uso:

  curl -fsSL https://raw.githubusercontent.com/pccurico/install/refs/heads/master/${SCRIPT_NAME} | sudo bash

Opciones:

  --install
      Instalación completa / continuar.

  --resume-5
      Reanudar directamente desde 5/10.

  --status
      Mostrar estado y componentes detectados.

  --mysql
      Diagnóstico completo de MySQL/MariaDB.

  --log
      Mostrar las últimas líneas del log.

  --help
      Mostrar esta ayuda.

EOF
}

# ============================================================
# MAIN
# ============================================================

main() {

    require_root
    prepare_directories
    acquire_lock

    case "${1:-}" in

        --install)
            install_all
            ;;

        --resume-5)
            resume_from_5
            ;;

        --status)
            show_status
            ;;

        --mysql)
            mysql_diagnostic
            ;;

        --log)
            show_log
            ;;

        --help|-h)
            usage
            ;;

        "")
            install_all
            ;;

        *)
            error "Argumento desconocido: $1"
            usage
            exit 1
            ;;
    esac
}

main "$@"
