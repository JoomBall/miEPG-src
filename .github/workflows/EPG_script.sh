#!/usr/bin/env bash
# Uso:
#   EPG_script.sh <ruta_epgs.txt> <ruta_canales.txt> <salida_xml>
# Ejemplo:
#   EPG_script.sh countries/es/epgs.txt countries/es/canales.txt miEPG_ES.xml

set -euo pipefail

EPGS_FILE="${1:?Falta ruta a epgs.txt}"
CANALES_FILE="${2:?Falta ruta a canales.txt}"
OUT_XML="${3:?Falta nombre de salida}"

echo "[INFO] EPGS_FILE: $EPGS_FILE"
echo "[INFO] CANALES_FILE: $CANALES_FILE"
echo "[INFO] OUT_XML: $OUT_XML"

# Limpieza previa
rm -f EPG_temp* || true

# Normaliza líneas en epgs.txt / canales.txt (quitar líneas vacías y espacios)
# (sin sed -i, por compatibilidad)
EPGS_CLEAN="$(mktemp)"; grep -v '^[[:space:]]*$' "$EPGS_FILE" > "$EPGS_CLEAN" || true
CANALES_CLEAN="$(mktemp)"; grep -v '^[[:space:]]*$' "$CANALES_FILE" > "$CANALES_CLEAN" || true

# 1) Descargar y concatenar EPGs
touch EPG_temp.xml
while IFS= read -r epg_url; do
  [ -z "${epg_url}" ] && continue
  echo "[INFO] Descargando: ${epg_url}"

  TMP_XML="$(mktemp)"
  if echo "$epg_url" | grep -qiE '\.gz($|\?)'; then
    # .gz
    if ! curl -fsSL -A "Mozilla/5.0" "$epg_url" | gzip -dc > "$TMP_XML"; then
      echo "[WARN] Falló descarga/descompresión: $epg_url"
      continue
    fi
  else
    if ! curl -fsSL -A "Mozilla/5.0" "$epg_url" > "$TMP_XML"; then
      echo "[WARN] Falló descarga: $epg_url"
      continue
    fi
  fi

  # Asegura saltos entre tags (para grep / sed posteriores)
  sed 's/></>\n</g' "$TMP_XML" >> EPG_temp.xml
done < "$EPGS_CLEAN"

TOTAL_PROGRAMMES_ALL=$(grep -c "<programme" EPG_temp.xml || echo 0)
echo "[INFO] Programmes acumulados en fuentes: $TOTAL_PROGRAMMES_ALL"

# 2) Filtrado por canales y renombrado/logos
touch EPG_temp1.xml EPG_temp2.xml
while IFS=, read -r old new logo; do
  # elimina espacios alrededor de comas
  old="$(echo "${old:-}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  new="$(echo "${new:-}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  logo="$(echo "${logo:-}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"

  [ -z "$old" ] && continue
  [ -z "$new" ] && new="$old"

  # cuenta coincidencias exactas del canal en <channel id="...">
  contar_channel=$(grep -c "<channel id=\"${old}\">" EPG_temp.xml || echo 0)
  if [ "$contar_channel" -gt 0 ]; then
    echo "[OK] Canal: '$old' -> '$new' (coincidencias: $contar_channel)"

    # Sección <channel> (primer logo que encuentre)
    sed -n "/<channel id=\"${old}\">/,/<\/channel>/p" EPG_temp.xml > EPG_temp01.xml
    # preserva <icon .../> si existe
    if [ -n "$logo" ]; then
      # reemplaza o añade icon
      if grep -q "<icon " EPG_temp01.xml; then
        sed -E -i "s#<icon src=\"[^\"]*\" ?/?>#<icon src=\"${logo}\" />#g" EPG_temp01.xml
      else
        sed -i "/<display-name>/a \ \ \ \ <icon src=\"${logo}\" />" EPG_temp01.xml
      fi
    fi
    # renombra id y display-name
    sed -i "s#<channel id=\"${old}\">#<channel id=\"${new}\">#" EPG_temp01.xml
    sed -E -i "s#<display-name>[^<]*</display-name>#<display-name>${new}</display-name>#" EPG_temp01.xml

    cat EPG_temp01.xml >> EPG_temp1.xml

    # Bloque de programmes de ese canal
    sed -n "/<programme[^\>]*channel=\"${old}\"[^\>]*>/,/<\/programme>/p" EPG_temp.xml > EPG_temp02.xml
    # cambia atributo channel a "new"
    sed -E -i "s#channel=\"${old}\"#channel=\"${new}\"#g" EPG_temp02.xml

    cat EPG_temp02.xml >> EPG_temp2.xml
  else
    echo "[SKIP] Canal sin coincidencias: '$old'"
  fi
done < "$CANALES_CLEAN"

# 3) Ensamblado final
date_stamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
{
  echo '<?xml version="1.0" encoding="UTF-8"?>'
  echo "<tv generator-info-name=\"miEPG build $(echo "$date_stamp")\" generator-info-url=\"https://github.com/JoomBall/miEPG-src\">"
  cat EPG_temp1.xml
  cat EPG_temp2.xml
  echo '</tv>'
} > "$OUT_XML"

TOTAL_PROGRAMMES_OUT=$(grep -c "<programme" "$OUT_XML" || echo 0)
echo "[INFO] Programmes en salida ($OUT_XML): $TOTAL_PROGRAMMES_OUT"

# Si no hay programmes, salimos con código 12 para que el workflow lo avise claramente
if [ "$TOTAL_PROGRAMMES_OUT" -eq 0 ]; then
  echo "[ERROR] La salida no contiene programmes. Revisa 'epgs.txt' y 'canales.txt'."
  exit 12
fi

echo "[DONE] Generado $OUT_XML"
