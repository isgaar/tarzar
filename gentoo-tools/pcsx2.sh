#!/usr/bin/env bash
# Compila PCSX2 desde ~/Documentos/pcsx2 y registra un lanzador solo de usuario.
set -euo pipefail

PCSX2_REPO_URL="https://github.com/PCSX2/pcsx2.git"
PCSX2_DIR="$HOME/Documentos/pcsx2"
DESKTOP_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
ICON_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/256x256/apps"
LOCAL_BIN_DIR="$HOME/.local/bin"
CLEAN_BUILD=false
LAUNCH_AFTER_BUILD=false
VERIFY_SYSTEM_DEPS=true

info() { printf '[i] %s\n' "$*"; }
ok() { printf '[✓] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*"; }
err() { printf '[x] %s\n' "$*" >&2; }

find_llvm_tool() {
    local tool="$1" candidate
    if command -v "$tool" >/dev/null 2>&1; then
        command -v "$tool"
        return 0
    fi
    candidate=$(find /usr/lib/llvm -type f -path "*/bin/$tool" -executable 2>/dev/null | sort -V | tail -n 1 || true)
    [ -n "$candidate" ] || return 1
    printf '%s\n' "$candidate"
}

install_dependencies() {
    info "Instalando/verificando dependencias de PCSX2 con Portage..."
    sudo emerge --ask \
        llvm-core/clang llvm-core/llvm llvm-core/lld \
        dev-build/cmake dev-build/ninja kde-frameworks/extra-cmake-modules \
        dev-util/ccache \
        dev-qt/qtbase:6 dev-qt/qtsvg:6 dev-qt/qttools:6 dev-qt/qtwayland:6 \
        gui-libs/kddockwidgets media-libs/libsdl3 media-libs/shaderc \
        media-video/ffmpeg net-libs/libpcap media-libs/libwebp \
        media-libs/alsa-lib media-libs/libpulse x11-libs/libXi x11-libs/libXrandr \
        dev-libs/glib
}

check_required_commands() {
    local command
    local missing=()
    local required_commands=(
        git cmake ninja ccache bash curl getconf gzip make patch pkg-config
        python3 realpath shasum tar
    )

    for command in "${required_commands[@]}"; do
        command -v "$command" >/dev/null 2>&1 || missing+=("$command")
    done

    if [ "${#missing[@]}" -gt 0 ]; then
        err "Faltan herramientas requeridas: ${missing[*]}"
        err "Instálalas con Portage y vuelve a ejecutar esta herramienta."
        return 1
    fi
}

validate_pcsx2_repo() {
    local origin_url

    [ -f "$PCSX2_DIR/CMakeLists.txt" ] || return 1
    grep -qiE '^[[:space:]]*project\(pcsx2[[:space:])]' "$PCSX2_DIR/CMakeLists.txt" || return 1
    origin_url=$(git -C "$PCSX2_DIR" config --get remote.origin.url 2>/dev/null || true)
    [[ "$origin_url" == *github.com/PCSX2/pcsx2* ]] || return 1
}

deps_are_ready() {
    local required_file
    local required_files=(
        'SDL3Config.cmake'
        'Qt6Config.cmake'
        'KDDockWidgets-qt6Config.cmake'
        'plutovgConfig.cmake'
        'plutosvgConfig.cmake'
        'rymlConfig.cmake'
        'shaderc.pc'
    )

    for required_file in "${required_files[@]}"; do
        find "$PCSX2_DIR/deps" -type f -name "$required_file" -print -quit 2>/dev/null | grep -q . || return 1
    done
}

build_third_party_deps() {
    local deps_script="$PCSX2_DIR/.github/workflows/scripts/linux/build-dependencies-qt.sh"
    local png_version png_archive png_url deps_log

    deps_log=$(mktemp "${TMPDIR:-/tmp}/tarzar-pcsx2-deps.XXXXXX.log")

    if (cd "$PCSX2_DIR" && bash "$deps_script" deps) 2>&1 | tee "$deps_log"; then
        rm -f "$deps_log"
        deps_are_ready && return 0
        err "El script de dependencias terminó, pero faltan archivos requeridos en deps/."
        return 1
    fi

    # El historial documenta un fallo intermitente del mirror de SourceForge
    # para libpng. Se descarga con reintentos y se relanza el script oficial.
    if ! grep -qE 'libpng-[^[:space:]]+\.tar\.xz: (No such file|FAILED)|sourceforge\.net' "$deps_log"; then
        err "Falló el script oficial por una causa distinta a la descarga de libpng. Consulta: $deps_log"
        return 1
    fi

    png_version=$(sed -n 's/^LIBPNG=//p' "$deps_script" | head -n 1)
    if [ -z "$png_version" ]; then
        err "No se pudo identificar la versión de libpng del script oficial."
        return 1
    fi
    png_archive="libpng-$png_version.tar.xz"
    png_url="https://downloads.sourceforge.net/project/libpng/libpng16/$png_version/$png_archive"
    warn "El script oficial falló. Reintentando la descarga de $png_archive..."
    mkdir -p "$PCSX2_DIR/deps-build"
    curl --fail --location --retry 8 --retry-delay 5 --retry-connrefused \
        --output "$PCSX2_DIR/deps-build/$png_archive" "$png_url"
    (cd "$PCSX2_DIR" && bash "$deps_script" deps)
    rm -f "$deps_log"
    deps_are_ready
}

configure_build() {
    local clang_bin="$1" clangxx_bin="$2" lld_bin="$3"
    local -a cmake_args=(
        -S "$PCSX2_DIR" -B "$PCSX2_DIR/build"
        -DCMAKE_C_COMPILER="$clang_bin" -DCMAKE_CXX_COMPILER="$clangxx_bin"
        -DCMAKE_EXE_LINKER_FLAGS_INIT="-fuse-ld=$lld_bin"
        -DCMAKE_MODULE_LINKER_FLAGS_INIT="-fuse-ld=$lld_bin"
        -DCMAKE_SHARED_LINKER_FLAGS_INIT="-fuse-ld=$lld_bin"
        -DCMAKE_EXE_LINKER_FLAGS="-fuse-ld=$lld_bin"
        -DCMAKE_MODULE_LINKER_FLAGS="-fuse-ld=$lld_bin"
        -DCMAKE_SHARED_LINKER_FLAGS="-fuse-ld=$lld_bin"
        -DCMAKE_PREFIX_PATH="$PCSX2_DIR/deps" -DCMAKE_BUILD_TYPE=Release
        -DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache
        -DCMAKE_EXPORT_COMPILE_COMMANDS=ON -DLTO_PCSX2_CORE=ON -DENABLE_TESTS=OFF
        -DDISABLE_ADVANCE_SIMD=OFF -DENABLE_QT_UI=ON -DUSE_VULKAN=ON -DUSE_OPENGL=ON
        -DWAYLAND_API=ON -DX11_API=ON -DENABLE_SETCAP=OFF -DPACKAGE_MODE=OFF -DUSE_VTUNE=OFF
        -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=OFF -GNinja
    )

    if cmake "${cmake_args[@]}"; then
        return 0
    fi

    # Un configure interrumpido puede dejar un CMakeCache inconsistente. build/
    # solo contiene artefactos generados, así que se reconstruye una vez limpia.
    warn "La configuración falló; se regenerará build/ una vez sin caché."
    rm -rf "$PCSX2_DIR/build"
    cmake "${cmake_args[@]}"
}

ensure_local_bin_path() {
    local path_line='export PATH="$HOME/.local/bin:$PATH"'

    case ":$PATH:" in
        *":$LOCAL_BIN_DIR:"*) return 0 ;;
    esac

    if ! grep -qxF "$path_line" "$HOME/.bashrc" 2>/dev/null; then
        printf '\n%s\n' "$path_line" >> "$HOME/.bashrc"
        ok "Se añadió ~/.local/bin al PATH de Bash. Abre una terminal nueva para usarlo."
    fi
}

