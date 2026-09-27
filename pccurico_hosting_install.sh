#!/usr/bin/env bash
# ============================================================
# PCCURICO HOSTING PANEL
# Instalador base para Ubuntu Server 24.04+
#
# Compatible con:
#   curl -fsSL URL | sudo bash
#
# Características:
#   - Instalación/reanudación por etapas
#   - Estado persistente
#   - Soporte para ejecución mediante pipe
#   - Entrada interactiva mediante /dev/tty
#   - MySQL/MariaDB
#   - No elimina bases de datos existentes
#   - No guarda contraseña root de MySQL
#   - Logs
#   - Diagnóstico
# ============================================================

set -Eeuo pipefail

# ------------------------------------------------------------
# CONFIGURACIÓN
# ------------------------------------------------------------

SCRIPT_NAME="pccurico_hosting_install.sh"
VERSION="1.1.0"

STATE_DIR="/var/lib/pccurico-installer"
STATE_FILE="${STATE_DIR}/state"
LOG_DIR="/var/log/pccurico"
LOG_FILE="${LOG_DIR}/installer.log"
CONFIG_DIR="/etc/pccurico"
DB_CONFIG="${CONFIG_DIR}/database.conf"

APP_DB_DEFAULT="pccurico"
APP_DB_USER_DEFAULT="pccurico"

MYSQL_ROOT_PASSWORD=""
MYSQL_AUTH_MODE=""

# ------------------------------------------------------------
# COLORES
# ------------------------------------------------------------

if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    CYAN=''
    NC=''
fi

# ------------------------------------------------------------
# FUNCIONES BÁSICAS
# ------------------------------------------------------------

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

# ------------------------------------------------------------
# LOG SEGURO
# ------------------------------------------------------------

mkdir -p "$STATE_DIR" "$LOG_DIR" "$CONFIG_DIR"
touch "$LOG_FILE"
chmod 700 "$STATE_DIR"
chmod 750 "$LOG_DIR"
chmod 700 "$CONFIG_DIR"

log() {
    # No imprimir contraseñas en log.
    printf '[%s] %s\n' "$(timestamp)" "$*" >> "$LOG_FILE"
}

# ------------------------------------------------------------
# REDIRECCIÓN DE SALIDA AL LOG
# ------------------------------------------------------------

exec > >(tee -a "$LOG_FILE") 2>&1

# ------------------------------------------------------------
# LIMPIEZA
# ------------------------------------------------------------

cleanup() {
    unset MYSQL_ROOT_PASSWORD 2>/dev/null || true
}

trap cleanup EXIT

