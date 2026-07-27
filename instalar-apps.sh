#!/bin/bash
# ==============================================================================
#  instalar-apps.sh
#  Gestor e Instalador de Aplicaciones en Tarball para Linux (.tar.gz, .tar.xz)
# ==============================================================================
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

# Colores para la interfaz
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
RESET='\033[0m'

DESKTOP_DIR="$HOME/.local/share/applications"
DOWNLOADS_DIR="$HOME/Descargas"
DOWNLOAD_SEARCH_DIRS=()

# Funciones de logging
log_info() { echo -e "${CYAN}[i] $*${RESET}"; }
log_ok() { echo -e "${GREEN}[✔] $*${RESET}"; }
log_warn() { echo -e "${YELLOW}[!] $*${RESET}"; }
log_err() { echo -e "${RED}[✘] $*${RESET}"; }

# Registrar una ruta de descargas una sola vez. Se conservan tanto el nombre
# localizado como el estándar porque xdg-user-dir puede no estar configurado.
add_download_search_dir() {
    local candidate="$1"
    local registered

    [ -n "$candidate" ] || return 0

    for registered in "${DOWNLOAD_SEARCH_DIRS[@]}"; do
        [ "$registered" = "$candidate" ] && return 0
    done

    DOWNLOAD_SEARCH_DIRS+=("$candidate")
}

init_download_search_dirs() {
    local xdg_download_dir=""

    add_download_search_dir "$DOWNLOADS_DIR"
    add_download_search_dir "$HOME/Downloads"

    if [ -n "${XDG_DOWNLOAD_DIR:-}" ]; then
        add_download_search_dir "$XDG_DOWNLOAD_DIR"
    fi

    if command -v xdg-user-dir &>/dev/null; then
        xdg_download_dir=$(xdg-user-dir DOWNLOAD 2>/dev/null || true)
        add_download_search_dir "$xdg_download_dir"
    fi
}

init_download_search_dirs

# Asegurar que el directorio de aplicaciones de usuario existe
mkdir -p "$DESKTOP_DIR"

# 1. Comprobación de dependencias básicas
check_deps() {
    local deps=(curl tar grep cut uniq wc find sed date)
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            log_err "Error: El comando '$dep' no está instalado. Instálalo para continuar."
            exit 1
        fi
    done
}

# Crear script wrapper en /usr/local/bin para lanzar la app de forma desvinculada
create_wrapper() {
    local cmd_name="$1"
    local exec_path="$2"
    local extra_args="$3"
    
    local wrapper_path="/usr/local/bin/$cmd_name"
    log_info "Creando lanzador de terminal en $wrapper_path..."
    
    sudo rm -f "$wrapper_path"
    sudo bash -c "cat > \"$wrapper_path\"" << EOF
#!/bin/bash
# Lanzador para $cmd_name generado automáticamente por instalar-apps.sh
set -u

log_dir="\${XDG_CACHE_HOME:-\$HOME/.cache}/tarzar-launchers"
mkdir -p "\$log_dir"
log_file="\$log_dir/$cmd_name.log"

unset ELECTRON_RUN_AS_NODE
unset VSCODE_CLI
unset VSCODE_IPC_HOOK_CLI
unset VSCODE_ESM_ENTRYPOINT
unset VSCODE_HANDLES_UNCAUGHT_ERRORS
unset VSCODE_NLS_CONFIG

{
    echo "[\$(date -Is)] Lanzando: $exec_path $extra_args \$*"
    nohup "$exec_path" $extra_args "\$@" >>"\$log_file" 2>&1 &
    echo "[\$(date -Is)] PID: \$!"
} >>"\$log_file" 2>&1
EOF
    sudo chmod +x "$wrapper_path"
    log_ok "Lanzador de terminal creado: $wrapper_path"
}

# Corregir dueño/permisos tras extraer en /opt. Algunas apps Electron/Chromium
# dependen de chrome-sandbox como root:root con setuid.
fix_opt_permissions() {
    local dest_dir="$1"
    local sandbox_path="$dest_dir/chrome-sandbox"

    log_info "Corrigiendo dueño de instalación en $dest_dir..."
    sudo chown -R root:root "$dest_dir"

    if [ -f "$sandbox_path" ]; then
        log_info "Ajustando permisos de chrome-sandbox..."
        sudo chown root:root "$sandbox_path"
        sudo chmod 4755 "$sandbox_path"
    fi
}