main() {
    local clang_bin clangxx_bin lld_bin pcsx2_bin icon_path

    command -v git >/dev/null 2>&1 || { err "Falta 'git'; instálalo antes de continuar."; return 1; }

    if [ ! -d "$PCSX2_DIR/.git" ]; then
        if [ -e "$PCSX2_DIR" ]; then
            err "$PCSX2_DIR existe, pero no es un clon de Git de PCSX2. No se modificó."
            return 1
        fi
        info "Clonando PCSX2 en $PCSX2_DIR..."
        mkdir -p "$(dirname "$PCSX2_DIR")"
        git clone --recursive "$PCSX2_REPO_URL" "$PCSX2_DIR"
    else
        if ! validate_pcsx2_repo; then
            err "$PCSX2_DIR no es el repositorio oficial de PCSX2. No se modificó."
            return 1
        fi
        ok "Repositorio oficial detectado: $PCSX2_DIR"
    fi
    git -C "$PCSX2_DIR" submodule update --init --recursive

    if [ "$VERIFY_SYSTEM_DEPS" = true ]; then
        install_dependencies
    fi
    clang_bin=$(find_llvm_tool clang) || { err "No se encontró clang; instala llvm-core/clang."; return 1; }
    clangxx_bin=$(find_llvm_tool clang++) || { err "No se encontró clang++; instala llvm-core/clang."; return 1; }
    lld_bin=$(find_llvm_tool ld.lld) || { err "No se encontró ld.lld; instala llvm-core/lld."; return 1; }
    ok "Toolchain: $("$clang_bin" --version | head -n 1)"

    check_required_commands

    if ! deps_are_ready; then
        info "Construyendo dependencias de terceros (solo la primera vez)..."
        build_third_party_deps
    else
        ok "Dependencias locales disponibles; se reutilizarán."
    fi

    if [ "$CLEAN_BUILD" = true ]; then
        warn "Eliminando el directorio de compilación solicitado: $PCSX2_DIR/build"
        rm -rf "$PCSX2_DIR/build"
    fi

    info "Configurando Release con -march=native, LTO selectivo y lld..."
    configure_build "$clang_bin" "$clangxx_bin" "$lld_bin"
    if ! grep -qm1 -- '-march=native' "$PCSX2_DIR/build/compile_commands.json"; then
        err "PCSX2 no activó -march=native; se detiene para no crear una compilación no optimizada."
        return 1
    fi
    ok 'Configuración confirmada con -march=native.'
    info "Compilando PCSX2 con $(nproc) hilos disponibles..."
    cmake --build "$PCSX2_DIR/build" --parallel "$(nproc)"

    pcsx2_bin="$PCSX2_DIR/build/bin/pcsx2-qt"
    [ -x "$pcsx2_bin" ] || { err "No se creó el ejecutable esperado: $pcsx2_bin"; return 1; }
    icon_path="$PCSX2_DIR/build/bin/resources/icons/AppIconLarge.png"
    [ -f "$icon_path" ] || icon_path="$PCSX2_DIR/bin/resources/icons/AppIconLarge.png"
    [ -f "$icon_path" ] || icon_path="applications-games"

    mkdir -p "$DESKTOP_DIR" "$ICON_DIR" "$LOCAL_BIN_DIR"
    ln -sfn "$pcsx2_bin" "$LOCAL_BIN_DIR/pcsx2-qt"
    ensure_local_bin_path
    if [ "$icon_path" != "applications-games" ]; then
        cp -f "$icon_path" "$ICON_DIR/pcsx2.png"
        icon_path="pcsx2"
    fi
    cat > "$DESKTOP_DIR/pcsx2-qt.desktop" << EOF
[Desktop Entry]
Type=Application
Name=PCSX2
GenericName=Emulador de PlayStation 2
Comment=PCSX2 compilado localmente para este equipo
Exec=$LOCAL_BIN_DIR/pcsx2-qt %f
Icon=$icon_path
Terminal=false
Categories=Game;Emulator;
StartupWMClass=pcsx2-qt
EOF
    chmod +x "$DESKTOP_DIR/pcsx2-qt.desktop"
    update-desktop-database "$DESKTOP_DIR" 2>/dev/null || true
    command -v kbuildsycoca6 >/dev/null 2>&1 && kbuildsycoca6 --noincremental || true
    ok "PCSX2 listo: $pcsx2_bin"
    ok "Comando de terminal: $LOCAL_BIN_DIR/pcsx2-qt"
    ok "Acceso de usuario: $DESKTOP_DIR/pcsx2-qt.desktop"
    warn "PCSX2 no incluye una BIOS. Usa únicamente una BIOS extraída de tu propia consola PS2."
    info "En tu Vega integrada, usa Vulkan y una resolución interna de 2x–3x en juegos exigentes."
    if [ "$LAUNCH_AFTER_BUILD" = true ]; then
        info "Abriendo PCSX2 para la prueba; al cerrarlo volverás a la terminal..."
        "$LOCAL_BIN_DIR/pcsx2-qt"
    fi
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    cat <<'EOF'
Uso: pcsx2.sh [--clean] [--launch] [--skip-system-deps]

Compila PCSX2 desde ~/Documentos/pcsx2 y crea un lanzador KDE solo para el
usuario actual. Si el repositorio no existe, lo clona con sus submódulos.

  --clean   elimina únicamente ~/Documentos/pcsx2/build antes de configurar.
  --launch  abre PCSX2 al terminar una compilación correcta.
  --skip-system-deps  omite la verificación explícita de dependencias de Portage.
EOF
    exit 0
fi

for argument in "$@"; do
    case "$argument" in
        --clean) CLEAN_BUILD=true ;;
        --launch) LAUNCH_AFTER_BUILD=true ;;
        --skip-system-deps) VERIFY_SYSTEM_DEPS=false ;;
        *) err "Opción no reconocida: $argument"; exit 2 ;;
    esac
done

main
