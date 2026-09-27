#!/usr/bin/env bash

set -Eeuo pipefail

APP_NAME="PCCURICO Hosting Panel"
APP_VERSION="1.0.0"

APP_ROOT="/var/www/pccurico-hosting-panel"
APP_PUBLIC="${APP_ROOT}/public"

CONFIG_DIR="/etc/pccurico/hosting-panel"
STATE_DIR="/var/lib/pccurico-hosting"
LOG_DIR="/var/log/pccurico"

DB_CONFIG="/etc/pccurico/database.conf"

LOG_FILE="${LOG_DIR}/panel_deploy.log"

REPOSITORY_URL="${PCCURICO_PANEL_REPOSITORY:-}"

GREEN="\033[0;32m"
YELLOW="\033[1;33m"
RED="\033[0;31m"
CYAN="\033[0;36m"
RESET="\033[0m"

info() {
    printf "${CYAN}[INFO]${RESET} %s\n" "$*"
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

fail() {
    error "$*"
    exit 1
}

if [[ "${EUID}" -ne 0 ]]; then
    fail "Este script debe ejecutarse como root."
fi

mkdir -p "$LOG_DIR"
touch "$LOG_FILE"
chmod 640 "$LOG_FILE"

exec > >(tee -a "$LOG_FILE") 2>&1

echo ""
echo "============================================================"
echo " PCCURICO HOSTING PANEL"
echo " Despliegue ${APP_VERSION}"
echo "============================================================"
echo ""

info "Servidor: $(hostname)"

if [[ ! -f /etc/os-release ]]; then
    fail "No se pudo determinar el sistema operativo."
fi

source /etc/os-release

if [[ "$ID" != "ubuntu" ]]; then
    fail "Este panel está preparado para Ubuntu."
fi

info "Sistema: ${PRETTY_NAME}"

echo ""
echo "============================================================"
echo "1. COMPROBACIÓN DEL SERVIDOR"
echo "============================================================"

command -v php >/dev/null 2>&1 \
    || fail "PHP no está instalado."

command -v composer >/dev/null 2>&1 \
    || fail "Composer no está instalado."

command -v git >/dev/null 2>&1 \
    || fail "Git no está instalado."

systemctl is-active --quiet apache2 \
    || fail "Apache no está activo."

systemctl is-active --quiet mysql \
    || fail "MySQL no está activo."

ok "PHP: $(php -r 'echo PHP_VERSION;')"
ok "Composer: $(composer --version | head -n 1)"
ok "Git: $(git --version)"
ok "Apache: ACTIVO"
ok "MySQL: ACTIVO"

echo ""
echo "============================================================"
echo "2. CONFIGURACIÓN PCCURICO"
echo "============================================================"

mkdir -p "$CONFIG_DIR"
mkdir -p "$STATE_DIR"

chmod 700 "$CONFIG_DIR"
chmod 700 "$STATE_DIR"

if [[ ! -f "$DB_CONFIG" ]]; then
    fail "No existe ${DB_CONFIG}"
fi

ok "Configuración MySQL encontrada."

echo ""
echo "============================================================"
echo "3. DIRECTORIO DEL PANEL"
echo "============================================================"

mkdir -p "$APP_ROOT"

ok "Directorio:"
echo "  $APP_ROOT"

echo ""
echo "============================================================"
echo "4. CÓDIGO DEL PANEL"
echo "============================================================"

if [[ -n "$REPOSITORY_URL" ]]; then

    info "Repositorio configurado:"
    echo "  $REPOSITORY_URL"

    if [[ -d "${APP_ROOT}/.git" ]]; then

        info "Repositorio existente detectado."

        git -C "$APP_ROOT" fetch --all --prune
        git -C "$APP_ROOT" reset --hard origin/HEAD

    else

        find "$APP_ROOT" \
            -mindepth 1 \
            -maxdepth 1 \
            -exec rm -rf {} +

        git clone "$REPOSITORY_URL" "$APP_ROOT"

    fi

    ok "Código descargado desde Git."

else

    warn "No se configuró repositorio Git."

    info "Se utilizará el directorio existente:"
    echo "  $APP_ROOT"

    if [[ ! -f "${APP_ROOT}/composer.json" ]]; then
        warn "Todavía no existe composer.json."
        warn "El repositorio del panel debe crearse antes del despliegue definitivo."
    fi
fi

echo ""
echo "============================================================"
echo "5. ESTRUCTURA DE DIRECTORIOS"
echo "============================================================"

mkdir -p "${APP_ROOT}/public"
mkdir -p "${APP_ROOT}/app"
mkdir -p "${APP_ROOT}/config"
mkdir -p "${APP_ROOT}/routes"
mkdir -p "${APP_ROOT}/database"
mkdir -p "${APP_ROOT}/storage"

mkdir -p "${APP_ROOT}/storage/logs"
mkdir -p "${APP_ROOT}/storage/cache"
mkdir -p "${APP_ROOT}/storage/sessions"
mkdir -p "${APP_ROOT}/storage/tmp"

ok "Estructura MVC preparada."

echo ""
echo "============================================================"
echo "6. COMPOSER"
echo "============================================================"

if [[ -f "${APP_ROOT}/composer.json" ]]; then

    info "Instalando dependencias Composer..."

    cd "$APP_ROOT"

    COMPOSER_ALLOW_SUPERUSER=1 \
        composer install \
        --no-interaction \
        --prefer-dist \
        --optimize-autoloader

    ok "Dependencias Composer instaladas."

else

    warn "composer.json todavía no existe."
    warn "Se omite Composer por ahora."
fi

echo ""
echo "============================================================"
echo "7. PERMISOS"
echo "============================================================"

chown -R root:www-data "$APP_ROOT"

find "$APP_ROOT" \
    -type d \
    -exec chmod 2755 {} \;

find "$APP_ROOT" \
    -type f \
    -exec chmod 0644 {} \;

if [[ -d "${APP_ROOT}/storage" ]]; then

    chown -R www-data:www-data "${APP_ROOT}/storage"

    find "${APP_ROOT}/storage" \
        -type d \
        -exec chmod 2770 {} \;

    find "${APP_ROOT}/storage" \
        -type f \
        -exec chmod 0660 {} \;
fi

ok "Permisos aplicados."

echo ""
echo "============================================================"
echo "8. APACHE"
echo "============================================================"

VHOST="/etc/apache2/sites-available/pccurico-hosting-panel.conf"

if [[ ! -f "$VHOST" ]]; then

    cat > "$VHOST" <<EOF
<VirtualHost *:80>

    ServerName hosting.pccurico.cl

    DocumentRoot ${APP_PUBLIC}

    <Directory ${APP_PUBLIC}>
        Options FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    DirectoryIndex index.php index.html

    ErrorLog \${APACHE_LOG_DIR}/pccurico-hosting-panel_error.log
    CustomLog \${APACHE_LOG_DIR}/pccurico-hosting-panel_access.log combined

</VirtualHost>
EOF

    a2ensite pccurico-hosting-panel.conf

    apache2ctl configtest

    systemctl reload apache2

    ok "VirtualHost del panel creado."

else

    info "VirtualHost del panel ya existe."

    apache2ctl configtest

    ok "Configuración Apache válida."
fi

echo ""
echo "============================================================"
echo "9. ESTADO"
echo "============================================================"

cat > "${CONFIG_DIR}/panel.conf" <<EOF
PANEL_NAME=${APP_NAME}
PANEL_VERSION=${APP_VERSION}
PANEL_ROOT=${APP_ROOT}
PANEL_PUBLIC=${APP_PUBLIC}
DATABASE_CONFIG=${DB_CONFIG}
EOF

chmod 600 "${CONFIG_DIR}/panel.conf"

cat > "${STATE_DIR}/panel_state" <<EOF
VERSION=${APP_VERSION}
STATUS=installed
APP_ROOT=${APP_ROOT}
APP_PUBLIC=${APP_PUBLIC}
INSTALLED_AT=$(date '+%Y-%m-%d %H:%M:%S %z')
EOF

chmod 600 "${STATE_DIR}/panel_state"

ok "Estado guardado."

echo ""
echo "============================================================"
echo "10. VALIDACIÓN"
echo "============================================================"

apache2ctl configtest

systemctl is-active --quiet apache2 \
    || fail "Apache dejó de estar activo."

systemctl is-active --quiet mysql \
    || fail "MySQL dejó de estar activo."

if [[ -f "${APP_PUBLIC}/index.php" ]]; then
    ok "public/index.php encontrado."
else
    warn "Todavía no existe public/index.php."
fi

if [[ -f "${APP_ROOT}/composer.json" ]]; then
    ok "composer.json encontrado."
else
    warn "Todavía no existe composer.json."
fi

echo ""
echo "============================================================"
echo " PCCURICO HOSTING PANEL"
echo " DESPLIEGUE FINALIZADO"
echo "============================================================"
echo ""

ok "Servidor:"
echo "  $(hostname)"

ok "Aplicación:"
echo "  ${APP_ROOT}"

ok "Public:"
echo "  ${APP_PUBLIC}"

ok "Configuración:"
echo "  ${CONFIG_DIR}"

ok "Estado:"
echo "  ${STATE_DIR}"

ok "Log:"
echo "  ${LOG_FILE}"

echo ""
info "Apache continúa operativo."
info "MySQL continúa operativo."
info "No se modificaron las bases de datos existentes."
info "No se modificaron los VirtualHost existentes salvo el del panel."
echo ""
