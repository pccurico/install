#!/usr/bin/env bash

# ============================================================
# PCCURICO HOSTING
# DIAGNOSTICO COMPLETO DEL SERVIDOR
# Ubuntu / Apache / PHP / MySQL-MariaDB / Node / Ollama
#
# VERSION: 1.0.0
#
# IMPORTANTE:
# Este script NO instala, elimina ni modifica servicios.
# Solo recopila información del servidor.
# ============================================================

set -Eeuo pipefail

SCRIPT_NAME="pccurico_hosting_diagnostico.sh"
VERSION="1.0.0"

REPORT_DIR="/var/log/pccurico"
REPORT_FILE="${REPORT_DIR}/hosting_diagnostico_$(date '+%Y%m%d_%H%M%S').log"

mkdir -p "$REPORT_DIR"
chmod 750 "$REPORT_DIR"

# ------------------------------------------------------------
# COLORES
# ------------------------------------------------------------

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

# ------------------------------------------------------------
# FUNCIONES
# ------------------------------------------------------------

line() {
    printf '%s\n' "============================================================"
}

title() {
    printf '\n'
    line
    printf '%b%s%b\n' "$C_CYAN" "$1" "$C_RESET"
    line
}

info() {
    printf '%b[INFO]%b %s\n' "$C_BLUE" "$C_RESET" "$1"
}

ok() {
    printf '%b[OK]%b %s\n' "$C_GREEN" "$C_RESET" "$1"
}

warn() {
    printf '%b[WARN]%b %s\n' "$C_YELLOW" "$C_RESET" "$1"
}

error() {
    printf '%b[ERROR]%b %s\n' "$C_RED" "$C_RESET" "$1"
}

run_cmd() {
    local description="$1"
    shift

    printf '\n%b--- %s ---%b\n' "$C_WHITE" "$description" "$C_RESET"

    if "$@" 2>&1; then
        return 0
    else
        warn "El comando no devolvió información válida: $*"
        return 0
    fi
}

run_shell() {
    local description="$1"
    local command="$2"

    printf '\n%b--- %s ---%b\n' "$C_WHITE" "$description" "$C_RESET"

    bash -c "$command" 2>&1 || true
}

# ------------------------------------------------------------
# CAPTURA SALIDA EN ARCHIVO Y CONSOLA
# ------------------------------------------------------------

exec > >(tee -a "$REPORT_FILE") 2>&1

# ------------------------------------------------------------
# INICIO
# ------------------------------------------------------------

clear 2>/dev/null || true

printf '\n'
printf '%bPCCURICO HOSTING - DIAGNOSTICO DEL SERVIDOR%b\n' "$C_CYAN" "$C_RESET"
printf 'Script: %s\n' "$SCRIPT_NAME"
printf 'Version: %s\n' "$VERSION"
printf 'Fecha: %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"
printf 'Hostname: %s\n' "$(hostname 2>/dev/null || echo desconocido)"
printf 'Usuario efectivo: %s\n' "$(id -un)"

# ============================================================
# 1. SISTEMA OPERATIVO
# ============================================================

title "1. SISTEMA OPERATIVO"

if [[ -f /etc/os-release ]]; then
    . /etc/os-release

    printf 'ID              : %s\n' "${ID:-desconocido}"
    printf 'NAME            : %s\n' "${NAME:-desconocido}"
    printf 'VERSION_ID      : %s\n' "${VERSION_ID:-desconocido}"
    printf 'VERSION         : %s\n' "${VERSION:-desconocido}"
    printf 'PRETTY_NAME     : %s\n' "${PRETTY_NAME:-desconocido}"
fi

run_cmd "Kernel" uname -a

run_shell "Arquitectura" \
    'uname -m'

run_shell "Uptime" \
    'uptime'

run_shell "Memoria" \
    'free -h'

run_shell "Discos" \
    'df -hT'

# ============================================================
# 2. CPU
# ============================================================

title "2. HARDWARE / CPU"

run_shell "CPU" \
    'lscpu 2>/dev/null | grep -E "^(Architecture|CPU\(s\)|Model name|Thread|Core|Socket|CPU MHz|Virtualization)" || true'

# ============================================================
# 3. SERVICIOS SYSTEMD
# ============================================================

title "3. SERVICIOS SYSTEMD"

run_shell "Servicios actualmente activos" \
    'systemctl --type=service --state=running --no-pager --no-legend 2>/dev/null || true'

# ============================================================
# 4. APACHE
# ============================================================

