#!/usr/bin/env bash
# Script para generar channels.txt a partir de un EPG.xml existente
# Uso: ./generate_channels.sh <COUNTRY>
# Ejemplo: ./generate_channels.sh us
# 
# Este script es útil para:
# 1. Generar channels.txt cuando se añade un nuevo país
# 2. Regenerar channels.txt si se corrompe o actualiza el EPG.xml
# 3. Debug: ver qué canales están disponibles en las fuentes EPG
set -euo pipefail

if [ $# -eq 0 ]; then
    echo "Uso: $0 <COUNTRY>"
    echo "Ejemplo: $0 us"
    echo "Países disponibles: es, gb, us, au"
    exit 1
fi

COUNTRY="$1"
EPG_FILE="countries/$COUNTRY/EPG.xml"
CHANNELS_FILE="countries/$COUNTRY/channels.txt"

if [ ! -f "$EPG_FILE" ]; then
    echo "[ERROR] No se encontró el archivo EPG: $EPG_FILE"
    exit 1
fi

echo "[INFO] Generando lista de canales para: $COUNTRY"
echo "[INFO] Fuente EPG: $EPG_FILE"
echo "[INFO] Destino: $CHANNELS_FILE"

# Crear archivo channels.txt
{
    echo "# Canales disponibles en las fuentes EPG"
    echo "# Formato: channel_id | display_name"
    echo "# Fecha: $(date -u)"
    echo ""
    
    # Extraer todos los canales con sus display-names
    sed -n '/<channel id=/,/<\/channel>/p' "$EPG_FILE" | \
    awk '
        /<channel id=/ { 
            match($0, /id="([^"]*)"/, arr); 
            id = arr[1]; 
        }
        /<display-name[^>]*>/ { 
            gsub(/<[^>]*>/, ""); 
            gsub(/^[ \t]*|[ \t]*$/, ""); 
            if ($0 != "" && id != "") {
                print id " | " $0;
                id = "";
            }
        }
    ' | sort -u
    
} > "$CHANNELS_FILE"

TOTAL_CHANNELS=$(grep -v '^#' "$CHANNELS_FILE" | grep -v '^$' | wc -l || echo 0)
echo "[INFO] Total de canales únicos encontrados: $TOTAL_CHANNELS"
echo "[INFO] Lista guardada en: $CHANNELS_FILE"

# Mostrar algunos ejemplos
echo "[INFO] Primeros 10 canales encontrados:"
head -15 "$CHANNELS_FILE" | tail -10 || true
