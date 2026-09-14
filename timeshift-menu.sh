
#!/usr/bin/env bash

set -u

SCRIPT_VERSION="1.0.0"
TTY_FD=3

# ============================================================
# Timeshift Menu
# Gestión de snapshots de sistema para Ubuntu Server
# ============================================================

setup_tty() {
    if [[ -r /dev/tty && -w /dev/tty ]]; then
        exec 3<>/dev/tty
    else
        echo "ERROR: No se puede acceder a /dev/tty."
        exit 1
    fi
}

pause() {
    echo
    read -r -u "$TTY_FD" -p "Presiona ENTER para continuar..."
}

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        echo "ERROR: Este script debe ejecutarse como root."
        echo
        echo "Ejecuta:"
        echo "  sudo bash timeshift-menu.sh"
        exit 1
    fi
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

timeshift_installed() {
    command_exists timeshift
}

install_timeshift() {
    echo
    echo "=============================================="
    echo " INSTALAR TIMESHHIFT"
    echo "=============================================="
    echo

    if timeshift_installed; then
        echo "Timeshift ya está instalado."
        timeshift --version 2>/dev/null || true
        pause
        return
    fi

    echo "Actualizando índice de paquetes..."
    apt-get update || {
        echo "ERROR: No se pudo actualizar APT."
        pause
        return
    }

    echo
    echo "Instalando Timeshift..."
    apt-get install -y timeshift || {
        echo "ERROR: No se pudo instalar Timeshift."
        pause
        return
    }

    echo
    echo "Timeshift instalado correctamente."
    timeshift --version 2>/dev/null || true

    pause
}

check_timeshift() {
    if ! timeshift_installed; then
        echo
        echo "Timeshift no está instalado."
        echo
        read -r -u "$TTY_FD" -p "¿Instalar Timeshift ahora? [s/N]: " answer

        if [[ "$answer" =~ ^[SsYy]$ ]]; then
            install_timeshift
        fi

        return 1
    fi

    return 0
}

show_version() {
    echo
    echo "=============================================="
    echo " VERSIÓN"
    echo "=============================================="
    echo

    if timeshift_installed; then
        timeshift --version
    else
        echo "Timeshift no está instalado."
    fi

    pause
}

list_devices() {
    check_timeshift || return

    echo
    echo "=============================================="
    echo " DISPOSITIVOS DISPONIBLES"
    echo "=============================================="
    echo

    timeshift --list-devices

    pause
}

list_snapshots() {
    check_timeshift || return

    echo
    echo "=============================================="
    echo " SNAPSHOTS"
    echo "=============================================="
    echo

    timeshift --list

    pause
}

create_snapshot() {
    check_timeshift || return

    echo
    echo "=============================================="
    echo " CREAR SNAPSHOT"
    echo "=============================================="
    echo

    read -r -u "$TTY_FD" -p \
        "Comentario del snapshot [Manual Timeshift]: " comment

    if [[ -z "$comment" ]]; then
        comment="Manual Timeshift"
    fi

    echo
    echo "Se creará un snapshot con el comentario:"
    echo
    echo "  $comment"
    echo

    read -r -u "$TTY_FD" -p \
        "¿Continuar? [s/N]: " answer

    if [[ ! "$answer" =~ ^[SsYy]$ ]]; then
        echo
        echo "Operación cancelada."
        pause
        return
    fi

    echo
    echo "Creando snapshot..."
    echo

    timeshift --create --comments "$comment" --scripted

    result=$?

    echo

    if [[ "$result" -eq 0 ]]; then
        echo "Snapshot creado correctamente."
    else
        echo "ERROR: Timeshift no pudo crear el snapshot."
    fi

    pause
}

restore_snapshot() {
    check_timeshift || return

    echo
    echo "=============================================="
    echo " RESTAURAR SNAPSHOT"
    echo "=============================================="
    echo

    echo "Snapshots disponibles:"
    echo

    timeshift --list

    echo
    echo "IMPORTANTE:"
    echo "La restauración puede modificar archivos del sistema."
    echo "Verifica cuidadosamente el snapshot seleccionado."
    echo

    read -r -u "$TTY_FD" -p \
        "ID del snapshot a restaurar: " snapshot_id

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
        "¿CONFIRMAS LA RESTAURACIÓN? Escribe RESTAURAR: " confirmation

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

    pause
}

delete_snapshot() {
    check_timeshift || return

    echo
    echo "=============================================="
    echo " ELIMINAR SNAPSHOT"
    echo "=============================================="
    echo

    echo "Snapshots disponibles:"
    echo

    timeshift --list

    echo
    read -r -u "$TTY_FD" -p \
        "ID del snapshot a eliminar: " snapshot_id

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
        echo "Snapshot eliminado."
    else
        echo "ERROR: No se pudo eliminar el snapshot."
    fi

    pause
}

launch_gui() {
    check_timeshift || return

    echo
    echo "=============================================="
    echo " INTERFAZ GRÁFICA"
    echo "=============================================="
    echo
    echo "Timeshift-gtk requiere un entorno gráfico."
    echo
    echo "En Ubuntu Server sin GUI no aparecerá una ventana."
    echo
    echo "Comando:"
    echo "  sudo timeshift-gtk"
    echo

    read -r -u "$TTY_FD" -p \
        "¿Intentar iniciar timeshift-gtk? [s/N]: " answer

    if [[ "$answer" =~ ^[SsYy]$ ]]; then
        timeshift-gtk
    fi
}

show_config() {
    check_timeshift || return

    echo
    echo "=============================================="
    echo " CONFIGURACIÓN"
    echo "=============================================="
    echo

    if [[ -f /etc/timeshift/timeshift.json ]]; then
        cat /etc/timeshift/timeshift.json
    else
        echo "No existe todavía:"
        echo "/etc/timeshift/timeshift.json"
        echo
        echo "Timeshift creará la configuración cuando sea configurado."
    fi

    pause
}

system_info() {
    echo
    echo "=============================================="
    echo " INFORMACIÓN DEL SISTEMA"
    echo "=============================================="
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
    echo "Discos:"
    lsblk -o NAME,SIZE,FSTYPE,TYPE,MOUNTPOINTS

    echo
    echo "Uso de almacenamiento:"
    df -h

    pause
}

main_menu() {
    while true; do
        clear

        echo "============================================================"
        echo "                 TIMESHIFT MENU"
        echo "                 Versión $SCRIPT_VERSION"
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
        echo "  9) Información del sistema"
        echo " 10) Abrir interfaz gráfica"
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
                system_info
                ;;
            10)
                launch_gui
                ;;
            0)
                echo
                echo "Saliendo."
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


### Guardarlo en tu repositorio

Por ejemplo:


nano timeshift-menu.sh


Pegas el contenido y guardas.

Luego:


chmod +x timeshift-menu.sh


Para ejecutarlo:


sudo ./timeshift-menu.sh


Y también funcionará correctamente descargándolo mediante `curl`, porque el menú lee desde `/dev/tty` y **no desde el pipe de `curl`**:


curl -fsSL https://raw.githubusercontent.com/pccurico/install/master/timeshift-menu.sh | sudo bash


El script **solo administra Timeshift**. No instala ni modifica Apache, PHP, MySQL, Ollama, OmniRoute ni el resto de tu configuración.
