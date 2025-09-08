#!/usr/bin/env bash
# Uso:
# Version 1.0.1
#   EPG_script.sh <ruta_epgs.txt> <ruta_canales.txt> <salida_xml>
set -euo pipefail

EPGS_FILE="${1:?Falta ruta a epgs.txt}"
CANALES_FILE="${2:?Falta ruta a canales.txt}"
OUT_XML="${3:?Falta nombre de salida}"
ALLOW_EMPTY="${ALLOW_EMPTY:-0}"

echo "[INFO] EPGS_FILE: $EPGS_FILE"
echo "[INFO] CANALES_FILE: $CANALES_FILE"
echo "[INFO] OUT_XML: $OUT_XML"

rm -f EPG_temp* || true

# Limpieza básica (quitar líneas vacías y comentarios)
EPGS_CLEAN="$(mktemp)";    grep -v -E '^[[:space:]]*$|^[[:space:]]*#' "$EPGS_FILE"    > "$EPGS_CLEAN"    || true
CANALES_CLEAN="$(mktemp)"; grep -v '^[[:space:]]*$' "$CANALES_FILE" > "$CANALES_CLEAN" || true

# 1) Descargar y unir fuentes a texto con una etiqueta por línea
touch EPG_temp.xml
while IFS= read -r epg_url; do
  [ -z "${epg_url}" ] && continue
  echo "[INFO] Descargando: ${epg_url}"
  TMP_XML="$(mktemp)"
  if echo "$epg_url" | grep -qiE '\.gz($|\?)'; then
    if ! curl -fsSL -A "Mozilla/5.0" "$epg_url" | gzip -dc > "$TMP_XML"; then
      echo "[WARN] Falló descarga/descompresión: $epg_url"; continue
    fi
  else
    if ! curl -fsSL -A "Mozilla/5.0" "$epg_url" > "$TMP_XML"; then
      echo "[WARN] Falló descarga: $epg_url"; continue
    fi
  fi
  sed 's/></>\n</g' "$TMP_XML" >> EPG_temp.xml
done < "$EPGS_CLEAN"

TOTAL_PROGRAMMES_ALL=$(grep -c "<programme" EPG_temp.xml || echo 0)
echo "[INFO] Programmes acumulados: $TOTAL_PROGRAMMES_ALL"

# DEBUG: Generar archivo con todos los canales disponibles
COUNTRY_DIR="$(dirname "$OUT_XML")"
CHANNELS_LIST="$COUNTRY_DIR/channels.txt"
echo "[INFO] Generando lista de canales disponibles en: $CHANNELS_LIST"

# Extraer todos los IDs de canales únicos y sus display-names
{
  echo "# Canales disponibles en las fuentes EPG"
  echo "# Formato: channel_id | display_name"
  echo "# Fecha: $(date -u)"
  echo ""
  
  # Obtener todos los canales con sus display-names
  sed -n '/<channel id=/,/<\/channel>/p' EPG_temp.xml | \
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
  
} > "$CHANNELS_LIST"

TOTAL_CHANNELS=$(grep -v '^#' "$CHANNELS_LIST" | grep -v '^$' | wc -l || echo 0)
echo "[INFO] Total de canales únicos encontrados: $TOTAL_CHANNELS"
echo "[INFO] Lista guardada en: $CHANNELS_LIST"

# DEBUG: Mostrar algunos canales disponibles
echo "[DEBUG] Primeros 20 canales disponibles:"
grep -v '^#' "$CHANNELS_LIST" | head -20 || true

# Verificar si canales.txt contiene "ALL" (incluir todos los canales)
if grep -q "^ALL$" "$CANALES_CLEAN"; then
  echo "[INFO] Encontrado 'ALL' en canales.txt - incluyendo todos los canales disponibles"
  # Crear archivo temporal con todos los canales en formato old,new
  TEMP_ALL_CHANNELS="$(mktemp)"
  grep -v '^#' "$CHANNELS_LIST" | grep -v '^$' | sed 's/ | /,/' > "$TEMP_ALL_CHANNELS"
  CANALES_CLEAN="$TEMP_ALL_CHANNELS"
