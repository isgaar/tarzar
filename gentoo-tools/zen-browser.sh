#!/usr/bin/env bash
# Clona y compila Zen Browser desde el código fuente en el directorio XDG de
# descargas. La compilación elimina necko-wifi, por lo que el binario no puede
# escanear redes Wi-Fi para la geolocalización.
set -euo pipefail

ZEN_REPO_URL="https://github.com/zen-browser/desktop.git"
ZEN_DIR_NAME="zen-browser-desktop"
ZEN_INSTALL_DIR="/opt/zen"
TARZAR_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
CLEAN_BUILD=false
LAUNCH_AFTER_BUILD=false

info() { printf '[i] %s\n' "$*"; }
ok() { printf '[✓] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*"; }
err() { printf '[x] %s\n' "$*" >&2; }

get_xdg_download_dir() {
    local download_dir=""

    if command -v xdg-user-dir >/dev/null 2>&1; then
        download_dir=$(xdg-user-dir DOWNLOAD 2>/dev/null || true)
    fi

    if [ -z "$download_dir" ] && [ -n "${XDG_DOWNLOAD_DIR:-}" ]; then
        download_dir="$XDG_DOWNLOAD_DIR"
    fi

    if [ -z "$download_dir" ]; then
        download_dir="$HOME/Downloads"
        warn "xdg-user-dir no está disponible; se usará $download_dir." >&2
    fi

    printf '%s\n' "$download_dir"
}

check_required_commands() {
    local command
    local missing=()
    local required_commands=(find git npm node python3 sudo)

    for command in "${required_commands[@]}"; do
        command -v "$command" >/dev/null 2>&1 || missing+=("$command")
    done

    if [ "${#missing[@]}" -gt 0 ]; then
        err "Faltan herramientas requeridas: ${missing[*]}"
        err "Instálalas con Portage y vuelve a ejecutar esta herramienta."
        return 1
    fi
}

validate_zen_repo() {
    local zen_dir="$1"
    local origin_url

    [ -f "$zen_dir/package.json" ] || return 1
    origin_url=$(git -C "$zen_dir" config --get remote.origin.url 2>/dev/null || true)
    [[ "$origin_url" == *github.com/zen-browser/desktop* ]]
}

ensure_mozconfig_option() {
    local mozconfig="$1"
    local option='ac_add_options --disable-necko-wifi'

    touch "$mozconfig"
    if ! grep -qxF "$option" "$mozconfig"; then
        printf '\n# Privacidad: excluir el escaneo Wi-Fi usado por geolocalización.\n%s\n' "$option" >> "$mozconfig"
        ok 'Se añadió --disable-necko-wifi al mozconfig.'
    else
        ok '--disable-necko-wifi ya está configurado.'
    fi
}

ensure_native_cpu_options() {
    local mozconfig="$1"
    local cflags='export CFLAGS="-march=native"'
    local cxxflags='export CXXFLAGS="-march=native"'
    local rustflags='export RUSTFLAGS="-C target-cpu=native"'
    local option
    local added=false

    touch "$mozconfig"
    for option in "$cflags" "$cxxflags" "$rustflags"; do
        if ! grep -qxF "$option" "$mozconfig"; then
            if [ "$added" = false ]; then
                printf '\n# Optimización para la CPU del equipo que realiza esta compilación.\n' >> "$mozconfig"
            fi
            printf '%s\n' "$option" >> "$mozconfig"
            added=true
        fi
    done

    if [ "$added" = true ]; then
        ok 'Se añadieron las optimizaciones -march=native para C/C++ y Rust.'
    else
        ok 'Las optimizaciones nativas de CPU ya están configuradas.'
    fi
}

load_rustup_env() {
    # mach bootstrap puede instalar Rust mediante rustup. Si ya existe su
    # entorno, hay que incorporarlo antes de compilar para usar ese toolchain.
    if [ -f "$HOME/.cargo/env" ]; then
        # shellcheck disable=SC1090
        source "$HOME/.cargo/env"
    fi
}

find_packaged_zen_dir() {
    local zen_dir="$1"
    local zen_binary

    # `dist/bin` es el árbol de desarrollo y contiene enlaces hacia obj-*/.
    # `npm run package` genera `dist/zen`, que sí es una instalación portable.
    zen_binary=$(find "$zen_dir/engine" -type f -path '*/obj-*/dist/zen/zen' \
        -executable -print -quit 2>/dev/null || true)
    if [ -z "$zen_binary" ]; then
        return 1
    fi

    printf '%s\n' "$(dirname "$zen_binary")"
}

install_compiled_zen() {
    local source_dir="$1"
    local staging_dir

    if [ ! -x "$source_dir/zen" ]; then
        err "El paquete de Zen no contiene el ejecutable esperado: $source_dir/zen"
        return 1
    fi

    info "Preparando la instalación compilada en $ZEN_INSTALL_DIR..."
    staging_dir=$(sudo mktemp -d /opt/.zen-browser-build.XXXXXX) || {
        err 'No se pudo crear el directorio temporal de instalación en /opt.'
        return 1
    }

    if ! sudo cp -a "$source_dir/." "$staging_dir/"; then
        sudo rm -rf "$staging_dir"
        err 'No se pudo copiar el paquete compilado de Zen.'
        return 1
    fi
    if ! sudo test -x "$staging_dir/zen"; then
        sudo rm -rf "$staging_dir"
        err 'La copia temporal no contiene un ejecutable de Zen válido.'
        return 1
    fi

    # Solo se sustituye /opt/zen después de preparar y validar el árbol nuevo.
    # Es el mismo destino que usa la instalación de Zen mediante tarball.
    if sudo test -e "$ZEN_INSTALL_DIR"; then
        warn "Se reemplazará la instalación existente en $ZEN_INSTALL_DIR."
        sudo rm -rf "$ZEN_INSTALL_DIR"
    fi
    if ! sudo mv "$staging_dir" "$ZEN_INSTALL_DIR"; then
        err "No se pudo instalar Zen Browser en $ZEN_INSTALL_DIR."
        return 1
    fi
    sudo chown -R root:root "$ZEN_INSTALL_DIR"
    ok "Zen Browser compilado instalado en $ZEN_INSTALL_DIR"
}

register_compiled_zen() {
    "$TARZAR_DIR/instalar-apps.sh" --zen-local
}

main() {
    local downloads_dir zen_dir packaged_zen_dir

    check_required_commands
    downloads_dir=$(get_xdg_download_dir)
    zen_dir="$downloads_dir/$ZEN_DIR_NAME"

    if [ ! -d "$zen_dir/.git" ]; then
        if [ -e "$zen_dir" ]; then
            err "$zen_dir existe, pero no es un clon de Zen Browser. No se modificó."
            return 1
        fi
        info "Clonando Zen Browser en $zen_dir..."
        mkdir -p "$downloads_dir"
        git clone --depth 10 "$ZEN_REPO_URL" "$zen_dir"
    elif ! validate_zen_repo "$zen_dir"; then
        err "$zen_dir no es el repositorio oficial de Zen Browser. No se modificó."
        return 1
    else
        ok "Repositorio oficial detectado: $zen_dir"
    fi

    ensure_mozconfig_option "$zen_dir/configs/common/mozconfig"
    ensure_native_cpu_options "$zen_dir/configs/linux/mozconfig"

    if [ "$CLEAN_BUILD" = true ]; then
        warn "Eliminando únicamente los artefactos generados de compilación de Zen..."
        rm -rf "$zen_dir/engine/obj-x86_64-pc-linux-gnu"
    fi

    cd "$zen_dir"
    load_rustup_env
    info 'Instalando las dependencias JavaScript del proyecto...'
    npm install

    if [ ! -x "$zen_dir/engine/mach" ]; then
        info 'Inicializando el motor Firefox y las dependencias de compilación...'
        npm run init
    else
        ok 'El motor Firefox ya está inicializado; se reutilizará.'
    fi

    load_rustup_env
    if ! command -v cargo >/dev/null 2>&1 || ! command -v rustc >/dev/null 2>&1; then
        err 'No se encontró cargo/rustc después de la inicialización.'
        err 'Instala dev-lang/rust o completa el bootstrap de Firefox y vuelve a ejecutar el script.'
        return 1
    fi

    info 'Actualizando los paquetes de idioma en-US...'
    python3 ./scripts/update_en_US_packs.py

    info "Compilando Zen Browser con $(nproc 2>/dev/null || printf 'los hilos disponibles')..."
    npm run build

    info 'Empaquetando Zen Browser para una instalación independiente...'
    npm run package
    packaged_zen_dir=$(find_packaged_zen_dir "$zen_dir") || {
        err 'No se encontró el paquete instalable en engine/obj-*/dist/zen.'
        return 1
    }
    install_compiled_zen "$packaged_zen_dir"
    register_compiled_zen

    ok "Zen Browser compilado correctamente en: $zen_dir"
    ok "La instalación activa y los lanzadores apuntan a: $ZEN_INSTALL_DIR"
    ok 'El binario incorpora --disable-necko-wifi para excluir el escaneo Wi-Fi de geolocalización.'
    if [ "$LAUNCH_AFTER_BUILD" = true ]; then
        info 'Abriendo Zen Browser para la prueba; al cerrarlo volverás a la terminal...'
        "$ZEN_INSTALL_DIR/zen" --name zen-browser --class zen-browser --ozone-platform=wayland --enable-features=UseOzonePlatform,WaylandWindowDecorations
    fi
}

if [ "${1:-}" = '-h' ] || [ "${1:-}" = '--help' ]; then
    cat <<'EOF'
Uso: zen-browser.sh [--clean] [--launch]

Clona Zen Browser en el directorio configurado por `xdg-user-dir DOWNLOAD`
(por ejemplo ~/Descargas/zen-browser-desktop) y lo compila para este equipo.

  --clean   elimina solamente los artefactos generados antes de recompilar.
  --launch  abre Zen al finalizar una compilación correcta.
EOF
    exit 0
fi

for argument in "$@"; do
    case "$argument" in
        --clean) CLEAN_BUILD=true ;;
        --launch) LAUNCH_AFTER_BUILD=true ;;
        *) err "Opción no reconocida: $argument"; exit 2 ;;
    esac
done

main
