# IA-SERVER — LAMP + Ollama

Instalador automatizado para preparar un servidor **Ubuntu Server 24.04 LTS** como plataforma local de servicios web, bases de datos e inteligencia artificial.

Repositorio:

https://github.com/pccurico/install

## Instalación rápida

Desde una instalación limpia de Ubuntu Server 24.04 LTS:

```bash
curl -fsSL https://raw.githubusercontent.com/pccurico/install/main/ia-server_lamp_ollama.sh | sudo bash
```

También es posible descargar el instalador, revisarlo y ejecutarlo:

```bash
wget -qO ia-server_lamp_ollama.sh https://raw.githubusercontent.com/pccurico/install/main/ia-server_lamp_ollama.sh
chmod +x ia-server_lamp_ollama.sh
sudo ./ia-server_lamp_ollama.sh
```

> Se recomienda descargar el archivo y revisarlo antes de ejecutarlo en un servidor de producción.

---

# IA-SERVER

El instalador proporciona un menú centralizado para configurar los principales componentes del servidor.

```text
========================================
             IA-SERVER
========================================

  1) Preparación del servidor
  2) PHP
  3) Apache2
  4) MySQL
  5) phpMyAdmin
  6) OmniRoute
  7) Ollama
  8) llmfit
  9) Modelos IA
 10) Estado del sistema
 11) Actualizar componentes
 12) Salir
```

Las opciones disponibles pueden variar según la versión publicada del instalador.

---

# Requisitos

## Sistema operativo

- Ubuntu Server 24.04 LTS
- Arquitectura x86_64 recomendada
- Acceso `sudo`
- Conexión a Internet durante la instalación
- Acceso SSH recomendado

## Hardware

Los requisitos dependen principalmente de los modelos de IA que se quieran ejecutar.

Para servidores con poca memoria RAM se recomienda utilizar `llmfit` para determinar qué modelos son apropiados antes de descargarlos.

---

# Componentes instalados

## LAMP

El instalador prepara el entorno web:

- Apache2
- PHP
- PHP-FPM
- MySQL
- phpMyAdmin

Se contemplan diferentes versiones de PHP para permitir seleccionar la versión necesaria para cada proyecto.

Versiones contempladas:

```text
PHP 8.2
PHP 8.3
PHP 8.4
```

---

# Apache2

El instalador permite crear Virtual Hosts.

Ejemplo:

```text
pccontrolhub.local
```

o:

```text
proyecto.pccurico.cl
```

La creación del Virtual Host configura Apache para atender el dominio solicitado.

## Importante

Crear un Virtual Host **no crea automáticamente la resolución DNS**.

Para acceder desde otro equipo de la red mediante:

```text
http://pccontrolhub.local
```

el nombre debe poder resolverse desde ese equipo.

Las alternativas son:

- DNS local
- dnsmasq
- hosts
- mDNS/Avahi para dominios `.local`

Ejemplo de archivo hosts en Windows:

```text
192.168.1.XX    pccontrolhub.local
```

Reemplazar:

```text
192.168.1.XX
```

por la dirección IP real del IA-SERVER.

---

# PHP

El instalador permite trabajar con:

```text
PHP 8.2
PHP 8.3
PHP 8.4
```

La versión activa de PHP puede comprobarse mediante:

```bash
php -v
```

Para comprobar PHP-FPM:

```bash
systemctl status php8.4-fpm
```

Cambiar `8.4` por la versión instalada.

---

# MySQL

El instalador permite:

- instalar MySQL
- crear bases de datos
- crear usuarios
- asignar contraseñas
- asignar permisos

Ejemplo conceptual:

```text
Base de datos:
pccontrolhub

Usuario:
pccontrolhub

Contraseña:
TU_CONTRASEÑA_REAL
```

Los valores anteriores son solamente ejemplos.

No utilizar contraseñas de ejemplo en producción.

---

# phpMyAdmin

phpMyAdmin proporciona una interfaz web para administrar MySQL.

Una vez configurado Apache, puede accederse mediante el Virtual Host correspondiente.

Ejemplo:

```text
http://IP_DEL_SERVIDOR/phpmyadmin
```

