#!/bin/bash
# Script para aplicar el tema de Zorin OS al GRUB de forma segura.

# Evitar que el script falle silenciosamente
set -e

# Asegurar que se ejecute con privilegios de root (sudo)
if [ "$EUID" -ne 0 ]; then
    echo "Este script necesita privilegios de root para modificar la configuración de GRUB."
    echo "Por favor, ejecútalo usando sudo:"
    echo "sudo $0"
    exit 1
fi

# Obtener de forma dinámica la carpeta donde se encuentra el script
# (Nota: Incluso ejecutando con sudo, esto apunta a la carpeta correcta del script)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

THEME_NAME="zorin"
DEST_THEME_DIR="/usr/share/grub/themes/$THEME_NAME"
BACKUP_DIR="$SCRIPT_DIR/tema_grub_extraido"
BACKUP_TAR="$SCRIPT_DIR/tema_grub_extraido.tar.gz"

echo "=== Aplicador de Tema de GRUB (Zorin OS) ==="

# 1. Determinar el origen del tema
SOURCE_PATH=""
if [ -d "$BACKUP_DIR" ] && [ -f "$BACKUP_DIR/theme.txt" ]; then
    SOURCE_PATH="$BACKUP_DIR"
    SOURCE_TYPE="dir"
    echo "Se detectó la carpeta del tema extraído en: $SOURCE_PATH"
elif [ -f "$BACKUP_TAR" ]; then
    SOURCE_PATH="$BACKUP_TAR"
    SOURCE_TYPE="tar"
    echo "Se detectó el archivo comprimido del tema extraído en: $SOURCE_PATH"
else
    echo "Error: No se encontró la carpeta del tema ($BACKUP_DIR) ni el archivo comprimido ($BACKUP_TAR)."
    echo "Asegúrate de ejecutar primero el script 'extraer_tema.sh'."
    exit 1
fi

# 2. Crear el directorio de destino
echo "Creando el directorio de destino en: $DEST_THEME_DIR"
mkdir -p "$DEST_THEME_DIR"

# 3. Copiar o extraer los archivos del tema al destino
if [ "$SOURCE_TYPE" = "dir" ]; then
    echo "Copiando archivos del tema..."
    cp -r "$SOURCE_PATH"/* "$DEST_THEME_DIR"/
else
    echo "Extrayendo archivos del tema..."
    tar -xzf "$SOURCE_PATH" -C "$DEST_THEME_DIR"/
fi

# Verificar que el archivo theme.txt esté en su lugar
if [ ! -f "$DEST_THEME_DIR/theme.txt" ]; then
    echo "Error: El archivo theme.txt no se encuentra en el destino. La estructura del tema es incorrecta."
    exit 1
fi

# 4. Modificar /etc/default/grub de manera segura
GRUB_CONFIG="/etc/default/grub"
if [ ! -f "$GRUB_CONFIG" ]; then
    echo "Error: No se encontró el archivo de configuración de GRUB en $GRUB_CONFIG."
    exit 1
fi

# Respaldar la configuración actual de GRUB con fecha y hora
BACKUP_FILE="${GRUB_CONFIG}.backup_$(date +%Y%m%d_%H%M%S)"
echo "Creando respaldo de seguridad de GRUB en: $BACKUP_FILE"
cp "$GRUB_CONFIG" "$BACKUP_FILE"

echo "Configurando el tema en /etc/default/grub..."

# Comentar GRUB_TERMINAL=console si está descomentado, para habilitar la interfaz gráfica
if grep -q "^GRUB_TERMINAL=console" "$GRUB_CONFIG"; then
    echo "Habilitando el modo gráfico en GRUB (comentando GRUB_TERMINAL=console)..."
    sed -i 's/^GRUB_TERMINAL=console/#GRUB_TERMINAL=console/g' "$GRUB_CONFIG"
fi

# Asegurar que el archivo termine con un salto de línea antes de añadir cosas
sed -i -e '$a\' "$GRUB_CONFIG"

# Eliminar líneas anteriores de GRUB_THEME para evitar duplicados
sed -i '/^GRUB_THEME=/d' "$GRUB_CONFIG"

# Añadir la nueva línea del tema
echo "GRUB_THEME=\"$DEST_THEME_DIR/theme.txt\"" >> "$GRUB_CONFIG"

# 5. Actualizar GRUB según la distribución
echo "Actualizando la configuración de GRUB..."
if command -v update-grub &> /dev/null; then
    update-grub
elif command -v grub-mkconfig &> /dev/null; then
    grub-mkconfig -o /boot/grub/grub.cfg
elif command -v grub2-mkconfig &> /dev/null; then
    if [ -f /boot/grub2/grub.cfg ]; then
        grub2-mkconfig -o /boot/grub2/grub.cfg
    elif [ -f /boot/efi/EFI/fedora/grub.cfg ]; then
        grub2-mkconfig -o /boot/efi/EFI/fedora/grub.cfg
    else
        grub2-mkconfig -o /boot/grub/grub.cfg
    fi
else
    echo "¡ATENCIÓN! No se encontró el comando estándar de actualización (update-grub o grub-mkconfig)."
    echo "Por favor, ejecuta la actualización de GRUB manualmente para tu distribución."
fi

echo ""
echo "¡Tema de GRUB aplicado con éxito!"
echo "Al reiniciar, deberías ver el tema de Zorin OS en tu GRUB."
echo "========================================"
