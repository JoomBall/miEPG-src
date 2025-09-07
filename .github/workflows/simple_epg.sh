#!/usr/bin/env bash
# Script EPG simplificado para debug
set -euo pipefail

COUNTRY="${1:-us}"
echo "[INFO] Testing EPG generation for: $COUNTRY"

# URLs base según país
if [ "$COUNTRY" = "us" ]; then
    EPGS=(
        "https://raw.githubusercontent.com/matthuisman/i.mjh.nz/master/PlutoTV/us.xml.gz"
        "https://raw.githubusercontent.com/matthuisman/i.mjh.nz/master/SamsungTVPlus/us.xml.gz"
    )
elif [ "$COUNTRY" = "au" ]; then
    EPGS=(
        "https://raw.githubusercontent.com/matthuisman/i.mjh.nz/master/au/all/epg.xml.gz"
        "https://raw.githubusercontent.com/matthuisman/i.mjh.nz/master/PlutoTV/all.xml.gz"
    )
else
    echo "País no soportado: $COUNTRY"
    exit 1
fi

# Crear EPG temporal
echo '<?xml version="1.0" encoding="UTF-8"?>' > "countries/$COUNTRY/EPG.xml"
echo '<tv generator-info-name="miEPG Test" generator-info-url="https://github.com/JoomBall/miEPG-src">' >> "countries/$COUNTRY/EPG.xml"

TOTAL_PROGRAMMES=0

# Descargar cada fuente
for epg_url in "${EPGS[@]}"; do
    echo "[INFO] Downloading: $epg_url"
    
    TMP_FILE=$(mktemp)
    if curl -fsSL "$epg_url" | gzip -dc > "$TMP_FILE"; then
        # Extraer canales
        sed -n '/<channel/,/<\/channel>/p' "$TMP_FILE" >> "countries/$COUNTRY/EPG.xml"
        
        # Contar programmes
        PROGRAMMES=$(grep -c "<programme" "$TMP_FILE" || echo 0)
        echo "[INFO] Found $PROGRAMMES programmes in $epg_url"
        TOTAL_PROGRAMMES=$((TOTAL_PROGRAMMES + PROGRAMMES))
        
        # Extraer programmes
        sed -n '/<programme/,/<\/programme>/p' "$TMP_FILE" >> "countries/$COUNTRY/EPG.xml"
    else
        echo "[WARN] Failed to download: $epg_url"
    fi
    rm -f "$TMP_FILE"
done

echo '</tv>' >> "countries/$COUNTRY/EPG.xml"

echo "[INFO] Total programmes generated: $TOTAL_PROGRAMMES"
echo "[INFO] EPG saved to: countries/$COUNTRY/EPG.xml"

# Mostrar estadísticas
CHANNELS=$(grep -c "<channel" "countries/$COUNTRY/EPG.xml" || echo 0)
echo "[INFO] Total channels: $CHANNELS"

echo "[INFO] First 20 lines of generated EPG:"
head -20 "countries/$COUNTRY/EPG.xml"