o mediante el dominio configurado:

```text
http://dominio.local/phpmyadmin
```

---

# Ollama

El instalador instala Ollama como servicio del sistema.

Comprobar estado:

```bash
systemctl status ollama
```

Comprobar versión:

```bash
ollama --version
```

Comprobar modelos:

```bash
ollama list
```

---

# API de Ollama

Para permitir conexiones desde otros equipos de la red se configura:

```text
OLLAMA_HOST=0.0.0.0:11434
```

La API queda disponible en:

```text
http://IP_DEL_SERVIDOR:11434
```

Ejemplo:

```text
http://192.168.1.14:11434
```

La IP anterior es solamente un ejemplo.

Comprobar desde el servidor:

```bash
curl http://127.0.0.1:11434/api/tags
```

Comprobar desde otro equipo:

```bash
curl http://IP_DEL_SERVIDOR:11434/api/tags
```

---

# Conexión desde Windows

Una instalación de Ollama en Windows puede utilizar el Ollama del IA-SERVER.

La dirección del servidor será:

```text
http://IP_DEL_SERVIDOR:11434
```

Ejemplo:

```text
http://192.168.1.14:11434
```

En VS Code, OmniRoute u otras herramientas compatibles se puede utilizar esta dirección como endpoint de Ollama.

---

# OmniRoute

OmniRoute funciona como gateway para los modelos y proveedores configurados.

Puerto utilizado:

```text
20128
```

Dashboard:

```text
http://IP_DEL_SERVIDOR:20128
```

API:

```text
http://IP_DEL_SERVIDOR:20128/v1
```

El instalador configura OmniRoute como servicio para permitir su ejecución automática junto con el sistema.

Comprobar estado:

```bash
systemctl status omniroute
```

---

# llmfit

`llmfit` permite analizar el hardware disponible y determinar qué modelos de lenguaje son adecuados para el servidor.

Instalación:

```bash
curl -fsSL https://llmfit.axjns.dev/install.sh | sh
```

Comprobar:

```bash
llmfit --help
```

Detectar hardware:

```bash
llmfit --json system
```

Obtener recomendaciones:

```bash
llmfit recommend
```

Recomendaciones para programación:

```bash
llmfit recommend --use-case coding
```

Limitar resultados:

```bash
llmfit recommend --limit 10
```

---

# Selección de modelos

No se recomienda instalar modelos grandes de forma arbitraria.

Primero ejecutar:

```bash
llmfit recommend
```

Para programación:

```bash
llmfit recommend --use-case coding
```

El objetivo es seleccionar modelos compatibles con:

- RAM disponible
- CPU
- GPU
- memoria de GPU
- cuantización
- contexto
- caso de uso

Después de seleccionar el modelo, puede descargarse mediante Ollama:

```bash
ollama pull NOMBRE_DEL_MODELO
```

Ejemplo:

```bash
ollama pull qwen2.5-coder:7b
```

El modelo de ejemplo no representa una recomendación universal. La selección debe realizarse de acuerdo con el hardware detectado.

---

# Modelos instalados

Ver modelos:

```bash
ollama list
```

Ver modelos actualmente cargados:

```bash
ollama ps
```

Eliminar un modelo:

```bash
ollama rm NOMBRE_DEL_MODELO
```

---

# Directorio de modelos Ollama

En una instalación estándar de Ollama para Linux, los modelos se almacenan en el directorio de datos configurado por Ollama.

Antes de descargar muchos modelos se recomienda comprobar el espacio disponible:

```bash
df -h
```

Los modelos de IA pueden ocupar varios gigabytes cada uno.

---

# Servicios

Servicios principales:

```text
Apache2
MySQL
PHP-FPM
Ollama
OmniRoute
```

Comprobar servicios:

```bash
systemctl --type=service --state=running
```

Comprobar específicamente:

```bash
systemctl status apache2
systemctl status mysql
systemctl status ollama
systemctl status omniroute
```

---

# Puertos

Puertos utilizados por los componentes principales:

