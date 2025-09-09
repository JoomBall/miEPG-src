#!/usr/bin/env bash
# Uso:
# Version 1.0.2
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
    sed -E "s@channel=\"$(printf '%s' "$old" | sed 's/[.[\*^$(){}?+|&#/\\]/\\&/g')\"@channel=\"${new}\"@g" \
      EPG_prog_block.xml >> EPG_programmes_mapped.xml
  fi
done < "$CANALES_CLEAN"

# 3) Proceso de mapeado de canales
date_stamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Procesar cada canal solicitado

# 3.5) Sanitización XML - Limpiar etiquetas programme malformadas
echo "[INFO] Sanitizando XML - validando etiquetas programme..."
TEMP_SANITIZED="$(mktemp)"

# Función para sanitizar programmes
sanitize_programmes() {
  local input_file="$1"
  local output_file="$2"
  local in_programme=false
  local line_num=0
  local orphan_content=""
  local orphan_channel=""
  
  while IFS= read -r line; do
    line_num=$((line_num + 1))
    
    # Si encontramos apertura de programme
    if echo "$line" | grep -q '^[[:space:]]*<programme[[:space:]>]'; then
      if [ "$in_programme" = true ]; then
        echo "[WARN] Línea $line_num: <programme> sin cerrar anterior - cerrando automáticamente"
        echo '</programme>' >> "$output_file"
      fi
      echo "$line" >> "$output_file"
      in_programme=true
      # Limpiar contenido huérfano acumulado
      orphan_content=""
      orphan_channel=""
      
    # Si encontramos cierre de programme
    elif echo "$line" | grep -q '^[[:space:]]*</programme>'; then
      if [ "$in_programme" = true ]; then
        echo "$line" >> "$output_file"
        in_programme=false
      else
        # Hay un </programme> huérfano, pero si tenemos contenido acumulado, crear el programme
        if [ -n "$orphan_content" ]; then
          echo "[WARN] Línea $line_num: Creando <programme> para contenido huérfano${orphan_channel:+ en canal $orphan_channel}"
          # Generar apertura con canal si lo detectamos
          if [ -n "$orphan_channel" ]; then
            echo "  <programme channel=\"$orphan_channel\">" >> "$output_file"
          else
            echo "  <programme>" >> "$output_file"
          fi
          # Escribir contenido acumulado
          echo "$orphan_content" >> "$output_file"
          # Escribir el cierre
          echo "$line" >> "$output_file"
          orphan_content=""
          orphan_channel=""
        else
          echo "[WARN] Línea $line_num: </programme> huérfano sin contenido - ignorando"
        fi
      fi
      
    # Cualquier otra línea
    else
      # Si es contenido de programme y estamos dentro
      if [ "$in_programme" = true ]; then
        echo "$line" >> "$output_file"
      # Si es contenido suelto (title, desc, etc.) fuera de programme
      elif echo "$line" | grep -qE '^[[:space:]]*<(title|desc|sub-title|category|episode-num|icon|rating|previously-shown|new|subtitles|audio|video|length|url|date|star-rating|review|image)'; then
        # Acumular contenido huérfano para posible reconstrucción
        orphan_content="${orphan_content}${orphan_content:+$'\n'}$line"
        # Intentar extraer canal del contexto anterior si es posible
        if echo "$line" | grep -q 'channel=' && [ -z "$orphan_channel" ]; then
          orphan_channel=$(echo "$line" | sed -n 's/.*channel="\([^"]*\)".*/\1/p')
        fi
      else
        # Otras líneas (no contenido de programme)
        echo "$line" >> "$output_file"
        # Si no es contenido de programme, limpiar acumulación
        if [ -n "$orphan_content" ]; then
          echo "[WARN] Línea $line_num: Contenido huérfano descartado por línea no-programme"
          orphan_content=""
          orphan_channel=""
        fi
      fi
    fi
  done < "$input_file"
  
  # Si quedó un programme abierto al final
  if [ "$in_programme" = true ]; then
    echo "[WARN] EOF: <programme> sin cerrar - cerrando automáticamente"
    echo '</programme>' >> "$output_file"
  fi
  
  # Si quedó contenido huérfano al final sin </programme>
  if [ -n "$orphan_content" ]; then
    echo "[WARN] EOF: Creando <programme> para contenido huérfano final${orphan_channel:+ en canal $orphan_channel}"
    if [ -n "$orphan_channel" ]; then
      echo "  <programme channel=\"$orphan_channel\">" >> "$output_file"
    else
      echo "  <programme>" >> "$output_file"
    fi
    echo "$orphan_content" >> "$output_file"
    echo '</programme>' >> "$output_file"
  fi
}