on_error() {
    local line="$1"
    local command="$2"

    error "Error en línea ${line}."
    error "Comando: ${command}"
    error "La instalación se detuvo para evitar daños."
    error "El estado anterior se conserva."
    error "Puedes volver a ejecutar el instalador."

    log "ERROR línea=${line}"
    log "ERROR comando=${command}"
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
# ENTRADA INTERACTIVA
#
# IMPORTANTE:
# Permite:
#
# curl URL | sudo bash
#
# porque /dev/tty se utiliza para las preguntas.
# ------------------------------------------------------------

read_input() {
    local prompt="$1"
    local variable="$2"
    local default="${3:-}"

    local value=""

    if [[ -n "$default" ]]; then
        if ! read -r -p "${prompt} [${default}]: " value </dev/tty; then
            return 1
        fi

        value="${value:-$default}"
    else
        if ! read -r -p "${prompt}: " value </dev/tty; then
            return 1
        fi
    fi

    printf -v "$variable" '%s' "$value"
}

read_password() {
    local prompt="$1"
    local variable="$2"

    local value=""

    if ! read -r -s -p "${prompt}: " value </dev/tty; then
        return 1
    fi

    echo

    printf -v "$variable" '%s' "$value"
}

confirm() {
    local prompt="$1"
    local answer=""

    read -r -p "${prompt} [s/N]: " answer </dev/tty || return 1

    case "${answer,,}" in
        s|si|sí|y|yes)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# ------------------------------------------------------------
# ESTADO
# ------------------------------------------------------------

is_done() {
    local stage="$1"

    [[ -f "$STATE_FILE" ]] &&
        grep -qxF "$stage" "$STATE_FILE"
}

mark_done() {
    local stage="$1"

    touch "$STATE_FILE"

    if ! is_done "$stage"; then
        echo "$stage" >> "$STATE_FILE"
    fi

    log "ETAPA COMPLETADA: $stage"
}

show_status() {
    step "ESTADO DEL INSTALADOR"

    echo "Versión: ${VERSION}"
    echo "Estado: ${STATE_FILE}"
    echo "Log: ${LOG_FILE}"
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

    local i=1
    local stage

    for stage in "${stages[@]}"; do
        if is_done "$stage"; then
            echo -e "  ${GREEN}[OK]${NC} ${i}/10 ${stage}"
        else
            echo -e "  ${YELLOW}[PENDIENTE]${NC} ${i}/10 ${stage}"
        fi

        ((i++))
    done

    echo

    if [[ -f "$DB_CONFIG" ]]; then
        echo -e "${GREEN}Configuración de base de datos:${NC}"
        echo "  $DB_CONFIG"
    else
        echo -e "${YELLOW}Configuración de base de datos todavía no creada.${NC}"
    fi
}

# ------------------------------------------------------------
# DETECCIÓN DE COMANDOS
# ------------------------------------------------------------

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# ------------------------------------------------------------
# APT
# ------------------------------------------------------------

apt_update_once() {
    if [[ ! -f "${STATE_DIR}/apt_updated" ]]; then
        info "Actualizando índices APT..."
        apt-get update
        touch "${STATE_DIR}/apt_updated"
    fi
}

apt_install() {
    DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
}

# ------------------------------------------------------------
# ETAPA 1
# ------------------------------------------------------------

step_1_base() {
    if is_done "1-base"; then
        info "Paso 1/10 ya completado."
        return
    fi

    step "[1/10] Preparación del sistema"

    apt_update_once

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
        rsync

    ok "Paquetes base instalados."

    mark_done "1-base"
}

# ------------------------------------------------------------
# ETAPA 2 APACHE
# ------------------------------------------------------------

step_2_apache() {
    if is_done "2-apache"; then
        info "Paso 2/10 ya completado."
        return
    fi

    step "[2/10] Apache2"

    if command_exists apache2; then
        info "Apache2 ya está instalado."
    else
        apt_update_once
        apt_install apache2
    fi

    systemctl enable apache2 >/dev/null 2>&1 || true
    systemctl start apache2

    if systemctl is-active --quiet apache2; then
        ok "Apache2 está activo."
    else
        die "Apache2 no pudo iniciarse."
    fi

    a2enmod rewrite >/dev/null 2>&1 || true
    a2enmod headers >/dev/null 2>&1 || true
    a2enmod ssl >/dev/null 2>&1 || true

    systemctl restart apache2

    mark_done "2-apache"
}

# ------------------------------------------------------------
# ETAPA 3 PHP
# ------------------------------------------------------------

step_3_php() {
    if is_done "3-php"; then
        info "Paso 3/10 ya completado."
        return
    fi

    step "[3/10] PHP"

    apt_update_once

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

    if command_exists php; then
        ok "PHP detectado: $(php -v | head -n 1)"
    else
        die "PHP no quedó disponible."
    fi

    mark_done "3-php"
}

# ------------------------------------------------------------
# DETECCIÓN MYSQL / MARIADB
# ------------------------------------------------------------

detect_mysql() {
    if command_exists mysql; then
        return 0
    fi

    return 1
}

mysql_service_name() {
    if systemctl list-unit-files 2>/dev/null |
        grep -q '^mysql.service'; then
        echo "mysql"
        return
    fi

    if systemctl list-unit-files 2>/dev/null |
        grep -q '^mariadb.service'; then
        echo "mariadb"
        return
    fi

    echo ""
}

# ------------------------------------------------------------
# ETAPA 4 MYSQL
# ------------------------------------------------------------

step_4_mysql() {
    if is_done "4-mysql"; then
        info "Paso 4/10 ya completado."
        return
    fi

    step "[4/10] MySQL / MariaDB"

    if detect_mysql; then
        info "Cliente MySQL/MariaDB ya está instalado."
    else
        apt_update_once
        apt_install mysql-server mysql-client
    fi

    local service
    service="$(mysql_service_name)"

    if [[ -n "$service" ]]; then
        systemctl enable "$service" >/dev/null 2>&1 || true
        systemctl start "$service"

        if systemctl is-active --quiet "$service"; then
            ok "Servicio ${service} activo."
        else
            die "No fue posible iniciar ${service}."
        fi
    else
        die "No se encontró el servicio MySQL/MariaDB."
    fi

    mark_done "4-mysql"
}

# ------------------------------------------------------------
# MYSQL - TEST SIN PASSWORD
# ------------------------------------------------------------

mysql_socket_test() {
    mysql \
        --protocol=socket \
        -uroot \
        -e "SELECT 1;" \
        >/dev/null 2>&1
}

# ------------------------------------------------------------
# MYSQL - TEST CON PASSWORD
# ------------------------------------------------------------

mysql_password_test() {
    local password="$1"

    MYSQL_PWD="$password" \
        mysql \
        --protocol=socket \
        -uroot \
        -e "SELECT 1;" \
        >/dev/null 2>&1
}

# ------------------------------------------------------------
# SOLICITAR PASSWORD MYSQL
# ------------------------------------------------------------

request_mysql_root_password() {
    local attempts=0

    echo
    echo "============================================================"
    echo " AUTENTICACIÓN ROOT MYSQL"
    echo "============================================================"
    echo
    echo "El instalador necesita acceso administrativo a MySQL."
    echo "La contraseña no será guardada en el archivo de estado."
    echo "Tampoco será escrita deliberadamente en el log."
    echo

    while (( attempts < 3 )); do
        ((attempts++))

        MYSQL_ROOT_PASSWORD=""

        if ! read_password \
            "Ingrese la contraseña de root de MySQL"; then
            die "No fue posible leer la contraseña desde la terminal."
        fi

        if mysql_password_test "$MYSQL_ROOT_PASSWORD"; then
            MYSQL_AUTH_MODE="password"
            ok "Autenticación MySQL validada."
            return 0
        fi

        warn "La contraseña no fue aceptada."

        if (( attempts < 3 )); then
            echo "Intento ${attempts}/3."
        fi
    done

    error "No fue posible autenticar root de MySQL."

    if mysql_socket_test; then
        warn "MySQL permite autenticación mediante socket."
        warn "Se utilizará autenticación socket para continuar."
        MYSQL_ROOT_PASSWORD=""
        MYSQL_AUTH_MODE="socket"
        return 0
    fi

    die "No existe un método de autenticación válido para root de MySQL."
}

# ------------------------------------------------------------
# MYSQL EXEC
# ------------------------------------------------------------

mysql_exec() {
    if [[ "${MYSQL_AUTH_MODE}" == "password" ]]; then
        MYSQL_PWD="$MYSQL_ROOT_PASSWORD" \
            mysql \
            --protocol=socket \
            -uroot \
            "$@"
    else
        mysql \
            --protocol=socket \
            -uroot \
            "$@"
    fi
}

mysql_exec_quiet() {
    mysql_exec "$@" >/dev/null
}

# ------------------------------------------------------------
# SQL QUOTING
# ------------------------------------------------------------

sql_escape() {
    local value="$1"

    value="${value//\\/\\\\}"
    value="${value//\'/\'\'}"

    printf '%s' "$value"
}

# ------------------------------------------------------------
# GENERAR PASSWORD
# ------------------------------------------------------------

generate_password() {
    if command_exists openssl; then
        openssl rand -base64 32 |
            tr -dc 'A-Za-z0-9' |
            head -c 24
    else
        tr -dc 'A-Za-z0-9' </dev/urandom |
            head -c 24
    fi
}

# ------------------------------------------------------------
# LEER CONFIG EXISTENTE
# ------------------------------------------------------------

load_existing_db_config() {
    if [[ ! -f "$DB_CONFIG" ]]; then
        return 1
    fi

    # shellcheck disable=SC1090
    source "$DB_CONFIG"

    if [[ -n "${DB_NAME:-}" ]] &&
       [[ -n "${DB_USER:-}" ]] &&
       [[ -n "${DB_PASSWORD:-}" ]]; then
        return 0
    fi

    return 1
}

# ------------------------------------------------------------
# ETAPA 5 BASE DE DATOS
# ------------------------------------------------------------

step_5_database() {
    if is_done "5-database"; then
        info "Paso 5/10 ya completado."
        return
    fi

    step "[5/10] Configuración de base de datos"

    # --------------------------------------------------------
    # Autenticación
    # --------------------------------------------------------

    if mysql_socket_test; then
        info "Root MySQL permite autenticación mediante socket."

        if confirm "¿Desea ingresar igualmente la contraseña de root de MySQL?"; then
            request_mysql_root_password
        else
            MYSQL_AUTH_MODE="socket"
            MYSQL_ROOT_PASSWORD=""
        fi
    else
        request_mysql_root_password
    fi

    # --------------------------------------------------------
    # Si existe configuración anterior, reutilizarla
    # --------------------------------------------------------

    if load_existing_db_config; then
        echo
        info "Se encontró configuración existente:"
        echo "  Base de datos : ${DB_NAME}"
        echo "  Usuario       : ${DB_USER}"
        echo

        if confirm "¿Desea conservar esta configuración?"; then
            EXISTING_CONFIG="yes"
        else
            EXISTING_CONFIG="no"
        fi
    else
        EXISTING_CONFIG="no"
    fi

    # --------------------------------------------------------
    # Base de datos
    # --------------------------------------------------------

    if [[ "$EXISTING_CONFIG" != "yes" ]]; then

        local input_db=""

        read_input \
            "Nombre de la base de datos" \
            input_db \
            "${APP_DB_DEFAULT}"

        DB_NAME="$input_db"

        if [[ ! "$DB_NAME" =~ ^[A-Za-z0-9_]+$ ]]; then
            die "Nombre de base de datos inválido: ${DB_NAME}"
        fi

        local input_user=""

        read_input \
            "Usuario de aplicación MySQL" \
            input_user \
            "${APP_DB_USER_DEFAULT}"

        DB_USER="$input_user"

        if [[ ! "$DB_USER" =~ ^[A-Za-z0-9_]+$ ]]; then
            die "Nombre de usuario MySQL inválido: ${DB_USER}"
        fi

        # ----------------------------------------------------
        # Password aplicación
        # ----------------------------------------------------

        echo
        echo "Contraseña para el usuario '${DB_USER}'."
        echo "Puede dejarla vacía para generar una automáticamente."
        echo

        local app_password=""

        read_password \
            "Contraseña del usuario ${DB_USER}"

        app_password="$REPLY"

        # read_password utiliza variable explícita, así que:
        # si REPLY quedó vacío generamos.
        if [[ -z "$app_password" ]]; then
            DB_PASSWORD="$(generate_password)"
            info "Se generó automáticamente una contraseña segura."
        else
            DB_PASSWORD="$app_password"
        fi

        unset app_password
        unset REPLY

    else

        # La configuración existente ya cargó:
        # DB_NAME
        # DB_USER
        # DB_PASSWORD

        if [[ ! "$DB_NAME" =~ ^[A-Za-z0-9_]+$ ]]; then
            die "DB_NAME existente inválido."
        fi

        if [[ ! "$DB_USER" =~ ^[A-Za-z0-9_]+$ ]]; then
            die "DB_USER existente inválido."
        fi
    fi

    # --------------------------------------------------------
    # Comprobar base de datos
    # --------------------------------------------------------

    local escaped_db
    escaped_db="$(sql_escape "$DB_NAME")"

    local db_exists

    db_exists="$(
        mysql_exec \
            -N \
            -B \
            -e "SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME='${escaped_db}';"
    )"

    if [[ "$db_exists" == "$DB_NAME" ]]; then
        warn "La base de datos '${DB_NAME}' ya existe."
        warn "NO será eliminada ni recreada."
    else
        info "Creando base de datos '${DB_NAME}'..."

        mysql_exec \
            -e "CREATE DATABASE \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"

        ok "Base de datos creada."
    fi

    # --------------------------------------------------------
    # Usuario MySQL
    # --------------------------------------------------------

    local escaped_user
    local escaped_password

    escaped_user="$(sql_escape "$DB_USER")"
    escaped_password="$(sql_escape "$DB_PASSWORD")"

    local user_exists

    user_exists="$(
        mysql_exec \
            -N \
            -B \
            -e "SELECT User FROM mysql.user WHERE User='${escaped_user}' AND Host='localhost';"
    )"

    if [[ "$user_exists" == "$DB_USER" ]]; then

        info "El usuario '${DB_USER}' ya existe."

        mysql_exec \
            -e "ALTER USER '${escaped_user}'@'localhost' IDENTIFIED BY '${escaped_password}';"

    else

        info "Creando usuario '${DB_USER}'..."

        mysql_exec \
            -e "CREATE USER '${escaped_user}'@'localhost' IDENTIFIED BY '${escaped_password}';"
    fi

    # --------------------------------------------------------
    # Usuario también para 127.0.0.1
    # --------------------------------------------------------

    local user_ip_exists

    user_ip_exists="$(
        mysql_exec \
            -N \
            -B \
            -e "SELECT User FROM mysql.user WHERE User='${escaped_user}' AND Host='127.0.0.1';"
    )"

    if [[ "$user_ip_exists" == "$DB_USER" ]]; then

        mysql_exec \
            -e "ALTER USER '${escaped_user}'@'127.0.0.1' IDENTIFIED BY '${escaped_password}';"

    else

        mysql_exec \
            -e "CREATE USER '${escaped_user}'@'127.0.0.1' IDENTIFIED BY '${escaped_password}';"
    fi

    # --------------------------------------------------------
    # Privilegios
    # --------------------------------------------------------

    info "Asignando privilegios..."

    mysql_exec \
        -e "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${escaped_user}'@'localhost';"

    mysql_exec \
        -e "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${escaped_user}'@'127.0.0.1';"

    mysql_exec \
        -e "FLUSH PRIVILEGES;"

    # --------------------------------------------------------
    # Archivo de configuración
    # --------------------------------------------------------

    cat > "$DB_CONFIG" <<EOF
