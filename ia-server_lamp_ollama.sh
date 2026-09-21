#!/usr/bin/env bash
# ============================================================================
# IA-SERVER Professional - Instalador LAMP + Ollama
# PCCURICO SPA
#
# Reescritura robusta de ia-server_lamp_ollama.sh
# Objetivo: Ubuntu Server 24.04 LTS
#
# Características:
# - Instalación idempotente
# - Manejo de errores por etapa
# - Reintentos APT/curl
# - Validación de sintaxis antes de ejecutar
# - Backups de configuraciones administradas
# - Apache + PHP-FPM + MySQL
# - Node.js
# - Ollama
# - Samba
# - dnsmasq
# - UFW + fail2ban
# - Certbot
# - Swap y optimización
# - Diagnóstico / estado / pruebas / reparación
# - Nunca usa heredoc sin delimitador correctamente cerrado
# ============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_NAME="ia-server_lamp_ollama.sh"
SCRIPT_VERSION="4.0.0"

LOG_DIR="/var/log/ia-server"
LOG_FILE="${LOG_DIR}/install.log"
CONFIG_DIR="/etc/ia-server"
CONFIG_FILE="${CONFIG_DIR}/ia-server.conf"
STATE_DIR="/var/lib/ia-server"
STATE_COMPONENTS="${STATE_DIR}/components"
BACKUP_DIR="/var/backups/ia-server"

PHP_VERSION="${PHP_VERSION:-8.3}"
NODE_MAJOR="${NODE_MAJOR:-24}"
OLLAMA_PORT="${OLLAMA_PORT:-11434}"
OLLAMA_BIND="${OLLAMA_BIND:-127.0.0.1}"
OLLAMA_CONTEXT_LENGTH="${OLLAMA_CONTEXT_LENGTH:-163840}"
OLLAMA_KEEP_ALIVE="${OLLAMA_KEEP_ALIVE:-10m}"

OMNI_PORT="${OMNI_PORT:-20128}"
OMNI_BIND="${OMNI_BIND:-0.0.0.0}"

TIMEZONE="${TIMEZONE:-America/Santiago}"
HOSTNAME_DEFAULT="${HOSTNAME_DEFAULT:-ia-server}"

LOCAL_DOMAIN="${LOCAL_DOMAIN:-home.pccontrolhub.arpa}"
DNS_UPSTREAM_1="${DNS_UPSTREAM_1:-1.1.1.1}"
DNS_UPSTREAM_2="${DNS_UPSTREAM_2:-8.8.8.8}"

DRY_RUN=0
TTY_FD=0
CURRENT_STAGE="inicio"

if [[ -t 1 ]]; then
    RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
    CYAN=$'\033[0;36m'; WHITE=$'\033[1;37m'; NC=$'\033[0m'
else
    RED=""; GREEN=""; YELLOW=""; CYAN=""; WHITE=""; NC=""
fi

mkdir -p /tmp 2>/dev/null || true

log() {
    mkdir -p "$LOG_DIR" 2>/dev/null || true
    printf '[%s] %s\n' "$(date '+%F %T')" "$*" >> "$LOG_FILE" 2>/dev/null || true
}

info() { printf '%s[INFO]%s %s\n' "$CYAN" "$NC" "$*"; log "INFO $*"; }
ok()   { printf '%s[OK]%s %s\n' "$GREEN" "$NC" "$*"; log "OK $*"; }
warn() { printf '%s[AVISO]%s %s\n' "$YELLOW" "$NC" "$*"; log "WARN $*"; }
err()  { printf '%s[ERROR]%s %s\n' "$RED" "$NC" "$*" >&2; log "ERROR $*"; }

on_error() {
    local rc=$?
    err "Fallo controlado."
    err "Etapa: ${CURRENT_STAGE}"
    err "Línea: ${BASH_LINENO[0]:-N/D}"
    err "Comando: ${BASH_COMMAND:-N/D}"
    err "Código: ${rc}"
    err "Log: ${LOG_FILE}"
    return "$rc"
}
trap on_error ERR

