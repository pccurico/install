#!/usr/bin/env bash

set -u

SCRIPT_VERSION="1.2.0"
TTY_FD=3

# ============================================================
# TIMESHIFT MENU
# Ubuntu Server
#
# Política:
# - Timeshift RSYNC
# - Configuración predeterminada de Timeshift
# - Sin particiones nuevas
# - Sin LVM nuevo
# - Excluir modelos de Ollama
# - Conservar configuración de Ollama
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
    if [[ "$EUID" -ne 0 ]]; then
        echo "ERROR: Ejecuta este script con sudo."
        echo
        echo "sudo ./timeshift-menu.sh"
        exit 1
    fi
}

pause() {
    echo
    read -r -u "$TTY_FD" -p "Presiona ENTER para continuar..."
}

timeshift_installed() {
    command -v timeshift >/dev/null 2>&1
}

ensure_timeshift() {
    if timeshift_installed; then
        return 0
    fi

    echo
    echo "Timeshift no está instalado."
    echo

    read -r -u "$TTY_FD" -p \
        "¿Deseas instalar Timeshift? [s/N]: " answer

    if [[ "$answer" =~ ^[SsYy]$ ]]; then
        install_timeshift
        return $?
    fi

    return 1
}

# ============================================================
# INSTALAR
# ============================================================

install_timeshift() {

    clear

    echo "============================================================"
    echo " INSTALAR TIMESHIFT"
    echo "============================================================"
    echo

    if timeshift_installed; then
        echo "Timeshift ya está instalado."
        timeshift --version 2>/dev/null || true
        pause
        return
    fi

    echo "Actualizando repositorios..."
    echo

    if ! apt-get update; then
        echo
        echo "ERROR: Falló apt-get update."
        pause
        return
    fi

    echo
    echo "Instalando Timeshift..."
    echo

    if apt-get install -y timeshift; then
        echo
        echo "Timeshift instalado correctamente."
        timeshift --version 2>/dev/null || true
    else
        echo
        echo "ERROR: No se pudo instalar Timeshift."
    fi

    pause
}

# ============================================================
# VERSION
# ============================================================

show_version() {

    clear

    echo "============================================================"
    echo " VERSIÓN"
    echo "============================================================"
    echo

    if timeshift_installed; then
        timeshift --version
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
    echo " DISPOSITIVOS DE TIMESHIFT"
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
    echo " SNAPSHOTS"
    echo "============================================================"
    echo

    timeshift --list

    pause
}

# ============================================================
# ESPACIO
# ============================================================

show_space() {

    clear

    echo "============================================================"
    echo " ESPACIO DE DISCO"
    echo "============================================================"
    echo

    df -hT

    echo
    echo "DISPOSITIVOS:"
    echo

    lsblk -o NAME,SIZE,FSTYPE,TYPE,MOUNTPOINTS

    pause
}

# ============================================================
# CONFIGURAR EXCLUSIÓN OLLAMA
# ============================================================

configure_ollama_exclusion() {

    ensure_timeshift || return

    clear

    echo "============================================================"
    echo " EXCLUSIÓN DE MODELOS OLLAMA"
    echo "============================================================"
    echo

    echo "Se excluirán los modelos de Ollama:"
    echo
    echo "  /var/lib/ollama/models"
    echo
    echo "La configuración de Ollama NO será excluida."
    echo
    echo "Esto significa que se conservarán:"
    echo
    echo "  /etc/ollama/"
    echo "  configuración del servicio"
    echo "  configuración del sistema"
    echo
    echo "y solamente se excluirán los archivos grandes de modelos."
    echo

    if [[ ! -d /var/lib/ollama/models ]]; then
        echo "Aviso: el directorio de modelos todavía no existe."
        echo
    else
        echo "Tamaño actual de modelos:"
        du -sh /var/lib/ollama/models 2>/dev/null || true
        echo
    fi

    pause
}

# ============================================================
# CREAR SNAPSHOT
# ============================================================

