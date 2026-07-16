#!/bin/bash
# Script para extraer el tema actual del GRUB de forma segura.

# Evitar que el script falle silenciosamente
set -e

# Obtener de forma dinámica la carpeta donde se encuentra el script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
DEST_DIR="$SCRIPT_DIR/tema_grub_extraido"
TAR_FILE="$SCRIPT_DIR/tema_grub_extraido.tar.gz"

echo "=== Extractor de Tema de GRUB Seguro ==="

# 1. Intentar obtener el tema configurado en /etc/default/grub
GRUB_DEFAULT="/etc/default/grub"
THEME_FILE=""

if [ -f "$GRUB_DEFAULT" ]; then
    # Extraer la línea GRUB_THEME, quitar comillas, espacios y comentarios
    THEME_FILE=$(grep -E '^GRUB_THEME=' "$GRUB_DEFAULT" | cut -d= -f2- | tr -d '"' | tr -d "'" | xargs)
fi

# 2. Si no se encontró en /etc/default/grub, buscar en rutas comunes
if [ -z "$THEME_FILE" ] || [ ! -f "$THEME_FILE" ]; then
    echo "No se detectó un tema activo en /etc/default/grub o el archivo no existe."
    echo "Buscando temas instalados en el sistema..."
    
    # Buscar temas en rutas típicas de Zorin OS y otras distros
    POSSIBLE_THEMES=(
        "/usr/share/grub/themes/zorin/theme.txt"
        "/boot/grub/themes/zorin/theme.txt"
    )
    
    for path in "${POSSIBLE_THEMES[@]}"; do
        if [ -f "$path" ]; then
            THEME_FILE="$path"
            echo "Se encontró un tema en: $THEME_FILE"
            break
        fi
    done
    
    if [ -z "$THEME_FILE" ] || [ ! -f "$THEME_FILE" ]; then
        # Buscar cualquier archivo theme.txt en rutas comunes de GRUB
        FOUND_THEME=$(find /usr/share/grub/themes /boot/grub/themes -name "theme.txt" 2>/dev/null | head -n 1)
        if [ -n "$FOUND_THEME" ]; then
            THEME_FILE="$FOUND_THEME"
            echo "Se encontró un tema alternativo en: $THEME_FILE"
        fi
    fi
fi

# 3. Si aun así no se encuentra, abortar
if [ -z "$THEME_FILE" ] || [ ! -f "$THEME_FILE" ]; then
    echo "Error: No se pudo localizar ningún tema de GRUB activo o instalado."
    exit 1
fi

THEME_DIR=$(dirname "$THEME_FILE")
THEME_NAME=$(basename "$THEME_DIR")

echo "Tema localizado: '$THEME_NAME' en la ruta '$THEME_DIR'"

# 4. Crear directorio de destino limpio
echo "Creando carpeta de respaldo en: $DEST_DIR"
rm -rf "$DEST_DIR"
mkdir -p "$DEST_DIR"

# 5. Copiar los archivos (generalmente son legibles por cualquier usuario)
echo "Copiando archivos del tema..."
cp -r "$THEME_DIR"/* "$DEST_DIR"/

# 6. Crear un archivo comprimido .tar.gz para facilitar su transporte
echo "Creando archivo comprimido en: $TAR_FILE"
tar -czf "$TAR_FILE" -C "$DEST_DIR" .

echo ""
echo "¡Extracción completada con éxito!"
echo "- Carpeta con archivos: $DEST_DIR"
echo "- Archivo comprimido para llevar a otra PC: $TAR_FILE"
echo "========================================"