require_root() {
    if [[ $EUID -ne 0 ]]; then
        err "Este instalador requiere root."
        err "Ejecuta: sudo bash ${SCRIPT_NAME}"
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
    local prompt="$1" var="$2" value=""
    if ! read -r -u "$TTY_FD" -p "$prompt" value; then
        return 1
    fi
    printf -v "$var" '%s' "$value"
}

yesno() {
    local answer=""
    read -r -u "$TTY_FD" -p "$1 [s/N]: " answer || return 1
    [[ "${answer,,}" =~ ^(s|si|sí|y|yes)$ ]]
}

command_exists() { command -v "$1" >/dev/null 2>&1; }

service_exists() {
    systemctl list-unit-files "$1.service" >/dev/null 2>&1 ||
    systemctl cat "$1.service" >/dev/null 2>&1
}

service_active() { systemctl is-active --quiet "$1"; }

pkg_installed() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null |
        grep -q 'install ok installed'
}

mark_component() {
    local name="$1"
    (( DRY_RUN )) && return 0
    mkdir -p "$STATE_COMPONENTS"
    printf '%s\n' "$(date '+%F %T')" > "${STATE_COMPONENTS}/${name}"
}

component_done() {
    [[ -f "${STATE_COMPONENTS}/$1" ]]
}

retry() {
    local attempts="$1"; shift
    local n=1
    until "$@"; do
        if (( n >= attempts )); then
            return 1
        fi
        warn "Reintento ${n}/${attempts}: $*"
        sleep $((n * 2))
        ((n++))
    done
}

run() {
    if (( DRY_RUN )); then
        printf '%s[DRY-RUN]%s' "$YELLOW" "$NC"
        printf ' %q' "$@"
        printf '\n'
        return 0
    fi
    "$@"
}

run_allow_fail() {
    if (( DRY_RUN )); then
        run "$@"
        return 0
    fi
    "$@" || {
        warn "Comando no crítico falló: $*"
        return 0
    }
}

apt_update() {
    export DEBIAN_FRONTEND=noninteractive
    retry 3 apt-get update
}

apt_install() {
    export DEBIAN_FRONTEND=noninteractive
    apt_update
    retry 3 apt-get install -y "$@"
}

check_os() {
    CURRENT_STAGE="verificación del sistema"
    if [[ ! -r /etc/os-release ]]; then
        err "No existe /etc/os-release."
        exit 1
    fi
    # shellcheck disable=SC1091
    source /etc/os-release
    if [[ "${ID:-}" != "ubuntu" || "${VERSION_ID:-}" != "24.04" ]]; then
        err "Se requiere Ubuntu 24.04 LTS."
        err "Detectado: ${PRETTY_NAME:-N/D}"
        exit 1
    fi
    ok "${PRETTY_NAME}"
}

prepare() {
    CURRENT_STAGE="preparación"
    run mkdir -p "$LOG_DIR" "$CONFIG_DIR" "$STATE_COMPONENTS" "$BACKUP_DIR"
    run touch "$LOG_FILE"
    run chmod 750 "$CONFIG_DIR" "$STATE_DIR" "$BACKUP_DIR" 2>/dev/null || true
    run chmod 640 "$LOG_FILE" 2>/dev/null || true
}

load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$CONFIG_FILE"
        info "Configuración cargada."
    fi
}