# PCCURICO Hosting Panel
# Generado automáticamente.
# NO compartir este archivo.

DB_HOST=127.0.0.1
DB_NAME=${DB_NAME}
DB_USER=${DB_USER}
DB_PASSWORD=${DB_PASSWORD}
EOF

    chmod 600 "$DB_CONFIG"

    ok "Configuración guardada en:"
    echo "  ${DB_CONFIG}"

    # No mostrar contraseña.
    echo
    info "La contraseña de la base de datos fue guardada con permisos 600."

    mark_done "5-database"
}

# ------------------------------------------------------------
# ETAPA 6 HERRAMIENTAS
# ------------------------------------------------------------

step_6_tools() {
    if is_done "6-tools"; then
        info "Paso 6/10 ya completado."
        return
    fi

    step "[6/10] Herramientas del sistema"

    apt_update_once

    apt_install \
        build-essential \
        pkg-config \
        software-properties-common \
        ca-certificates \
        gnupg \
        lsb-release \
        acl \
        tree \
        jq \
        cron \
        logrotate

    systemctl enable cron >/dev/null 2>&1 || true
    systemctl start cron >/dev/null 2>&1 || true

    ok "Herramientas instaladas."

    mark_done "6-tools"
}

# ------------------------------------------------------------
# ETAPA 7 NODE.JS
# ------------------------------------------------------------

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
        apt_update_once

        apt_install nodejs npm

        if command_exists node; then
            ok "Node.js instalado: $(node --version)"
        fi

        if command_exists npm; then
            ok "npm instalado: $(npm --version)"
        fi
    fi

    mark_done "7-node"
}