title "4. APACHE"

if command -v apache2 >/dev/null 2>&1; then
    ok "apache2 está instalado."

    run_shell "Versión Apache" \
        'apache2 -v 2>&1 || true'

    run_shell "Estado servicio Apache" \
        'systemctl status apache2 --no-pager -l 2>&1 || true'

    run_shell "Apache habilitado al iniciar" \
        'systemctl is-enabled apache2 2>&1 || true'

    run_shell "Configuración Apache" \
        'apache2ctl -S 2>&1 || true'

    run_shell "Módulos Apache activos" \
        'apache2ctl -M 2>&1 || true'

    run_shell "VirtualHosts habilitados" \
        'ls -la /etc/apache2/sites-enabled/ 2>&1 || true'

    run_shell "VirtualHosts disponibles" \
        'ls -la /etc/apache2/sites-available/ 2>&1 || true'

    run_shell "DocumentRoot detectados" \
        'grep -RniE "^[[:space:]]*DocumentRoot" /etc/apache2/sites-enabled /etc/apache2/sites-available 2>/dev/null || true'

else
    warn "apache2 NO está instalado."
fi

# ============================================================
# 5. PHP
# ============================================================

title "5. PHP"

if command -v php >/dev/null 2>&1; then

    ok "PHP está instalado."

    run_shell "Versión PHP" \
        'php -v 2>&1 || true'

    run_shell "PHP_VERSION exacta" \
        'php -r "echo PHP_VERSION, PHP_EOL;" 2>&1 || true'

    run_shell "PHP SAPI CLI" \
        'php -r "echo PHP_SAPI, PHP_EOL;" 2>&1 || true'

    run_shell "Archivo php.ini CLI" \
        'php --ini 2>&1 || true'

    run_shell "Extensiones PHP" \
        'php -m 2>&1 || true'

    run_shell "Paquetes PHP instalados" \
        'dpkg -l 2>/dev/null | grep -E "^ii[[:space:]]+php" || true'

    run_shell "Servicios PHP-FPM" \
        'systemctl list-units --type=service --all --no-pager 2>/dev/null | grep -Ei "php.*fpm" || true'

    run_shell "PHP-FPM instalado" \
        'dpkg -l 2>/dev/null | grep -Ei "^ii[[:space:]]+php[0-9.]+-fpm" || true'

else
    warn "PHP NO está instalado."
fi

# ============================================================
# 6. MYSQL / MARIADB
# ============================================================

title "6. MYSQL / MARIADB"

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

if [[ -n "$MYSQL_CLIENT" ]]; then
    ok "Cliente MySQL/MariaDB encontrado: $MYSQL_CLIENT"

    run_shell "Versión MySQL/MariaDB" \
        "\"$MYSQL_CLIENT\" --version 2>&1 || true"
else
    warn "No se encontró cliente mysql/mariadb."
fi

run_shell "Servicios MySQL/MariaDB" \
    'systemctl list-units --type=service --all --no-pager 2>/dev/null | grep -Ei "mysql|mariadb" || true'

run_shell "Servicios habilitados MySQL/MariaDB" \
    'systemctl list-unit-files --type=service --no-pager 2>/dev/null | grep -Ei "mysql|mariadb" || true'

run_shell "Procesos MySQL/MariaDB" \
    'ps aux 2>/dev/null | grep -Ei "[m]ysqld|[m]ariadbd" || true'

run_shell "Sockets MySQL" \
    'find /run /var/run -type s 2>/dev/null | grep -Ei "mysql|mariadb" || true'

run_shell "Directorios de datos" \
    'ls -ld /var/lib/mysql /var/lib/mariadb 2>/dev/null || true'

run_shell "Archivos de configuración MySQL" \
    'find /etc/mysql /etc/my.cnf.d /etc/my.cnf -maxdepth 3 -type f 2>/dev/null | sort || true'

run_shell "Paquetes MySQL/MariaDB instalados" \
    'dpkg -l 2>/dev/null | grep -Ei "^ii[[:space:]]+(mysql|mariadb)" || true'

# ------------------------------------------------------------
# Bases de datos
# ------------------------------------------------------------

