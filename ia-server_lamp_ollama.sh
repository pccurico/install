#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

# ============================================================
# IA-SERVER
# Instalador y administrador para Ubuntu Server 24.04 LTS
#
# Componentes:
#   Apache2
#   PHP 8.2 / 8.3 / 8.4
#   MySQL
#   phpMyAdmin
#   OmniRoute
#   Ollama
#   llmfit
#   Resolución LAN
#   UFW
#
# Uso:
#   curl -fsSL https://TU-REPO/raw/main/install.sh | sudo bash
#
# IMPORTANTE:
#   No almacenar contraseñas ni secretos en este archivo.
# ============================================================

readonly APP_NAME="IA-SERVER"
readonly LOG_DIR="/var/log/ia-server"
readonly LOG_FILE="${LOG_DIR}/install.log"
readonly CONFIG_DIR="/etc/ia-server"
readonly PHP_PPA="ppa:ondrej/php"

readonly OMNIROUTE_PORT="20128"
readonly OLLAMA_PORT="11434"
readonly LLMFIT_PORT="8787"

readonly DEFAULT_WEB_ROOT="/var/www"

mkdir -p "$LOG_DIR" "$CONFIG_DIR"
touch "$LOG_FILE"

exec > >(tee -a "$LOG_FILE") 2>&1

# ============================================================
# COLORES
# ============================================================

if [[ -t 1 ]]; then
    C_RESET='\033[0m'
    C_RED='\033[0;31m'
    C_GREEN='\033[0;32m'
    C_YELLOW='\033[1;33m'
    C_BLUE='\033[0;34m'
    C_CYAN='\033[0;36m'
    C_WHITE='\033[1;37m'
else
    C_RESET=''
    C_RED=''
    C_GREEN=''
    C_YELLOW=''
    C_BLUE=''
    C_CYAN=''
    C_WHITE=''
fi

# ============================================================
# UTILIDADES
# ============================================================

msg() {
    echo -e "${C_CYAN}[IA-SERVER]${C_RESET} $*"
}

ok() {
    echo -e "${C_GREEN}[OK]${C_RESET} $*"
}

warn() {
    echo -e "${C_YELLOW}[AVISO]${C_RESET} $*"
}

err() {
    echo -e "${C_RED}[ERROR]${C_RESET} $*" >&2
}

die() {
    err "$*"
    exit 1
}

pause_menu() {
    echo
    read -rp "Presiona ENTER para continuar..." _
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

service_exists() {
    systemctl list-unit-files "$1.service" >/dev/null 2>&1
}

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        die "Ejecuta este script como root: sudo bash install.sh"
    fi
}

check_ubuntu() {
    [[ -f /etc/os-release ]] || die "No se pudo detectar el sistema operativo."

    # shellcheck disable=SC1091
    source /etc/os-release

    if [[ "${ID}" != "ubuntu" ]]; then
        die "Este instalador requiere Ubuntu."
    fi

    if [[ "${VERSION_ID}" != "24.04" ]]; then
        warn "Sistema detectado: Ubuntu ${VERSION_ID}"
        warn "Este instalador está diseñado para Ubuntu 24.04 LTS."
        read -rp "¿Continuar igualmente? [s/N]: " answer

        if [[ ! "$answer" =~ ^[sS]$ ]]; then
            exit 0
        fi
    fi
}

get_lan_ip() {
    local ip

    ip="$(hostname -I 2>/dev/null | awk '{print $1}')"

    if [[ -z "$ip" ]]; then
        ip="127.0.0.1"
    fi

    echo "$ip"
}

get_lan_interface() {
    ip route get 1.1.1.1 2>/dev/null \
        | awk '/dev/ {for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}'
}

get_lan_network() {
    local iface
    iface="$(get_lan_interface || true)"

    if [[ -z "$iface" ]]; then
        echo ""
        return
    fi

    ip -o -f inet addr show "$iface" \
        | awk '{print $4}' \
        | head -n1
}

generate_secret() {
    openssl rand -hex 32
}

# ============================================================
# PREPARACIÓN
# ============================================================

install_base_packages() {

    msg "Instalando paquetes base..."

    apt-get update

    apt-get install -y \
        ca-certificates \
        curl \
        wget \
        git \
        unzip \
        zip \
        tar \
        gzip \
        bzip2 \
        gnupg \
        lsb-release \
        software-properties-common \
        apt-transport-https \
        jq \
        openssl \
        nano \
        vim \
        htop \
        ncdu \
        tree \
        net-tools \
        iproute2 \
        dnsutils \
        rsync \
        acl \
        cron \
        logrotate \
        ufw \
        avahi-daemon \
        avahi-utils

    systemctl enable --now avahi-daemon || true

    ok "Paquetes base instalados."
}