save_config() {
    (( DRY_RUN )) && return 0
    cat > "$CONFIG_FILE" <<CFG
# IA-SERVER configuration
SCRIPT_VERSION="$SCRIPT_VERSION"
PHP_VERSION="$PHP_VERSION"
NODE_MAJOR="$NODE_MAJOR"
OLLAMA_PORT="$OLLAMA_PORT"
OLLAMA_BIND="$OLLAMA_BIND"
OLLAMA_CONTEXT_LENGTH="$OLLAMA_CONTEXT_LENGTH"
OLLAMA_KEEP_ALIVE="$OLLAMA_KEEP_ALIVE"
OMNI_PORT="$OMNI_PORT"
OMNI_BIND="$OMNI_BIND"
TIMEZONE="$TIMEZONE"
HOSTNAME_DEFAULT="$HOSTNAME_DEFAULT"
LOCAL_DOMAIN="$LOCAL_DOMAIN"
DNS_UPSTREAM_1="$DNS_UPSTREAM_1"
DNS_UPSTREAM_2="$DNS_UPSTREAM_2"
CFG
    chmod 640 "$CONFIG_FILE"
}

net_detect() {
    LAN_IP="$(ip -4 route get 1.1.1.1 2>/dev/null |
        awk '/src/ {for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true)"
    LAN_IFACE="$(ip -4 route get 1.1.1.1 2>/dev/null |
        awk '/dev/ {for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}' || true)"
    GATEWAY="$(ip route show default 2>/dev/null | awk '/default/{print $3; exit}' || true)"

    [[ -n "${LAN_IP:-}" ]] || LAN_IP="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"

    if [[ -n "${LAN_IFACE:-}" && -n "${LAN_IP:-}" ]]; then
        LAN_CIDR="$(ip -4 -o addr show dev "$LAN_IFACE" 2>/dev/null |
            awk -v ip="$LAN_IP" '$4 ~ "^" ip "/" {print $4; exit}' || true)"
    fi
    [[ -n "${LAN_CIDR:-}" && -n "${LAN_IP:-}" ]] || LAN_CIDR="${LAN_IP:-127.0.0.1}/24"
}

base_install() {
    CURRENT_STAGE="paquetes base"
    apt_install \
        ca-certificates curl wget gnupg lsb-release software-properties-common \
        unzip zip tar git rsync jq nano vim htop btop tree net-tools iproute2 \
        dnsutils bind9-dnsutils pciutils usbutils lsof procps psmisc openssh-server \
        ufw fail2ban cron build-essential pkg-config acl attr ncdu iotop nload \
        sysstat smartmontools unattended-upgrades apt-listchanges openssl \
        software-properties-common

    run systemctl enable --now ssh
    run systemctl enable --now cron
    mark_component base
    ok "Paquetes base instalados."
}

identity() {
    CURRENT_STAGE="identidad del sistema"
    net_detect
    if [[ "$(hostname)" != "$HOSTNAME_DEFAULT" ]]; then
        if yesno "¿Cambiar hostname a ${HOSTNAME_DEFAULT}?"; then
            run hostnamectl set-hostname "$HOSTNAME_DEFAULT"
        fi
    fi
    run timedatectl set-timezone "$TIMEZONE"
    save_config
    mark_component identity
    ok "Host=$(hostname) IP=${LAN_IP:-N/D} IF=${LAN_IFACE:-N/D}"
}

apache_install() {
    CURRENT_STAGE="Apache"
    apt_install apache2 apache2-utils
    local module
    for module in rewrite headers ssl proxy proxy_http proxy_fcgi setenvif expires deflate env http2 status; do
        run_allow_fail a2enmod "$module"
    done
    run_allow_fail a2dissite 000-default.conf
    run systemctl enable --now apache2
    run apache2ctl configtest
    run systemctl reload apache2
    mark_component apache
    ok "Apache operativo."
}