# Aplicar sanitización a programmes
sanitize_programmes "EPG_programmes_mapped.xml" "$TEMP_SANITIZED"
mv "$TEMP_SANITIZED" "EPG_programmes_mapped.xml"

# 4) Generación del XML final
{
  echo '<?xml version="1.0" encoding="UTF-8"?>'
  echo "<tv generator-info-name=\"miEPG build $(echo "$date_stamp")\" generator-info-url=\"https://github.com/JoomBall/miEPG-src\">"
  cat EPG_channels_mapped.xml
  cat EPG_programmes_mapped.xml
  echo '</tv>'
} > "$OUT_XML"

# 5) MEJORA DE CALIDAD EPG - Eliminar duplicados y optimizar horarios
echo "[INFO] Aplicando mejoras de calidad EPG..."

# Función para eliminar duplicados por canal+horario
remove_duplicate_programmes() {
  local input_file="$1"
  local output_file="$2"
  
  echo "[INFO] Eliminando programas duplicados..."
  
  # Usar Python para procesar duplicados de manera más eficiente
  python3 -c "
import xml.etree.ElementTree as ET
import sys
from collections import defaultdict

try:
    tree = ET.parse('$input_file')
    root = tree.getroot()
    
    # Crear diccionario para detectar duplicados
    seen_programmes = set()
    programmes_to_remove = []
    
    for prog in root.findall('programme'):
        channel = prog.get('channel', '')
        start = prog.get('start', '')
        stop = prog.get('stop', '')
        
        # Crear clave única basada en canal + horarios
        key = f'{channel}|{start}|{stop}'
        
        if key in seen_programmes:
            programmes_to_remove.append(prog)
        else:
            seen_programmes.add(key)
    
    # Remover duplicados
    duplicates_count = len(programmes_to_remove)
    for prog in programmes_to_remove:
        root.remove(prog)
    
    # Guardar XML limpio
    tree.write('$output_file', encoding='utf-8', xml_declaration=True)
    print(f'[INFO] Duplicados eliminados: {duplicates_count}')
    
except Exception as e:
    print(f'[ERROR] Error procesando duplicados: {e}')
    # En caso de error, copiar archivo original
    import shutil
    shutil.copy('$input_file', '$output_file')
"
}

# Crear archivo temporal para procesamiento
TEMP_DEDUP="${OUT_XML}.dedup"
remove_duplicate_programmes "$OUT_XML" "$TEMP_DEDUP"

# Reemplazar archivo original con versión sin duplicados
if [ -f "$TEMP_DEDUP" ]; then
  mv "$TEMP_DEDUP" "$OUT_XML"
fi

# 6) Chequeos de sanidad XML
OPEN_CHANNELS=$(grep -c '<channel id="' "$OUT_XML" || echo 0)
CLOSE_CHANNELS=$(grep -c '</channel>'     "$OUT_XML" || echo 0)
OPEN_PROGRAMMES=$(grep -c '<programme[[:space:]>]' "$OUT_XML" || echo 0)
CLOSE_PROGRAMMES=$(grep -c '</programme>'     "$OUT_XML" || echo 0)

echo "[INFO] Validación XML final:"
echo "[INFO] Canales -> abiertos: $OPEN_CHANNELS | cerrados: $CLOSE_CHANNELS"
echo "[INFO] Programmes -> abiertos: $OPEN_PROGRAMMES | cerrados: $CLOSE_PROGRAMMES"

# Validar que las etiquetas estén balanceadas
if [ "$OPEN_CHANNELS" -ne "$CLOSE_CHANNELS" ]; then
  echo "[ERROR] Desfase entre <channel> abiertos ($OPEN_CHANNELS) y cerrados ($CLOSE_CHANNELS)"
  exit 20
fi

if [ "$OPEN_PROGRAMMES" -ne "$CLOSE_PROGRAMMES" ]; then
  echo "[ERROR] Desfase entre <programme> abiertos ($OPEN_PROGRAMMES) y cerrados ($CLOSE_PROGRAMMES)"
  exit 21
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