if [[ -n "$MYSQL_CLIENT" ]]; then

    printf '\n'
    info "Intentando detectar acceso administrativo mediante socket local..."

    if "$MYSQL_CLIENT" -uroot -e "SELECT VERSION();" >/tmp/pccurico_mysql_diag.txt 2>&1; then
        ok "Acceso administrativo local mediante socket: FUNCIONA."

        cat /tmp/pccurico_mysql_diag.txt

        run_shell "Bases de datos existentes" \
            "\"$MYSQL_CLIENT\" -uroot -N -e 'SHOW DATABASES;' 2>/dev/null || true"

        run_shell "Usuarios MySQL existentes" \
            "\"$MYSQL_CLIENT\" -uroot -N -e \\\"SELECT User,Host,plugin FROM mysql.user ORDER BY User,Host;\\\" 2>/dev/null || true"

        run_shell "Estado servidor MySQL" \
            "\"$MYSQL_CLIENT\" -uroot -e 'STATUS;' 2>/dev/null || true"

    else
        warn "No fue posible acceder a MySQL root mediante socket sin contraseña."

        cat /tmp/pccurico_mysql_diag.txt 2>/dev/null || true

        info "No se solicitará ninguna contraseña en este diagnóstico."
    fi

    rm -f /tmp/pccurico_mysql_diag.txt 2>/dev/null || true
fi

# ============================================================
# 7. PUERTOS
# ============================================================

title "7. PUERTOS EN ESCUCHA"

run_shell "Puertos TCP/UDP" \
    'ss -lntup 2>/dev/null || true'

# ============================================================
# 8. FIREWALL
# ============================================================

title "8. FIREWALL"

if command -v ufw >/dev/null 2>&1; then
    ok "UFW instalado."

    run_shell "Estado UFW" \
        'ufw status verbose 2>&1 || true'
else
    warn "UFW no está instalado."
fi

if command -v firewall-cmd >/dev/null 2>&1; then
    ok "firewalld instalado."

    run_shell "Estado firewalld" \
        'systemctl status firewalld --no-pager -l 2>&1 || true'
else
    info "firewalld no está instalado."
fi

# ============================================================
# 9. CLOUDFLARE TUNNEL
# ============================================================

title "9. CLOUDFLARE TUNNEL"

if command -v cloudflared >/dev/null 2>&1; then

    ok "cloudflared está instalado."

    run_shell "Versión cloudflared" \
        'cloudflared --version 2>&1 || true'

    run_shell "Servicio cloudflared" \
        'systemctl status cloudflared --no-pager -l 2>&1 || true'

    run_shell "Servicios cloudflared encontrados" \
        'systemctl list-units --type=service --all --no-pager 2>/dev/null | grep -i cloudflared || true'

    run_shell "Configuración Cloudflare" \
        'find /etc/cloudflared /root/.cloudflared -maxdepth 2 -type f 2>/dev/null | sort || true'

else
    warn "cloudflared no está instalado como comando."
fi

# ============================================================
# 10. NODE / NPM
# ============================================================

title "10. NODE.JS / NPM"

if command -v node >/dev/null 2>&1; then
    ok "Node.js instalado."

    run_shell "Versión Node.js" \
        'node --version 2>&1 || true'
else
    warn "Node.js NO está instalado."
fi

if command -v npm >/dev/null 2>&1; then
    ok "npm instalado."

    run_shell "Versión npm" \
        'npm --version 2>&1 || true'
else
    warn "npm NO está instalado."
fi

run_shell "Paquetes Node instalados por APT" \
    'dpkg -l 2>/dev/null | grep -E "^ii[[:space:]]+(nodejs|npm)" || true'

# ============================================================
# 11. OLLAMA
# ============================================================

title "11. OLLAMA"

if command -v ollama >/dev/null 2>&1; then

    ok "Ollama está instalado."

    run_shell "Versión Ollama" \
        'ollama --version 2>&1 || true'

    run_shell "Servicio Ollama" \
        'systemctl status ollama --no-pager -l 2>&1 || true'

    run_shell "Servicio Ollama habilitado" \
        'systemctl is-enabled ollama 2>&1 || true'

    run_shell "Modelos Ollama" \
        'ollama list 2>&1 || true'

    run_shell "Proceso Ollama" \
        'ps aux 2>/dev/null | grep -Ei "[o]llama" || true'

else
    warn "Ollama NO está instalado."
fi

# ============================================================
# 12. FAIL2BAN
# ============================================================

title "12. FAIL2BAN"

if command -v fail2ban-client >/dev/null 2>&1; then

    ok "Fail2ban está instalado."

    run_shell "Versión Fail2ban" \
        'fail2ban-client --version 2>&1 || true'

    run_shell "Estado Fail2ban" \
        'systemctl status fail2ban --no-pager -l 2>&1 || true'

    run_shell "Jails activas" \
        'fail2ban-client status 2>&1 || true'