php_install() {
    CURRENT_STAGE="PHP ${PHP_VERSION}"
    apt_install \
        "php${PHP_VERSION}" "php${PHP_VERSION}-cli" "php${PHP_VERSION}-common" \
        "php${PHP_VERSION}-fpm" "php${PHP_VERSION}-mysql" "php${PHP_VERSION}-xml" \
        "php${PHP_VERSION}-curl" "php${PHP_VERSION}-zip" "php${PHP_VERSION}-mbstring" \
        "php${PHP_VERSION}-gd" "php${PHP_VERSION}-intl" "php${PHP_VERSION}-bcmath" \
        "php${PHP_VERSION}-soap" "php${PHP_VERSION}-readline" "php${PHP_VERSION}-opcache"

    run systemctl enable --now "php${PHP_VERSION}-fpm"
    run_allow_fail a2enconf "php${PHP_VERSION}-fpm"

    if command_exists update-alternatives; then
        run update-alternatives --install /usr/bin/php php "/usr/bin/php${PHP_VERSION}" 83
        run update-alternatives --set php "/usr/bin/php${PHP_VERSION}"
    fi

    if (( !DRY_RUN )); then
        mkdir -p "/etc/php/${PHP_VERSION}/fpm/conf.d"
        cat > "/etc/php/${PHP_VERSION}/fpm/conf.d/99-ia-server.ini" <<INI
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
    mark_component php
    ok "PHP ${PHP_VERSION} operativo."
}

mysql_install() {
    CURRENT_STAGE="MySQL"
    apt_install mysql-server mysql-client
    run systemctl enable --now mysql
    if (( !DRY_RUN )); then
        mysql --protocol=socket -uroot -e 'SELECT 1' >/dev/null
    fi
    mark_component mysql
    ok "MySQL operativo."
}

node_install() {
    CURRENT_STAGE="Node.js ${NODE_MAJOR}"
    apt_install ca-certificates curl gnupg
    if ! command_exists node || [[ "$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)" != "$NODE_MAJOR" ]]; then
        if (( !DRY_RUN )); then
            rm -f /etc/apt/sources.list.d/nodesource.list
            mkdir -p /etc/apt/keyrings
            curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key |
                gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
            chmod 644 /etc/apt/keyrings/nodesource.gpg
            printf 'deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_%s.x nodistro main\n' \
                "$NODE_MAJOR" > /etc/apt/sources.list.d/nodesource.list
        fi
        apt_install nodejs
    fi
    mark_component node
    ok "Node.js $(node --version 2>/dev/null || echo N/D)"
}

ollama_install() {
    CURRENT_STAGE="Ollama"
    apt_install curl ca-certificates
    if ! command_exists ollama; then
        if (( DRY_RUN )); then
            info "DRY-RUN: instalaría Ollama."
        else
            retry 3 bash -c 'curl -fsSL https://ollama.com/install.sh | sh'
        fi
    fi

    if command_exists ollama && (( !DRY_RUN )); then
        mkdir -p /etc/systemd/system/ollama.service.d
        cat > /etc/systemd/system/ollama.service.d/override.conf <<INI
[Service]
Environment="OLLAMA_HOST=${OLLAMA_BIND}:${OLLAMA_PORT}"
Environment="OLLAMA_CONTEXT_LENGTH=${OLLAMA_CONTEXT_LENGTH}"
Environment="OLLAMA_KEEP_ALIVE=${OLLAMA_KEEP_ALIVE}"
INI
        run systemctl daemon-reload
        run systemctl enable --now ollama
        run systemctl restart ollama
    fi
    mark_component ollama
    ok "Ollama configurado."
}

samba_install() {
    CURRENT_STAGE="Samba"
    apt_install samba smbclient
    mkdir -p /var/www
    if (( !DRY_RUN )); then
        if ! grep -q '^\[www\]' /etc/samba/smb.conf 2>/dev/null; then
            cat >> /etc/samba/smb.conf <<SMB

[www]
   path = /var/www
   browseable = yes
   read only = no
   guest ok = no
   force group = www-data
   create mask = 0664
   directory mask = 0775
SMB
        fi
    fi
    run testparm -s
    run systemctl enable --now smbd
    mark_component samba
    ok "Samba operativo."
}

