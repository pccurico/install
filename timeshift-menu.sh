#!/usr/bin/env bash

set -u

SCRIPT_VERSION="1.1.0"
TTY_FD=3

# ============================================================
# TIMESHIFT MENU
# Gestión de snapshots del sistema
# Ubuntu Server / Ubuntu Desktop
#
# Este script administra exclusivamente Timeshift.
# No modifica Apache, PHP, MySQL, Ollama, OmniRoute
# ni otros servicios del sistema.
# ============================================================

setup_tty() {
    if [[ -r /dev/tty && -w /dev/tty ]]; then
        exec 3<>/dev/tty
    else
        echo "ERROR: No se puede acceder a /dev/tty."
        exit 1
    fi
}

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        echo "ERROR: Este script debe ejecutarse como root."
        echo
        echo "Uso:"
        echo "  sudo ./timeshift-menu.sh"
        exit 1
    fi
}

pause() {
    echo
    read -r -u "$TTY_FD" -p "Presiona ENTER para continuar..."
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

timeshift_installed() {
    command_exists timeshift
}

# ============================================================
# INSTALACIÓN
# ============================================================

install_timeshift() {
    clear

    echo "============================================================"
    echo " INSTALAR TIMESHIFT"
    echo "============================================================"
    echo

    if timeshift_installed; then
        echo "Timeshift ya está instalado."
        echo
        timeshift --version 2>/dev/null || true
        pause
        return
    fi

    echo "Actualizando índice de paquetes..."
    echo

    if ! apt-get update; then
        echo
        echo "ERROR: No se pudo actualizar APT."
        pause
        return
    fi

    echo
    echo "Instalando Timeshift..."
    echo

    if ! apt-get install -y timeshift; then
        echo
        echo "ERROR: No se pudo instalar Timeshift."
        pause
        return
    fi

    echo
    echo "Timeshift instalado correctamente."
    echo

    timeshift --version 2>/dev/null || true

    pause
}

ensure_timeshift() {
    if timeshift_installed; then
        return 0
    fi

    clear

    echo "============================================================"
    echo " TIMESHIFT NO ESTÁ INSTALADO"
    echo "============================================================"
    echo

    read -r -u "$TTY_FD" -p \
        "¿Deseas instalar Timeshift ahora? [s/N]: " answer

    if [[ "$answer" =~ ^[SsYy]$ ]]; then
        install_timeshift
    fi

    return 1
}

# ============================================================
# VERSIÓN
# ============================================================

show_version() {
    clear

    echo "============================================================"
    echo " VERSIÓN DE TIMESHIFT"
    echo "============================================================"
    echo

    if timeshift_installed; then
        timeshift --version 2>/dev/null || true
    else
        echo "Timeshift no está instalado."
    fi

    pause
}

# ============================================================
# DISPOSITIVOS
# ============================================================

list_devices() {
    ensure_timeshift || return

    clear

    echo "============================================================"
    echo " DISPOSITIVOS DISPONIBLES PARA TIMESHIFT"
    echo "============================================================"
    echo

    timeshift --list-devices

    pause
}

# ============================================================
# SNAPSHOTS
# ============================================================

list_snapshots() {
    ensure_timeshift || return

    clear

    echo "============================================================"
    echo " SNAPSHOTS EXISTENTES"
    echo "============================================================"
    echo

    timeshift --list

    pause
}

# ============================================================
# ESPACIO
# ============================================================

show_disk_space() {
    clear

    echo "============================================================"
    echo " ESPACIO DE ALMACENAMIENTO"
    echo "============================================================"
    echo

    echo "Sistemas de archivos:"
    echo

    df -hT

    echo
    echo "Dispositivos:"
    echo

    lsblk -o NAME,SIZE,FSTYPE,TYPE,MOUNTPOINTS

    pause
}

# ============================================================
# CREAR SNAPSHOT
# ============================================================

create_snapshot() {
    ensure_timeshift || return

    clear

    echo "============================================================"
    echo " CREAR SNAPSHOT"
    echo "============================================================"
    echo

    echo "Dispositivos disponibles:"
    echo

    timeshift --list-devices

    echo
    echo "Espacio actual:"
    echo

    df -hT

    echo

    read -r -u "$TTY_FD" -p \
        "Comentario del snapshot [Manual Timeshift]: " comment

    if [[ -z "$comment" ]]; then
        comment="Manual Timeshift"
    fi

    echo
    echo "Comentario:"
    echo "  $comment"
    echo

    echo "Timeshift determinará automáticamente el dispositivo"
    echo "configurado para almacenar el snapshot."
    echo

    read -r -u "$TTY_FD" -p \
        "¿Crear el snapshot? [s/N]: " answer

    if [[ ! "$answer" =~ ^[SsYy]$ ]]; then
        echo
        echo "Operación cancelada."
        pause
        return
    fi

    echo
    echo "============================================================"
    echo " CREANDO SNAPSHOT"
    echo "============================================================"
    echo

    timeshift --create \
        --comments "$comment" \
        --scripted

    result=$?

    echo
    echo "============================================================"

    if [[ "$result" -eq 0 ]]; then
        echo " SNAPSHOT CREADO CORRECTAMENTE"
        echo "============================================================"
        echo

        echo "Snapshots actuales:"
        echo

        timeshift --list
    else
        echo " ERROR AL CREAR SNAPSHOT"
        echo "============================================================"
        echo
        echo "Timeshift devolvió código de error: $result"
        echo
        echo "El snapshot NO debe considerarse creado."
        echo
        echo "Comprueba el espacio disponible:"
        echo
        df -hT
        echo
        echo "Dispositivos de Timeshift:"
        echo
        timeshift --list-devices
    fi

    pause
}

# ============================================================
# RESTAURAR
# ============================================================

restore_snapshot() {
    ensure_timeshift || return

    clear

    echo "============================================================"
    echo " RESTAURAR SNAPSHOT"
    echo "============================================================"
    echo

    echo "Snapshots disponibles:"
    echo

    timeshift --list

    echo
    echo "IMPORTANTE"
    echo "============================================================"
    echo
    echo "La restauración puede reemplazar archivos del sistema."
    echo
    echo "Verifica cuidadosamente el snapshot antes de continuar."
    echo

    read -r -u "$TTY_FD" -p \
        "ID exacto del snapshot: " snapshot_id

    if [[ -z "$snapshot_id" ]]; then
        echo
        echo "No se indicó ningún snapshot."
        pause
        return
    fi

    echo
    echo "Snapshot seleccionado:"
    echo
    echo "  $snapshot_id"
    echo

    read -r -u "$TTY_FD" -p \
        "Para confirmar escribe RESTAURAR: " confirmation

    if [[ "$confirmation" != "RESTAURAR" ]]; then
        echo
        echo "Restauración cancelada."
        pause
        return
    fi

    echo
    echo "Iniciando restauración..."
    echo

    timeshift --restore --snapshot "$snapshot_id"

    result=$?

    echo

    if [[ "$result" -eq 0 ]]; then
        echo "Restauración finalizada."
        echo "Es posible que sea necesario reiniciar el sistema."
    else
        echo "ERROR: La restauración terminó con código: $result"
    fi

    pause
}

# ============================================================
# ELIMINAR
# ============================================================

delete_snapshot() {
    ensure_timeshift || return

    clear

    echo "============================================================"
    echo " ELIMINAR SNAPSHOT"
    echo "============================================================"
    echo

    echo "Snapshots disponibles:"
    echo

    timeshift --list

    echo

    read -r -u "$TTY_FD" -p \
        "ID exacto del snapshot a eliminar: " snapshot_id

    if [[ -z "$snapshot_id" ]]; then
        echo
        echo "No se indicó ningún snapshot."
        pause
        return
    fi

    echo
    echo "Snapshot seleccionado:"
    echo "  $snapshot_id"
    echo

    read -r -u "$TTY_FD" -p \
        "¿Eliminar este snapshot? [s/N]: " answer

    if [[ ! "$answer" =~ ^[SsYy]$ ]]; then
        echo
        echo "Operación cancelada."
        pause
        return
    fi

    echo
    echo "Eliminando snapshot..."
    echo

    timeshift --delete --snapshot "$snapshot_id"

    result=$?

    echo

    if [[ "$result" -eq 0 ]]; then
        echo "Snapshot eliminado correctamente."
    else
        echo "ERROR: No se pudo eliminar el snapshot."
        echo "Código de salida: $result"
    fi

    pause
}

# ============================================================
# CONFIGURACIÓN
# ============================================================

show_config() {
    ensure_timeshift || return

    clear

    echo "============================================================"
    echo " CONFIGURACIÓN DE TIMESHIFT"
    echo "============================================================"
    echo

    if [[ -f /etc/timeshift/timeshift.json ]]; then
        echo "Archivo:"
        echo "/etc/timeshift/timeshift.json"
        echo
        echo "------------------------------------------------------------"
        cat /etc/timeshift/timeshift.json
        echo
        echo "------------------------------------------------------------"
    else
        echo "No existe todavía:"
        echo
        echo "/etc/timeshift/timeshift.json"
        echo
        echo "Timeshift está funcionando en modo de primera ejecución."
    fi

    pause
}

# ============================================================
# INFORMACIÓN DEL SISTEMA
# ============================================================

system_info() {
    clear

    echo "============================================================"
    echo " INFORMACIÓN DEL SISTEMA"
    echo "============================================================"
    echo

    echo "Hostname:"
    hostname

    echo
    echo "Sistema operativo:"

    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        echo "$PRETTY_NAME"
    fi

    echo
    echo "Kernel:"
    uname -r

    echo
    echo "Arquitectura:"
    uname -m

    echo
    echo "Memoria:"
    free -h

    echo
    echo "Almacenamiento:"
    df -hT

    echo
    echo "Dispositivos:"
    lsblk -o NAME,SIZE,FSTYPE,TYPE,MOUNTPOINTS

    pause
}

# ============================================================
# INTERFAZ GRÁFICA
# ============================================================

launch_gui() {
    ensure_timeshift || return

    clear

    echo "============================================================"
    echo " INTERFAZ GRÁFICA DE TIMESHIFT"
    echo "============================================================"
    echo

    if ! command_exists timeshift-gtk; then
        echo "timeshift-gtk no está disponible."
        echo
        echo "Instala el paquete Timeshift:"
        echo
        echo "  sudo apt install timeshift"
        pause
        return
    fi

    echo "Este servidor está diseñado para funcionar sin entorno gráfico."
    echo
    echo "Si existe un DISPLAY disponible, se intentará iniciar"
    echo "la interfaz gráfica de Timeshift."
    echo

    read -r -u "$TTY_FD" -p \
        "¿Iniciar timeshift-gtk? [s/N]: " answer

    if [[ ! "$answer" =~ ^[SsYy]$ ]]; then
        echo
        echo "Operación cancelada."
        pause
        return
    fi

    echo

    timeshift-gtk

    result=$?

    echo

    if [[ "$result" -ne 0 ]]; then
        echo "No se pudo iniciar la interfaz gráfica."
        echo
        echo "En Ubuntu Server sin GUI esto es normal."
        echo "La administración por consola continúa disponible."
    fi

    pause
}

# ============================================================
# MENÚ PRINCIPAL
# ============================================================

main_menu() {

    while true; do

        clear

        echo "============================================================"
        echo "                    TIMESHIFT MENU"
        echo "                    Versión $SCRIPT_VERSION"
        echo "============================================================"
        echo
        echo "  1) Instalar Timeshift"
        echo "  2) Ver versión"
        echo "  3) Ver dispositivos"
        echo "  4) Ver snapshots"
        echo "  5) Crear snapshot"
        echo "  6) Restaurar snapshot"
        echo "  7) Eliminar snapshot"
        echo "  8) Ver configuración"
        echo "  9) Ver espacio y discos"
        echo " 10) Información del sistema"
        echo " 11) Abrir interfaz gráfica"
        echo
        echo "  0) Salir"
        echo
        echo "============================================================"
        echo

        read -r -u "$TTY_FD" -p "Selecciona una opción: " option

        case "$option" in

            1)
                install_timeshift
                ;;

            2)
                show_version
                ;;

            3)
                list_devices
                ;;

            4)
                list_snapshots
                ;;

            5)
                create_snapshot
                ;;

            6)
                restore_snapshot
                ;;

            7)
                delete_snapshot
                ;;

            8)
                show_config
                ;;

            9)
                show_disk_space
                ;;

            10)
                system_info
                ;;

            11)
                launch_gui
                ;;

            0)
                clear
                echo "Timeshift Menu finalizado."
                exit 0
                ;;

            *)
                echo
                echo "Opción no válida."
                sleep 1
                ;;

        esac

    done
}

# ============================================================
# INICIO
# ============================================================

require_root
setup_tty
main_menu