else
    warn "Fail2ban NO está instalado."
fi

# ============================================================
# 13. COMPOSER
# ============================================================

title "13. COMPOSER"

if command -v composer >/dev/null 2>&1; then

    ok "Composer está instalado."

    run_shell "Versión Composer" \
        'composer --version 2>&1 || true'

else
    warn "Composer NO está disponible en PATH."
fi

run_shell "Composer global" \
    'find /usr/local/bin /usr/bin /root -maxdepth 3 -type f -name composer 2>/dev/null | sort || true'

# ============================================================
# 14. GIT
# ============================================================

title "14. GIT"

if command -v git >/dev/null 2>&1; then

    ok "Git está instalado."

    run_shell "Versión Git" \
        'git --version 2>&1 || true'

else
    warn "Git NO está instalado."
fi

# ============================================================
# 15. ESTRUCTURA WEB
# ============================================================

title "15. ESTRUCTURA WEB"

run_shell "/var/www" \
    'ls -lah /var/www 2>&1 || true'

run_shell "Subdirectorios /var/www" \
    'find /var/www -maxdepth 2 -type d -print 2>/dev/null | sort || true'

run_shell "DocumentRoot Apache reales" \
    'find /var/www -maxdepth 4 -type f \( -name index.php -o -name index.html \) -print 2>/dev/null | sort || true'

# ============================================================
# 16. PCCURICO
# ============================================================

title "16. CONFIGURACION PCCURICO EXISTENTE"

if [[ -d /etc/pccurico ]]; then

    ok "Existe /etc/pccurico"

    run_shell "Contenido /etc/pccurico" \
        'ls -lah /etc/pccurico 2>&1 || true'

    if [[ -f /etc/pccurico/database.conf ]]; then

        ok "Existe /etc/pccurico/database.conf"

        printf '\n--- database.conf SIN MOSTRAR CONTRASEÑAS ---\n'

        awk '
        BEGIN {
            FS="="
        }

        /^[[:space:]]*#/ {
            print
            next
        }

        /^[[:space:]]*DB_PASSWORD[[:space:]]*=/ {
            print "DB_PASSWORD=[REDACTED]"
            next
        }

        {
            print
        }
        ' /etc/pccurico/database.conf 2>/dev/null || true

        printf '%s\n' "-----------------------------------------------"

    else
        warn "No existe /etc/pccurico/database.conf"
    fi

else
    info "No existe /etc/pccurico"
fi

# ============================================================
# 17. ESTADO INSTALADOR PCCURICO
# ============================================================

title "17. ESTADO DEL INSTALADOR PCCURICO"

if [[ -d /var/lib/pccurico-installer ]]; then

    ok "Existe /var/lib/pccurico-installer"

    run_shell "Archivos de estado" \
        'find /var/lib/pccurico-installer -maxdepth 2 -type f -print -exec ls -lh {} \; 2>/dev/null || true'

    if [[ -f /var/lib/pccurico-installer/state ]]; then

        printf '\n--- STATE ---\n'
        cat /var/lib/pccurico-installer/state
        printf '%s\n' "-------------"

    fi

else
    info "No existe estado anterior del instalador."
fi

# ============================================================
# 18. LOG PCCURICO
# ============================================================

title "18. LOGS PCCURICO"

if [[ -d /var/log/pccurico ]]; then

    run_shell "Archivos de log PCCURICO" \
        'ls -lah /var/log/pccurico 2>/dev/null || true'

else
    info "No existe /var/log/pccurico"
fi

# ============================================================
# 19. CRON / SYSTEMD TIMERS
# ============================================================

title "19. TAREAS PROGRAMADAS"

run_shell "Cron del sistema" \
    'grep -RniE "pccurico|cloudflared|ollama|apache|mysql" /etc/cron* /var/spool/cron 2>/dev/null || true'

run_shell "Systemd timers" \
    'systemctl list-timers --all --no-pager 2>/dev/null || true'

# ============================================================
# 20. RED
# ============================================================

title "20. RED"

run_shell "Interfaces" \
    'ip -br addr 2>/dev/null || true'

run_shell "Rutas" \
    'ip route 2>/dev/null || true'

run_shell "DNS" \
    'resolvectl status 2>/dev/null || cat /etc/resolv.conf 2>/dev/null || true'

# ============================================================
# 21. PAQUETES RELACIONADOS CON SERVIDOR
# ============================================================

title "21. PAQUETES RELEVANTES INSTALADOS"