fi

# 2) Mapear canales de forma SEGURA: reconstruimos el bloque <channel> explícitamente
> EPG_channels_mapped.xml
> EPG_programmes_mapped.xml

while IFS=, read -r old new logo; do
  old="$(echo "${old:-}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  new="$(echo "${new:-}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  logo="$(echo "${logo:-}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  [ -z "$old" ] && continue
  [ -z "$new" ] && new="$old"

  # Extrae el bloque del canal original
  sed -n "/<channel id=\"$(printf '%s' "$old" | sed 's/[.[\*^$(){}?+|&#/\\]/\\&/g')\">/,/<\/channel>/p" \
    EPG_temp.xml > EPG_chan_block.xml || true

  if [ ! -s EPG_chan_block.xml ]; then
    echo "[SKIP] Canal sin coincidencias: '$old'"
    continue
  fi

  echo "[OK] Canal: '$old' -> '$new'"

  # 2.1 Construye SIEMPRE la cabecera del canal
  {
    echo "  <channel id=\"${new}\">"
    echo "    <display-name>${new}</display-name>"
    # Si tenemos logo en canales.txt, úsalo; si no, intenta rescatar el primero del bloque original
    if [ -n "$logo" ]; then
      echo "    <icon src=\"${logo}\" />"
    else
      grep -m1 -E '^[[:space:]]*<icon ' EPG_chan_block.xml || true
    fi
    # Preserva display-name extra del bloque original, excepto el primero (ya añadido)
    grep -E '^[[:space:]]*<display-name' EPG_chan_block.xml | tail -n +2 || true
    echo "  </channel>"
  } >> EPG_channels_mapped.xml

  # 2.2 Programmes del canal remapeados
  sed -n "/<programme[^\>]*channel=\"$(printf '%s' "$old" | sed 's/[.[\*^$(){}?+|&#/\\]/\\&/g')\"[^\>]*>/,/<\/programme>/p" \
    EPG_temp.xml > EPG_prog_block.xml || true

  if [ -s EPG_prog_block.xml ]; then
    sed -E "s/channel=\"$(printf '%s' "$old" | sed 's/[.[\*^$(){}?+|&#/\\]/\\&/g')\"/channel=\"${new}\"/g" \
      EPG_prog_block.xml >> EPG_programmes_mapped.xml
  fi
done < "$CANALES_CLEAN"

# 3) Ensamblado final
date_stamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
{
  echo '<?xml version="1.0" encoding="UTF-8"?>'
  echo "<tv generator-info-name=\"miEPG build $(echo "$date_stamp")\" generator-info-url=\"https://github.com/JoomBall/miEPG-src\">"
  cat EPG_channels_mapped.xml
  cat EPG_programmes_mapped.xml
  echo '</tv>'
} > "$OUT_XML"

# 4) Chequeos mínimos de sanidad
OPEN_TAGS=$(grep -c '<channel id="' "$OUT_XML" || echo 0)
CLOSE_TAGS=$(grep -c '</channel>'     "$OUT_XML" || echo 0)
echo "[INFO] Canales abiertos: $OPEN_TAGS | cerrados: $CLOSE_TAGS"

if [ "$OPEN_TAGS" -ne "$CLOSE_TAGS" ]; then
  echo "[ERROR] Desfase entre <channel> abiertos y cerrados. No publico salida corrupta."
  exit 20
fi

TOTAL_PROGRAMMES_OUT=$(grep -c "<programme" "$OUT_XML" || echo 0)
echo "[INFO] Programmes en salida ($OUT_XML): $TOTAL_PROGRAMMES_OUT"

if [ "$TOTAL_PROGRAMMES_OUT" -eq 0 ]; then
  if [ "${ALLOW_EMPTY}" = "1" ]; then
    echo "[WARN] Salida sin programmes; continúo (no se publicará)."
    exit 0
  else
    echo "[ERROR] La salida no contiene programmes."
    exit 12
  fi
fi

echo "[DONE] Generado $OUT_XML"