# ============================================================
# FIREWALL
# ============================================================

configure_firewall() {

    msg "Configuración del firewall..."

    if ! command_exists ufw; then
        apt-get install -y ufw
    fi

    ufw allow 22/tcp comment 'SSH' || true
    ufw allow 80/tcp comment 'Apache HTTP LAN' || true
    ufw allow 443/tcp comment 'Apache HTTPS LAN' || true

    ufw allow "${OMNIROUTE_PORT}/tcp" comment 'OmniRoute LAN' || true
    ufw allow "${OLLAMA_PORT}/tcp" comment 'Ollama LAN' || true
    ufw allow "${LLMFIT_PORT}/tcp" comment 'llmfit LAN' || true

    ufw --force enable

    ok "UFW configurado."
}

# ============================================================
# APACHE
# ============================================================

install_apache() {

    msg "Instalando Apache2..."

    apt-get update
    apt-get install -y apache2

    a2enmod rewrite
    a2enmod headers
    a2enmod ssl
    a2enmod expires
    a2enmod proxy
    a2enmod proxy_http
    a2enmod dir
    a2enmod mime

    systemctl enable --now apache2

    ok "Apache2 instalado."
}

# ============================================================
# PHP
# ============================================================

install_php_repository() {

    if ! grep -Rqs "^deb .*ondrej/php" /etc/apt/sources.list.d/ 2>/dev/null; then

        msg "Agregando repositorio PHP Ondřej..."

        apt-get install -y software-properties-common

        add-apt-repository -y "$PHP_PPA"

        apt-get update
    fi
}

php_packages() {
    local version="$1"

    echo \
        "php${version}" \
        "php${version}-cli" \
        "php${version}-common" \
        "php${version}-fpm" \
        "php${version}-mysql" \
        "php${version}-xml" \
        "php${version}-curl" \
        "php${version}-mbstring" \
        "php${version}-zip" \
        "php${version}-gd" \
        "php${version}-intl" \
        "php${version}-bcmath" \
        "php${version}-opcache" \
        "php${version}-readline"
}

install_php_version() {

    local version="$1"

    case "$version" in
        8.2|8.3|8.4)
            ;;
        *)
            err "Versión PHP no soportada: $version"
            return 1
            ;;
    esac

    msg "Instalando PHP ${version}..."

    install_php_repository

    # shellcheck disable=SC2046
    apt-get install -y $(php_packages "$version")

    a2enmod proxy_fcgi setenvif
    a2enconf "php${version}-fpm"

    systemctl enable --now "php${version}-fpm"

    ok "PHP ${version} instalado."
}

set_php_default() {

    local version="$1"

    [[ "$version" =~ ^8\.(2|3|4)$ ]] || {
        err "Versión PHP inválida."
        return
    }

    if ! command_exists "php${version}"; then
        install_php_version "$version"
    fi

    update-alternatives --install /usr/bin/php php "/usr/bin/php${version}" 80

    update-alternatives --set php "/usr/bin/php${version}"

    for binary in phpize php-config; do
        if [[ -x "/usr/bin/${binary}${version}" ]]; then
            update-alternatives \
                --install "/usr/bin/${binary}" "$binary" \
                "/usr/bin/${binary}${version}" 80

            update-alternatives \
                --set "$binary" "/usr/bin/${binary}${version}" || true
        fi
    done

    for svc in php8.2-fpm php8.3-fpm php8.4-fpm; do
        if systemctl list-unit-files "$svc" >/dev/null 2>&1; then
            systemctl disable --now "$svc" 2>/dev/null || true
        fi
    done

    systemctl enable --now "php${version}-fpm"

    # Activar solamente el FPM seleccionado para Apache.
    a2disconf php8.2-fpm 2>/dev/null || true
    a2disconf php8.3-fpm 2>/dev/null || true
    a2disconf php8.4-fpm 2>/dev/null || true

    a2enconf "php${version}-fpm"

    systemctl reload apache2

    ok "PHP ${version} seleccionado como versión principal."
    php -v | head -n1
}

