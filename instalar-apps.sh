#!/bin/bash
# ==============================================================================
#  instalar-apps.sh
#  Gestor e Instalador de Aplicaciones en Tarball para Linux (.tar.gz, .tar.xz)
# ==============================================================================
set -euo pipefail

# Colores para la interfaz
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
RESET='\033[0m'

DESKTOP_DIR="$HOME/.local/share/applications"
DOWNLOADS_DIR="$HOME/Descargas"

# Funciones de logging
log_info() { echo -e "${CYAN}[i] $*${RESET}"; }
log_ok() { echo -e "${GREEN}[✔] $*${RESET}"; }
log_warn() { echo -e "${YELLOW}[!] $*${RESET}"; }
log_err() { echo -e "${RED}[✘] $*${RESET}"; }

# Asegurar que el directorio de aplicaciones de usuario existe
mkdir -p "$DESKTOP_DIR"

# 1. Comprobación de dependencias básicas
check_deps() {
    local deps=(curl tar grep cut uniq wc find)
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
nohup "$exec_path" $extra_args "\$@" >/dev/null 2>&1 &
EOF
    sudo chmod +x "$wrapper_path"
    log_ok "Lanzador de terminal creado: $wrapper_path"
}

# Extraer un tarball de forma inteligente a /opt/
extract_tarball() {
    local tarball="$1"
    local dest_dir="$2"
    
    log_info "Analizando estructura del tarball: $(basename "$tarball")..."
    
    # Comprobar si tiene un único directorio raíz
    local root_entries
    root_entries=$(tar -tf "$tarball" | head -n 100 | cut -d/ -f1 | grep -v '^\s*$' | uniq | wc -l)
    
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
        sudo tar -xf "$tarball" -C "$dest_dir" --strip-components=1
    else
        sudo tar -xf "$tarball" -C "$dest_dir"
    fi
    
    log_ok "Extracción completada en $dest_dir"
}

# === PERFIL: ZEN BROWSER ===
install_zen() {
    echo -e "\n${BOLD}${GREEN}--- Instalando Zen Browser ---${RESET}"
    
    # Buscar si ya hay un tarball de Zen en Descargas o directorio actual
    local tarball=""
    local search_paths=("$DOWNLOADS_DIR" ".")
    for path in "${search_paths[@]}"; do
        local found
        found=$(find "$path" -maxdepth 1 \( -iname "*zen*.tar.*" -o -iname "*zen*.tgz" \) 2>/dev/null | head -n 1 || true)
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
    local search_paths=("$DOWNLOADS_DIR" ".")
    for path in "${search_paths[@]}"; do
        local found
        found=$(find "$path" -maxdepth 1 \( -iname "*antigravity*.tar.*" -o -iname "*antigravity*.tgz" \) 2>/dev/null | head -n 1 || true)
        if [ -n "$found" ]; then
            tarball="$found"
            break
        fi
    done
    
    local opt_dir="/opt/Antigravity IDE"
    
    if [ -n "$tarball" ]; then
        log_ok "Se encontró un archivo local de Antigravity IDE: $tarball"
        extract_tarball "$tarball" "$opt_dir"
    else
        log_info "No se encontró un archivo local de instalación para Antigravity IDE."
        if [ -d "$opt_dir" ]; then
            log_ok "La carpeta de instalación '$opt_dir' ya existe en /opt/. Se procederá a configurar los accesos directos."
        else
            log_err "Error: No se encontró el tarball en Descargas ni la carpeta instalada en /opt/."
            echo "Por favor descarga 'Antigravity IDE.tar.gz' y colócalo en tu carpeta de Descargas."
            return 1
        fi
    fi
    
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
Exec="$opt_dir/antigravity-ide" %F
Icon=$icon_path
Type=Application
StartupNotify=true
StartupWMClass=antigravity-ide
Categories=Development;IDE;
EOF
    chmod +x "$DESKTOP_DIR/antigravity-ide.desktop"
    
    # Crear wrapper de terminal
    create_wrapper "antigravity-ide" "$opt_dir/antigravity-ide" ""
    
    update-desktop-database "$DESKTOP_DIR" 2>/dev/null || true
    
    log_ok "¡Antigravity IDE configurado correctamente!"
}