# ------------------------------------------------------------
# ETAPA 8 OLLAMA
# ------------------------------------------------------------

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
        info "Instalando Ollama..."

        local tmp_ollama
        tmp_ollama="$(mktemp)"

        curl -fsSL https://ollama.com/install.sh -o "$tmp_ollama"

        if [[ ! -s "$tmp_ollama" ]]; then
            rm -f "$tmp_ollama"
            die "No fue posible descargar el instalador de Ollama."
        fi

        sh "$tmp_ollama"

        rm -f "$tmp_ollama"

        if command_exists ollama; then
            ok "Ollama instalado."
        else
            warn "Ollama no quedó disponible inmediatamente."
        fi
    fi

    if systemctl list-unit-files 2>/dev/null |
        grep -q '^ollama.service'; then

        systemctl enable ollama >/dev/null 2>&1 || true
        systemctl start ollama >/dev/null 2>&1 || true

        if systemctl is-active --quiet ollama; then
            ok "Servicio Ollama activo."
        else
            warn "Ollama está instalado pero el servicio no está activo."
        fi
    fi

    mark_done "8-ollama"
}

# ------------------------------------------------------------
# ETAPA 9 SEGURIDAD
# ------------------------------------------------------------

step_9_security() {
    if is_done "9-security"; then
        info "Paso 9/10 ya completado."
        return
    fi

    step "[9/10] Seguridad básica"

    apt_update_once

    apt_install fail2ban

    systemctl enable fail2ban >/dev/null 2>&1 || true
    systemctl start fail2ban >/dev/null 2>&1 || true

    if systemctl is-active --quiet fail2ban; then
        ok "Fail2ban activo."
    else
        warn "Fail2ban fue instalado pero no está activo."
    fi

    # --------------------------------------------------------
    # NO activar UFW automáticamente.
    #
    # Esto evita cortar SSH si el usuario no tiene las reglas
    # configuradas.
    # --------------------------------------------------------

    info "UFW no será activado automáticamente para evitar bloquear SSH."

    mark_done "9-security"
}

