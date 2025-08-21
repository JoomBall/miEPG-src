#!/usr/bin/env bash
# EPG_script.sh — build EPG combinado con fallback GitHub API + DEBUG
# Requisitos del runner: curl, gzip, sed, awk, coreutils
set -euo pipefail

# === 0) Ubicación: trabaja desde la raíz del repo ===
# (el workflow lo invoca con: bash -x .github/workflows/EPG_script.sh)
cd "$(git rev-parse --show-toplevel)"

EPGS_FILE="${EPGS_FILE:-epgs.txt}"
CHANNELS_FILE="${CHANNELS_FILE:-canales.txt}"
OUTPUT="${OUTPUT:-miEPG.xml}"
UA="Mozilla/5.0 (GitHubActions)"

echo "== Paths =="
echo "  EPGS_FILE:     $EPGS_FILE"
echo "  CHANNELS_FILE: $CHANNELS_FILE"
echo "  OUTPUT:        $OUTPUT"

[[ -f "$EPGS_FILE" ]]     || { echo "ERROR: no existe $EPGS_FILE"; exit 10; }
[[ -f "$CHANNELS_FILE" ]] || { echo "ERROR: no existe $CHANNELS_FILE"; exit 11; }

# === 1) Normaliza listas (CRLF, BOM, comentarios/blank) ===
# Quita CRLF
sed -i 's/\r$//' "$EPGS_FILE"     || true
sed -i 's/\r$//' "$CHANNELS_FILE" || true
# Quita BOM
sed -i '1s/^\xEF\xBB\xBF//' "$EPGS_FILE"     || true
sed -i '1s/^\xEF\xBB\xBF//' "$CHANNELS_FILE" || true

# Limpia y genera versiones "clean"
EPGS_CLEAN="$(mktemp)"
CHANNELS_CLEAN="$(mktemp)"
trap 'rm -f "$EPGS_CLEAN" "$CHANNELS_CLEAN" EPG_temp*' EXIT

grep -v -E '^\s*$|^\s*#' "$EPGS_FILE"     > "$EPGS_CLEAN"     || true
grep -v -E '^\s*$|^\s*#' "$CHANNELS_FILE" > "$CHANNELS_CLEAN" || true

# === 2) Descarga de fuentes y merge ===
rm -f EPG_temp.xml EPG_temp00.xml EPG_temp00.xml.gz
: > EPG_temp.xml

