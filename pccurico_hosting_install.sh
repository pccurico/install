#!/usr/bin/env bash

# ============================================================
# PCCURICO HOSTING SERVER
# Ubuntu Server 24.04.x
#
# Instalación LAMP + herramientas base
# Reanudable: detecta componentes ya instalados.
#
# NO elimina bases de datos existentes.
# NO almacena la contraseña MySQL en disco.
# ============================================================

set -Eeuo pipefail

SCRIPT_NAME="PCCURICO Hosting Installer"
SCRIPT_VERSION="1.0.0"

STATE_DIR="/var/lib/pccurico-installer"
STATE_FILE="${STATE_DIR}/state"
LOG_DIR="/var/log/pccurico"
LOG_FILE="${LOG_DIR}/installer.log"

MYSQL_ROOT_PASSWORD=""

# ------------------------------------------------------------
# COLORES
# ------------------------------------------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

# ------------------------------------------------------------
# FUNCIONES BÁSICAS
# ------------------------------------------------------------

info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

ok() {
    echo -e "${GREEN}[OK]${NC} $*"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

step() {
    echo
    echo -e "${CYAN}============================================================${NC}"
    echo -e "${WHITE}$*${NC}"
    echo -e "${CYAN}============================================================${NC}"
}

die() {
    error "$*"
    exit 1
}

# ------------------------------------------------------------
# LOG
# ------------------------------------------------------------

prepare_logging() {
    mkdir -p "$LOG_DIR"
    touch "$LOG_FILE"
    chmod 600 "$LOG_FILE"

    exec > >(tee -a "$LOG_FILE") 2>&1
}

# ------------------------------------------------------------
# MANEJO DE ERRORES
# ------------------------------------------------------------

on_error() {
    local line="$1"
    local command="$2"

    error "Error en línea ${line}."
    error "Comando: ${command}"
    error "La instalación se detuvo para evitar daños."

    echo
    echo "El estado anterior se conserva."
    echo "Puedes volver a ejecutar el instalador."
    echo
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
# ESTADO
# ------------------------------------------------------------

prepare_state() {
    mkdir -p "$STATE_DIR"

    touch "$STATE_FILE"

    chmod 700 "$STATE_DIR"
    chmod 600 "$STATE_FILE"
}

is_done() {
    local stage="$1"

    grep -qxF "$stage" "$STATE_FILE" 2>/dev/null
}

mark_done() {
    local stage="$1"

    if ! is_done "$stage"; then
        echo "$stage" >> "$STATE_FILE"
    fi
}

show_state() {
    echo
    echo "Estado actual:"

    if [[ ! -s "$STATE_FILE" ]]; then
        echo "  Ningún paso registrado."
        return
    fi

    cat "$STATE_FILE"
}

# ------------------------------------------------------------
# SISTEMA
# ------------------------------------------------------------

check_os() {
    if [[ ! -f /etc/os-release ]]; then
        die "No se pudo identificar el sistema operativo."
    fi

    source /etc/os-release

    info "Sistema: ${PRETTY_NAME}"

    if [[ "${ID}" != "ubuntu" ]]; then
        warn "Este instalador fue diseñado para Ubuntu."
    fi
}

# ------------------------------------------------------------
# APT
# ------------------------------------------------------------

apt_update() {

    if [[ -f "${STATE_DIR}/apt-update.done" ]]; then
        ok "APT ya fue actualizado anteriormente."
        return
    fi

    info "Actualizando repositorios..."

    export DEBIAN_FRONTEND=noninteractive

    apt-get update

    touch "${STATE_DIR}/apt-update.done"

    ok "Repositorios actualizados."
}

apt_install() {

    export DEBIAN_FRONTEND=noninteractive

    apt-get install -y "$@"
}

# ------------------------------------------------------------
# PASO 1
# ------------------------------------------------------------

step_1_base() {

    if is_done "1-base"; then
        ok "[1/10] Base del sistema ya configurada. Omitiendo."
        return
    fi

    step "[1/10] Preparando sistema base"

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
        ufw

    mark_done "1-base"

    ok "[1/10] Sistema base preparado."
}

# ------------------------------------------------------------
# PASO 2
# ------------------------------------------------------------

step_2_apache() {

    if is_done "2-apache" && systemctl is-active --quiet apache2; then
        ok "[2/10] Apache ya está instalado y operativo. Omitiendo."
        return
    fi

    step "[2/10] Instalando/verificando Apache"

    if ! command -v apache2 >/dev/null 2>&1; then
        info "Apache no está instalado."
        apt_install apache2
    else
        ok "Apache ya está instalado."
    fi

    systemctl enable apache2
    systemctl start apache2

    if ! systemctl is-active --quiet apache2; then
        error "Apache no pudo iniciarse."
        systemctl status apache2 --no-pager || true
        return 1
    fi

    mark_done "2-apache"

    ok "[2/10] Apache operativo."
}

# ------------------------------------------------------------
# PASO 3
# ------------------------------------------------------------

step_3_php() {

    if is_done "3-php" && command -v php >/dev/null 2>&1; then
        ok "[3/10] PHP ya está instalado. Omitiendo."
        return
    fi

    step "[3/10] Instalando/verificando PHP"

    if ! command -v php >/dev/null 2>&1; then

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

    else
        ok "PHP ya está instalado."
    fi

    PHP_VERSION="$(php -r 'echo PHP_VERSION;' 2>/dev/null || true)"

    if [[ -z "$PHP_VERSION" ]]; then
        error "PHP no responde correctamente."
        return 1
    fi

    ok "PHP ${PHP_VERSION}"

    # Habilitar FPM si existe
    if systemctl list-unit-files | grep -q '^php.*-fpm.service'; then

        PHP_FPM_SERVICE="$(systemctl list-unit-files \
            | awk '/^php[0-9.]+-fpm\.service/ {print $1; exit}')"

        if [[ -n "${PHP_FPM_SERVICE:-}" ]]; then
            systemctl enable "$PHP_FPM_SERVICE"
            systemctl start "$PHP_FPM_SERVICE" || true
        fi
    fi

    systemctl reload apache2 || true

    mark_done "3-php"

    ok "[3/10] PHP operativo."
}

# ------------------------------------------------------------
# PASO 4
# ------------------------------------------------------------

step_4_mysql_server() {

    if is_done "4-mysql-server"; then

        if systemctl is-active --quiet mysql 2>/dev/null ||
           systemctl is-active --quiet mariadb 2>/dev/null; then

            ok "[4/10] MySQL/MariaDB ya está operativo. Omitiendo."
            return
        fi
    fi

    step "[4/10] Instalando/verificando MySQL"

    if command -v mysql >/dev/null 2>&1; then
        ok "Cliente MySQL ya está instalado."
    else
        apt_install mysql-server mysql-client
    fi

    if systemctl list-unit-files | grep -q '^mysql.service'; then
        systemctl enable mysql
        systemctl start mysql
    elif systemctl list-unit-files | grep -q '^mariadb.service'; then
        systemctl enable mariadb
        systemctl start mariadb
    fi

    if systemctl is-active --quiet mysql 2>/dev/null ||
       systemctl is-active --quiet mariadb 2>/dev/null; then

        ok "Servidor MySQL/MariaDB operativo."

    else

        error "MySQL/MariaDB no está ejecutándose."
        return 1

    fi

    mark_done "4-mysql-server"

    ok "[4/10] MySQL preparado."
}

# ------------------------------------------------------------
# MYSQL - AUTENTICACIÓN
# ------------------------------------------------------------

mysql_socket_test() {

    if mysql --protocol=socket -uroot -e "SELECT 1;" >/dev/null 2>&1; then
        return 0
    fi

    return 1
}

mysql_password_test() {

    if [[ -z "${MYSQL_ROOT_PASSWORD:-}" ]]; then
        return 1
    fi

    MYSQL_PWD="${MYSQL_ROOT_PASSWORD}" \
        mysql --protocol=socket -uroot -e "SELECT 1;" \
        >/dev/null 2>&1
}

mysql_exec() {

    if [[ -n "${MYSQL_ROOT_PASSWORD:-}" ]]; then

        MYSQL_PWD="${MYSQL_ROOT_PASSWORD}" \
            mysql --protocol=socket -uroot "$@"

    else

        mysql --protocol=socket -uroot "$@"

    fi
}

# ------------------------------------------------------------
# SOLICITAR PASSWORD
# ------------------------------------------------------------

request_mysql_password() {

    echo
    echo -e "${WHITE}Autenticación de MySQL${NC}"
    echo

    echo "El instalador necesita acceso administrativo a MySQL."
    echo "La contraseña NO será guardada en disco."
    echo

    while true; do

        read -r -s -p "Contraseña de root de MySQL: " MYSQL_ROOT_PASSWORD
        echo

        if [[ -z "$MYSQL_ROOT_PASSWORD" ]]; then
            warn "La contraseña no puede estar vacía."
            continue
        fi

        info "Probando credenciales..."

        if mysql_password_test; then
            ok "Credenciales MySQL verificadas."
            break
        fi

        error "La contraseña no permitió acceder como root."
        echo
        echo "También puede ocurrir que MySQL use autenticación unix_socket."
        echo "Se probará automáticamente el acceso mediante sudo/socket."
        echo

        if mysql_socket_test; then
            ok "Acceso administrativo mediante socket disponible."
            MYSQL_ROOT_PASSWORD=""
            break
        fi

        read -r -p "¿Desea volver a ingresar la contraseña? [S/n]: " retry

        case "${retry,,}" in
            n|no)
                return 1
                ;;
        esac
    done
}

# ------------------------------------------------------------
# PASO 5
# ------------------------------------------------------------

step_5_database() {

    if is_done "5-database"; then
        ok "[5/10] Base de datos ya configurada. Omitiendo."
        return
    fi

    step "[5/10] Configurando acceso y base de datos MySQL"

    # --------------------------------------------------------
    # Primero intentamos socket sin contraseña.
    # --------------------------------------------------------

    if mysql_socket_test; then

        ok "Root MySQL funciona mediante autenticación socket."

        MYSQL_ROOT_PASSWORD=""

    else

        info "Se requiere contraseña de root de MySQL."

        if ! request_mysql_password; then
            error "No fue posible autenticar contra MySQL."
            return 1
        fi

    fi

    # --------------------------------------------------------
    # Determinar base de datos
    # --------------------------------------------------------

    local DB_NAME="${PCCURICO_DB_NAME:-pccurico}"

    read -r -p "Nombre de la base de datos [${DB_NAME}]: " INPUT_DB

    if [[ -n "$INPUT_DB" ]]; then
        DB_NAME="$INPUT_DB"
    fi

    # Validación
    if [[ ! "$DB_NAME" =~ ^[a-zA-Z0-9_]+$ ]]; then
        error "Nombre de base de datos inválido: $DB_NAME"
        return 1
    fi

    info "Comprobando base de datos '${DB_NAME}'..."

    local DB_EXISTS

    DB_EXISTS="$(
        mysql_exec -Nse \
        "SELECT COUNT(*) FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME='${DB_NAME}';"
    )"

    if [[ "$DB_EXISTS" == "1" ]]; then

        ok "La base de datos '${DB_NAME}' ya existe."
        warn "NO será eliminada ni recreada."

    else

        info "Creando base de datos '${DB_NAME}'..."

        mysql_exec <<SQL
CREATE DATABASE \`${DB_NAME}\`
CHARACTER SET utf8mb4
COLLATE utf8mb4_unicode_ci;
SQL

        ok "Base de datos creada."
    fi

    # --------------------------------------------------------
    # Crear usuario de aplicación
    # --------------------------------------------------------

    local APP_DB_USER="${PCCURICO_DB_USER:-pccurico}"

    read -r -p "Usuario MySQL de la aplicación [${APP_DB_USER}]: " INPUT_USER

    if [[ -n "$INPUT_USER" ]]; then
        APP_DB_USER="$INPUT_USER"
    fi

    if [[ ! "$APP_DB_USER" =~ ^[a-zA-Z0-9_]+$ ]]; then
        error "Usuario MySQL inválido."
        return 1
    fi

    local APP_DB_PASSWORD=""

    read -r -s -p \
        "Contraseña para usuario ${APP_DB_USER} [ENTER = generar automáticamente]: " \
        APP_DB_PASSWORD
    echo

    if [[ -z "$APP_DB_PASSWORD" ]]; then

        APP_DB_PASSWORD="$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 24)"

        echo
        echo -e "${YELLOW}Contraseña generada:${NC}"
        echo "$APP_DB_PASSWORD"
        echo

    fi

    # --------------------------------------------------------
    # Crear usuario sin destruir si ya existe
    # --------------------------------------------------------

    info "Configurando usuario MySQL '${APP_DB_USER}'..."

    mysql_exec <<SQL
CREATE USER IF NOT EXISTS '${APP_DB_USER}'@'localhost'
IDENTIFIED BY '${APP_DB_PASSWORD}';

ALTER USER '${APP_DB_USER}'@'localhost'
IDENTIFIED BY '${APP_DB_PASSWORD}';

GRANT ALL PRIVILEGES
ON \`${DB_NAME}\`.*
TO '${APP_DB_USER}'@'localhost';

FLUSH PRIVILEGES;
SQL

    ok "Usuario MySQL configurado."

    # --------------------------------------------------------
    # Guardar SOLO configuración no sensible
    # --------------------------------------------------------

    mkdir -p /etc/pccurico

    cat > /etc/pccurico/database.conf <<EOF
DB_HOST=127.0.0.1
DB_NAME=${DB_NAME}
DB_USER=${APP_DB_USER}
DB_PASSWORD=${APP_DB_PASSWORD}
EOF

    chmod 600 /etc/pccurico/database.conf

    ok "Configuración de aplicación creada."

    mark_done "5-database"

    ok "[5/10] Base de datos lista."
}

# ------------------------------------------------------------
# PASO 6
# ------------------------------------------------------------

step_6_tools() {

    if is_done "6-tools"; then
        ok "[6/10] Herramientas base ya instaladas. Omitiendo."
        return
    fi

    step "[6/10] Instalando herramientas de servidor"

    apt_install \
        unzip \
        zip \
        git \
        curl \
        wget \
        ca-certificates \
        rsync

    mark_done "6-tools"

    ok "[6/10] Herramientas instaladas."
}

# ------------------------------------------------------------
# PASO 7
# ------------------------------------------------------------

step_7_node() {

    if is_done "7-node"; then
        ok "[7/10] Node.js ya configurado. Omitiendo."
        return
    fi

    step "[7/10] Verificando Node.js"

    if command -v node >/dev/null 2>&1; then

        ok "Node.js $(node --version)"

    else

        info "Instalando Node.js desde repositorio Ubuntu..."

        apt_install nodejs npm

        ok "Node.js $(node --version)"
    fi

    mark_done "7-node"

    ok "[7/10] Node.js listo."
}

# ------------------------------------------------------------
# PASO 8
# ------------------------------------------------------------

step_8_ollama() {

    if is_done "8-ollama"; then
        ok "[8/10] Ollama ya configurado. Omitiendo."
        return
    fi

    step "[8/10] Instalando/verificando Ollama"

    if command -v ollama >/dev/null 2>&1; then

        ok "Ollama ya está instalado."

    else

        info "Instalando Ollama..."

        curl -fsSL https://ollama.com/install.sh | sh
    fi

    if systemctl list-unit-files | grep -q '^ollama.service'; then
        systemctl enable ollama
        systemctl start ollama
    fi

    if command -v ollama >/dev/null 2>&1; then
        ok "Ollama $(ollama --version 2>/dev/null || true)"
    else
        warn "Ollama fue instalado pero no se pudo verificar."
    fi

    mark_done "8-ollama"

    ok "[8/10] Ollama listo."
}

# ------------------------------------------------------------
# PASO 9
# ------------------------------------------------------------

step_9_security() {

    if is_done "9-security"; then
        ok "[9/10] Seguridad básica ya configurada. Omitiendo."
        return
    fi

    step "[9/10] Configurando seguridad básica"

    apt_install fail2ban

    systemctl enable fail2ban
    systemctl start fail2ban

    # SSH
    if systemctl is-active --quiet ssh; then
        ok "SSH operativo."
    fi

    # UFW
    if command -v ufw >/dev/null 2>&1; then

        ufw allow OpenSSH >/dev/null 2>&1 || true
        ufw allow 80/tcp >/dev/null 2>&1 || true
        ufw allow 443/tcp >/dev/null 2>&1 || true

        # No activar automáticamente si existe riesgo de perder
        # acceso remoto.
        warn "UFW instalado. No se activa automáticamente."
    fi

    mark_done "9-security"

    ok "[9/10] Seguridad básica preparada."
}

# ------------------------------------------------------------
# PASO 10
# ------------------------------------------------------------

step_10_final() {

    if is_done "10-final"; then
        ok "[10/10] Instalación finalizada anteriormente. Omitiendo."
        return
    fi

    step "[10/10] Verificación final"

    echo

    echo "===== SERVICIOS ====="

    if systemctl is-active --quiet apache2; then
        ok "Apache: OK"
    else
        warn "Apache: NO ACTIVO"
    fi

    if systemctl is-active --quiet mysql 2>/dev/null ||
       systemctl is-active --quiet mariadb 2>/dev/null; then
        ok "MySQL/MariaDB: OK"
    else
        warn "MySQL/MariaDB: NO ACTIVO"
    fi

    if command -v php >/dev/null 2>&1; then
        ok "PHP: $(php -r 'echo PHP_VERSION;')"
    else
        warn "PHP: NO DISPONIBLE"
    fi

    if command -v node >/dev/null 2>&1; then
        ok "Node.js: $(node --version)"
    fi

    if command -v ollama >/dev/null 2>&1; then
        ok "Ollama: instalado"
    fi

    echo
    echo "===== CONFIGURACIÓN MYSQL ====="

    if [[ -f /etc/pccurico/database.conf ]]; then
        echo "Archivo: /etc/pccurico/database.conf"
        echo "Permisos: $(stat -c '%A' /etc/pccurico/database.conf)"
    fi

    echo
    echo "===== ESTADO ====="

    show_state

    mark_done "10-final"

    ok "[10/10] Instalación completada."
}

# ------------------------------------------------------------
# LIMPIEZA
# ------------------------------------------------------------

cleanup() {

    unset MYSQL_ROOT_PASSWORD

}

trap cleanup EXIT

# ------------------------------------------------------------
# INSTALACIÓN COMPLETA
# ------------------------------------------------------------

full_install() {

    step "PCCURICO HOSTING SERVER"
    echo "Instalador ${SCRIPT_VERSION}"
    echo

    info "Modo reanudable activado."
    info "Los pasos ya completados serán omitidos."
    info "Las bases de datos existentes NO serán eliminadas."
    echo

    step_1_base
    step_2_apache
    step_3_php
    step_4_mysql_server
    step_5_database
    step_6_tools
    step_7_node
    step_8_ollama
    step_9_security
    step_10_final

    echo
    echo -e "${GREEN}============================================================${NC}"
    echo -e "${GREEN}     PCCURICO HOSTING SERVER INSTALADO${NC}"
    echo -e "${GREEN}============================================================${NC}"
    echo

    ok "La instalación puede volver a ejecutarse sin repetir"
    ok "los pasos que ya están registrados como completos."

    echo
    echo "Log:"
    echo "$LOG_FILE"

    echo
    echo "Estado:"
    echo "$STATE_FILE"
}

# ------------------------------------------------------------
# REANUDAR ESPECÍFICAMENTE DESDE 5
# ------------------------------------------------------------

resume_from_5() {

    step "[REANUDACIÓN] Continuando desde el paso 5/10"

    info "Los pasos 1 al 4 NO serán ejecutados."
    info "Se asumirá que están completados."
    echo

    # Registrar solamente si realmente están operativos.
    if systemctl is-active --quiet apache2; then
        mark_done "2-apache"
    fi

    if command -v php >/dev/null 2>&1; then
        mark_done "3-php"
    fi

    if systemctl is-active --quiet mysql 2>/dev/null ||
       systemctl is-active --quiet mariadb 2>/dev/null; then
        mark_done "4-mysql-server"
    fi

    step_5_database
    step_6_tools
    step_7_node
    step_8_ollama
    step_9_security
    step_10_final
}

# ------------------------------------------------------------
# ESTADO
# ------------------------------------------------------------

status() {

    step "ESTADO PCCURICO HOSTING"

    echo

    echo "Sistema:"
    hostnamectl 2>/dev/null | grep -E 'Operating System|Kernel' || true

    echo
    echo "Apache:"
    systemctl is-active apache2 2>/dev/null || true

    echo
    echo "MySQL:"
    systemctl is-active mysql 2>/dev/null || \
    systemctl is-active mariadb 2>/dev/null || true

    echo
    echo "PHP:"
    php --version 2>/dev/null | head -1 || true

    echo
    echo "Node:"
    node --version 2>/dev/null || true

    echo
    echo "Ollama:"
    ollama --version 2>/dev/null || true

    echo
    echo "Estado instalación:"
    show_state
}

# ------------------------------------------------------------
# DIAGNÓSTICO MYSQL
# ------------------------------------------------------------

diagnose_mysql() {

    step "DIAGNÓSTICO MYSQL"

    echo "Versión:"
    mysql --version 2>/dev/null || true

    echo
    echo "Servicio:"

    systemctl status mysql --no-pager 2>/dev/null || \
    systemctl status mariadb --no-pager 2>/dev/null || true

    echo
    echo "Root mediante socket:"

    if mysql_socket_test; then
        ok "ROOT funciona mediante socket."
    else
        warn "ROOT no funciona mediante socket sin contraseña."
    fi

    echo
    echo "Usuarios root:"

    if mysql_socket_test; then
        mysql --protocol=socket -uroot -e \
            "SELECT User,Host,plugin FROM mysql.user WHERE User='root';"
    else
        warn "No se puede consultar mysql.user sin autenticación."
    fi
}

# ------------------------------------------------------------
# MENU
# ------------------------------------------------------------

menu() {

    while true; do

        clear || true

        echo
        echo -e "${CYAN}============================================================${NC}"
        echo -e "${WHITE}          PCCURICO HOSTING SERVER${NC}"
        echo -e "${CYAN}============================================================${NC}"
        echo
        echo "1) Instalación completa / continuar"
        echo "2) Reanudar desde 5/10"
        echo "3) Estado"
        echo "4) Diagnóstico MySQL"
        echo "5) Ver log"
        echo "0) Salir"
        echo

        read -r -p "Seleccione una opción: " OPTION

        case "$OPTION" in

            1)
                full_install
                ;;

            2)
                resume_from_5
                ;;

            3)
                status
                ;;

            4)
                diagnose_mysql
                ;;

            5)
                less "$LOG_FILE" 2>/dev/null || cat "$LOG_FILE"
                ;;

            0)
                exit 0
                ;;

            *)
                warn "Opción inválida."
                ;;

        esac

        echo
        read -r -p "Presione ENTER para continuar..." _
    done
}

# ------------------------------------------------------------
# ARGUMENTOS
# ------------------------------------------------------------

main() {

    require_root
    prepare_logging
    prepare_state
    check_os

    case "${1:-}" in

        --install)
            full_install
            ;;

        --resume-5)
            resume_from_5
            ;;

        --status)
            status
            ;;

        --mysql)
            diagnose_mysql
            ;;

        --help|-h)
            echo
            echo "${SCRIPT_NAME} ${SCRIPT_VERSION}"
            echo
            echo "Uso:"
            echo "  sudo bash $0"
            echo "  sudo bash $0 --install"
            echo "  sudo bash $0 --resume-5"
            echo "  sudo bash $0 --status"
            echo "  sudo bash $0 --mysql"
            echo
            ;;

        *)
            menu
            ;;

    esac
}

main "$@"