dns_install() {
    CURRENT_STAGE="dnsmasq"
    apt_install dnsmasq
    if (( !DRY_RUN )); then
        mkdir -p /etc/dnsmasq.d
        cat > /etc/dnsmasq.d/ia-server.conf <<DNS
# IA-SERVER dnsmasq
domain=${LOCAL_DOMAIN}
local=/${LOCAL_DOMAIN}/
server=${DNS_UPSTREAM_1}
server=${DNS_UPSTREAM_2}
conf-file=/etc/dnsmasq.d/ia-server-vhosts.conf
DNS
        [[ -f /etc/dnsmasq.d/ia-server-vhosts.conf ]] ||
            printf '# IA-SERVER local records\n' > /etc/dnsmasq.d/ia-server-vhosts.conf
    fi
    run dnsmasq --test
    run systemctl enable --now dnsmasq
    mark_component dns
    ok "DNS local operativo."
}

security_install() {
    CURRENT_STAGE="seguridad"
    apt_install fail2ban unattended-upgrades
    if (( !DRY_RUN )); then
        mkdir -p /etc/fail2ban/jail.d
        cat > /etc/fail2ban/jail.d/ia-server.local <<JAIL
[sshd]
enabled = true
backend = systemd
maxretry = 5
findtime = 10m
bantime = 1h

[apache-auth]
enabled = true
JAIL
    fi
    run systemctl enable --now fail2ban
    mark_component security
    ok "Fail2ban operativo."
}

firewall_install() {
    CURRENT_STAGE="UFW"
    apt_install ufw
    net_detect
    run_allow_fail ufw allow OpenSSH
    run_allow_fail ufw allow 80/tcp
    run_allow_fail ufw allow 443/tcp
    run_allow_fail ufw allow 445/tcp
    run_allow_fail ufw allow 139/tcp
    run_allow_fail ufw allow 53/tcp
    run_allow_fail ufw allow 53/udp
    run_allow_fail ufw allow "${OMNI_PORT}/tcp"

    if yesno "¿Activar UFW ahora?"; then
        run ufw --force enable
    fi
    mark_component firewall
    ok "Firewall configurado."
}

swap_install() {
    CURRENT_STAGE="swap"
    if swapon --show 2>/dev/null | grep -q .; then
        ok "Ya existe swap."
        mark_component swap
        return
    fi
    local size="8G"
    ask "Tamaño de swap [8G]: " size || true
    size="${size:-8G}"
    if (( !DRY_RUN )); then
        fallocate -l "$size" /swapfile
        chmod 600 /swapfile
        mkswap /swapfile
        swapon /swapfile
        grep -q '^/swapfile ' /etc/fstab ||
            printf '/swapfile none swap sw 0 0\n' >> /etc/fstab
    else
        info "DRY-RUN: crearía ${size} de swap."
    fi
    mark_component swap
    ok "Swap configurada."
}

optimize() {
    CURRENT_STAGE="optimización"
    if (( !DRY_RUN )); then
        cat > /etc/sysctl.d/99-ia-server.conf <<SYS
vm.swappiness=10
vm.vfs_cache_pressure=50
fs.inotify.max_user_watches=524288
fs.inotify.max_user_instances=1024
net.core.somaxconn=65535
net.ipv4.tcp_fin_timeout=15
net.ipv4.tcp_keepalive_time=600
SYS
        mkdir -p /etc/systemd/journald.conf.d
        cat > /etc/systemd/journald.conf.d/ia-server.conf <<JOURNAL
[Journal]
SystemMaxUse=1G
RuntimeMaxUse=256M
MaxRetentionSec=14day
JOURNAL
    fi
    run sysctl --system
    run systemctl restart systemd-journald
    mark_component optimize
    ok "Optimización aplicada."
}

certbot_install() {
    CURRENT_STAGE="Certbot"
    apt_install certbot python3-certbot-apache
    mark_component certbot
    ok "Certbot instalado."
}

