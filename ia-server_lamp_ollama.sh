#!/usr/bin/env bash
# ============================================================================
# IA-SERVER Professional Admin Installer
# PCCURICO SPA
#
# Ubuntu Server 24.04 LTS
# Version: 3.1.0
#
# Instalador + administrador + diagnóstico + reparación
#
# Componentes:
#   Apache 2
#   PHP 8.3 + PHP-FPM
#   MySQL
#   phpMyAdmin
#   Node.js 24
#   OmniRoute
#   Ollama
#   llmfit
#   Samba
#   dnsmasq
#   UFW
#   fail2ban
#   Certbot
#   swap
#   sysctl/journald
#
# Características:
#   - Instalación idempotente
#   - Configuración persistente
#   - Estado persistente
#   - Backup automático
#   - DNS local
#   - Gestión de VirtualHosts
#   - Bind configurable para OmniRoute/Ollama
#   - Firewall basado en exposición
#   - Samba /var/www
#   - Diagnóstico
#   - Pruebas de integración
#   - Reparación
#   - Dry-run
#
# ============================================================================
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_NAME="ia-server_lamp_ollama.sh"
SCRIPT_VERSION="3.1.0"

# ---------------------------------------------------------------------------
# Directorios
# ---------------------------------------------------------------------------
LOG_DIR="/var/log/ia-server"
LOG_FILE="${LOG_DIR}/install.log"

CONFIG_DIR="/etc/ia-server"
CONFIG_FILE="${CONFIG_DIR}/ia-server.conf"
MANAGED_DIR="${CONFIG_DIR}/managed"

STATE_DIR="/var/lib/ia-server"
STATE_COMPONENTS="${STATE_DIR}/components"
STATE_DIRTY="${STATE_DIR}/dirty"

BACKUP_DIR="/var/backups/ia-server"

# ---------------------------------------------------------------------------
# Software / versiones
# ---------------------------------------------------------------------------
PHP_VERSION="8.3"
NODE_MAJOR="24"

OMNI_PORT="20128"
OLLAMA_PORT="11434"

OMNI_BIND="0.0.0.0"
OLLAMA_BIND="127.0.0.1"

OLLAMA_CONTEXT_LENGTH="163840"
OLLAMA_KEEP_ALIVE="10m"

OMNI_USER="omniroute"
OMNI_GROUP="omniroute"
OMNI_HOME="/var/lib/omniroute"

# ---------------------------------------------------------------------------
# Sistema
# ---------------------------------------------------------------------------
HOSTNAME_DEFAULT="ia-server"
TIMEZONE="America/Santiago"

# ---------------------------------------------------------------------------
# Samba
# ---------------------------------------------------------------------------
SAMBA_SHARE_NAME="www"
SAMBA_SHARE_PATH="/var/www"

# ---------------------------------------------------------------------------
# DNS
# ---------------------------------------------------------------------------
DNSMASQ_CONF="/etc/dnsmasq.d/ia-server.conf"
DNSMASQ_RECORDS="/etc/dnsmasq.d/ia-server-vhosts.conf"

LOCAL_DOMAIN="home.pccontrolhub.arpa"

DNS_UPSTREAM_1="1.1.1.1"
DNS_UPSTREAM_2="8.8.8.8"

# ---------------------------------------------------------------------------
# Red
# ---------------------------------------------------------------------------
LAN_IP=""
LAN_IFACE=""
LAN_CIDR=""
GATEWAY=""

# ---------------------------------------------------------------------------
# Configuración
# ---------------------------------------------------------------------------
DRY_RUN=0
TTY_FD=0

# ---------------------------------------------------------------------------
# Colores
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    MAGENTA='\033[0;35m'
    CYAN='\033[0;36m'
    WHITE='\033[1;37m'
    GRAY='\033[0;90m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    MAGENTA=''
    CYAN=''
    WHITE=''
    GRAY=''
    NC=''
fi

# ============================================================================
# LOGGING
# ============================================================================

log() {
    mkdir -p "$LOG_DIR" 2>/dev/null || true
    printf '[%s] %s\n' "$(date '+%F %T')" "$*" >>"$LOG_FILE" 2>/dev/null || true
}

info() {
    echo -e "${CYAN}[INFO]${NC} $*"
    log "INFO $*"
}

ok() {
    echo -e "${GREEN}[OK]${NC} $*"
    log "OK $*"
}

warn() {
    echo -e "${YELLOW}[AVISO]${NC} $*"
    log "WARN $*"
}

err() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
    log "ERROR $*"
}

debug() {
    log "DEBUG $*"
}

run() {
    if (( DRY_RUN )); then
        printf '%s[DRY-RUN]%s ' "$YELLOW" "$NC"
        printf '%q ' "$@"
        echo
        return 0
    fi

    "$@"
}

run_shell() {
    if (( DRY_RUN )); then
        printf '%s[DRY-RUN]%s %s\n' "$YELLOW" "$NC" "$*"
        return 0
    fi

    bash -c "$*"
}

trap 'rc=$?; err "Fallo línea $LINENO (rc=$rc): $BASH_COMMAND"; exit "$rc"' ERR

# ============================================================================
# UTILIDADES
# ============================================================================

require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "Ejecuta como root:"
        echo "sudo bash ${SCRIPT_NAME}"
        exit 1
    fi
}

setup_tty() {
    if [[ -r /dev/tty ]]; then
        exec 3</dev/tty
        TTY_FD=3
    else
        TTY_FD=0
    fi
}

ask() {
    local prompt="$1"
    local variable="$2"
    local value=""

    read -r -u "$TTY_FD" -p "$prompt" value || return 1
    printf -v "$variable" '%s' "$value"
}

secret() {
    local prompt="$1"
    local variable="$2"
    local value=""

    read -r -u "$TTY_FD" -s -p "$prompt" value || {
        echo
        return 1
    }

    echo
    printf -v "$variable" '%s' "$value"
}

yesno() {
    local answer=""

    read -r -u "$TTY_FD" -p "$1 [s/N]: " answer || return 1

    [[ "${answer,,}" =~ ^(s|si|sí|y|yes)$ ]]
}

pause() {
    local value=""
    echo
    read -r -u "$TTY_FD" -p "ENTER para continuar..." value || true
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

service_exists() {
    systemctl list-unit-files "$1" >/dev/null 2>&1
}

service_active() {
    systemctl is-active --quiet "$1"
}

is_installed_pkg() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null |
        grep -q 'install ok installed'
}

mark_component() {
    local component="$1"

    if (( !DRY_RUN )); then
        mkdir -p "$STATE_COMPONENTS"
        printf '%s\n' "$(date '+%F %T')" >"${STATE_COMPONENTS}/${component}"
    fi
}

component_done() {
    [[ -f "${STATE_COMPONENTS}/${1}" ]]
}

valid_domain() {
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$ ]]
}

ident() {
    [[ "$1" =~ ^[A-Za-z0-9_.-]+$ ]]
}