run_shell "Apache / PHP / MySQL / Node / Ollama / Cloudflare / Seguridad" \
    'dpkg-query -W -f="${Package}\t${Version}\n" 2>/dev/null | grep -Ei "apache2|php|mysql|mariadb|nodejs|npm|ollama|cloudflared|fail2ban|composer|certbot|ufw" | sort || true'

# ============================================================
# 22. VARIABLES PCCURICO
# ============================================================

title "22. VARIABLES / RUTAS IMPORTANTES"

printf 'HOSTNAME              : %s\n' "$(hostname 2>/dev/null || echo desconocido)"
printf 'PHP                   : %s\n' "$(command -v php 2>/dev/null || echo NO)"
printf 'MYSQL                 : %s\n' "${MYSQL_CLIENT:-NO}"
printf 'NODE                  : %s\n' "$(command -v node 2>/dev/null || echo NO)"
printf 'NPM                   : %s\n' "$(command -v npm 2>/dev/null || echo NO)"
printf 'OLLAMA                : %s\n' "$(command -v ollama 2>/dev/null || echo NO)"
printf 'CLOUDFLARED           : %s\n' "$(command -v cloudflared 2>/dev/null || echo NO)"
printf 'COMPOSER              : %s\n' "$(command -v composer 2>/dev/null || echo NO)"
printf 'GIT                   : %s\n' "$(command -v git 2>/dev/null || echo NO)"
printf 'APACHE CONFIG         : /etc/apache2\n'
printf 'MYSQL CONFIG          : /etc/mysql\n'
printf 'WEB ROOT              : /var/www\n'
printf 'PCCURICO CONFIG       : /etc/pccurico\n'
printf 'PCCURICO STATE        : /var/lib/pccurico-installer\n'
printf 'PCCURICO LOG          : /var/log/pccurico\n'

# ============================================================
# 23. RESUMEN AUTOMATICO
# ============================================================

title "23. RESUMEN DEL SERVIDOR"

check_service() {
    local service="$1"
    local label="$2"

    if systemctl is-active --quiet "$service" 2>/dev/null; then
        printf '%b[ACTIVO]%b   %s (%s)\n' "$C_GREEN" "$C_RESET" "$label" "$service"
    elif systemctl cat "$service.service" >/dev/null 2>&1; then
        printf '%b[INSTALADO]%b %s (%s), pero no está activo\n' "$C_YELLOW" "$C_RESET" "$label" "$service"
    else
        printf '%b[NO]%b       %s (%s)\n' "$C_RED" "$C_RESET" "$label" "$service"
    fi
}

check_service "apache2" "Apache"

if systemctl cat mysql.service >/dev/null 2>&1; then
    check_service "mysql" "MySQL"
elif systemctl cat mariadb.service >/dev/null 2>&1; then
    check_service "mariadb" "MariaDB"
else
    printf '%b[NO]%b       MySQL/MariaDB\n' "$C_RED" "$C_RESET"
fi

if systemctl cat ollama.service >/dev/null 2>&1; then
    check_service "ollama" "Ollama"
else
    printf '%b[NO]%b       Ollama\n' "$C_RED" "$C_RESET"
fi

if systemctl cat fail2ban.service >/dev/null 2>&1; then
    check_service "fail2ban" "Fail2ban"
else
    printf '%b[NO]%b       Fail2ban\n' "$C_RED" "$C_RESET"
fi

if systemctl cat cloudflared.service >/dev/null 2>&1; then
    check_service "cloudflared" "Cloudflare Tunnel"
else
    printf '%b[NO]%b       Cloudflare Tunnel como servicio systemd\n' "$C_RED" "$C_RESET"
fi

# ============================================================
# FINAL
# ============================================================

title "DIAGNOSTICO TERMINADO"

printf 'Informe completo:\n'
printf '  %s\n' "$REPORT_FILE"

printf '\n'
printf '%bIMPORTANTE:%b\n' "$C_YELLOW" "$C_RESET"
printf 'Este diagnóstico NO ha instalado, eliminado ni modificado servicios.\n'
printf 'No se han solicitado contraseñas.\n'
printf 'No se ha mostrado ninguna contraseña existente.\n'

printf '\n'
printf 'Para mostrar posteriormente el informe completo:\n'
printf '  cat "%s"\n' "$REPORT_FILE"

printf '\n'
line
printf '%bFIN DEL DIAGNOSTICO%b\n' "$C_GREEN" "$C_RESET"
line
