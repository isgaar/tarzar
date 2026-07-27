# Tarzar

**Tarzar** (de `tar` + `lanzar`) es una herramienta sencilla y funcional en Bash para instalar, extraer y registrar aplicaciones distribuidas en formato Tarball (`.tar.gz`, `.tar.xz`, `.tgz`) en sistemas GNU/Linux.

Automatiza la extracción en `/opt/`, la creación de accesos directos de escritorio (`.desktop`) y la generación de comandos wrappers en `/usr/local/bin/` para que las aplicaciones se ejecuten desvinculadas de la terminal.

## Características

- **Perfiles integrados con soporte especial**:
  - **Zen Browser**: Con soporte nativo para Wayland (`--ozone-platform=wayland`) y registro de tipos MIME de navegador.
  - **Antigravity IDE**: Creación ágil del entorno de desarrollo.
  - **Telegram Desktop**: Registro y descarga oficial automática.
  - **PCSX2 desde código fuente**: Clona (si hace falta) siempre en `~/Documentos/pcsx2`, prepara el entorno de Gentoo, compila con Clang/lld y genera un acceso de KDE limitado a tu usuario.
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

# Compilar/actualizar PCSX2 desde ~/Documentos/pcsx2
./gentoo-tools/pcsx2.sh
```

### PCSX2 en Gentoo

La herramienta ejecutable `gentoo-tools/pcsx2.sh` usa el repositorio existente en `~/Documentos/pcsx2`; si
no existe, lo clona ahí con sus submódulos. Nunca instala PCSX2 en `/usr` ni en
`/opt/`. Por defecto verifica las dependencias mediante `sudo emerge --ask`,
construye las dependencias locales que usa el proyecto,
configura una compilación `Release` con Clang, lld, `ccache`, LTO selectivo y
las optimizaciones `-march=native` propias de PCSX2, y finalmente deja el
lanzador en `~/.local/share/applications/pcsx2-qt.desktop`. También crea el
comando de usuario `~/.local/bin/pcsx2-qt` y registra su icono en el tema local
de KDE (`~/.local/share/icons/hicolor/256x256/apps/pcsx2.png`).

En ejecuciones posteriores reutiliza `deps/`, vuelve a configurar y compila
solo lo que haya cambiado. También puede invocarse desde el menú de Tarzar o
con `./instalar-apps.sh --pcsx2`.

Si una configuración anterior de CMake quedó incompleta, usa
`./gentoo-tools/pcsx2.sh --clean`; solo elimina el directorio generado
`~/Documentos/pcsx2/build` antes de recompilar. `--launch` abre PCSX2 al final.
Si falla temporalmente la descarga de libpng desde SourceForge, la herramienta
la reintenta automáticamente antes de volver a ejecutar el script oficial.
`--skip-system-deps` existe solo para una recompilación en la que ya hayas
verificado las dependencias de Portage.

PCSX2 no incluye una BIOS: usa solamente un volcado obtenido de tu propia PS2.
En la Radeon Vega integrada se recomienda Vulkan y una resolución interna de
2x–3x para los juegos exigentes.

## Licencia
Este proyecto es software libre. Puedes usarlo, modificarlo y distribuirlo libremente.