sqlq() {
    local x="$1"
    x=${x//\\/\\\\}
    x=${x//\'/\'\'}
    printf '%s' "$x"
}

# ============================================================================
# SISTEMA
# ============================================================================

check_os() {
    source /etc/os-release

    if [[ "${ID:-}" != "ubuntu" || "${VERSION_ID:-}" != "24.04" ]]; then
        err "Se requiere Ubuntu 24.04 LTS."
        err "Sistema detectado: ${PRETTY_NAME:-N/D}"
        exit 1
    fi

    ok "${PRETTY_NAME}"
}

prepare() {
    run mkdir -p \
        "$CONFIG_DIR" \
        "$MANAGED_DIR" \
        "$STATE_DIR" \
        "$STATE_COMPONENTS" \
        "$BACKUP_DIR" \
        "$LOG_DIR"

    run touch "$LOG_FILE"

    run chmod 750 \
        "$CONFIG_DIR" \
        "$STATE_DIR" \
        "$BACKUP_DIR"

    run chmod 640 "$LOG_FILE"
}

load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$CONFIG_FILE"
        debug "Configuración cargada desde $CONFIG_FILE"
    fi
}

save_config() {
    if (( DRY_RUN )); then
        info "DRY-RUN: no se modifica $CONFIG_FILE"
        return 0
    fi

    cat >"$CONFIG_FILE" <<CFG
# IA-SERVER configuration
# Generated by ${SCRIPT_NAME} ${SCRIPT_VERSION}

PHP_VERSION="$PHP_VERSION"
NODE_MAJOR="$NODE_MAJOR"

OMNI_PORT="$OMNI_PORT"
OLLAMA_PORT="$OLLAMA_PORT"

OMNI_BIND="$OMNI_BIND"
OLLAMA_BIND="$OLLAMA_BIND"

OLLAMA_CONTEXT_LENGTH="$OLLAMA_CONTEXT_LENGTH"
OLLAMA_KEEP_ALIVE="$OLLAMA_KEEP_ALIVE"

HOSTNAME_DEFAULT="$HOSTNAME_DEFAULT"
TIMEZONE="$TIMEZONE"

SAMBA_SHARE_NAME="$SAMBA_SHARE_NAME"
SAMBA_SHARE_PATH="$SAMBA_SHARE_PATH"

LOCAL_DOMAIN="$LOCAL_DOMAIN"

DNS_UPSTREAM_1="$DNS_UPSTREAM_1"
DNS_UPSTREAM_2="$DNS_UPSTREAM_2"
CFG

    chmod 640 "$CONFIG_FILE"
}

# ============================================================================
# RED
# ============================================================================

net_detect() {
    local route_info=""

    route_info="$(ip -4 route get 1.1.1.1 2>/dev/null || true)"

    LAN_IP="$(
        awk '
            /src/ {
                for (i=1; i<=NF; i++) {
                    if ($i=="src") {
                        print $(i+1)
                        exit
                    }
                }
            }
        ' <<<"$route_info"
    )"

    LAN_IFACE="$(
        awk '
            /dev/ {
                for (i=1; i<=NF; i++) {
                    if ($i=="dev") {
                        print $(i+1)
                        exit
                    }
                }
            }
        ' <<<"$route_info"
    )"

    GATEWAY="$(
        ip route show default 2>/dev/null |
            awk '/default/ {print $3; exit}' ||
            true
    )"

    if [[ -z "$LAN_IP" ]]; then
        LAN_IP="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
    fi

    if [[ -z "$LAN_IFACE" && -n "$LAN_IP" ]]; then
        LAN_IFACE="$(
            ip -4 -o addr show 2>/dev/null |
                awk -v ip="$LAN_IP" '$4 ~ "^" ip "/" {print $2; exit}' ||
                true
        )"
    fi

    if [[ -n "$LAN_IFACE" ]]; then
        LAN_CIDR="$(
            ip -4 -o addr show dev "$LAN_IFACE" 2>/dev/null |
                awk -v ip="$LAN_IP" '$4 ~ "^" ip "/" {print $4; exit}' ||
                true
        )"
    fi

    if [[ -z "$LAN_CIDR" && -n "$LAN_IP" ]]; then
        LAN_CIDR="${LAN_IP}/24"
    fi
}

show_network() {
    net_detect

    echo
    echo "================ RED ================"
    printf 'Hostname : %s\n' "$(hostname)"
    printf 'IP       : %s\n' "${LAN_IP:-N/D}"
    printf 'Interfaz : %s\n' "${LAN_IFACE:-N/D}"
    printf 'CIDR     : %s\n' "${LAN_CIDR:-N/D}"
    printf 'Gateway  : %s\n' "${GATEWAY:-N/D}"
    echo
}

# ============================================================================
# APT
# ============================================================================

apt_prepare() {
    export DEBIAN_FRONTEND=noninteractive

    run apt-get update
}

apt_install() {
    export DEBIAN_FRONTEND=noninteractive

    run apt-get update
    run apt-get install -y "$@"
}

# ============================================================================
# BASE
# ============================================================================

base_install() {
    apt_install \
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
        bind9-dnsutils \
        pciutils \
        usbutils \
        lsof \
        procps \
        psmisc \
        openssh-server \
        ufw \
        fail2ban \
        cron \
        build-essential \
        pkg-config \
        acl \
        attr \
        ncdu \
        iotop \
        nload \
        sysstat \
        smartmontools \
        unattended-upgrades \
        apt-listchanges \
        ca-certificates \
        openssl

    run systemctl enable --now ssh
    run systemctl enable --now cron

    ok "Herramientas base instaladas."
    mark_component base
}

identity() {
    net_detect

    if [[ "$(hostname)" != "$HOSTNAME_DEFAULT" ]]; then
        if yesno "¿Cambiar hostname a $HOSTNAME_DEFAULT?"; then
            run hostnamectl set-hostname "$HOSTNAME_DEFAULT"
        fi
    fi

    run timedatectl set-timezone "$TIMEZONE"

    save_config

    ok "Host=$(hostname) IP=${LAN_IP:-N/D} IF=${LAN_IFACE:-N/D} LAN=${LAN_CIDR:-N/D} GW=${GATEWAY:-N/D}"
    mark_component identity
}

# ============================================================================
# APACHE
# ============================================================================

apache_install() {
    apt_install apache2 apache2-utils

    for module in \
        rewrite \
        headers \
        ssl \
        proxy \
        proxy_http \
        proxy_fcgi \
        setenvif \
        expires \
        deflate \
        env \
        http2 \
        status
    do
        run a2enmod "$module"
    done

    run a2dissite 000-default.conf || true
    run systemctl enable --now apache2

    run apache2ctl configtest
    run systemctl reload apache2

    ok "Apache2 operativo."
    mark_component apache
}