# === PERFIL: TELEGRAM DESKTOP ===
install_telegram() {
    echo -e "\n${BOLD}${GREEN}--- Instalando/Configurando Telegram Desktop ---${RESET}"
    
    local opt_dir="/opt/Telegram"
    
    # Si la carpeta ya existe en Descargas pero no en /opt/
    if [ -d "$DOWNLOADS_DIR/Telegram" ] && [ ! -d "$opt_dir" ]; then
        log_info "Moviendo Telegram desde Descargas a /opt/Telegram..."
        sudo cp -r "$DOWNLOADS_DIR/Telegram" "/opt/"
        sudo chown -R root:root "$opt_dir"
    fi
    
    if [ ! -d "$opt_dir" ]; then
        log_warn "No se encontró la carpeta /opt/Telegram instalada."
        # Buscar tarball
        local tarball=""
        local found
        found=$(find "$DOWNLOADS_DIR" -maxdepth 1 \( -iname "*tsetup*.tar.*" -o -iname "*telegram*.tar.*" \) 2>/dev/null | head -n 1 || true)
        if [ -n "$found" ]; then
            tarball="$found"
            log_ok "Se encontró un archivo de Telegram: $tarball"
            extract_tarball "$tarball" "$opt_dir"
        else
            log_warn "No se encontró instalación de Telegram. Intentando descargar..."
            echo -ne "¿Deseas descargar Telegram Desktop oficial? (S/n): "
            read -r reply
            if [[ "$reply" =~ ^[Nn] ]]; then
                return 1
            fi
            tarball="/tmp/telegram.tar.xz"
            log_info "Descargando Telegram Desktop..."
            curl -L -o "$tarball" "https://telegram.org/dl/desktop/linux"
            extract_tarball "$tarball" "$opt_dir"
        fi
    fi
    
    # Buscar ícono
    local icon_path
    icon_path=$(find "$opt_dir" -maxdepth 4 \( -name "*.png" -o -name "*.svg" \) | grep -i "icon\|logo\|app\|telegram" | head -n 1 || true)
    if [ -z "$icon_path" ]; then
        icon_path="telegram"
    fi
    
    log_info "Creando acceso directo (.desktop) para Telegram..."
    cat > "$DESKTOP_DIR/telegram.desktop" << EOF
[Desktop Entry]
Name=Telegram Desktop
Comment=Official desktop version of Telegram messaging app
GenericName=Chat Client
Exec=/opt/Telegram/Telegram -- %u
Icon=$icon_path
Type=Application
StartupNotify=true
StartupWMClass=TelegramDesktop
Categories=Network;InstantMessaging;
MimeType=x-scheme-handler/tg;
EOF
    chmod +x "$DESKTOP_DIR/telegram.desktop"
    
    # Crear wrapper de terminal
    create_wrapper "telegram" "/opt/Telegram/Telegram" "--"
    
    update-desktop-database "$DESKTOP_DIR" 2>/dev/null || true
    
    log_ok "¡Telegram Desktop configurado correctamente!"
}

# === PERFIL: APLICACIÓN GENÉRICA ===
install_generic() {
    echo -e "\n${BOLD}${GREEN}--- Instalando Aplicación Genérica ---${RESET}"
    
    # 1. Buscar tarballs en Descargas y actual
    local tarballs=()
    while IFS= read -r line; do
        [ -n "$line" ] && tarballs+=("$line")
    done < <(find "$DOWNLOADS_DIR" "." -maxdepth 1 \( -name "*.tar.*" -o -name "*.tgz" \) 2>/dev/null || true)
    
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
    echo -e "  --telegram      Instala/registra Telegram Desktop directamente"
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
        --telegram)
            install_telegram
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
    echo -e "  3) Instalar o Registrar ${BOLD}Telegram Desktop${RESET}"
    echo -e "  4) Instalar/Registrar una ${BOLD}Aplicación Genérica${RESET} (.tar.*)"
    echo -e "  5) Configurar accesos directos para carpeta en ${BOLD}/opt/${RESET}"
    echo -e "  6) Salir"
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
            install_telegram || true
            ;;
        4)
            install_generic || true
            ;;
        5)
            configure_existing || true
            ;;
        6)
            echo "¡Hasta luego!"
            break
            ;;
        *)
            log_err "Opción inválida. Intenta de nuevo."
            ;;
    esac
done