# ------------------------------------------------------------
# ETAPA 10 VERIFICACIÓN
# ------------------------------------------------------------

step_10_verification() {
    if is_done "10-verification"; then
        info "Paso 10/10 ya completado."
        return
    fi

    step "[10/10] Verificación final"

    local errors=0

    echo
    echo "---- SISTEMA ----"

    if command_exists apache2; then
        echo "[OK] Apache2 instalado"
    else
        echo "[ERROR] Apache2 no encontrado"
        ((errors++))
    fi

    if systemctl is-active --quiet apache2; then
        echo "[OK] Apache2 activo"
    else
        echo "[ERROR] Apache2 inactivo"
        ((errors++))
    fi

    if command_exists php; then
        echo "[OK] PHP $(php -r 'echo PHP_VERSION;')"
    else
        echo "[ERROR] PHP no encontrado"
        ((errors++))
    fi

    if command_exists mysql; then
        echo "[OK] Cliente MySQL disponible"
    else
        echo "[ERROR] Cliente MySQL no encontrado"
        ((errors++))
    fi

    echo
    echo "---- BASE DE DATOS ----"

    if [[ -f "$DB_CONFIG" ]]; then
        echo "[OK] Configuración: $DB_CONFIG"

        # shellcheck disable=SC1090
        source "$DB_CONFIG"

        if [[ -n "${DB_NAME:-}" ]] &&
           [[ -n "${DB_USER:-}" ]]; then

            echo "[OK] Base: ${DB_NAME}"
            echo "[OK] Usuario: ${DB_USER}"
        else
            echo "[ERROR] Configuración incompleta"
            ((errors++))
        fi
    else
        echo "[ERROR] No existe $DB_CONFIG"
        ((errors++))
    fi

    echo
    echo "---- NODE ----"

    if command_exists node; then
        echo "[OK] Node.js $(node --version)"
    else
        echo "[AVISO] Node.js no disponible"
    fi

    echo
    echo "---- OLLAMA ----"

    if command_exists ollama; then
        echo "[OK] Ollama instalado"
    else
        echo "[AVISO] Ollama no disponible"
    fi

    echo
    echo "---- FAIL2BAN ----"

    if systemctl is-active --quiet fail2ban; then
        echo "[OK] Fail2ban activo"
    else
        echo "[AVISO] Fail2ban inactivo"
    fi

    echo

    if (( errors > 0 )); then
        warn "La verificación terminó con ${errors} problema(s)."
        return 1
    fi

    ok "Verificación final completada."

    mark_done "10-verification"
}