vhost_create() {
    local domain=""
    local root=""
    local aliases=""
    local file=""

    ask "Dominio: " domain

    valid_domain "$domain" || {
        err "Dominio inválido."
        return 1
    }

    ask "DocumentRoot [/var/www/$domain]: " root
    root="${root:-/var/www/$domain}"

    ask "Aliases separados por espacio: " aliases

    file="${domain//[^A-Za-z0-9._-]/_}.conf"

    run mkdir -p "$root"
    run chown -R www-data:www-data "$root"

    if (( !DRY_RUN )); then
        {
            echo "<VirtualHost *:80>"
            echo "    ServerName $domain"

            for alias in $aliases; do
                valid_domain "$alias" || continue
                echo "    ServerAlias $alias"
            done

            echo "    DocumentRoot $root"
            echo
            echo "    <Directory $root>"
            echo "        Options FollowSymLinks"
            echo "        AllowOverride All"
            echo "        Require all granted"
            echo "    </Directory>"
            echo
            echo "    DirectoryIndex index.php index.html index.htm"
            echo "    ErrorLog \${APACHE_LOG_DIR}/${domain}_error.log"
            echo "    CustomLog \${APACHE_LOG_DIR}/${domain}_access.log combined"
            echo "</VirtualHost>"
        } >"/etc/apache2/sites-available/$file"
    fi

    run a2ensite "$file"
    run apache2ctl configtest
    run systemctl reload apache2

    net_detect

    dns_record "$domain" "${LAN_IP:-127.0.0.1}"

    for alias in $aliases; do
        dns_record "$alias" "${LAN_IP:-127.0.0.1}"
    done

    ok "VHost $domain -> $root"
}

vhost_disable() {
    local domain=""
    ask "Dominio: " domain

    valid_domain "$domain" || {
        err "Dominio inválido."
        return 1
    }

    local file="${domain//[^A-Za-z0-9._-]/_}.conf"

    run a2dissite "$file" || true
    run apache2ctl configtest
    run systemctl reload apache2

    ok "VHost deshabilitado: $domain"
}

vhost_list() {
    echo
    echo "================ APACHE VHOSTS ================"
    apache2ctl -S 2>&1 || true
}

# ============================================================================
# PHP
# ============================================================================

php_install() {
    apt_install \
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

    run systemctl enable --now "php${PHP_VERSION}-fpm"

    run a2enconf "php${PHP_VERSION}-fpm"

    run update-alternatives \
        --install \
        /usr/bin/php \
        php \
        "/usr/bin/php${PHP_VERSION}" \
        83

    run update-alternatives \
        --set \
        php \
        "/usr/bin/php${PHP_VERSION}"

    if (( !DRY_RUN )); then
        mkdir -p "/etc/php/${PHP_VERSION}/fpm/conf.d"

        cat >"/etc/php/${PHP_VERSION}/fpm/conf.d/99-ia-server.ini" <<'INI'
memory_limit=512M
upload_max_filesize=128M
post_max_size=128M
max_execution_time=120
max_input_vars=5000

opcache.enable=1
opcache.memory_consumption=192
opcache.interned_strings_buffer=16
opcache.max_accelerated_files=20000
opcache.validate_timestamps=1
INI
    fi

    run systemctl restart "php${PHP_VERSION}-fpm"
    run systemctl reload apache2

    ok "PHP ${PHP_VERSION} operativo."
    mark_component php
}

# ============================================================================
# MYSQL
# ============================================================================

mysql_install() {
    apt_install mysql-server mysql-client

    run systemctl enable --now mysql

    if (( !DRY_RUN )); then
        mysql --protocol=socket -uroot -e 'SELECT 1' >/dev/null
    fi

    ok "MySQL operativo."
    mark_component mysql
}

mysql_db() {
    local db=""

    ask "Base de datos: " db

    ident "$db" || {
        err "Nombre inválido."
        return 1
    }

    if (( !DRY_RUN )); then
        mysql -uroot -e \
            "CREATE DATABASE IF NOT EXISTS \`$db\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
    fi

    ok "BD $db creada/verificada."
}

mysql_user() {
    local u=""
    local h="localhost"
    local p=""
    local q=""

    ask "Usuario: " u
    ident "$u" || {
        err "Usuario inválido."
        return 1
    }

    ask "Host [localhost]: " h
    h="${h:-localhost}"

    secret "Contraseña: " p

    [[ -n "$p" ]] || {
        err "Contraseña vacía."
        return 1
    }

    q="$(sqlq "$p")"

    if (( !DRY_RUN )); then
        mysql -uroot <<SQL
CREATE USER IF NOT EXISTS '$(sqlq "$u")'@'$(sqlq "$h")' IDENTIFIED BY '$q';
ALTER USER '$(sqlq "$u")'@'$(sqlq "$h")' IDENTIFIED BY '$q';
FLUSH PRIVILEGES;
SQL
    fi

    ok "Usuario $u@$h configurado."
}