php_menu() {

    while true; do

        clear

        echo "=============================================="
        echo "           IA-SERVER - PHP"
        echo "=============================================="
        echo
        echo "1) Instalar PHP 8.2"
        echo "2) Instalar PHP 8.3"
        echo "3) Instalar PHP 8.4"
        echo "4) Instalar las tres versiones"
        echo "5) Seleccionar versión PHP activa"
        echo "6) Mostrar versión PHP"
        echo "0) Volver"
        echo

        read -rp "Opción: " option

        case "$option" in
            1) install_php_version "8.2"; pause_menu ;;
            2) install_php_version "8.3"; pause_menu ;;
            3) install_php_version "8.4"; pause_menu ;;
            4)
                install_php_version "8.2"
                install_php_version "8.3"
                install_php_version "8.4"
                set_php_default "8.3"
                pause_menu
                ;;
            5)
                read -rp "Versión [8.2/8.3/8.4]: " version
                set_php_default "$version"
                pause_menu
                ;;
            6)
                php -v || true
                pause_menu
                ;;
            0)
                return
                ;;
            *)
                warn "Opción inválida."
                sleep 1
                ;;
        esac
    done
}

# ============================================================
# VHOST
# ============================================================

create_vhost() {

    local domain
    local document_root
    local conf
    local php_version

    read -rp "Nombre del dominio (ej. pccontrolhub.local): " domain

    [[ "$domain" =~ ^[a-zA-Z0-9.-]+$ ]] || {
        err "Nombre de dominio inválido."
        return
    }

    read -rp \
        "DocumentRoot [/var/www/${domain}]: " \
        document_root

    document_root="${document_root:-/var/www/${domain}}"

    mkdir -p "$document_root"

    chown -R www-data:www-data "$document_root"

    chmod 755 "$document_root"

    cat > "${document_root}/index.php" <<EOF
<?php
phpinfo();
EOF

    echo
    echo "PHP disponible:"
    php -v | head -n1
    echo

    php_version="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || echo '')"

    conf="/etc/apache2/sites-available/${domain}.conf"

    cat > "$conf" <<EOF
<VirtualHost *:80>

    ServerName ${domain}

    DocumentRoot ${document_root}

    <Directory ${document_root}>
        Options FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    DirectoryIndex index.php index.html

    ErrorLog \${APACHE_LOG_DIR}/${domain}-error.log
    CustomLog \${APACHE_LOG_DIR}/${domain}-access.log combined

</VirtualHost>
EOF

    a2ensite "${domain}.conf"

    apache2ctl configtest

    systemctl reload apache2

    ok "VirtualHost creado: ${domain}"
    echo
    echo "URL local:"
    echo "  http://${domain}"
    echo
    echo "IP del servidor:"
    echo "  http://$(get_lan_ip)"
    echo
    echo "Para otra máquina de la LAN, agrega en su archivo hosts:"
    echo
    echo "  $(get_lan_ip) ${domain}"
    echo
    echo "Windows:"
    echo "  C:\\Windows\\System32\\drivers\\etc\\hosts"
    echo
}

vhost_menu() {

    while true; do

        clear

        echo "=============================================="
        echo "           IA-SERVER - APACHE"
        echo "=============================================="
        echo
        echo "IP LAN: $(get_lan_ip)"
        echo
        echo "1) Crear VirtualHost"
        echo "2) Listar VirtualHosts"
        echo "3) Validar configuración Apache"
        echo "4) Reiniciar Apache"
        echo "5) Mostrar IP LAN"
        echo "0) Volver"
        echo

        read -rp "Opción: " option

        case "$option" in
            1) create_vhost; pause_menu ;;
            2) apache2ctl -S; pause_menu ;;
            3) apache2ctl configtest; pause_menu ;;
            4) systemctl restart apache2; pause_menu ;;
            5)
                echo
                ip addr
                pause_menu
                ;;
            0) return ;;
            *) warn "Opción inválida"; sleep 1 ;;
        esac
    done
}

# ============================================================
# RESOLUCIÓN LAN
# ============================================================

configure_avahi_domain() {

    local domain

    read -rp "Dominio .local (ej. ia-server.local): " domain

    [[ "$domain" == *.local ]] || {
        err "Para Avahi utiliza un dominio terminado en .local."
        return
    }

    local hostname_name="${domain%.local}"

    hostnamectl set-hostname "$hostname_name"

    systemctl restart avahi-daemon

    ok "Avahi configurado."

    echo
    echo "Desde otra máquina compatible con mDNS:"
    echo
    echo "  http://${domain}"
    echo
}