vhost_create() {
    CURRENT_STAGE="VirtualHost"
    local domain="" root="" aliases="" file="" alias=""
    ask "Dominio: " domain
    [[ "$domain" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$ ]] || {
        err "Dominio inválido."
        return 1
    }
    ask "DocumentRoot [/var/www/${domain}]: " root || true
    root="${root:-/var/www/${domain}}"
    ask "Aliases separados por espacio: " aliases || true
    file="${domain//[^A-Za-z0-9._-]/_}.conf"

    run mkdir -p "$root"
    run chown -R www-data:www-data "$root"

    if (( !DRY_RUN )); then
        {
            printf '<VirtualHost *:80>\n'
            printf '    ServerName %s\n' "$domain"
            for alias in $aliases; do
                [[ "$alias" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$ ]] &&
                    printf '    ServerAlias %s\n' "$alias"
            done
            printf '    DocumentRoot %s\n\n' "$root"
            printf '    <Directory %s>\n' "$root"
            printf '        Options FollowSymLinks\n'
            printf '        AllowOverride All\n'
            printf '        Require all granted\n'
            printf '    </Directory>\n\n'
            printf '    DirectoryIndex index.php index.html index.htm\n'
            printf '    ErrorLog ${APACHE_LOG_DIR}/%s_error.log\n' "$domain"
            printf '    CustomLog ${APACHE_LOG_DIR}/%s_access.log combined\n' "$domain"
            printf '</VirtualHost>\n'
        } > "/etc/apache2/sites-available/${file}"
    fi

    run a2ensite "$file"
    run apache2ctl configtest
    run systemctl reload apache2

    net_detect
    if (( !DRY_RUN )); then
        printf 'address=/%s/%s\n' "$domain" "${LAN_IP:-127.0.0.1}" >> /etc/dnsmasq.d/ia-server-vhosts.conf
        for alias in $aliases; do
            [[ "$alias" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$ ]] &&
                printf 'address=/%s/%s\n' "$alias" "${LAN_IP:-127.0.0.1}" >> /etc/dnsmasq.d/ia-server-vhosts.conf
        done
        systemctl restart dnsmasq
    fi
    ok "VirtualHost creado: ${domain}"
}

backup() {
    CURRENT_STAGE="backup"
    local name="${1:-manual}" stamp dest
    stamp="$(date +%Y%m%d-%H%M%S)"
    dest="${BACKUP_DIR}/${stamp}-${name}"
    run mkdir -p "$dest"
    (( DRY_RUN )) && return 0

    printf 'IA-SERVER BACKUP\nVersion=%s\nDate=%s\nHost=%s\n' \
        "$SCRIPT_VERSION" "$(date '+%F %T')" "$(hostname)" > "${dest}/manifest.txt"

    local f
    for f in \
        "$CONFIG_FILE" \
        /etc/samba/smb.conf \
        /etc/dnsmasq.d/ia-server.conf \
        /etc/dnsmasq.d/ia-server-vhosts.conf \
        /etc/fail2ban/jail.d/ia-server.local \
        /etc/sysctl.d/99-ia-server.conf \
        /etc/systemd/journald.conf.d/ia-server.conf \
        /etc/systemd/system/ollama.service.d/override.conf
    do
        [[ -e "$f" ]] && cp -a "$f" "$dest/" || true
    done

    apache2ctl -S > "${dest}/apache-vhosts.txt" 2>&1 || true
    ss -lntup > "${dest}/ports.txt" 2>&1 || true
    ip addr > "${dest}/ip.txt" 2>&1 || true
    ip route > "${dest}/routes.txt" 2>&1 || true
    ufw status verbose > "${dest}/ufw.txt" 2>&1 || true
    systemctl list-units --type=service --state=running > "${dest}/services.txt" 2>&1 || true

    if command_exists ollama; then
        ollama list > "${dest}/ollama-models.txt" 2>&1 || true
    fi
    ok "Backup: ${dest}"
}