repair_config_path() {
    local config_path="$1"

    if [ -L "$config_path" ]; then
        local link_target
        link_target=$(readlink "$config_path" || true)
        if [ -n "$link_target" ]; then
            case "$link_target" in
                /*) ;;
                *) link_target="$(dirname "$config_path")/$link_target" ;;
            esac

            if [ ! -d "$link_target" ]; then
                log_warn "El enlace $config_path apunta a un directorio inexistente. Creando $link_target..."
                mkdir -p "$link_target"
            fi
        fi
        return 0
    fi

    if [ -e "$config_path" ] && [ ! -d "$config_path" ]; then
        local backup_path
        backup_path="$config_path.bak.$(date +%Y%m%d%H%M%S)"
        log_warn "$config_path existe pero no es un directorio. Moviendo a $backup_path..."
        mv "$config_path" "$backup_path"
    fi

    mkdir -p "$config_path"
}

ensure_antigravity_config_dir() {
    local config_base="${XDG_CONFIG_HOME:-$HOME/.config}"

    repair_config_path "$config_base/Antigravity IDE"

    if [ -d "$HOME/.config/niri/xdg-config" ]; then
        repair_config_path "$HOME/.config/niri/xdg-config/Antigravity IDE"
    fi
}

# Extraer un tarball de forma inteligente a /opt/
extract_tarball() {
    local tarball="$1"
    local dest_dir="$2"
    
    log_info "Analizando estructura del tarball: $(basename "$tarball")..."
    
    # Comprobar si tiene un único directorio raíz
    local root_entries
    root_entries=$(tar -tf "$tarball" 2>/dev/null | sed -n '1,100p' | cut -d/ -f1 | grep -v '^\s*$' | uniq | wc -l)
    
    # Crear directorio si no existe (con sudo)
    sudo mkdir -p "$dest_dir"
    
    # Limpiar contenido anterior si existe
    if [ "$(ls -A "$dest_dir" 2>/dev/null)" ]; then
        log_warn "El directorio $dest_dir no está vacío. Vaciando para evitar conflictos..."
        sudo rm -rf "${dest_dir:?}"/*
    fi
    
    log_info "Extrayendo archivos en $dest_dir..."
    if [ "$root_entries" -eq 1 ]; then
        # Extraer quitando el primer directorio raíz redundante
        sudo tar --same-owner -xf "$tarball" -C "$dest_dir" --strip-components=1
    else
        sudo tar --same-owner -xf "$tarball" -C "$dest_dir"
    fi

    fix_opt_permissions "$dest_dir"
    
    log_ok "Extracción completada en $dest_dir"
}

# === PERFIL: ZEN BROWSER ===
install_zen() {
    echo -e "\n${BOLD}${GREEN}--- Instalando Zen Browser ---${RESET}"
    
    # Buscar si ya hay un tarball de Zen en Descargas o directorio actual
    local tarball=""
    local search_paths=("${DOWNLOAD_SEARCH_DIRS[@]}" ".")
    for path in "${search_paths[@]}"; do
        local found
        found=$(find "$path" -maxdepth 1 -type f \
            \( -iname "*zen*.tar.*" -o -iname "*zen*.tgz" \) \
            -print -quit 2>/dev/null || true)
        if [ -n "$found" ]; then
            tarball="$found"
            break
        fi
    done
    
    if [ -n "$tarball" ]; then
        log_ok "Se encontró un archivo local de Zen Browser: $tarball"
    else
        log_warn "No se encontró un archivo local de Zen Browser en Descargas."
        echo -ne "¿Deseas descargar la última versión desde GitHub? (S/n): "
        read -r reply
        if [[ "$reply" =~ ^[Nn] ]]; then
            log_info "Cancelando instalación de Zen."
            return 1
        fi
        
        log_info "Obteniendo URL de descarga de Zen Browser..."
        local zen_url=""
        # Intentar obtener de la API de GitHub la versión optimizada o genérica para Linux
        zen_url=$(curl -s https://api.github.com/repos/zen-browser/desktop/releases/latest | grep "browser_download_url" | grep -E "zen\.linux-.*\.tar\.xz" | cut -d '"' -f 4 | head -n 1 || true)
        
        if [ -z "$zen_url" ]; then
            zen_url="https://github.com/zen-browser/desktop/releases/latest/download/zen.linux-specific.tar.xz"
            log_warn "No se pudo consultar la API de GitHub. Usando fallback URL: $zen_url"
        else
            log_info "URL detectada: $zen_url"
        fi
        
        tarball="/tmp/zen.linux.tar.xz"
        log_info "Descargando Zen Browser..."
        curl -L -o "$tarball" "$zen_url"
    fi
    
    # Extraer a /opt/zen
    extract_tarball "$tarball" "/opt/zen"
    
    # Configurar ícono
    local icon_path="/opt/zen/browser/chrome/icons/default/default128.png"
    if [ ! -f "$icon_path" ]; then
        icon_path=$(find "/opt/zen" -maxdepth 4 \( -name "*.png" -o -name "*.svg" \) | grep -i "icon\|logo\|app" | head -n 1 || true)
        if [ -z "$icon_path" ]; then
            icon_path="application-x-executable"
        fi
    fi
    
    log_info "Creando acceso directo (.desktop) para Zen Browser..."
    cat > "$DESKTOP_DIR/zen-browser.desktop" << EOF
[Desktop Entry]
Name=Zen Browser
Comment=Experience tranquillity while browsing the web
GenericName=Web Browser
Exec=/opt/zen/zen --name zen-browser --class zen-browser --ozone-platform=wayland --enable-features=UseOzonePlatform,WaylandWindowDecorations %u
Icon=$icon_path
Type=Application
StartupNotify=true
StartupWMClass=zen-browser
Categories=Network;WebBrowser;
MimeType=text/html;text/xml;application/xhtml+xml;x-scheme-handler/http;x-scheme-handler/https;
EOF
    chmod +x "$DESKTOP_DIR/zen-browser.desktop"
    
    # Crear wrapper de terminal
    create_wrapper "zen-browser" "/opt/zen/zen" "--name zen-browser --class zen-browser --ozone-platform=wayland --enable-features=UseOzonePlatform,WaylandWindowDecorations"
    
    # Actualizar base de datos de escritorio
    update-desktop-database "$DESKTOP_DIR" 2>/dev/null || true
    
    # Limpiar archivo temporal si se descargó
    if [ "$tarball" = "/tmp/zen.linux.tar.xz" ]; then
        rm -f "$tarball"
    fi
    
    log_ok "¡Zen Browser instalado y configurado correctamente!"
}

# === PERFIL: ANTIGRAVITY IDE ===
install_antigravity() {
    echo -e "\n${BOLD}${GREEN}--- Instalando/Configurando Antigravity IDE ---${RESET}"
    
    # Buscar si ya hay un tarball en Descargas o directorio actual
    local tarball=""
    local search_paths=("${DOWNLOAD_SEARCH_DIRS[@]}" ".")
    for path in "${search_paths[@]}"; do
        local found
        found=$(find "$path" -maxdepth 1 -type f \
            \( -iname "*antigravity*.tar.*" -o -iname "*antigravity*.tgz" \) \
            -print -quit 2>/dev/null || true)
        if [ -n "$found" ]; then
            tarball="$found"
            break
        fi
    done
    
    local opt_dir="/opt/Antigravity IDE"
    
    if [ -n "$tarball" ]; then
        log_ok "Se encontró un archivo local de Antigravity IDE: $tarball"
        log_info "Verificando que el archivo sea un tarball válido..."
        if ! tar -tf "$tarball" >/dev/null 2>&1; then
            log_err "El archivo encontrado no es un tarball válido o no se puede leer: $tarball"
            return 1
        fi
        extract_tarball "$tarball" "$opt_dir"
    else
        log_info "No se encontró un archivo local de instalación para Antigravity IDE."
        log_info "Rutas revisadas:"
        for path in "${search_paths[@]}"; do
            echo "  - $path"
        done
        if [ -d "$opt_dir" ]; then
            log_ok "La carpeta de instalación '$opt_dir' ya existe en /opt/. Se procederá a configurar los accesos directos."
        else
            log_err "Error: No se encontró el tarball en Descargas ni la carpeta instalada en /opt/."
            echo "Por favor descarga 'Antigravity IDE.tar.gz' y colócalo en una de las rutas indicadas."
            return 1
        fi
    fi

    # El nombre del binario no coincide en todas las versiones del paquete:
    # las actuales usan "antigravity", mientras que otras pueden usar
    # "antigravity-ide". No crear lanzadores hasta haberlo localizado.
    local exec_path=""
    local candidate
    for candidate in "$opt_dir/antigravity" "$opt_dir/antigravity-ide"; do
        if [ -x "$candidate" ]; then
            exec_path="$candidate"
            break
        fi
    done

    if [ -z "$exec_path" ]; then
        log_err "No se encontró un ejecutable de Antigravity IDE en $opt_dir."
        log_err "Se esperaba '$opt_dir/antigravity' o '$opt_dir/antigravity-ide'."
        return 1
    fi

    log_ok "Ejecutable de Antigravity IDE localizado: $exec_path"

    fix_opt_permissions "$opt_dir"
    ensure_antigravity_config_dir
    
    # Buscar ícono
    local icon_path
    icon_path=$(find "$opt_dir" -maxdepth 4 \( -name "*.png" -o -name "*.svg" \) | grep -i "icon\|logo\|app" | head -n 1 || true)
    if [ -z "$icon_path" ]; then
        icon_path=$(find "$opt_dir" -maxdepth 4 -name "*.png" | head -n 1 || true)
    fi
    if [ -z "$icon_path" ]; then
        icon_path="application-x-executable"
    fi
    
    log_info "Creando acceso directo (.desktop) para Antigravity IDE..."
    cat > "$DESKTOP_DIR/antigravity-ide.desktop" << EOF
[Desktop Entry]
Name=Antigravity IDE
GenericName=Entorno de Desarrollo
Comment=Antigravity IDE
Exec=env -u ELECTRON_RUN_AS_NODE -u VSCODE_CLI -u VSCODE_IPC_HOOK_CLI -u VSCODE_ESM_ENTRYPOINT -u VSCODE_HANDLES_UNCAUGHT_ERRORS -u VSCODE_NLS_CONFIG "$exec_path" %F
Icon=$icon_path
Type=Application
StartupNotify=true
StartupWMClass=antigravity-ide
Categories=Development;IDE;
EOF
    chmod +x "$DESKTOP_DIR/antigravity-ide.desktop"
    
    # Crear wrapper de terminal
    create_wrapper "antigravity-ide" "$exec_path" ""
    
    update-desktop-database "$DESKTOP_DIR" 2>/dev/null || true
    
    log_ok "¡Antigravity IDE configurado correctamente!"
}

# === PERFIL: VSCODIUM ===
install_vscodium() {
    echo -e "\n${BOLD}${GREEN}--- Instalando/Configurando VSCodium ---${RESET}"

    local opt_dir="/opt/vscodium"
    local tarball=""
    local search_paths=("${DOWNLOAD_SEARCH_DIRS[@]}" ".")

    # El paquete portable oficial se publica como VSCodium-linux-<arquitectura>-<versión>.tar.gz.
    # Si hay varias versiones locales, seleccionar la más reciente.
    for path in "${search_paths[@]}"; do
        local found
        found=$(find "$path" -maxdepth 1 -type f \
            \( -iname "VSCodium-linux-*.tar.gz" -o -iname "VSCodium-linux-*.tar.xz" \) \
            2>/dev/null | sort -V | tail -n 1 || true)
        if [ -n "$found" ]; then
            tarball="$found"
            break
        fi
    done

    if [ -n "$tarball" ]; then
        log_ok "Se encontró el tarball de VSCodium: $tarball"
        extract_tarball "$tarball" "$opt_dir"
    elif [ -x "$opt_dir/codium" ]; then
        log_ok "VSCodium ya está instalado en $opt_dir. Se volverán a registrar sus accesos."
        fix_opt_permissions "$opt_dir"
    else
        log_err "No se encontró un tarball oficial de VSCodium ni una instalación en $opt_dir."
        echo "Descarga 'VSCodium-linux-<arquitectura>-<versión>.tar.gz' desde:"
        echo "  https://github.com/VSCodium/vscodium/releases"
        echo "y colócalo en $DOWNLOADS_DIR antes de volver a ejecutar esta opción."
        return 1
    fi

    if [ ! -x "$opt_dir/codium" ]; then
        log_err "El tarball no contiene el ejecutable esperado: $opt_dir/codium"
        return 1
    fi

    # El tarball oficial incluye este icono de aplicación (PNG de alta resolución).
    local icon_path="$opt_dir/resources/app/resources/linux/code.png"
    if [ ! -f "$icon_path" ]; then
        icon_path=$(find "$opt_dir/resources/app" -maxdepth 5 \
            \( -iname "code.png" -o -iname "*vscodium*.png" -o -iname "*codium*.svg" \) \
            2>/dev/null | head -n 1 || true)
    fi
    if [ -z "$icon_path" ] || [ ! -f "$icon_path" ]; then
        log_warn "No se encontró el icono incluido en VSCodium; se usará uno genérico."
        icon_path="text-editor"
    else
        log_ok "Icono de VSCodium localizado: $icon_path"
    fi

    log_info "Creando acceso directo (.desktop) para VSCodium..."
    cat > "$DESKTOP_DIR/codium.desktop" << EOF
[Desktop Entry]
Name=VSCodium
Comment=Editor de código libre, sin telemetría de Microsoft
GenericName=Editor de código
Exec=env -u ELECTRON_RUN_AS_NODE -u VSCODE_CLI -u VSCODE_IPC_HOOK_CLI -u VSCODE_ESM_ENTRYPOINT -u VSCODE_HANDLES_UNCAUGHT_ERRORS -u VSCODE_NLS_CONFIG $opt_dir/codium %F
Icon=$icon_path
Type=Application
Terminal=false
StartupNotify=true
StartupWMClass=VSCodium
Categories=Development;IDE;
MimeType=text/plain;inode/directory;application/x-code-workspace;
Keywords=vscodium;codium;vscode;editor;development;ide;
Actions=new-empty-window;

[Desktop Action new-empty-window]
Name=Nueva ventana vacía
Exec=env -u ELECTRON_RUN_AS_NODE -u VSCODE_CLI -u VSCODE_IPC_HOOK_CLI -u VSCODE_ESM_ENTRYPOINT -u VSCODE_HANDLES_UNCAUGHT_ERRORS -u VSCODE_NLS_CONFIG $opt_dir/codium --new-window
Icon=$icon_path
EOF
    chmod +x "$DESKTOP_DIR/codium.desktop"

    # Crear /usr/local/bin/codium; sus argumentos se conservan, por lo que "codium ." funciona.
    create_wrapper "codium" "$opt_dir/codium" ""

    update-desktop-database "$DESKTOP_DIR" 2>/dev/null || true

    log_ok "¡VSCodium instalado y configurado correctamente!"
    log_ok "Desde cualquier proyecto puedes abrir el directorio actual con: codium ."
}

# === PERFIL: APLICACIÓN GENÉRICA ===
install_generic() {
    echo -e "\n${BOLD}${GREEN}--- Instalando Aplicación Genérica ---${RESET}"
    
    # 1. Buscar tarballs en Descargas y actual
    local tarballs=()
    while IFS= read -r line; do
        [ -n "$line" ] && tarballs+=("$line")
    done < <(find "${DOWNLOAD_SEARCH_DIRS[@]}" "." -maxdepth 1 \
        \( -name "*.tar.*" -o -name "*.tgz" \) 2>/dev/null || true)
    
    local tarball=""
    if [ ${#tarballs[@]} -gt 0 ]; then
        echo "Se encontraron los siguientes tarballs disponibles:"
        for i in "${!tarballs[@]}"; do
            echo "  $((i+1))) $(basename "${tarballs[i]}")"
        done
        echo "  $(( ${#tarballs[@]} + 1 ))) Ingresar ruta manual de otro archivo"
        echo "  $(( ${#tarballs[@]} + 2 ))) Cancelar"
        
        echo -ne "\nSelecciona una opción: "
        read -r choice
        
        if [[ "$choice" =~ ^[0-9]+$ ]]; then
            if [ "$choice" -le "${#tarballs[@]}" ]; then
                tarball="${tarballs[$((choice-1))]}"
            elif [ "$choice" -eq $(( ${#tarballs[@]} + 1 )) ]; then
                echo -n "Introduce la ruta completa al archivo .tar.*: "
                read -r tarball
            else
                return 0
            fi
        else
            log_err "Opción inválida."
            return 1
        fi
    else
        echo -n "No se encontraron tarballs locales. Introduce la ruta completa al archivo .tar.*: "
        read -r tarball
    fi
    
    if [ ! -f "$tarball" ]; then
        log_err "Error: El archivo '$tarball' no existe."
        return 1
    fi
    
    # 2. Nombre del programa
    echo -n "Introduce el nombre comercial de la aplicación (ej: My Cool App): "
    read -r app_name
    if [ -z "$app_name" ]; then
        log_err "El nombre no puede estar vacío."
        return 1
    fi
    
    # Generar un nombre de directorio limpio (sin espacios ni caracteres raros)
    local sanitized_name
    sanitized_name=$(echo "$app_name" | tr -cd '[:alnum:]_-')
    local opt_dir="/opt/$sanitized_name"
    
    echo -n "Directorio de instalación [Por defecto: $opt_dir]: "
    read -r custom_opt_dir
    if [ -n "$custom_opt_dir" ]; then
        opt_dir="$custom_opt_dir"
    fi
    
    # 3. Extraer
    extract_tarball "$tarball" "$opt_dir"
    
    # 4. Detectar ejecutables en la carpeta extraída
    log_info "Buscando ejecutables en la carpeta extraída..."
    local execs=()
    while IFS= read -r line; do
        [ -n "$line" ] && execs+=("$line")
    done < <(find "$opt_dir" -maxdepth 3 -executable -type f 2>/dev/null || true)
    
    local exec_path=""
    if [ ${#execs[@]} -eq 0 ]; then
        log_warn "No se encontraron ejecutables automáticos."
        echo -n "Introduce la ruta relativa del ejecutable principal (ej: bin/launch): "
        read -r rel_exec
        exec_path="$opt_dir/$rel_exec"
    elif [ ${#execs[@]} -eq 1 ]; then
        exec_path="${execs[0]}"
        log_ok "Ejecutable autodetectado: $exec_path"
    else
        echo "Se encontraron múltiples ejecutables. Selecciona el principal:"
        for i in "${!execs[@]}"; do
            echo "  $((i+1))) ${execs[i]#$opt_dir/}"
        done
        echo -ne "\nSelecciona el número de ejecutable: "
        read -r exec_choice
        if [[ "$exec_choice" =~ ^[0-9]+$ ]] && [ "$exec_choice" -le "${#execs[@]}" ]; then
            exec_path="${execs[$((exec_choice-1))]}"
        else
            log_err "Opción inválida. Usando el primero por defecto."
            exec_path="${execs[0]}"
        fi
    fi
    
    if [ ! -f "$exec_path" ]; then
        log_err "Error: El ejecutable '$exec_path' no existe."
        return 1
    fi
    
    # 5. Detectar íconos
    log_info "Buscando archivos de ícono en la carpeta extraída..."
    local icons=()
    while IFS= read -r line; do
        [ -n "$line" ] && icons+=("$line")
    done < <(find "$opt_dir" -maxdepth 4 \( -name "*.png" -o -name "*.svg" \) | grep -i "icon\|logo\|app\|brand" || true)
    
    local icon_path=""
    if [ ${#icons[@]} -eq 0 ]; then
        # Buscar cualquier png/svg
        while IFS= read -r line; do
            [ -n "$line" ] && icons+=("$line")
        done < <(find "$opt_dir" -maxdepth 4 \( -name "*.png" -o -name "*.svg" \) || true)
    fi
    
    if [ ${#icons[@]} -eq 0 ]; then
        log_warn "No se encontraron íconos."
        icon_path="application-x-executable"
    elif [ ${#icons[@]} -eq 1 ]; then
        icon_path="${icons[0]}"
        log_ok "Ícono autodetectado: $icon_path"
    else
        echo "Se encontraron múltiples posibles íconos. Selecciona uno:"
        for i in "${!icons[@]}"; do
            echo "  $((i+1))) ${icons[i]#$opt_dir/}"
        done
        echo "  $(( ${#icons[@]} + 1 ))) Usar ícono genérico del sistema"
        echo -ne "\nSelecciona el número de ícono: "
        read -r icon_choice
        if [[ "$icon_choice" =~ ^[0-9]+$ ]]; then
            if [ "$icon_choice" -le "${#icons[@]}" ]; then
                icon_path="${icons[$((icon_choice-1))]}"
            else
                icon_path="application-x-executable"
            fi
        else
            icon_path="application-x-executable"
        fi
    fi
    
    # 6. Comentarios y Categorías
    echo -n "Introduce un comentario corto (ej: Editor de código potente): "
    read -r comment
    [ -z "$comment" ] && comment="$app_name"
    
    echo -n "Categorías de escritorio (ej: Development;IDE; o Network;WebBrowser;): [Por defecto: Utility;]: "
    read -r categories
    [ -z "$categories" ] && categories="Utility;"
    
    echo -n "Introduce argumentos adicionales para el ejecutable (opcional): "
    read -r exec_args
    
    # Generar ID de archivo .desktop único
    local desktop_id
    desktop_id=$(echo "$sanitized_name" | tr '[:upper:]' '[:lower:]')
    
    # Escribir lanzador
    log_info "Creando acceso directo (.desktop) para $app_name..."
    cat > "$DESKTOP_DIR/$desktop_id.desktop" << EOF
[Desktop Entry]
Name=$app_name
Comment=$comment
Exec="$exec_path" $exec_args
Icon=$icon_path
Type=Application
StartupNotify=true
StartupWMClass=$desktop_id
Categories=$categories
EOF
    chmod +x "$DESKTOP_DIR/$desktop_id.desktop"
    
    # Crear wrapper de terminal
    create_wrapper "$desktop_id" "$exec_path" "$exec_args"
    
    update-desktop-database "$DESKTOP_DIR" 2>/dev/null || true
    
    log_ok "¡$app_name instalada y configurada con éxito!"
}

# === PERFIL: CONFIGURAR CARPETA EXISTENTE ===
configure_existing() {
    echo -e "\n${BOLD}${GREEN}--- Configurar Lanzador para Carpeta Existente ---${RESET}"
    
    # 1. Listar carpetas en /opt/
    local dirs=()
    while IFS= read -r line; do
        [ -n "$line" ] && dirs+=("$line")
    done < <(find /opt/ -maxdepth 1 -mindepth 1 -type d 2>/dev/null || true)
    
    if [ ${#dirs[@]} -eq 0 ]; then
        log_err "No se encontraron carpetas en /opt/"
        return 1
    fi
    
    echo "Carpetas encontradas en /opt/:"
    for i in "${!dirs[@]}"; do
        echo "  $((i+1))) $(basename "${dirs[i]}")"
    done
    echo "  $(( ${#dirs[@]} + 1 ))) Cancelar"
    
    echo -ne "\nSelecciona una carpeta: "
    read -r choice
    
    local opt_dir=""
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -le "${#dirs[@]}" ]; then
        opt_dir="${dirs[$((choice-1))]}"
    else
        return 0
    fi
    
    local app_name
    app_name=$(basename "$opt_dir")
    
    # Proceder a autodetectar ejecutable e ícono
    log_info "Buscando ejecutables en $opt_dir..."
    local execs=()
    while IFS= read -r line; do
        [ -n "$line" ] && execs+=("$line")
    done < <(find "$opt_dir" -maxdepth 3 -executable -type f 2>/dev/null || true)
    
    local exec_path=""
    if [ ${#execs[@]} -eq 0 ]; then
        echo -n "Introduce la ruta relativa del ejecutable principal (ej: bin/launch): "
        read -r rel_exec
        exec_path="$opt_dir/$rel_exec"
    elif [ ${#execs[@]} -eq 1 ]; then
        exec_path="${execs[0]}"
        log_ok "Ejecutable autodetectado: $exec_path"
    else
        echo "Se encontraron múltiples ejecutables. Selecciona el principal:"
        for i in "${!execs[@]}"; do
            echo "  $((i+1))) ${execs[i]#$opt_dir/}"
        done
        echo -ne "\nSelecciona el número de ejecutable: "
        read -r exec_choice
        if [[ "$exec_choice" =~ ^[0-9]+$ ]] && [ "$exec_choice" -le "${#execs[@]}" ]; then
            exec_path="${execs[$((exec_choice-1))]}"
        else
            exec_path="${execs[0]}"
        fi
    fi
    
    log_info "Buscando íconos..."
    local icons=()
    while IFS= read -r line; do
        [ -n "$line" ] && icons+=("$line")
    done < <(find "$opt_dir" -maxdepth 4 \( -name "*.png" -o -name "*.svg" \) | grep -i "icon\|logo\|app\|brand" || true)
    
    local icon_path=""
    if [ ${#icons[@]} -eq 0 ]; then
        while IFS= read -r line; do
            [ -n "$line" ] && icons+=("$line")
        done < <(find "$opt_dir" -maxdepth 4 \( -name "*.png" -o -name "*.svg" \) || true)
    fi
    
    if [ ${#icons[@]} -eq 0 ]; then
        icon_path="application-x-executable"
    elif [ ${#icons[@]} -eq 1 ]; then
        icon_path="${icons[0]}"
    else
        echo "Se encontraron múltiples íconos. Selecciona uno:"
        for i in "${!icons[@]}"; do
            echo "  $((i+1))) ${icons[i]#$opt_dir/}"
        done
        echo "  $(( ${#icons[@]} + 1 ))) Usar ícono genérico"
        echo -ne "\nSelecciona el número de ícono: "
        read -r icon_choice
        if [[ "$icon_choice" =~ ^[0-9]+$ ]] && [ "$icon_choice" -le "${#icons[@]}" ]; then
            icon_path="${icons[$((icon_choice-1))]}"
        else
            icon_path="application-x-executable"
        fi
    fi
    
    echo -n "Introduce el nombre comercial de la aplicación [$app_name]: "
    read -r custom_name
    if [ -n "$custom_name" ]; then
        app_name="$custom_name"
    fi
    
    echo -n "Introduce un comentario corto: "
    read -r comment
    [ -z "$comment" ] && comment="$app_name"
    
    echo -n "Categorías [Por defecto: Utility;]: "
    read -r categories
    [ -z "$categories" ] && categories="Utility;"
    
    echo -n "Argumentos de lanzamiento (opcional): "
    read -r exec_args
    
    local desktop_id
    desktop_id=$(echo "$(basename "$opt_dir")" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]_-')
    
    log_info "Creando acceso directo (.desktop) para $app_name..."
    cat > "$DESKTOP_DIR/$desktop_id.desktop" << EOF
[Desktop Entry]
Name=$app_name
Comment=$comment
Exec="$exec_path" $exec_args
Icon=$icon_path
Type=Application
StartupNotify=true
StartupWMClass=$desktop_id
Categories=$categories
EOF
    chmod +x "$DESKTOP_DIR/$desktop_id.desktop"
    
    create_wrapper "$desktop_id" "$exec_path" "$exec_args"
    
    update-desktop-database "$DESKTOP_DIR" 2>/dev/null || true
    
    log_ok "¡Acceso directo configurado para la carpeta existente con éxito!"
}

# === MENÚ PRINCIPAL E INICIO ===
show_help() {
    echo -e "Uso: $0 [opción]"
    echo -e "Opciones:"
    echo -e "  --zen           Instala/registra Zen Browser directamente"
    echo -e "  --antigravity   Instala/registra Antigravity IDE directamente"
    echo -e "  --vscodium      Instala/registra VSCodium directamente"
    echo -e "  --pcsx2        Compila PCSX2 en ~/Documentos/pcsx2 y crea su lanzador KDE"
    echo -e "  -h, --help      Muestra esta ayuda"
}

# Parsear argumentos si se proveen
if [ $# -gt 0 ]; then
    check_deps
    case "$1" in
        --zen)
            install_zen
            ;;
        --antigravity)
            install_antigravity
            ;;
        --vscodium|--codium)
            install_vscodium
            ;;
        --pcsx2)
            exec "$SCRIPT_DIR/gentoo-tools/pcsx2.sh"
            ;;
        -h|--help)
            show_help
            ;;
        *)
            log_err "Opción no reconocida: $1"
            show_help
            exit 1
            ;;
    esac
    exit 0
fi

# Ejecución interactiva (sin argumentos)
check_deps

while true; do
    echo -e "\n${CYAN}==================================================${RESET}"
    echo -e "${BOLD}${GREEN}        INSTALADOR DE APLICACIONES TARBALL       ${RESET}"
    echo -e "${CYAN}==================================================${RESET}"
    echo -e "Selecciona una opción:"
    echo -e "  1) Instalar o Registrar ${BOLD}Zen Browser${RESET}"
    echo -e "  2) Instalar o Registrar ${BOLD}Antigravity IDE${RESET}"
    echo -e "  3) Instalar o Registrar ${BOLD}VSCodium${RESET}"
    echo -e "  4) Compilar y registrar ${BOLD}PCSX2${RESET} desde ~/Documentos/pcsx2"
    echo -e "  5) Instalar/Registrar una ${BOLD}Aplicación Genérica${RESET} (.tar.*)"
    echo -e "  6) Configurar accesos directos para carpeta en ${BOLD}/opt/${RESET}"
    echo -e "  7) Salir"
    echo -e "${CYAN}--------------------------------------------------${RESET}"
    echo -ne "Opción: "
    read -r main_choice
    
    case "$main_choice" in
        1)
            install_zen || true
            ;;
        2)
            install_antigravity || true
            ;;
        3)
            install_vscodium || true
            ;;
        4)
            "$SCRIPT_DIR/gentoo-tools/pcsx2.sh" || true
            ;;
        5)
            install_generic || true
            ;;
        6)
            configure_existing || true
            ;;
        7)
            echo "¡Hasta luego!"
            break
            ;;
        *)
            log_err "Opción inválida. Intenta de nuevo."
            ;;
    esac
done