configure_dnsmasq() {

    local domain
    local ip

    apt-get install -y dnsmasq

    ip="$(get_lan_ip)"

    read -rp "Dominio LAN (ej. pccontrolhub.local): " domain

    [[ -n "$domain" ]] || return

    cat > "/etc/dnsmasq.d/ia-server.conf" <<EOF
# IA-SERVER
address=/${domain}/${ip}
EOF

    systemctl enable dnsmasq
    systemctl restart dnsmasq

    ok "dnsmasq configurado."

    echo
    echo "DNS del servidor:"
    echo "  ${ip}"
    echo
    echo "En los equipos LAN debes utilizar ${ip} como servidor DNS"
    echo "o crear la entrada equivalente en su DNS local."
}

lan_dns_menu() {

    while true; do

        clear

        echo "=============================================="
        echo "        IA-SERVER - RESOLUCIÓN LAN"
        echo "=============================================="
        echo
        echo "1) Avahi / mDNS (.local)"
        echo "2) dnsmasq / DNS LAN"
        echo "3) Mostrar IP y hostname"
        echo "0) Volver"
        echo

        read -rp "Opción: " option

        case "$option" in
            1) configure_avahi_domain; pause_menu ;;
            2) configure_dnsmasq; pause_menu ;;
            3)
                hostname
                hostname -I
                pause_menu
                ;;
            0) return ;;
            *) warn "Opción inválida"; sleep 1 ;;
        esac
    done
}

# ============================================================
# MYSQL
# ============================================================

install_mysql() {

    msg "Instalando MySQL..."

    apt-get update

    apt-get install -y mysql-server mysql-client

    systemctl enable --now mysql

    ok "MySQL instalado."
}