service_state() {
    if service_active "$1"; then echo "ACTIVO"
    elif service_exists "$1"; then echo "DETENIDO"
    else echo "NO-INSTALADO"
    fi
}

port_state() {
    ss -lntup 2>/dev/null | grep -Eq ":${1}[[:space:]]" && echo OPEN || echo CLOSED
}

status() {
    CURRENT_STAGE="estado"
    net_detect
    echo
    printf '%s============================================================%s\n' "$CYAN" "$NC"
    printf '%s IA-SERVER %s v%s%s\n' "$WHITE" "$CYAN" "$SCRIPT_VERSION" "$NC"
    printf '%s============================================================%s\n' "$CYAN" "$NC"
    printf 'Host: %s\nIP: %s\nInterfaz: %s\nGateway: %s\n' \
        "$(hostname)" "${LAN_IP:-N/D}" "${LAN_IFACE:-N/D}" "${GATEWAY:-N/D}"

    echo
    local s
    for s in ssh apache2 mysql "php${PHP_VERSION}-fpm" ollama smbd dnsmasq fail2ban; do
        printf '%-22s %s\n' "$s" "$(service_state "$s")"
    done

    echo
    local p
    for p in 22 53 80 443 139 445 "$OLLAMA_PORT" "$OMNI_PORT"; do
        printf 'Puerto %-6s %s\n' "$p" "$(port_state "$p")"
    done

    echo
    if command_exists ollama; then
        echo "Modelos Ollama:"
        ollama list 2>/dev/null || true
    fi
}

diagnose() {
    CURRENT_STAGE="diagnóstico"
    status
    echo
    echo "=== CPU / RAM ==="
    lscpu | grep -E 'Model name|CPU\(s\)|Core|Socket' || true
    free -h
    echo
    echo "=== DISCO ==="
    df -hT
    echo
    echo "=== RED ==="
    ip -br addr
    ip route
    echo
    echo "=== APACHE ==="
    apache2ctl configtest || true
    apache2ctl -S 2>&1 || true
    echo
    echo "=== DNS ==="
    dnsmasq --test 2>&1 || true
    echo
    echo "=== UFW ==="
    ufw status verbose 2>&1 || true
    echo
    echo "=== FAIL2BAN ==="
    fail2ban-client status 2>&1 || true
    echo
    echo "=== LOG ==="
    tail -100 "$LOG_FILE" 2>/dev/null || true
}

test_all() {
    CURRENT_STAGE="pruebas"
    local url
    echo "=== HTTP ==="
    for url in \
        "http://127.0.0.1:${OLLAMA_PORT}/api/tags" \
        "http://127.0.0.1/"; do
        if curl -fsS --max-time 5 "$url" >/dev/null 2>&1; then
            echo "OK   $url"
        else
            echo "FAIL $url"
        fi
    done

    echo
    echo "=== CONFIGURACIONES ==="
    apache2ctl configtest && echo "OK Apache" || echo "FAIL Apache"
    dnsmasq --test && echo "OK dnsmasq" || echo "FAIL dnsmasq"
    if command_exists testparm; then
        testparm -s >/dev/null && echo "OK Samba" || echo "FAIL Samba"
    fi
    echo
    echo "=== SERVICIOS ==="
    local s
    for s in apache2 mysql "php${PHP_VERSION}-fpm" ollama smbd dnsmasq fail2ban; do
        service_active "$s" && echo "OK   $s" || echo "FAIL $s"
    done
}

repair() {
    CURRENT_STAGE="reparación"
    backup repair-before
    info "Reinstalando/revalidando componentes existentes..."
    component_done apache && apache_install
    component_done php && php_install
    component_done mysql && mysql_install
    component_done node && node_install
    component_done ollama && ollama_install
    component_done samba && samba_install
    component_done dns && dns_install
    component_done security && security_install
    component_done firewall && firewall_install
    component_done optimize && optimize
    run systemctl daemon-reload
    ok "Reparación terminada."
    status
}