download_to_file() {
  # $1=url, $2=expect_gz (yes/no), $3=out_file
  local url="$1" is_gz="$2" out="$3"

  # intento directo contra la URL
  if [ "$is_gz" = "yes" ]; then
    if curl -fsSL -A "$UA" --max-time 60 "$url" | gzip -dc > "$out" 2>/dev/null; then
      return 0
    fi
  else
    if curl -fsSL -A "$UA" --max-time 60 "$url" > "$out" 2>/dev/null; then
      return 0
    fi
  fi

  # fallback: si es raw.githubusercontent.com → API contents
  if [[ "$url" =~ ^https://raw\.githubusercontent\.com/([^/]+)/([^/]+)/([^/]+)/(.*)$ ]]; then
    local owner="${BASH_REMATCH[1]}"
    local repo="${BASH_REMATCH[2]}"
    local branch="${BASH_REMATCH[3]}"
    local path="${BASH_REMATCH[4]}"
    local api_url="https://api.github.com/repos/${owner}/${repo}/contents/${path}?ref=${branch}"

    local hdr=(-H "Accept: application/vnd.github.raw")
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
      hdr+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
    fi

    if [ "$is_gz" = "yes" ]; then
      if curl -fsSL "${hdr[@]}" -A "$UA" --max-time 60 "$api_url" | gzip -dc > "$out" 2>/dev/null; then
        echo "(fallback API OK: $api_url)"
        return 0
      fi
    else
      if curl -fsSL "${hdr[@]}" -A "$UA" --max-time 60 "$api_url" > "$out" 2>/dev/null; then
        echo "(fallback API OK: $api_url)"
        return 0
      fi
    fi
  fi

  return 1
}

echo "== Descargando fuentes de $EPGS_CLEAN =="
while IFS= read -r url; do
  url="${url%%#*}"; url="$(echo -n "$url" | xargs || true)"
  [[ -z "$url" ]] && continue

  echo "-- Fuente: $url"
  is_gz="no"; echo "$url" | grep -qiE '\.gz($|\?)' && is_gz="yes"

  if download_to_file "$url" "$is_gz" "EPG_temp00.xml"; then
    # Normaliza para facilitar greps (pone cada tag en línea separada)
    sed -i 's/></>\n</g' EPG_temp00.xml || true
    cat EPG_temp00.xml >> EPG_temp.xml
    echo >> EPG_temp.xml
    echo "   OK"
  else
    echo "   WARN: no se pudo descargar (raw ni API); sigo con las demás"
  fi
done < "$EPGS_CLEAN"

# === DEBUG: inspección de lo descargado ===
echo "=== DEBUG: tamaño total de EPG_temp.xml ==="
wc -c EPG_temp.xml || true

echo "=== DEBUG: primeras 50 líneas de EPG_temp.xml ==="
sed -n '1,50p' EPG_temp.xml || true

echo "=== DEBUG: primeros 200 <channel id> detectados (únicos, ordenados) ==="
grep -oP '(?<=<channel id=")[^"]+' EPG_temp.xml | sort -u | head -n 200 | nl -ba || true

echo "=== DEBUG: top 50 channel ids por frecuencia de <programme> ==="
grep -oP '<programme[^>]*channel="[^"]+"' EPG_temp.xml \
  | sed -E 's/.*channel="([^"]+)".*/\1/' \
  | sort | uniq -c | sort -rn | head -n 50 || true

echo "=== DEBUG: total de <programme> detectados en fuentes ==="
grep -c "<programme" EPG_temp.xml || true

# Si realmente no hay programas, cortamos aquí (fuentes vacías)
if ! grep -q "<programme" EPG_temp.xml; then
  echo "ERROR: Las fuentes no traen <programme>. Revisa epgs.txt"
  exit 20
fi

# === 3) Mapeo según canales.txt: renombra id, display-name y aplica logo ===
: > EPG_temp1.xml   # canales resultantes
: > EPG_temp2.xml   # programmes resultantes

COUNTER_OK=0
COUNTER_SKIP=0

# Formato canales.txt: old_id,new_name,logo_url(opcional)
while IFS=, read -r old new logo; do
  old="$(echo -n "${old:-}" | xargs || true)"
  new="$(echo -n "${new:-}" | xargs || true)"
  logo="$(echo -n "${logo:-}" | xargs || true)"
  [[ -z "$old" || -z "$new" ]] && continue

  cnt_prog="$(grep -c "<programme[^>]*channel=\"${old}\"" EPG_temp.xml || true)"
  cnt_chan="$(grep -c "<channel id=\"${old}\">" EPG_temp.xml || true)"

  if [[ "${cnt_prog:-0}" -gt 0 || "${cnt_chan:-0}" -gt 0 ]]; then
    echo "OK: '${old}' → '${new}' (programmes:${cnt_prog}, channels:${cnt_chan})"
    COUNTER_OK=$((COUNTER_OK+1))

    # --- CHANNEL ---
    tmp_ch="EPG_ch_${old}.xml"
    sed -n "/<channel id=\"${old}\">/,/<\/channel>/p" EPG_temp.xml > "$tmp_ch" || true

    if [[ ! -s "$tmp_ch" ]]; then
      # la fuente no traía bloque <channel>, generamos uno mínimo
      {
        echo "  <channel id=\"${new}\">"
        echo "    <display-name>${new}</display-name>"
        [[ -n "$logo" ]] && echo "    <icon src=\"${logo}\" />"
        echo "  </channel>"
      } >> EPG_temp1.xml
    else
      # reescribe id
      sed -i "1s#<channel id=\"${old}\">#<channel id=\"${new}\">#" "$tmp_ch"
      # display-name (si no hay, lo metemos; si hay, lo sustituimos)
      if ! grep -q "<display-name>" "$tmp_ch"; then
        sed -i "2i\    <display-name>${new}</display-name>" "$tmp_ch"
      else
        sed -i "s#<display-name>.*</display-name>#<display-name>${new}</display-name>#g" "$tmp_ch"
      fi
      # logo (si se pasa, fuerza)
      if [[ -n "$logo" ]]; then
        if grep -q "<icon " "$tmp_ch"; then
          sed -i "s#<icon src=.*#<icon src=\"${logo}\" />#g" "$tmp_ch"
        else
          sed -i "/<display-name>/a\    <icon src=\"${logo}\" />" "$tmp_ch"
        fi
      fi
      cat "$tmp_ch" >> EPG_temp1.xml
      rm -f "$tmp_ch"
    fi

    # --- PROGRAMMES ---
    tmp_pg="EPG_pg_${old}.xml"
    sed -n "/<programme[^>]*channel=\"${old}\"/,/<\/programme>/p" EPG_temp.xml > "$tmp_pg" || true
    if [[ -s "$tmp_pg" ]]; then
      sed -i "s#channel=\"${old}\"#channel=\"${new}\"#g" "$tmp_pg"
      cat "$tmp_pg" >> EPG_temp2.xml
      rm -f "$tmp_pg"
    fi
  else
    echo "SKIP: '${old}' (no aparece en fuentes)"
    COUNTER_SKIP=$((COUNTER_SKIP+1))
  fi
done < "$CHANNELS_CLEAN"

echo "== Resumen mapeo: OK=${COUNTER_OK}  SKIP=${COUNTER_SKIP} =="
if [[ "$COUNTER_OK" -eq 0 ]]; then
  echo "ERROR: no se mapeó ningún canal (los OLD ids no coinciden con la guía)."
  exit 12
fi

# Dedup de canales por id (por si varias fuentes aportaron el mismo)
awk '
  /<channel id="/{
    match($0, /<channel id="([^"]+)">/, m);
    if (seen[m[1]]++) next
  }
  {print}
' EPG_temp1.xml > EPG_temp1_dedup.xml

# === 4) Ensamble y validación de salida ===
date_stamp="$(date +"%d/%m/%Y %R")"
{
  echo '<?xml version="1.0" encoding="UTF-8"?>'
  echo "<tv generator-info-name=\"miEPG ${date_stamp}\" generator-info-url=\"https://github.com/JoomBall/miEPG-src\">"
  cat EPG_temp1_dedup.xml
  cat EPG_temp2.xml
  echo '</tv>'
} > "$OUTPUT"

echo "== Salida: $OUTPUT =="
wc -c "$OUTPUT" || true
grep -q "<programme" "$OUTPUT" || { echo "ERROR: $OUTPUT no contiene <programme>"; exit 12; }

echo "=== Cabecera de salida ==="
sed -n '1,30p' "$OUTPUT" || true

echo "=== Ejemplos de <channel id> finales ==="
grep -oP '(?<=<channel id=")[^"]+' "$OUTPUT" | sort -u | head -n 50 | nl -ba || true

echo "=== Conteo total de <programme> en salida ==="
grep -c "<programme" "$OUTPUT" || true

echo "OK: generado $OUTPUT"