# ------------------------------------------------------------
# INSTALACIÓN COMPLETA
# ------------------------------------------------------------

install_all() {
    step "PCCURICO HOSTING PANEL"
    echo "Instalador ${VERSION}"
    echo
    echo "El instalador es re-ejecutable."
    echo "Las etapas completadas serán omitidas."
    echo "Las bases de datos existentes NO serán eliminadas."
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

# ------------------------------------------------------------
# REANUDAR DESDE 5
# ------------------------------------------------------------

resume_from_5() {
    step "REANUDANDO INSTALACIÓN DESDE 5/10"

    echo
    echo "Los pasos 1 a 4 NO serán reinstalados."
    echo "Se verificará que Apache, PHP y MySQL estén disponibles."
    echo

    # --------------------------------------------------------
    # Verificación previa
    # --------------------------------------------------------

    if ! command_exists apache2; then
        die "Apache2 no está instalado. No se puede reanudar desde 5/10."
    fi

    if ! command_exists php; then
        die "PHP no está instalado. No se puede reanudar desde 5/10."
    fi

    if ! command_exists mysql; then
        die "MySQL/MariaDB no está instalado. No se puede reanudar desde 5/10."
    fi

    if ! systemctl is-active --quiet apache2; then
        warn "Apache2 no está activo. Intentando iniciarlo..."
        systemctl start apache2
    fi

    local service
    service="$(mysql_service_name)"

    if [[ -z "$service" ]]; then
        die "No se encontró MySQL/MariaDB."
    fi

    if ! systemctl is-active --quiet "$service"; then
        warn "${service} no está activo. Intentando iniciarlo..."
        systemctl start "$service"
    fi

    mark_done "1-base"
    mark_done "2-apache"
    mark_done "3-php"
    mark_done "4-mysql"

    step_5_database
    step_6_tools
    step_7_node
    step_8_ollama
    step_9_security
    step_10_verification

    final_message
}

# ------------------------------------------------------------
# DIAGNÓSTICO MYSQL
# ------------------------------------------------------------

mysql_diagnostic() {
    step "DIAGNÓSTICO MYSQL / MARIADB"

    echo
    echo "---- CLIENTE ----"

    if command_exists mysql; then
        echo "[OK] Cliente:"
        mysql --version
    else
        echo "[ERROR] mysql no encontrado."
    fi

    echo
    echo "---- SERVICIO ----"

    local service
    service="$(mysql_service_name)"

    if [[ -n "$service" ]]; then
        echo "Servicio detectado: ${service}"
        systemctl --no-pager --full status "$service" || true
    else
        echo "No se encontró servicio mysql/mariadb."
    fi

    echo
    echo "---- AUTENTICACIÓN SOCKET ----"

    if mysql_socket_test; then
        echo "[OK] root puede autenticarse mediante socket."
    else
        echo "[AVISO] root no puede autenticarse mediante socket sin contraseña."
    fi

    echo
    echo "---- CONFIGURACIÓN PCCURICO ----"

    if [[ -f "$DB_CONFIG" ]]; then
        echo "[OK] Existe ${DB_CONFIG}"
        echo "No se mostrará su contraseña."

        if grep -q '^DB_NAME=' "$DB_CONFIG"; then
            grep '^DB_NAME=' "$DB_CONFIG"
        fi

        if grep -q '^DB_USER=' "$DB_CONFIG"; then
            grep '^DB_USER=' "$DB_CONFIG"
        fi

        if grep -q '^DB_HOST=' "$DB_CONFIG"; then
            grep '^DB_HOST=' "$DB_CONFIG"
        fi
    else
        echo "[AVISO] No existe ${DB_CONFIG}"
    fi
}

# ------------------------------------------------------------
# VER LOG
# ------------------------------------------------------------

show_log() {
    step "LOG DEL INSTALADOR"

    if [[ ! -f "$LOG_FILE" ]]; then
        warn "No existe todavía el log."
        return
    fi

    echo
    tail -n 100 "$LOG_FILE"
}

# ------------------------------------------------------------
# FINAL
# ------------------------------------------------------------

final_message() {
    step "INSTALACIÓN / CONFIGURACIÓN FINALIZADA"

    echo
    echo "PCCURICO Hosting Panel"
    echo
    echo "Estado:"
    echo "  ${STATE_FILE}"
    echo
    echo "Configuración DB:"
    echo "  ${DB_CONFIG}"
    echo
    echo "Log:"
    echo "  ${LOG_FILE}"
    echo

    if [[ -f "$DB_CONFIG" ]]; then
        echo "Base de datos configurada correctamente."
    fi

    echo
    ok "Proceso finalizado."
}

# ------------------------------------------------------------
# MENÚ
# ------------------------------------------------------------

menu() {
    while true; do

        echo
        echo "============================================================"
        echo "       PCCURICO HOSTING PANEL - INSTALADOR"
        echo "============================================================"
        echo
        echo "Versión: ${VERSION}"
        echo
        echo "1) Instalación completa / continuar"
        echo "2) Reanudar desde 5/10"
        echo "3) Estado"
        echo "4) Diagnóstico MySQL"
        echo "5) Ver log"
        echo "0) Salir"
        echo

        local option=""

        if ! read -r -p "Seleccione una opción: " option </dev/tty; then
            error "No se pudo leer la opción desde /dev/tty."
            error "Compruebe que está ejecutando el instalador desde una terminal."
            exit 1
        fi

        case "$option" in

            1)
                install_all
                ;;

            2)
                resume_from_5
                ;;

            3)
                show_status
                ;;

            4)
                mysql_diagnostic
                ;;

            5)
                show_log
                ;;

            0)
                echo
                info "Instalador finalizado por el usuario."
                exit 0
                ;;

            *)
                warn "Opción no válida."
                ;;
        esac
    done
}

# ------------------------------------------------------------
# ARGUMENTOS
# ------------------------------------------------------------

usage() {
    cat <<EOF

PCCURICO Hosting Panel Installer ${VERSION}

Uso:

  curl -fsSL URL | sudo bash

  sudo bash ${SCRIPT_NAME}

Opciones:

  --install
      Instalación completa / continuar

  --resume-5
      Reanudar directamente desde 5/10

  --status
      Mostrar estado

  --mysql
      Diagnóstico MySQL/MariaDB

  --log
      Mostrar log

  --help
      Mostrar ayuda

EOF
}

# ------------------------------------------------------------
# MAIN
# ------------------------------------------------------------

main() {

    require_root

    # Crear directorios nuevamente por seguridad.
    mkdir -p "$STATE_DIR" "$LOG_DIR" "$CONFIG_DIR"

    chmod 700 "$STATE_DIR"
    chmod 700 "$CONFIG_DIR"
    chmod 750 "$LOG_DIR"

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
            menu
            ;;

        *)
            error "Opción desconocida: $1"
            usage
            exit 1
            ;;
    esac
}

main "$@"