create_snapshot() {

    ensure_timeshift || return

    clear

    echo "============================================================"
    echo " CREAR SNAPSHOT RSYNC"
    echo "============================================================"
    echo

    echo "Configuración:"
    echo
    echo "  Tipo:             RSYNC"
    echo "  Particiones:      Ninguna nueva"
    echo "  Modelos Ollama:   EXCLUIDOS"
    echo "  Configuración:    CONSERVADA"
    echo

    echo "Exclusión:"
    echo
    echo "  /var/lib/ollama/models"
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

    read -r -u "$TTY_FD" -p \
        "¿Crear snapshot? [s/N]: " answer

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

    # --------------------------------------------------------
    # Importante:
    #
    # Timeshift utiliza su configuración normal.
    # La exclusión se aplica mediante --exclude.
    #
    # Se excluyen únicamente los modelos de Ollama.
    # --------------------------------------------------------

    timeshift \
        --create \
        --comments "$comment" \
        --exclude "/var/lib/ollama/models/**" \
        --scripted

    result=$?

    echo
    echo "============================================================"

    if [[ "$result" -ne 0 ]]; then

        echo " ERROR AL CREAR SNAPSHOT"
        echo "============================================================"
        echo
        echo "Timeshift devolvió código de salida: $result"
        echo
        echo "El snapshot NO se considera creado."
        echo

        pause
        return

    fi

    # --------------------------------------------------------
    # Verificación adicional.
    #
    # No mostramos éxito solamente porque el comando terminó.
    # Comprobamos que Timeshift tenga snapshots.
    # --------------------------------------------------------

    echo "Verificando snapshot..."
    echo

    snapshot_output="$(timeshift --list 2>&1)"
    list_result=$?

    if [[ "$list_result" -ne 0 ]]; then
        echo "ERROR: No se pudo verificar el snapshot."
        echo
        echo "$snapshot_output"
        pause
        return
    fi

    if echo "$snapshot_output" | grep -q "No snapshots found"; then
        echo "ERROR: Timeshift no tiene snapshots registrados."
        echo
        echo "$snapshot_output"
        pause
        return
    fi

    echo
    echo "============================================================"
    echo " SNAPSHOT CREADO CORRECTAMENTE"
    echo "============================================================"
    echo
    echo "$snapshot_output"

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

    timeshift --list

    echo
    echo "ADVERTENCIA"
    echo "La restauración puede modificar archivos del sistema."
    echo

    read -r -u "$TTY_FD" -p \
        "ID del snapshot: " snapshot_id

    if [[ -z "$snapshot_id" ]]; then
        echo "No se indicó ningún snapshot."
        pause
        return
    fi

    echo
    echo "Snapshot seleccionado:"
    echo "$snapshot_id"
    echo

    read -r -u "$TTY_FD" -p \
        "Escribe RESTAURAR para confirmar: " confirmation

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
        echo
        echo "Se recomienda reiniciar el servidor."
    else
        echo "ERROR: Restauración fallida."
        echo "Código: $result"
    fi

    pause
}

# ============================================================
# ELIMINAR SNAPSHOT
# ============================================================

delete_snapshot() {

    ensure_timeshift || return

    clear

    echo "============================================================"
    echo " ELIMINAR SNAPSHOT"
    echo "============================================================"
    echo

    timeshift --list

    echo

    read -r -u "$TTY_FD" -p \
        "ID del snapshot: " snapshot_id

    if [[ -z "$snapshot_id" ]]; then
        echo "No se indicó ningún snapshot."
        pause
        return
    fi

    echo
    echo "Snapshot:"
    echo "  $snapshot_id"
    echo

    read -r -u "$TTY_FD" -p \
        "¿Eliminar? [s/N]: " answer

    if [[ ! "$answer" =~ ^[SsYy]$ ]]; then
        echo
        echo "Operación cancelada."
        pause
        return
    fi

    echo
    echo "Eliminando..."
    echo

    timeshift --delete --snapshot "$snapshot_id"

    result=$?

    echo

    if [[ "$result" -eq 0 ]]; then
        echo "Snapshot eliminado correctamente."
    else
        echo "ERROR al eliminar snapshot."
        echo "Código: $result"
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
    echo " CONFIGURACIÓN TIMESHIFT"
    echo "============================================================"
    echo

    if [[ -f /etc/timeshift/timeshift.json ]]; then
        cat /etc/timeshift/timeshift.json
    else
        echo "No existe todavía:"
        echo
        echo "/etc/timeshift/timeshift.json"
        echo
        echo "Timeshift está utilizando su configuración inicial."
    fi

    pause
}

# ============================================================
# SISTEMA
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
    echo "Sistema:"

    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        echo "$PRETTY_NAME"
    fi

    echo
    echo "Kernel:"
    uname -r

    echo
    echo "Memoria:"
    free -h

    echo
    echo "Discos:"
    lsblk -o NAME,SIZE,FSTYPE,TYPE,MOUNTPOINTS

    echo
    echo "Espacio:"
    df -hT

    pause
}

# ============================================================
# GUI
# ============================================================

launch_gui() {

    ensure_timeshift || return

    clear

    echo "============================================================"
    echo " INTERFAZ GRÁFICA"
    echo "============================================================"
    echo

    if ! command -v timeshift-gtk >/dev/null 2>&1; then
        echo "timeshift-gtk no está disponible."
        echo
        echo "Instala Timeshift con:"
        echo
        echo "sudo apt install timeshift"
        pause
        return
    fi

    echo "Ubuntu Server normalmente no tiene entorno gráfico."
    echo

    read -r -u "$TTY_FD" -p \
        "¿Intentar iniciar timeshift-gtk? [s/N]: " answer

    if [[ ! "$answer" =~ ^[SsYy]$ ]]; then
        echo "Operación cancelada."
        pause
        return
    fi

    timeshift-gtk

    pause
}

# ============================================================
# MENÚ
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
        echo "  5) Crear snapshot RSYNC"
        echo "  6) Restaurar snapshot"
        echo "  7) Eliminar snapshot"
        echo "  8) Ver configuración"
        echo "  9) Ver espacio y discos"
        echo " 10) Información del sistema"
        echo " 11) Ver exclusión de modelos Ollama"
        echo " 12) Abrir interfaz gráfica"
        echo
        echo "  0) Salir"
        echo
        echo "============================================================"
        echo

        read -r -u "$TTY_FD" -p \
            "Selecciona una opción: " option

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
                show_space
                ;;

            10)
                system_info
                ;;

            11)
                configure_ollama_exclusion
                ;;

            12)
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