| Servicio | Puerto |
|---|---:|
| SSH | 22 |
| HTTP | 80 |
| HTTPS | 443 |
| OmniRoute | 20128 |
| Ollama | 11434 |
| llmfit Dashboard | 8787 |

Los puertos pueden cambiar según la configuración utilizada.

---

# Seguridad

El servidor debe mantenerse preferentemente dentro de la red LAN cuando los servicios no necesiten exposición pública.

Especialmente:

```text
11434  Ollama
20128  OmniRoute
8787   llmfit
```

No se recomienda exponer estos servicios directamente a Internet sin una configuración de seguridad adecuada.

Para acceso externo se recomienda utilizar:

- VPN
- reverse proxy
- autenticación
- firewall
- HTTPS

---

# Firewall

Si se utiliza UFW, comprobar estado:

```bash
sudo ufw status
```

Permitir SSH:

```bash
sudo ufw allow 22/tcp
```

HTTP:

```bash
sudo ufw allow 80/tcp
```

HTTPS:

```bash
sudo ufw allow 443/tcp
```

Para servicios IA se recomienda limitar el acceso a la red LAN en lugar de abrirlos globalmente.

Ejemplo:

```bash
sudo ufw allow from 192.168.1.0/24 to any port 11434 proto tcp
sudo ufw allow from 192.168.1.0/24 to any port 20128 proto tcp
```

Reemplazar:

```text
192.168.1.0/24
```

por la red LAN real.

---

# Diagnóstico rápido

## Apache

```bash
apache2ctl configtest
```

Debe devolver:

```text
Syntax OK
```

Estado:

```bash
systemctl status apache2
```

---

## MySQL

```bash
systemctl status mysql
```

Probar conexión:

```bash
mysql -u root -p
```

---

## PHP

```bash
php -v
```

Comprobar módulos:

```bash
php -m
```

---

## Ollama

```bash
systemctl status ollama
```

```bash
curl http://127.0.0.1:11434/api/tags
```

---

## OmniRoute

```bash
systemctl status omniroute
```

Probar:

```bash
curl http://127.0.0.1:20128
```

---

## Red

Ver IP:

```bash
ip addr
```

Ver rutas:

```bash
ip route
```

Probar conectividad:

```bash
ping 8.8.8.8
```

---

# Actualización

Actualizar paquetes del sistema:

```bash
sudo apt update
sudo apt upgrade
```

Actualizar Ollama utilizando su instalador oficial:

```bash
curl -fsSL https://ollama.com/install.sh | sh
```

Actualizar OmniRoute:

```bash
sudo npm update -g omniroute
```

Actualizar llmfit utilizando su instalador oficial:

```bash
curl -fsSL https://llmfit.axjns.dev/install.sh | sh
```

---

# Repositorio

Proyecto:

https://github.com/pccurico/install

Instalador:

```text
ia-server_lamp_ollama.sh
```

Instalación directa:

```bash
curl -fsSL https://raw.githubusercontent.com/pccurico/install/main/ia-server_lamp_ollama.sh | sudo bash
```

---

# Filosofía del instalador

El instalador está diseñado para convertir una instalación limpia de Ubuntu Server 24.04 LTS en una plataforma centralizada para:

```text
                    IA-SERVER
                        │
        ┌───────────────┼────────────────┐
        │               │                │
      LAMP           IA LOCAL         GATEWAY
        │               │                │
   Apache/PHP        Ollama          OmniRoute
   MySQL             llmfit
   phpMyAdmin        Modelos
        │               │
        └───────────────┼────────────────┘
                        │
                  Red LAN / SSH
                        │
             ┌──────────┴──────────┐
             │                     │
          Windows                VS Code
```

El servidor centraliza los servicios y permite que otros equipos de la red consuman las APIs mediante HTTP.

---

# Recomendación de instalación

Para una instalación nueva:

```bash
curl -fsSL https://raw.githubusercontent.com/pccurico/install/main/ia-server_lamp_ollama.sh | sudo bash
```

Después:

```bash
llmfit --json system
```

y:

```bash
llmfit recommend --use-case coding
```

Finalmente:

```bash
ollama list
```

La selección de modelos debe realizarse después de conocer las capacidades reales del servidor.