create_mysql_user() {

    command_exists mysql || {
        err "MySQL no está instalado."
        return
    }

    local username
    local password
    local database

    read -rp "Usuario MySQL: " username

    [[ "$username" =~ ^[a-zA-Z0-9_]+$ ]] || {
        err "Nombre de usuario inválido."
        return
    }

    read -rsp "Password MySQL: " password
    echo

    read -rp "Crear también una base de datos con el mismo nombre? [S/n]: " answer

    if [[ ! "$answer" =~ ^[nN]$ ]]; then
        database="$username"
    else
        read -rp "Nombre de base de datos: " database
    fi

    mysql --protocol=socket <<SQL
CREATE USER IF NOT EXISTS '${username}'@'localhost'
IDENTIFIED BY '${password}';

ALTER USER '${username}'@'localhost'
IDENTIFIED BY '${password}';

CREATE DATABASE IF NOT EXISTS \`${database}\`
CHARACTER SET utf8mb4
COLLATE utf8mb4_unicode_ci;

GRANT ALL PRIVILEGES ON \`${database}\`.*
TO '${username}'@'localhost';

FLUSH PRIVILEGES;
SQL

    ok "Usuario MySQL creado."
    echo "Base de datos: ${database}"
    echo "Usuario: ${username}"
}

mysql_menu() {

    while true; do

        clear

        echo "=============================================="
        echo "            IA-SERVER - MYSQL"
        echo "=============================================="
        echo
        echo "1) Instalar MySQL"
        echo "2) Crear usuario y base de datos"
        echo "3) Listar usuarios"
        echo "4) Estado MySQL"
        echo "5) Ejecutar mysql_secure_installation"
        echo "0) Volver"
        echo

        read -rp "Opción: " option

        case "$option" in
            1) install_mysql; pause_menu ;;
            2) create_mysql_user; pause_menu ;;
            3)
                mysql -e "SELECT User,Host FROM mysql.user;"
                pause_menu
                ;;
            4)
                systemctl status mysql --no-pager
                pause_menu
                ;;
            5)
                mysql_secure_installation
                pause_menu
                ;;
            0) return ;;
            *) warn "Opción inválida"; sleep 1 ;;
        esac
    done
}

# ============================================================
# PHPMYADMIN
# ============================================================

install_phpmyadmin() {

    command_exists apache2 || install_apache

    if ! command_exists php; then
        install_php_version "8.3"
        set_php_default "8.3"
    fi

    msg "Instalando phpMyAdmin..."

    apt-get update

    echo
    echo "Durante la instalación:"
    echo "  Servidor web: Apache2"
    echo "  Configuración de base de datos: sí"
    echo

    apt-get install phpmyadmin

    if [[ -f /etc/phpmyadmin/apache.conf ]]; then

        if ! grep -q "phpmyadmin" /etc/apache2/conf-available/phpmyadmin.conf 2>/dev/null; then
            cp /etc/phpmyadmin/apache.conf \
                /etc/apache2/conf-available/phpmyadmin.conf
        fi

        a2enconf phpmyadmin || true
    fi

    systemctl reload apache2

    ok "phpMyAdmin instalado."

    echo
    echo "Acceso:"
    echo "  http://$(get_lan_ip)/phpmyadmin"
    echo
}

phpmyadmin_menu() {

    while true; do

        clear

        echo "=============================================="
        echo "          IA-SERVER - PHPMYADMIN"
        echo "=============================================="
        echo
        echo "1) Instalar phpMyAdmin"
        echo "2) Habilitar configuración Apache"
        echo "3) Reiniciar Apache"
        echo "4) Mostrar URL"
        echo "0) Volver"
        echo

        read -rp "Opción: " option

        case "$option" in
            1) install_phpmyadmin; pause_menu ;;
            2)
                a2enconf phpmyadmin || true
                systemctl reload apache2
                pause_menu
                ;;
            3)
                systemctl restart apache2
                pause_menu
                ;;
            4)
                echo "http://$(get_lan_ip)/phpmyadmin"
                pause_menu
                ;;
            0) return ;;
            *) warn "Opción inválida"; sleep 1 ;;
        esac
    done
}

# ============================================================
# NODE.JS
# ============================================================

install_nodejs() {

    if command_exists node && command_exists npm; then
        ok "Node.js ya está instalado."
        node --version
        npm --version
        return
    fi

    msg "Instalando Node.js..."

    curl -fsSL https://deb.nodesource.com/setup_22.x | bash -

    apt-get install -y nodejs

    node --version
    npm --version

    ok "Node.js instalado."
}

# ============================================================
# OMNIROUTE
# ============================================================

install_omniroute() {

    install_nodejs

    msg "Instalando OmniRoute..."

    npm install -g omniroute

    command_exists omniroute || {
        err "OmniRoute no quedó disponible en PATH."
        return 1
    }

    local omni_user="omniroute"
    local omni_home="/var/lib/omniroute"

    if ! id "$omni_user" >/dev/null 2>&1; then
        useradd \
            --system \
            --home "$omni_home" \
            --create-home \
            --shell /usr/sbin/nologin \
            "$omni_user"
    fi

    mkdir -p "$omni_home"
    chown -R "$omni_user:$omni_user" "$omni_home"

    cat > /etc/systemd/system/omniroute.service <<EOF
[Unit]
Description=OmniRoute AI Gateway
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${omni_user}
Group=${omni_user}
WorkingDirectory=${omni_home}

Environment=NODE_ENV=production
Environment=PORT=${OMNIROUTE_PORT}
Environment=HOSTNAME=0.0.0.0
Environment=DATA_DIR=${omni_home}/data

ExecStart=/usr/bin/env omniroute --no-open

Restart=always
RestartSec=5

NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

    mkdir -p "${omni_home}/data"
    chown -R "$omni_user:$omni_user" "$omni_home"

    systemctl daemon-reload
    systemctl enable --now omniroute

    sleep 3

    if systemctl is-active --quiet omniroute; then
        ok "OmniRoute funcionando."
    else
        warn "OmniRoute fue instalado pero el servicio no está activo."
        journalctl -u omniroute --no-pager -n 30
    fi

    echo
    echo "Dashboard:"
    echo "  http://$(get_lan_ip):${OMNIROUTE_PORT}"
    echo
    echo "API:"
    echo "  http://$(get_lan_ip):${OMNIROUTE_PORT}/v1"
}

# ============================================================
# OLLAMA
# ============================================================

install_ollama() {

    msg "Instalando Ollama..."

    if command_exists ollama; then
        ok "Ollama ya está instalado."
    else
        curl -fsSL https://ollama.com/install.sh | sh
    fi

    if ! id ollama >/dev/null 2>&1; then
        useradd -r -s /bin/false -U -m -d /usr/share/ollama ollama
    fi

    mkdir -p /etc/systemd/system/ollama.service.d

    cat > /etc/systemd/system/ollama.service.d/override.conf <<EOF
[Service]
Environment="OLLAMA_HOST=0.0.0.0:${OLLAMA_PORT}"
Environment="OLLAMA_KEEP_ALIVE=5m"
EOF

    systemctl daemon-reload
    systemctl enable --now ollama
    systemctl restart ollama

    sleep 3

    if systemctl is-active --quiet ollama; then
        ok "Ollama funcionando."
    else
        err "Ollama no inició correctamente."
        journalctl -u ollama --no-pager -n 50
        return 1
    fi

    echo
    echo "Ollama:"
    echo "  http://$(get_lan_ip):${OLLAMA_PORT}"
    echo

    curl -fsS "http://127.0.0.1:${OLLAMA_PORT}/api/tags" \
        | jq . || true
}

configure_ollama() {

    command_exists ollama || {
        err "Ollama no está instalado."
        return
    }

    local keep_alive
    local context

    echo
    read -rp \
        "OLLAMA_KEEP_ALIVE [5m]: " \
        keep_alive

    keep_alive="${keep_alive:-5m}"

    read -rp \
        "OLLAMA_CONTEXT_LENGTH [8192]: " \
        context

    context="${context:-8192}"

    cat > /etc/systemd/system/ollama.service.d/override.conf <<EOF
[Service]
Environment="OLLAMA_HOST=0.0.0.0:${OLLAMA_PORT}"
Environment="OLLAMA_KEEP_ALIVE=${keep_alive}"
Environment="OLLAMA_CONTEXT_LENGTH=${context}"
EOF

    systemctl daemon-reload
    systemctl restart ollama

    ok "Ollama configurado."
}

ollama_menu() {

    while true; do

        clear

        echo "=============================================="
        echo "            IA-SERVER - OLLAMA"
        echo "=============================================="
        echo
        echo "1) Instalar Ollama"
        echo "2) Configurar Ollama"
        echo "3) Listar modelos"
        echo "4) Estado Ollama"
        echo "5) Descargar modelo manualmente"
        echo "6) Detener modelo"
        echo "7) Mostrar configuración"
        echo "0) Volver"
        echo

        read -rp "Opción: " option

        case "$option" in

            1)
                install_ollama
                pause_menu
                ;;

            2)
                configure_ollama
                pause_menu
                ;;

            3)
                ollama list
                pause_menu
                ;;

            4)
                systemctl status ollama --no-pager
                pause_menu
                ;;

            5)
                read -rp "Modelo Ollama (ej. qwen3:8b): " model
                [[ -n "$model" ]] && ollama pull "$model"
                pause_menu
                ;;

            6)
                read -rp "Modelo a detener: " model
                [[ -n "$model" ]] && ollama stop "$model"
                pause_menu
                ;;

            7)
                systemctl cat ollama
                echo
                systemctl cat ollama.service.d/override.conf 2>/dev/null || true
                pause_menu
                ;;

            0)
                return
                ;;

            *)
                warn "Opción inválida."
                sleep 1
                ;;
        esac
    done
}

# ============================================================
# LLMFIT
# ============================================================

install_llmfit() {

    msg "Instalando llmfit..."

    curl -fsSL https://llmfit.axjns.dev/install.sh | sh

    if ! command_exists llmfit; then

        export PATH="/usr/local/bin:$HOME/.local/bin:$PATH"

    fi

    command_exists llmfit || {
        err "llmfit no quedó disponible en PATH."
        return 1
    }

    ok "llmfit instalado."

    echo
    llmfit --version || true
}

llmfit_system() {

    command_exists llmfit || {
        err "Instala llmfit primero."
        return
    }

    llmfit --json system | jq .
}

llmfit_recommend() {

    command_exists llmfit || {
        err "Instala llmfit primero."
        return
    }

    echo
    echo "=============================================="
    echo " MODELOS RECOMENDADOS POR LLMFIT"
    echo "=============================================="
    echo

    llmfit recommend \
        --json \
        --min-fit good \
        --limit 10 \
        | jq .
}

llmfit_coding() {

    command_exists llmfit || {
        err "Instala llmfit primero."
        return
    }

    llmfit recommend \
        --json \
        --use-case coding \
        --min-fit good \
        --limit 10 \
        | jq .
}

llmfit_benchmark() {

    command_exists llmfit || {
        err "Instala llmfit primero."
        return
    }

    command_exists ollama || {
        err "Ollama debe estar instalado."
        return
    }

    echo
    echo "Ejecutando benchmark contra Ollama..."
    echo

    llmfit bench --provider ollama
}

download_ollama_model() {

    command_exists ollama || {
        err "Ollama no está instalado."
        return
    }

    command_exists llmfit || {
        err "llmfit no está instalado."
        return
    }

    echo
    echo "llmfit permite analizar los modelos compatibles."
    echo "La descarga se realizará mediante Ollama."
    echo

    llmfit recommend \
        --json \
        --min-fit good \
        --limit 10 \
        | jq -r '
            .models[] |
            [
              .name,
              (.fit_level // "unknown"),
              (.provider // "unknown")
            ] |
            @tsv
        ' 2>/dev/null || true

    echo
    echo "Introduce el TAG de Ollama que deseas descargar."
    echo "Ejemplos:"
    echo "  qwen3:8b"
    echo "  qwen2.5-coder:7b"
    echo "  gemma3:12b"
    echo

    read -rp "Modelo Ollama: " model

    [[ -n "$model" ]] || return

    ollama pull "$model"
}

llmfit_menu() {

    while true; do

        clear

        echo "=============================================="
        echo "             IA-SERVER - LLMFIT"
        echo "=============================================="
        echo
        echo "1) Instalar llmfit"
        echo "2) Detectar hardware"
        echo "3) Recomendar modelos"
        echo "4) Recomendar modelos para programación"
        echo "5) Descargar modelo Ollama"
        echo "6) Benchmark de Ollama"
        echo "7) Abrir TUI de llmfit"
        echo "0) Volver"
        echo

        read -rp "Opción: " option

        case "$option" in

            1)
                install_llmfit
                pause_menu
                ;;

            2)
                llmfit_system
                pause_menu
                ;;

            3)
                llmfit_recommend
                pause_menu
                ;;

            4)
                llmfit_coding
                pause_menu
                ;;

            5)
                download_ollama_model
                pause_menu
                ;;

            6)
                llmfit_benchmark
                pause_menu
                ;;

            7)
                llmfit
                pause_menu
                ;;

            0)
                return
                ;;

            *)
                warn "Opción inválida."
                sleep 1
                ;;
        esac
    done
}

# ============================================================
# DIAGNÓSTICO
# ============================================================

show_status() {

    clear

    echo "=============================================="
    echo "              IA-SERVER - ESTADO"
    echo "=============================================="
    echo

    echo "Sistema:"
    echo "----------------------------------------------"

    hostnamectl
    echo

    echo "IP:"
    hostname -I
    echo

    echo "CPU:"
    lscpu | grep -E \
        'Model name|CPU\(s\):|Thread|Core|Socket' \
        | head -n 10

    echo
    echo "RAM:"
    free -h

    echo
    echo "DISCO:"
    df -h /

    echo
    echo "----------------------------------------------"
    echo "SERVICIOS"
    echo "----------------------------------------------"

    services=(
        apache2
        mysql
        ollama
        omniroute
        ssh
    )

    for service in "${services[@]}"; do

        if systemctl list-unit-files \
            | grep -q "^${service}.service"; then

            if systemctl is-active --quiet "$service"; then
                echo -e "${C_GREEN}[ACTIVO]${C_RESET} ${service}"
            else
                echo -e "${C_RED}[DETENIDO]${C_RESET} ${service}"
            fi

        else

            echo -e "${C_YELLOW}[NO INSTALADO]${C_RESET} ${service}"

        fi

    done

    echo
    echo "----------------------------------------------"
    echo "PUERTOS"
    echo "----------------------------------------------"

    ss -lntp | grep -E \
        ':22 |:80 |:443 |:20128 |:11434 |:8787 ' \
        || true

    echo
    echo "----------------------------------------------"
    echo "VERSIONES"
    echo "----------------------------------------------"

    php -v 2>/dev/null | head -n1 || true
    mysql --version 2>/dev/null || true
    node --version 2>/dev/null || true
    npm --version 2>/dev/null || true
    ollama --version 2>/dev/null || true
    omniroute --version 2>/dev/null || true
    llmfit --version 2>/dev/null || true

    pause_menu
}

# ============================================================
# ACTUALIZACIÓN
# ============================================================

update_components() {

    msg "Actualizando paquetes Ubuntu..."

    apt-get update
    apt-get upgrade -y

    if command_exists ollama; then
        msg "Actualizando Ollama..."
        curl -fsSL https://ollama.com/install.sh | sh
    fi

    if command_exists llmfit; then
        msg "Actualizando llmfit..."
        curl -fsSL https://llmfit.axjns.dev/install.sh | sh
    fi

    if command_exists npm && npm list -g omniroute >/dev/null 2>&1; then
        msg "Actualizando OmniRoute..."
        npm install -g omniroute
        systemctl restart omniroute || true
    fi

    systemctl daemon-reload
    systemctl restart ollama || true
    systemctl restart apache2 || true

    ok "Actualización finalizada."
}

# ============================================================
# INSTALACIÓN COMPLETA
# ============================================================

full_install() {

    clear

    echo "=============================================="
    echo "             INSTALACIÓN COMPLETA"
    echo "=============================================="
    echo
    echo "Se instalará:"
    echo
    echo "  Apache2"
    echo "  PHP 8.2 / 8.3 / 8.4"
    echo "  MySQL"
    echo "  phpMyAdmin"
    echo "  Node.js"
    echo "  OmniRoute"
    echo "  Ollama"
    echo "  llmfit"
    echo "  UFW"
    echo "  Avahi"
    echo
    echo "No se instalará entorno gráfico."
    echo

    read -rp "¿Continuar? [s/N]: " answer

    [[ "$answer" =~ ^[sS]$ ]] || return

    install_base_packages

    install_apache

    install_php_version "8.2"
    install_php_version "8.3"
    install_php_version "8.4"

    set_php_default "8.3"

    install_mysql

    echo
    read -rp \
        "¿Ejecutar mysql_secure_installation ahora? [S/n]: " answer

    if [[ ! "$answer" =~ ^[nN]$ ]]; then
        mysql_secure_installation
    fi

    install_phpmyadmin

    install_nodejs
    install_omniroute

    install_ollama

    install_llmfit

    configure_firewall

    ok "Instalación completa finalizada."

    echo
    echo "IP IA-SERVER:"
    echo "  $(get_lan_ip)"
    echo

    echo "Apache:"
    echo "  http://$(get_lan_ip)"

    echo
    echo "phpMyAdmin:"
    echo "  http://$(get_lan_ip)/phpmyadmin"

    echo
    echo "OmniRoute:"
    echo "  http://$(get_lan_ip):${OMNIROUTE_PORT}"

    echo
    echo "Ollama:"
    echo "  http://$(get_lan_ip):${OLLAMA_PORT}"

    echo
    echo "llmfit:"
    echo "  http://$(get_lan_ip):${LLMFIT_PORT}"

    echo
    echo "Log:"
    echo "  ${LOG_FILE}"

    echo
    echo "IMPORTANTE:"
    echo "Los modelos NO se descargan automáticamente."
    echo "Utiliza:"
    echo "  Menú → llmfit → Recomendar modelos"
    echo "  Menú → llmfit → Descargar modelo Ollama"

    pause_menu
}

# ============================================================
# MENÚ PRINCIPAL
# ============================================================

main_menu() {

    while true; do

        clear

        local ip
        ip="$(get_lan_ip)"

        echo
        echo "=============================================================="
        echo "                         IA-SERVER"
        echo "=============================================================="
        echo
        echo " Ubuntu 24.04 LTS"
        echo " IP LAN: ${ip}"
        echo
        echo "--------------------------------------------------------------"
        echo " SERVIDOR WEB"
        echo "--------------------------------------------------------------"
        echo " 1) Preparar paquetes"
        echo " 2) Apache2 / VirtualHosts"
        echo " 3) PHP 8.2 / 8.3 / 8.4"
        echo " 4) MySQL"
        echo " 5) phpMyAdmin"
        echo " 6) Resolución de dominios LAN"
        echo
        echo "--------------------------------------------------------------"
        echo " IA"
        echo "--------------------------------------------------------------"
        echo " 7) OmniRoute"
        echo " 8) Ollama"
        echo " 9) llmfit / modelos"
        echo
        echo "--------------------------------------------------------------"
        echo " SISTEMA"
        echo "--------------------------------------------------------------"
        echo " 10) Firewall"
        echo " 11) Estado del IA-SERVER"
        echo " 12) Actualizar componentes"
        echo " 13) Instalación completa"
        echo
        echo "--------------------------------------------------------------"
        echo " 0) Salir"
        echo "--------------------------------------------------------------"
        echo

        read -rp "Selecciona una opción: " option

        case "$option" in

            1)
                install_base_packages
                pause_menu
                ;;

            2)
                vhost_menu
                ;;

            3)
                php_menu
                ;;

            4)
                mysql_menu
                ;;

            5)
                phpmyadmin_menu
                ;;

            6)
                lan_dns_menu
                ;;

            7)
                install_omniroute
                pause_menu
                ;;

            8)
                ollama_menu
                ;;

            9)
                llmfit_menu
                ;;

            10)
                configure_firewall
                pause_menu
                ;;

            11)
                show_status
                ;;

            12)
                update_components
                pause_menu
                ;;

            13)
                full_install
                ;;

            0)
                echo
                ok "IA-SERVER finalizado."
                exit 0
                ;;

            *)
                warn "Opción inválida."
                sleep 1
                ;;
        esac

    done
}

# ============================================================
# TRAMPAS
# ============================================================

trap 'err "Error en línea ${LINENO}. Revisa ${LOG_FILE}"' ERR

# ============================================================
# INICIO
# ============================================================

require_root
check_ubuntu
main_menu