full_install() {
    CURRENT_STAGE="instalación completa"
    yesno "¿Ejecutar instalación completa?" || return 0

    prepare
    load_config
    backup before-install || true

    base_install
    identity
    apache_install
    php_install
    mysql_install
    node_install
    ollama_install
    samba_install
    dns_install
    security_install
    firewall_install
    swap_install
    optimize
    certbot_install

    backup full-install
    status
    ok "IA-SERVER ${SCRIPT_VERSION} instalado."
}

menu() {
    local option=""
    while :; do
        clear 2>/dev/null || true
        net_detect
        printf '%s============================================================%s\n' "$CYAN" "$NC"
        printf '%s IA-SERVER ADMIN v%s%s\n' "$WHITE" "$SCRIPT_VERSION" "$NC"
        printf '%s============================================================%s\n' "$CYAN" "$NC"
        printf 'Host=%s  IP=%s\n\n' "$(hostname)" "${LAN_IP:-N/D}"

        cat <<'MENU'
1  Instalación completa
2  Base / identidad
3  Apache
4  Crear VirtualHost
5  PHP-FPM
6  MySQL
7  Node.js
8  Ollama
9  Samba
10 DNS local
11 Seguridad / fail2ban
12 Firewall UFW
13 Swap
14 Optimización
15 Certbot
16 Backup
17 Estado
18 Diagnóstico
19 Pruebas
20 Reparar
0  Salir
MENU

        read -r -u "$TTY_FD" -p "Opción: " option || return 0
        case "$option" in
            1) full_install ;;
            2) base_install; identity ;;
            3) apache_install ;;
            4) vhost_create ;;
            5) php_install ;;
            6) mysql_install ;;
            7) node_install ;;
            8) ollama_install ;;
            9) samba_install ;;
            10) dns_install ;;
            11) security_install ;;
            12) firewall_install ;;
            13) swap_install ;;
            14) optimize ;;
            15) certbot_install ;;
            16) backup manual ;;
            17) status ;;
            18) diagnose ;;
            19) test_all ;;
            20) repair ;;
            0) return 0 ;;
            *) warn "Opción inválida." ;;
        esac
        echo
        read -r -u "$TTY_FD" -p "ENTER para continuar..." _ || true
    done
}

help() {
    cat <<HELP
${SCRIPT_NAME} v${SCRIPT_VERSION}

Uso:
  sudo bash ${SCRIPT_NAME}
  sudo bash ${SCRIPT_NAME} --install
  sudo bash ${SCRIPT_NAME} --status
  sudo bash ${SCRIPT_NAME} --diagnose
  sudo bash ${SCRIPT_NAME} --test
  sudo bash ${SCRIPT_NAME} --backup
  sudo bash ${SCRIPT_NAME} --repair
  sudo bash ${SCRIPT_NAME} --dry-run --install
  sudo bash ${SCRIPT_NAME} --version
  sudo bash ${SCRIPT_NAME} --help

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

validate_script() {
    CURRENT_STAGE="validación del script"
    if ! bash -n "$0"; then
        err "La sintaxis de este script es inválida."
        exit 2
    fi
}

main() {
    require_root
    setup_tty

    if [[ "${1:-}" == "--dry-run" ]]; then
        DRY_RUN=1
        shift
    fi

    validate_script
    check_os
    prepare
    load_config

    case "${1:-}" in
        --install) full_install ;;
        --status) status ;;
        --diagnose) diagnose ;;
        --test) test_all ;;
        --backup) backup manual ;;
        --repair) repair ;;
        --version|-v) echo "${SCRIPT_NAME} ${SCRIPT_VERSION}" ;;
        --help|-h) help ;;
        --menu|'') menu ;;
        *) err "Opción desconocida: ${1}"; help; exit 2 ;;
    esac
}

main "$@"