mysql_db_user() {
    local db=""
    local u=""
    local h="localhost"
    local p=""
    local q=""

    ask "BD: " db
    ask "Usuario: " u
    ask "Host [localhost]: " h

    h="${h:-localhost}"

    secret "Contraseña: " p

    ident "$db" && ident "$u" || {
        err "BD/usuario inválido."
        return 1
    }

    q="$(sqlq "$p")"

    if (( !DRY_RUN )); then
        mysql -uroot <<SQL
CREATE DATABASE IF NOT EXISTS \`$db\`
    CHARACTER SET utf8mb4
    COLLATE utf8mb4_unicode_ci;

CREATE USER IF NOT EXISTS '$(sqlq "$u")'@'$(sqlq "$h")'
    IDENTIFIED BY '$q';

ALTER USER '$(sqlq "$u")'@'$(sqlq "$h")'
    IDENTIFIED BY '$q';

GRANT ALL PRIVILEGES ON \`$db\`.* TO '$(sqlq "$u")'@'$(sqlq "$h")';

FLUSH PRIVILEGES;
SQL
    fi

    ok "BD + usuario configurados."
}

mysql_list() {
    mysql -uroot -e 'SELECT User,Host FROM mysql.user ORDER BY User,Host;'
    echo
    mysql -uroot -e 'SHOW DATABASES;'
}

mysql_grants() {
    local u=""
    local h="localhost"

    ask "Usuario: " u
    ask "Host [localhost]: " h

    h="${h:-localhost}"

    mysql -uroot -e \
        "SHOW GRANTS FOR '$(sqlq "$u")'@'$(sqlq "$h")';"
}

mysql_drop_user() {
    local u=""
    local h="localhost"

    ask "Usuario: " u
    ask "Host [localhost]: " h

    h="${h:-localhost}"

    yesno "¿Eliminar $u@$h?" || return

    mysql -uroot -e \
        "DROP USER IF EXISTS '$(sqlq "$u")'@'$(sqlq "$h")'; FLUSH PRIVILEGES;"

    ok "Usuario eliminado."
}

mysql_drop_db() {
    local db=""

    ask "BD: " db

    ident "$db" || {
        err "BD inválida."
        return 1
    }

    yesno "¿ELIMINAR DEFINITIVAMENTE $db?" || return

    mysql -uroot -e \
        "DROP DATABASE IF EXISTS \`$db\`;"

    ok "BD eliminada."
}

mysql_menu() {
    local option=""

    while :; do
        echo
        echo "================ MYSQL ================"
        echo "1  Crear BD"
        echo "2  Crear usuario"
        echo "3  Crear BD + usuario"
        echo "4  Listar"
        echo "5  GRANTS"
        echo "6  Eliminar usuario"
        echo "7  Eliminar BD"
        echo "0  Volver"

        read -r -u "$TTY_FD" -p "Opción: " option || return

        case "$option" in
            1) mysql_db ;;
            2) mysql_user ;;
            3) mysql_db_user ;;
            4) mysql_list ;;
            5) mysql_grants ;;
            6) mysql_drop_user ;;
            7) mysql_drop_db ;;
            0) return ;;
            *) warn "Opción inválida." ;;
        esac

        pause
    done
}

# ============================================================================
# PHPMYADMIN
# ============================================================================

phpmyadmin_install() {
    export DEBIAN_FRONTEND=noninteractive

    if (( !DRY_RUN )); then
        echo 'phpmyadmin phpmyadmin/reconfigure-webserver multiselect apache2' |
            debconf-set-selections

        echo 'phpmyadmin phpmyadmin/dbconfig-install boolean false' |
            debconf-set-selections
    fi

    apt_install phpmyadmin

    if (( !DRY_RUN )); then
        cat >/etc/apache2/conf-available/phpmyadmin-custom.conf <<'CONF'
Alias /phpmyadmin /usr/share/phpmyadmin

<Directory /usr/share/phpmyadmin>
    Options FollowSymLinks
    DirectoryIndex index.php
    AllowOverride All
    Require local
</Directory>
CONF
    fi

    run a2enconf phpmyadmin-custom
    run apache2ctl configtest
    run systemctl reload apache2

    ok "phpMyAdmin instalado."
    mark_component phpmyadmin
}

# ============================================================================
# NODE
# ============================================================================

node_install() {
    local current_major=""

    if command_exists node; then
        current_major="$(
            node -p 'process.versions.node.split(".")[0]' 2>/dev/null ||
                true
        )
    fi

    if [[ "$current_major" == "$NODE_MAJOR" ]]; then
        ok "Node $(node --version)"
        return
    fi

    run_shell \
        "curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR}.x | bash -"

    apt_install nodejs

    ok "Node $(node --version)"
    ok "npm $(npm --version)"

    mark_component node
}

# ============================================================================
# OMNIROUTE
# ============================================================================

omni_user() {
    getent group "$OMNI_GROUP" >/dev/null ||
        run groupadd --system "$OMNI_GROUP"

    id "$OMNI_USER" >/dev/null 2>&1 ||
        run useradd \
            --system \
            --gid "$OMNI_GROUP" \
            --home-dir "$OMNI_HOME" \
            --create-home \
            --shell /usr/sbin/nologin \
            "$OMNI_USER"

    run mkdir -p "$OMNI_HOME"
    run chown -R "$OMNI_USER:$OMNI_GROUP" "$OMNI_HOME"
    run chmod 750 "$OMNI_HOME"
}

omni_binary() {
    command -v omniroute || true
}

omni_install() {
    node_install

    local binary=""

    if ! command_exists omniroute; then
        run npm install -g omniroute
    fi

    binary="$(omni_binary)"

    [[ -n "$binary" ]] || {
        err "No se encontró el binario OmniRoute."
        return 1
    }

    omni_user

    if (( !DRY_RUN )); then
        cat >/etc/systemd/system/omniroute.service <<UNIT
[Unit]
Description=OmniRoute AI Gateway
After=network-online.target
Wants=network-online.target

[Service]
Type=simple

User=$OMNI_USER
Group=$OMNI_GROUP

WorkingDirectory=$OMNI_HOME

Environment=NODE_ENV=production
Environment=HOME=$OMNI_HOME
Environment=HOST=$OMNI_BIND
Environment=PORT=$OMNI_PORT

ExecStart=$binary serve --host $OMNI_BIND --port $OMNI_PORT --no-open

Restart=always
RestartSec=5

NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true

ReadWritePaths=$OMNI_HOME

[Install]
WantedBy=multi-user.target
UNIT
    fi

    run systemctl daemon-reload
    run systemctl enable --now omniroute

    sleep 1

    if service_active omniroute; then
        ok "OmniRoute activo."
    else
        warn "OmniRoute no quedó activo."
        systemctl --no-pager --full status omniroute || true
    fi

    save_config
    mark_component omniroute

    omni_health
}

omni_health() {
    if ! command_exists curl; then
        return 0
    fi

    if curl -fsS \
        --max-time 5 \
        "http://127.0.0.1:${OMNI_PORT}/v1/models" \
        >/dev/null 2>&1
    then
        ok "OmniRoute API: OK"
    else
        warn "OmniRoute API: no responde en localhost:${OMNI_PORT}"
    fi
}

omni_bind() {
    local option=""

    echo
    echo "================ OMNIROUTE BIND ================"
    echo "1  Solo localhost       127.0.0.1"
    echo "2  Solo LAN              IP detectada"
    echo "3  Todos IPv4            0.0.0.0"

    ask "Opción [3]: " option

    net_detect

    case "${option:-3}" in
        1)
            OMNI_BIND="127.0.0.1"
            ;;
        2)
            [[ -n "$LAN_IP" ]] || {
                err "No se pudo detectar IP LAN."
                return 1
            }
            OMNI_BIND="$LAN_IP"
            ;;
        3)
            OMNI_BIND="0.0.0.0"
            ;;
        *)
            err "Opción inválida."
            return 1
            ;;
    esac

    save_config
    omni_install
}

# ============================================================================
# OLLAMA
# ============================================================================

ollama_install() {
    if ! command_exists ollama; then
        run_shell 'curl -fsSL https://ollama.com/install.sh | sh'
    fi

    command_exists ollama || {
        err "Ollama no está instalado."
        return 1
    }

    if (( !DRY_RUN )); then
        mkdir -p /etc/systemd/system/ollama.service.d

        cat >/etc/systemd/system/ollama.service.d/override.conf <<UNIT
[Service]
Environment="OLLAMA_HOST=${OLLAMA_BIND}:${OLLAMA_PORT}"
Environment="OLLAMA_KEEP_ALIVE=${OLLAMA_KEEP_ALIVE}"
Environment="OLLAMA_CONTEXT_LENGTH=${OLLAMA_CONTEXT_LENGTH}"
UNIT
    fi

    run systemctl daemon-reload
    run systemctl enable --now ollama
    run systemctl restart ollama

    sleep 2

    if service_active ollama; then
        ok "Ollama activo."
    else
        warn "Ollama no quedó activo."
        systemctl --no-pager --full status ollama || true
    fi

    save_config
    mark_component ollama

    ollama_health
}

ollama_health() {
    if curl -fsS \
        --max-time 5 \
        "http://127.0.0.1:${OLLAMA_PORT}/api/tags" \
        >/dev/null 2>&1
    then
        ok "Ollama API: OK"
    else
        warn "Ollama API: no responde en localhost:${OLLAMA_PORT}"
    fi
}

ollama_bind() {
    local option=""
    local context=""

    echo
    echo "================ OLLAMA BIND ================"
    echo "1  Solo localhost       127.0.0.1"
    echo "2  Solo LAN              IP detectada"
    echo "3  Todos IPv4            0.0.0.0"

    ask "Bind [1]: " option

    net_detect

    case "${option:-1}" in
        1)
            OLLAMA_BIND="127.0.0.1"
            ;;
        2)
            [[ -n "$LAN_IP" ]] || {
                err "No se pudo detectar IP LAN."
                return 1
            }
            OLLAMA_BIND="$LAN_IP"
            ;;
        3)
            OLLAMA_BIND="0.0.0.0"
            ;;
        *)
            err "Opción inválida."
            return 1
            ;;
    esac

    ask "Context length [$OLLAMA_CONTEXT_LENGTH]: " context
    OLLAMA_CONTEXT_LENGTH="${context:-$OLLAMA_CONTEXT_LENGTH}"

    [[ "$OLLAMA_CONTEXT_LENGTH" =~ ^[0-9]+$ ]] || {
        err "Context length inválido."
        return 1
    }

    save_config
    ollama_install
}

model_pull() {
    local model=""

    ask "Modelo Ollama: " model

    [[ -n "$model" ]] || {
        err "Modelo vacío."
        return 1
    }

    run ollama pull "$model"
}

model_list() {
    ollama list
}

# ============================================================================
# LLMFIT
# ============================================================================

llmfit_install() {
    if command_exists llmfit; then
        return 0
    fi

    run_shell 'curl -fsSL https://llmfit.axjns.dev/install.sh | sh'

    if [[ -x /root/.local/bin/llmfit ]]; then
        run ln -sf /root/.local/bin/llmfit /usr/local/bin/llmfit
    fi

    command_exists llmfit || {
        err "llmfit no está disponible."
        return 1
    }

    mark_component llmfit
}

llmfit_menu() {
    local option=""

    llmfit_install

    while :; do
        echo
        echo "================ LLMFIT ================"
        echo "1  Hardware"
        echo "2  Recommend"
        echo "3  Coding"
        echo "4  Benchmark"
        echo "0  Volver"

        read -r -u "$TTY_FD" -p "Opción: " option || return

        case "$option" in
            1) llmfit hardware ;;
            2) llmfit recommend ;;
            3) llmfit recommend --coding ;;
            4) llmfit benchmark ;;
            0) return ;;
            *) warn "Opción inválida." ;;
        esac

        pause
    done
}

# ============================================================================
# SAMBA
# ============================================================================

samba_install() {
    apt_install \
        samba \
        samba-common-bin \
        smbclient \
        cifs-utils \
        acl \
        attr

    run systemctl enable --now smbd
    run systemctl enable --now nmbd

    ok "Samba instalado."
    mark_component samba
}

samba_www() {
    samba_install

    run mkdir -p "$SAMBA_SHARE_PATH"

    if (( !DRY_RUN )); then
        if [[ -f /etc/samba/smb.conf ]]; then
            cp -a \
                /etc/samba/smb.conf \
                "/etc/samba/smb.conf.ia-server.$(date +%Y%m%d-%H%M%S)"
        fi

        if ! grep -q "^\\[$SAMBA_SHARE_NAME\\]$" /etc/samba/smb.conf; then
            cat >>/etc/samba/smb.conf <<SHARE

[$SAMBA_SHARE_NAME]
    comment = IA-SERVER Web Root
    path = $SAMBA_SHARE_PATH
    browseable = yes
    read only = no
    writable = yes
    valid users = %U
    create mask = 0664
    directory mask = 0775
    force create mode = 0664
    force directory mode = 0775
    inherit permissions = yes
SHARE
        fi
    fi

    run testparm -s
    run systemctl restart smbd
    run systemctl restart nmbd

    ok "Samba [$SAMBA_SHARE_NAME] -> $SAMBA_SHARE_PATH"
}

samba_users() {
    local option=""

    while :; do
        echo
        echo "================ SAMBA ================"
        echo "1  Listar usuarios"
        echo "2  Agregar usuario"
        echo "3  Cambiar contraseña"
        echo "4  Eliminar usuario"
        echo "5  Probar servidor"
        echo "0  Volver"

        read -r -u "$TTY_FD" -p "Opción: " option || return

        case "$option" in
            1)
                pdbedit -L || true
                ;;
            2)
                local user=""
                ask "Usuario Linux existente: " user

                id "$user" >/dev/null 2>&1 || {
                    err "El usuario Linux no existe."
                    pause
                    continue
                }

                run smbpasswd -a "$user"
                ;;
            3)
                local user=""
                ask "Usuario: " user
                run smbpasswd "$user"
                ;;
            4)
                local user=""
                ask "Usuario: " user
                yesno "¿Eliminar usuario Samba $user?" || continue
                run smbpasswd -x "$user"
                ;;
            5)
                run smbclient -L localhost -N || true
                ;;
            0)
                return
                ;;
            *)
                warn "Opción inválida."
                ;;
        esac

        pause
    done
}

# ============================================================================
# DNSMASQ
# ============================================================================

dns_install() {
    apt_install dnsmasq

    net_detect

    [[ -n "$LAN_IP" ]] || {
        err "No se pudo detectar IP LAN."
        return 1
    }

    [[ -n "$LAN_IFACE" ]] || {
        err "No se pudo detectar interfaz LAN."
        return 1
    }

    if (( !DRY_RUN )); then
        cat >"$DNSMASQ_CONF" <<DNS
# ============================================================================
# IA-SERVER dnsmasq
# Gestionado por ${SCRIPT_NAME}
# ============================================================================

port=53

interface=${LAN_IFACE}
listen-address=${LAN_IP}

bind-interfaces

# No DHCP:
no-dhcp-interface=${LAN_IFACE}

domain-needed
bogus-priv

cache-size=1000

server=${DNS_UPSTREAM_1}
server=${DNS_UPSTREAM_2}

conf-file=${DNSMASQ_RECORDS}
DNS

        if [[ ! -f "$DNSMASQ_RECORDS" ]]; then
            cat >"$DNSMASQ_RECORDS" <<DNS
# Registros locales IA-SERVER
# Formato:
# address=/dominio/IP
DNS
        fi
    fi

    run dnsmasq --test
    run systemctl enable --now dnsmasq
    run systemctl restart dnsmasq

    ok "dnsmasq operativo en ${LAN_IP}:53"
    mark_component dns
}

dns_record() {
    local domain="$1"
    local ip="${2:-$LAN_IP}"

    valid_domain "$domain" || {
        err "Dominio DNS inválido: $domain"
        return 1
    }

    [[ -n "$ip" ]] || {
        err "IP DNS vacía."
        return 1
    }

    [[ -f "$DNSMASQ_RECORDS" ]] || dns_install

    if (( !DRY_RUN )); then
        touch "$DNSMASQ_RECORDS"

        local tmp
        tmp="$(mktemp)"

        grep -v -E "^address=/${domain}/" \
            "$DNSMASQ_RECORDS" >"$tmp" || true

        printf 'address=/%s/%s\n' "$domain" "$ip" >>"$tmp"

        mv "$tmp" "$DNSMASQ_RECORDS"
    fi

    run dnsmasq --test
    run systemctl restart dnsmasq

    ok "DNS: $domain -> $ip"
}

dns_import_vhosts() {
    dns_install
    net_detect

    if (( !DRY_RUN )); then
        {
            echo "# Registros sincronizados desde Apache"
            echo

            apache2ctl -S 2>&1 |
                sed -n -E \
                    -e 's/.*namevhost[[:space:]]+([^[:space:]]+).*/\1/p' \
                    -e 's/.*alias[[:space:]]+([^[:space:]]+).*/\1/p' |
                sort -u |
                while read -r domain; do
                    if valid_domain "$domain"; then
                        printf 'address=/%s/%s\n' "$domain" "$LAN_IP"
                    fi
                done

            printf 'address=/%s/%s\n' "$LOCAL_DOMAIN" "$LAN_IP"

        } >"$DNSMASQ_RECORDS"
    fi

    run dnsmasq --test
    run systemctl restart dnsmasq

    ok "DNS local sincronizado con Apache."
}

dns_test() {
    net_detect

    echo
    echo "================ DNS TEST ================"
    echo "DNS local: ${LAN_IP}:53"

    if command_exists dig; then
        echo
        echo "Consulta $LOCAL_DOMAIN:"
        dig +short @"$LAN_IP" "$LOCAL_DOMAIN" 2>/dev/null || true

        echo
        echo "Consulta localhost:"
        dig +short @127.0.0.1 "$LOCAL_DOMAIN" 2>/dev/null || true
    fi
}

dns_status() {
    net_detect

    echo
    echo "================ DNS ================"
    printf 'Servidor : %s\n' "${LAN_IP:-N/D}"
    printf 'Interfaz : %s\n' "${LAN_IFACE:-N/D}"
    printf 'Puerto   : 53\n'
    printf 'Dominio  : %s\n' "$LOCAL_DOMAIN"

    ss -lunpt 2>/dev/null |
        grep -E '(:53[[:space:]]|:53$)' ||
        true

    dns_test
}

# ============================================================================
# FIREWALL
# ============================================================================

firewall() {
    net_detect

    apt_install ufw

    run ufw --force reset

    run ufw default deny incoming
    run ufw default allow outgoing

    run ufw allow 22/tcp
    run ufw allow 80/tcp
    run ufw allow 443/tcp

    if [[ -n "$LAN_CIDR" ]]; then

        # DNS
        run ufw allow from "$LAN_CIDR" to any port 53 proto udp
        run ufw allow from "$LAN_CIDR" to any port 53 proto tcp

        # Samba
        run ufw allow from "$LAN_CIDR" to any port 139 proto tcp
        run ufw allow from "$LAN_CIDR" to any port 445 proto tcp
        run ufw allow from "$LAN_CIDR" to any port 137 proto udp
        run ufw allow from "$LAN_CIDR" to any port 138 proto udp

        # OmniRoute
        if [[ "$OMNI_BIND" != "127.0.0.1" ]]; then
            run ufw allow from "$LAN_CIDR" to any port "$OMNI_PORT" proto tcp
        fi

        # Ollama
        if [[ "$OLLAMA_BIND" != "127.0.0.1" ]]; then
            run ufw allow from "$LAN_CIDR" to any port "$OLLAMA_PORT" proto tcp
        fi
    fi

    run ufw --force enable
    run ufw status verbose

    ok "UFW configurado."
    mark_component firewall
}

# ============================================================================
# SEGURIDAD
# ============================================================================

security() {
    apt_install \
        fail2ban \
        unattended-upgrades \
        apt-listchanges

    if (( !DRY_RUN )); then
        mkdir -p /etc/fail2ban/jail.d

        cat >/etc/fail2ban/jail.d/ia-server.local <<'JAIL'
[sshd]
enabled = true
backend = systemd
maxretry = 5
findtime = 10m
bantime = 1h
JAIL

        mkdir -p /etc/apt/apt.conf.d

        cat >/etc/apt/apt.conf.d/52ia-server-unattended <<'APT'
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
APT
    fi

    run systemctl enable --now fail2ban
    run systemctl enable --now apt-daily.timer
    run systemctl enable --now apt-daily-upgrade.timer

    ok "Seguridad configurada."
    mark_component security
}

# ============================================================================
# SWAP
# ============================================================================

swap_config() {
    if swapon --show --noheadings 2>/dev/null | grep -q .; then
        echo
        echo "Swap existente:"
        swapon --show
        return 0
    fi

    local size="16G"

    ask "Swap [$size]: " size
    size="${size:-16G}"

    run fallocate -l "$size" /swapfile
    run chmod 600 /swapfile
    run mkswap /swapfile
    run swapon /swapfile

    if (( !DRY_RUN )); then
        grep -q '^/swapfile ' /etc/fstab ||
            echo '/swapfile none swap sw 0 0' >>/etc/fstab
    fi

    ok "Swap configurada: $size"
    mark_component swap
}

# ============================================================================
# OPTIMIZACIÓN
# ============================================================================

optimize() {
    if (( !DRY_RUN )); then
        cat >/etc/sysctl.d/99-ia-server.conf <<'SYS'
vm.swappiness=10
vm.vfs_cache_pressure=50

fs.inotify.max_user_watches=524288
fs.inotify.max_user_instances=1024

net.core.somaxconn=65535
net.ipv4.tcp_fin_timeout=15
net.ipv4.tcp_keepalive_time=600
SYS

        mkdir -p /etc/systemd/journald.conf.d

        cat >/etc/systemd/journald.conf.d/ia-server.conf <<'JOURNAL'
[Journal]
SystemMaxUse=1G
RuntimeMaxUse=256M
MaxRetentionSec=14day
JOURNAL
    fi

    run sysctl --system
    run systemctl restart systemd-journald

    ok "Optimización aplicada."
    mark_component optimize
}

# ============================================================================
# CERTBOT
# ============================================================================

certbot_install() {
    apt_install certbot python3-certbot-apache

    ok "Certbot instalado."
    info "Ejemplo: certbot --apache -d dominio.example"
    mark_component certbot
}

# ============================================================================
# BACKUP
# ============================================================================

backup() {
    local name="${1:-manual}"
    local timestamp
    local destination

    timestamp="$(date +%Y%m%d-%H%M%S)"
    destination="${BACKUP_DIR}/${timestamp}-${name}"

    net_detect

    run mkdir -p "$destination"

    (( DRY_RUN )) && return 0

    cat >"${destination}/manifest.txt" <<MANIFEST
IA-SERVER BACKUP
================
Version=${SCRIPT_VERSION}
Date=$(date '+%F %T')
Hostname=$(hostname)
IP=${LAN_IP}
CIDR=${LAN_CIDR}
Gateway=${GATEWAY}
MANIFEST

    local files=(
        "$CONFIG_FILE"
        "/etc/samba/smb.conf"
        "/etc/ufw/user.rules"
        "/etc/ufw/user6.rules"
        "$DNSMASQ_CONF"
        "$DNSMASQ_RECORDS"
        "/etc/fail2ban/jail.d/ia-server.local"
        "/etc/apt/apt.conf.d/52ia-server-unattended"
        "/etc/sysctl.d/99-ia-server.conf"
        "/etc/systemd/journald.conf.d/ia-server.conf"
        "/etc/systemd/system/omniroute.service"
        "/etc/systemd/system/ollama.service.d/override.conf"
    )

    for file in "${files[@]}"; do
        [[ -e "$file" ]] &&
            cp -a "$file" "$destination/" ||
            true
    done

    apache2ctl -S >"${destination}/apache-vhosts.txt" 2>&1 || true
    ss -lntup >"${destination}/ports.txt" || true
    ip addr >"${destination}/ip.txt" || true
    ip route >"${destination}/routes.txt" || true
    ufw status numbered >"${destination}/ufw.txt" 2>&1 || true
    systemctl list-units \
        --type=service \
        --state=running \
        >"${destination}/services.txt" || true

    if command_exists ollama; then
        ollama list >"${destination}/ollama-models.txt" 2>&1 || true
    fi

    ok "Backup creado: $destination"
}

# ============================================================================
# ESTADO
# ============================================================================

service_state() {
    local service="$1"

    if systemctl is-active --quiet "$service"; then
        echo "ACTIVO"
    elif systemctl list-unit-files "$service" >/dev/null 2>&1; then
        echo "DETENIDO"
    else
        echo "NO-INSTALADO"
    fi
}

http_ok() {
    curl -fsS --max-time 5 "$1" >/dev/null 2>&1
}

port_state() {
    local port="$1"

    if ss -lntup 2>/dev/null |
        grep -Eq ":${port}[[:space:]]"
    then
        echo "OPEN"
    else
        echo "CLOSED"
    fi
}

status() {
    net_detect

    echo
    echo "======================================================================"
    echo " IA-SERVER STATUS v${SCRIPT_VERSION}"
    echo "======================================================================"

    printf 'Host     : %s\n' "$(hostname)"
    printf 'IP       : %s\n' "${LAN_IP:-N/D}"
    printf 'Interface: %s\n' "${LAN_IFACE:-N/D}"
    printf 'LAN      : %s\n' "${LAN_CIDR:-N/D}"
    printf 'Gateway  : %s\n' "${GATEWAY:-N/D}"

    echo
    echo "---------------- SERVICES ----------------"

    for service in \
        ssh \
        apache2 \
        mysql \
        "php${PHP_VERSION}-fpm" \
        omniroute \
        ollama \
        smbd \
        nmbd \
        dnsmasq \
        fail2ban
    do
        printf '%-24s %s\n' \
            "$service" \
            "$(service_state "$service")"
    done

    echo
    echo "---------------- PORTS ----------------"

    for port in \
        22 \
        53 \
        80 \
        443 \
        139 \
        445 \
        "$OMNI_PORT" \
        "$OLLAMA_PORT"
    do
        printf '%-8s %s\n' \
            "$port" \
            "$(port_state "$port")"
    done

    echo
    echo "---------------- APIS ----------------"

    if http_ok "http://127.0.0.1:${OLLAMA_PORT}/api/tags"; then
        echo "Ollama API       : OK"
    else
        echo "Ollama API       : ERROR"
    fi

    if http_ok "http://127.0.0.1:${OMNI_PORT}/v1/models"; then
        echo "OmniRoute API    : OK"
    else
        echo "OmniRoute API    : ERROR"
    fi

    echo
    echo "---------------- BINDS ----------------"

    printf 'OmniRoute : %s:%s\n' "$OMNI_BIND" "$OMNI_PORT"
    printf 'Ollama    : %s:%s\n' "$OLLAMA_BIND" "$OLLAMA_PORT"
    printf 'DNS       : %s:53\n' "${LAN_IP:-N/D}"
    printf 'Samba     : %s\n' "$SAMBA_SHARE_PATH"

    echo
    echo "---------------- OLLAMA MODELS ----------------"

    if command_exists ollama; then
        ollama list 2>/dev/null || true
    else
        echo "Ollama no instalado."
    fi
}

# ============================================================================
# DIAGNÓSTICO
# ============================================================================

diagnose() {
    status

    echo
    echo "================ CPU / RAM / DISCO ================"

    lscpu |
        grep -E 'Model name|CPU\(s\)|Core|Socket' ||
        true

    echo
    free -h

    echo
    df -hT

    echo
    echo "================ RED ================"

    ip -br addr
    echo
    ip route

    echo
    echo "================ APACHE ================"

    apache2ctl configtest
    apache2ctl -S 2>&1 || true

    echo
    echo "================ DNS ================"

    dnsmasq --test 2>&1 || true
    dns_status || true

    echo
    echo "================ UFW ================"

    ufw status verbose 2>&1 || true

    echo
    echo "================ FAIL2BAN ================"

    fail2ban-client status 2>&1 || true

    echo
    echo "================ SYSTEMD OMNIROUTE ================"

    systemctl --no-pager --full status omniroute 2>&1 | tail -50 || true

    echo
    echo "================ SYSTEMD OLLAMA ================"

    systemctl --no-pager --full status ollama 2>&1 | tail -50 || true

    echo
    echo "================ LOG ================"

    tail -100 "$LOG_FILE" 2>/dev/null || true
}

# ============================================================================
# INTEGRATION TEST
# ============================================================================

test_tcp() {
    local host="$1"
    local port="$2"

    timeout 3 bash -c \
        "</dev/tcp/${host}/${port}" \
        >/dev/null 2>&1
}

test_all() {
    net_detect

    echo
    echo "======================================================================"
    echo " INTEGRATION TEST"
    echo "======================================================================"

    echo
    echo "HTTP:"

    local urls=(
        "http://127.0.0.1:${OLLAMA_PORT}/api/tags"
        "http://127.0.0.1:${OMNI_PORT}/v1/models"
        "http://127.0.0.1/"
    )

    local url

    for url in "${urls[@]}"; do
        if http_ok "$url"; then
            echo "OK   $url"
        else
            echo "FAIL $url"
        fi
    done

    echo
    echo "TCP LAN:"

    if [[ -n "$LAN_IP" ]]; then
        local ports=(
            53
            80
            443
            445
        )

        [[ "$OMNI_BIND" != "127.0.0.1" ]] &&
            ports+=("$OMNI_PORT")

        [[ "$OLLAMA_BIND" != "127.0.0.1" ]] &&
            ports+=("$OLLAMA_PORT")

        local port

        for port in "${ports[@]}"; do
            if test_tcp "$LAN_IP" "$port"; then
                echo "OPEN  ${LAN_IP}:${port}"
            else
                echo "CLOSED ${LAN_IP}:${port}"
            fi
        done
    fi

    echo
    echo "DNS:"

    dns_test || true

    echo
    echo "Samba:"

    if command_exists smbclient; then
        smbclient -L localhost -N 2>&1 || true
    fi

    echo
    echo "RESULTADO: pruebas finalizadas."
}

# ============================================================================
# REPARACIÓN
# ============================================================================

repair() {
    echo
    echo "======================================================================"
    echo " IA-SERVER REPAIR"
    echo "======================================================================"

    net_detect

    backup repair-before

    info "Reparando servicios y configuraciones gestionadas..."

    if component_done apache; then
        apache_install
    fi

    if component_done php; then
        php_install
    fi

    if component_done mysql; then
        mysql_install
    fi

    if component_done omniroute; then
        omni_install
    fi

    if component_done ollama; then
        ollama_install
    fi

    if component_done samba; then
        samba_www
    fi

    if component_done dns; then
        dns_install
        dns_import_vhosts
    fi

    if component_done security; then
        security
    fi

    if component_done firewall; then
        firewall
    fi

    if component_done optimize; then
        optimize
    fi

    run systemctl daemon-reload

    ok "Proceso de reparación terminado."

    status
}

# ============================================================================
# REMOVE MANAGED
# ============================================================================

remove_managed() {
    echo
    warn "Esto elimina solamente configuraciones gestionadas por IA-SERVER."
    warn "No desinstala paquetes ni elimina bases de datos."
    warn "No elimina /var/www ni modelos de Ollama."

    yesno "¿Continuar?" || return

    backup before-remove

    run rm -f \
        "$DNSMASQ_CONF" \
        "$DNSMASQ_RECORDS" \
        /etc/systemd/system/omniroute.service \
        /etc/systemd/system/ollama.service.d/override.conf \
        /etc/fail2ban/jail.d/ia-server.local \
        /etc/apt/apt.conf.d/52ia-server-unattended \
        /etc/sysctl.d/99-ia-server.conf \
        /etc/systemd/journald.conf.d/ia-server.conf

    run systemctl daemon-reload

    if service_exists dnsmasq; then
        run systemctl restart dnsmasq || true
    fi

    if service_exists fail2ban; then
        run systemctl restart fail2ban || true
    fi

    run sysctl --system || true

    ok "Configuración gestionada retirada."
}

# ============================================================================
# FULL INSTALL
# ============================================================================

full() {
    yesno "¿Ejecutar instalación completa?" || return

    prepare
    load_config

    info "Iniciando IA-SERVER Professional ${SCRIPT_VERSION}"

    base_install
    identity
    save_config

    info "Actualizando sistema..."
    run apt-get upgrade -y

    apache_install
    php_install
    mysql_install
    phpmyadmin_install

    node_install

    omni_install
    ollama_install

    llmfit_install

    samba_www

    dns_install
    dns_import_vhosts

    security
    firewall

    swap_config
    optimize

    certbot_install

    backup full-install

    status

    echo
    echo "======================================================================"
    echo " INSTALACIÓN COMPLETA FINALIZADA"
    echo "======================================================================"

    ok "IA-SERVER Professional ${SCRIPT_VERSION} instalado."
}

# ============================================================================
# MENU
# ============================================================================

menu() {
    local option=""

    while :; do
        clear 2>/dev/null || true

        net_detect

        echo -e "${CYAN}======================================================================${NC}"
        echo -e "${WHITE} IA-SERVER ADMIN v${SCRIPT_VERSION}${NC}"
        echo -e "${CYAN}======================================================================${NC}"

        echo "Host=$(hostname)"
        echo "IP=${LAN_IP:-N/D}"
        echo "LAN=${LAN_CIDR:-N/D}"
        echo "Gateway=${GATEWAY:-N/D}"

        echo
        cat <<'MENU'
 1  Instalación completa
 2  Base / identidad
 3  Apache / VirtualHost
 4  PHP-FPM
 5  MySQL
 6  Administración MySQL
 7  phpMyAdmin
 8  Node.js
 9  OmniRoute
10  Bind OmniRoute
11  Estado OmniRoute
12  Ollama
13  Bind / contexto Ollama
14  Descargar modelo Ollama
15  Listar modelos Ollama
16  llmfit
17  Samba [www]
18  Usuarios Samba
19  DNS local / VirtualHosts
20  Estado DNS
21  Firewall UFW
22  Seguridad
23  Swap
24  Optimización
25  Certbot / HTTPS
26  Backup
27  Estado general
28  Diagnóstico
29  Pruebas integración
30  Reparar instalación
31  Retirar configuración gestionada
 0  Salir
MENU

        read -r -u "$TTY_FD" -p "Opción: " option || return

        case "$option" in
            1)
                full
                ;;
            2)
                base_install
                identity
                ;;
            3)
                apache_install
                vhost_create
                ;;
            4)
                php_install
                ;;
            5)
                mysql_install
                ;;
            6)
                mysql_menu
                ;;
            7)
                phpmyadmin_install
                ;;
            8)
                node_install
                ;;
            9)
                omni_install
                ;;
            10)
                omni_bind
                ;;
            11)
                omni_health
                ;;
            12)
                ollama_install
                ;;
            13)
                ollama_bind
                ;;
            14)
                model_pull
                ;;
            15)
                model_list
                ;;
            16)
                llmfit_menu
                ;;
            17)
                samba_www
                ;;
            18)
                samba_users
                ;;
            19)
                dns_install
                dns_import_vhosts
                dns_status
                ;;
            20)
                dns_status
                ;;
            21)
                firewall
                ;;
            22)
                security
                ;;
            23)
                swap_config
                ;;
            24)
                optimize
                ;;
            25)
                certbot_install
                ;;
            26)
                backup manual
                ;;
            27)
                status
                ;;
            28)
                diagnose
                ;;
            29)
                test_all
                ;;
            30)
                repair
                ;;
            31)
                remove_managed
                ;;
            0)
                return
                ;;
            *)
                warn "Opción inválida."
                ;;
        esac

        pause
    done
}

# ============================================================================
# HELP
# ============================================================================

help() {
    cat <<HELP
IA-SERVER Professional Admin Installer
Version: ${SCRIPT_VERSION}

Uso:

  sudo bash ${SCRIPT_NAME}

Instalación completa:

  sudo bash ${SCRIPT_NAME} --install

Estado:

  sudo bash ${SCRIPT_NAME} --status

Diagnóstico:

  sudo bash ${SCRIPT_NAME} --diagnose

Pruebas:

  sudo bash ${SCRIPT_NAME} --test

Backup:

  sudo bash ${SCRIPT_NAME} --backup

Reparación:

  sudo bash ${SCRIPT_NAME} --repair

Dry-run:

  sudo bash ${SCRIPT_NAME} --dry-run --install

Ayuda:

  sudo bash ${SCRIPT_NAME} --help

Versión:

  sudo bash ${SCRIPT_NAME} --version

Componentes:

  Apache
  PHP-FPM ${PHP_VERSION}
  MySQL
  phpMyAdmin
  Node.js ${NODE_MAJOR}
  OmniRoute
  Ollama
  llmfit
  Samba
  dnsmasq
  UFW
  fail2ban
  Certbot
  Swap
  sysctl
  journald

Servicios principales:

  OmniRoute : ${OMNI_PORT}
  Ollama    : ${OLLAMA_PORT}
  DNS       : 53
  HTTP      : 80
  HTTPS     : 443
  Samba     : 139/445

Configuración:

  ${CONFIG_FILE}

Estado:

  ${STATE_DIR}

Backups:

  ${BACKUP_DIR}

Log:

  ${LOG_FILE}

HELP
}

# ============================================================================
# MAIN
# ============================================================================

main() {
    require_root
    setup_tty

    if [[ "${1:-}" == "--dry-run" ]]; then
        DRY_RUN=1
        shift
    fi

    check_os
    prepare
    load_config

    case "${1:-}" in
        --install)
            full
            ;;

        --status)
            status
            ;;

        --diagnose)
            diagnose
            ;;

        --test)
            test_all
            ;;

        --backup)
            backup manual
            ;;

        --repair)
            repair
            ;;

        --menu|'')
            menu
            ;;

        --help|-h)
            help
            ;;

        --version|-v)
            echo "${SCRIPT_NAME} ${SCRIPT_VERSION}"
            ;;

        *)
            err "Opción desconocida: ${1:-}"
            echo
            help
            exit 2
            ;;
    esac
}

main "$@"
