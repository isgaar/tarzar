# Tarzar

**Tarzar** (de `tar` + `lanzar`) es una herramienta sencilla y funcional en Bash para instalar, extraer y registrar aplicaciones distribuidas en formato Tarball (`.tar.gz`, `.tar.xz`, `.tgz`) en sistemas GNU/Linux.

Automatiza la extracción en `/opt/`, la creación de accesos directos de escritorio (`.desktop`) y la generación de comandos wrappers en `/usr/local/bin/` para que las aplicaciones se ejecuten desvinculadas de la terminal.

## Características

- **Perfiles integrados con soporte especial**:
  - **Zen Browser**: Con soporte nativo para Wayland (`--ozone-platform=wayland`) y registro de tipos MIME de navegador.
  - **Antigravity IDE**: Creación ágil del entorno de desarrollo.
  - **Telegram Desktop**: Registro y descarga oficial automática.
- **Asistente interactivo genérico**: Permite instalar cualquier tarball local, detectando automáticamente el binario ejecutable y los íconos de la aplicación de forma inteligente.
- **Soporte para apps ya existentes**: Crea accesos directos para cualquier aplicación que ya tengas descomprimida en `/opt/`.
- **Lanzadores silenciosos**: Los ejecutables creados en `/usr/local/bin` corren en segundo plano mediante `nohup` para que no bloqueen tu terminal.

## Requisitos

El script utiliza utilidades comunes del sistema:
- `curl`, `tar`, `find`, `grep`, `cut`, `uniq`, `wc`.

## Uso y Ejecución

Asigna permisos de ejecución al script y lánzalo:

```bash
chmod +x instalar-apps.sh
```

### 1. Menú interactivo (Recomendado)
Ejecútalo sin argumentos para abrir la interfaz de consola:
```bash
./instalar-apps.sh
```

### 2. Instalación directa por parámetros
Puedes lanzar directamente la configuración de un perfil específico:
```bash
# Instalar / configurar Zen Browser
./instalar-apps.sh --zen

# Instalar / configurar Antigravity IDE
./instalar-apps.sh --antigravity

# Instalar / configurar Telegram Desktop
./instalar-apps.sh --telegram
```

## Licencia
Este proyecto es software libre. Puedes usarlo, modificarlo y distribuirlo libremente.
