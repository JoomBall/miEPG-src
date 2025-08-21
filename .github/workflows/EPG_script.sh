#!/usr/bin/env bash
# EPG_script.sh — per-country, tolerante a vacío, sin romper el workflow
# Requisitos: curl, gzip, sed, awk (ubuntu-latest los trae)
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

EPGS_FILE="${EPGS_FILE:-epgs.txt}"           # lista de fuentes (una por línea)
CHANNELS_FILE="${CHANNELS_FILE:-canales.txt}" # old_id,new_name,logo_url(opc)
OUTPUT="${OUTPUT:-miEPG.xml}"                 # salida final
COUNTRY="${COUNTRY:-XX}"                      # es / gb / etc. (solo para logs)
ALLOW_EMPTY="${ALLOW_EMPTY:-0}"               # 1 = no fallar si no hay datos
UA="Mozilla/5.0 (GitHubActions)"

echo "== Build EPG ($COUNTRY) =="
echo "  EPGS_FILE:     $EPGS_FILE"
echo "  CHANNELS_FILE: $CHANNELS_FILE"
echo "  OUTPUT:        $OUTPUT"
echo "  ALLOW_EMPTY:   $ALLOW_EMPTY"

# Si no hay listas, salimos "limpio" si ALLOW_EMPTY=1
if [[ ! -f "$EPGS_FILE" || ! -s "$EPGS_FILE" ]]; then
  echo "WARN: $EPGS_FILE no existe o está vacío."
  [[ "$ALLOW_EMPTY" == "1" ]] && exit 0 || exit 10
fi
if [[ ! -f "$CHANNELS_FILE" || ! -s "$CHANNELS_FILE" ]]; then
  echo "WARN: $CHANNELS_FILE no existe o está vacío."
  [[ "$ALLOW_EMPTY" == "1" ]] && exit 0 || exit 11
fi

# Normaliza CRLF/BOM
sed -i 's/\r$//' "$EPGS_FILE" "$CHANNELS_FILE" || true
sed -i '1s/^\xEF\xBB\xBF//' "$EPGS_FILE" "$CHANNELS_FILE" || true

EPGS_CLEAN="$(mktemp)"
CHANNELS_CLEAN="$(mktemp)"
trap 'rm -f "$EPGS_CLEAN" "$CHANNELS_CLEAN" EPG_temp*' EXIT

grep -v -E '^\s*$|^\s*#' "$EPGS_FILE"     > "$EPGS_CLEAN"     || true
grep -v -E '^\s*$|^\s*#' "$CHANNELS_FILE" > "$CHANNELS_CLEAN" || true

rm -f EPG_temp.xml EPG_temp00.xml EPG_temp00.xml.gz
: > EPG_temp.xml

download_to_file() {
  local url="$1" is_gz="$2" out="$3"
  if [ "$is_gz" = "yes" ]; then
    if curl -fsSL -A "$UA" --max-time 60 "$url" | gzip -dc > "$out" 2>/dev/null; then
      return 0
    fi
  else
    if curl -fsSL -A "$UA" --max-time 60 "$url" > "$out" 2>/dev/null; then
      return 0
    fi
  fi
  # Fallback a API contents si viene de raw.githubusercontent.com
  if [[ "$url" =~ ^https://raw\.githubusercontent\.com/([^/]+)/([^/]+)/([^/]+)/(.*)$ ]]; then
    local owner="${BASH_REMATCH[1]}" repo="${BASH_REMATCH[2]}" branch="${BASH_REMATCH[3]}" path="${BASH_REMATCH[4]}"
    local api_url="https://api.github.com/repos/${owner}/${repo}/contents/${path}?ref=${branch}"
    local hdr=(-H "Accept: application/vnd.github.raw")
    [[ -n "${GITHUB_TOKEN:-}" ]] && hdr+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
    if [ "$is_gz" = "yes" ]; then
      curl -fsSL "${hdr[@]}" -A "$UA" --max-time 60 "$api_url" | gzip -dc > "$out" 2>/dev/null || return 1
    else
      curl -fsSL "${hdr[@]}" -A "$UA" --max-time 60 "$api_url" > "$out" 2>/dev/null || return 1
    fi
    echo "(fallback API OK: $api_url)"
    return 0
  fi
  return 1
}

echo "== Descargando fuentes =="
while IFS= read -r url; do
  url="${url%%#*}"; url="$(echo -n "$url" | xargs || true)"
  [[ -z "$url" ]] && continue
  echo "-- $url"
  is_gz="no"; echo "$url" | grep -qiE '\.gz($|\?)' && is_gz="yes"
  if download_to_file "$url" "$is_gz" "EPG_temp00.xml"; then
    sed -i 's/></>\n</g' EPG_temp00.xml || true
    cat EPG_temp00.xml >> EPG_temp.xml
    echo >> EPG_temp.xml
    echo "   OK"
  else
    echo "   WARN: no se pudo descargar"
  fi
done < "$EPGS_CLEAN"

echo "=== DEBUG: programas totales en fuentes ==="
TOTAL_SRC=$(grep -c "<programme" EPG_temp.xml || true)
echo "TOTAL_SRC=$TOTAL_SRC"

# Si no hay programas en la(s) fuente(s): salta limpio si ALLOW_EMPTY
if [[ "${TOTAL_SRC:-0}" -eq 0 ]]; then
  echo "INFO: sin <programme> en fuentes ($COUNTRY)."
  [[ "$ALLOW_EMPTY" == "1" ]] && exit 0 || exit 20
fi

# Mapeo canales
: > EPG_temp1.xml   # canales
: > EPG_temp2.xml   # programmes
COUNTER_OK=0

while IFS=, read -r old new logo; do
  old="$(echo -n "${old:-}" | xargs || true)"
  new="$(echo -n "${new:-}" | xargs || true)"
  logo="$(echo -n "${logo:-}" | xargs || true)"
  [[ -z "$old" || -z "$new" ]] && continue

  cnt_prog="$(grep -c "<programme[^>]*channel=\"${old}\"" EPG_temp.xml || true)"
  cnt_chan="$(grep -c "<channel id=\"${old}\">" EPG_temp.xml || true)"

  if [[ "${cnt_prog:-0}" -gt 0 || "${cnt_chan:-0}" -gt 0 ]]; then
    COUNTER_OK=$((COUNTER_OK+1))
    # CHANNEL
    tmp_ch="EPG_ch_${old}.xml"
    sed -n "/<channel id=\"${old}\">/,/<\/channel>/p" EPG_temp.xml > "$tmp_ch" || true
    if [[ ! -s "$tmp_ch" ]]; then
      {
        echo "  <channel id=\"${new}\">"
        echo "    <display-name>${new}</display-name>"
        [[ -n "$logo" ]] && echo "    <icon src=\"${logo}\" />"
        echo "  </channel>"
      } >> EPG_temp1.xml
    else
      sed -i "1s#<channel id=\"${old}\">#<channel id=\"${new}\">#" "$tmp_ch"
      if ! grep -q "<display-name>" "$tmp_ch"; then
        sed -i "2i\    <display-name>${new}</display-name>" "$tmp_ch"
      else
        sed -i "s#<display-name>.*</display-name>#<display-name>${new}</display-name>#g" "$tmp_ch"
      fi
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
    # PROGRAMMES
    tmp_pg="EPG_pg_${old}.xml"
    sed -n "/<programme[^>]*channel=\"${old}\"/,/<\/programme>/p" EPG_temp.xml > "$tmp_pg" || true
    if [[ -s "$tmp_pg" ]]; then
      sed -i "s#channel=\"${old}\"#channel=\"${new}\"#g" "$tmp_pg"
      cat "$tmp_pg" >> EPG_temp2.xml
      rm -f "$tmp_pg"
    fi
  fi
done < "$CHANNELS_CLEAN"

if [[ "$COUNTER_OK" -eq 0 ]]; then
  echo "INFO: ningún canal de $COUNTRY mapeó (ids no coinciden)."
  [[ "$ALLOW_EMPTY" == "1" ]] && exit 0 || exit 12
fi

# Dedup canales
awk '
  /<channel id="/{
    match($0, /<channel id="([^"]+)">/, m);
    if (seen[m[1]]++) next
  }
  {print}
' EPG_temp1.xml > EPG_temp1_dedup.xml

# Ensamble salida
date_stamp="$(date +"%d/%m/%Y %R")"
{
  echo '<?xml version="1.0" encoding="UTF-8"?>'
  echo "<tv generator-info-name=\"miEPG ${date_stamp}\" generator-info-url=\"https://github.com/${GITHUB_REPOSITORY}\">"
  cat EPG_temp1_dedup.xml
  cat EPG_temp2.xml
  echo '</tv>'
} > "$OUTPUT"

# Validación suave: si está vacío, permite continuar si ALLOW_EMPTY=1
if ! grep -q "<programme" "$OUTPUT"; then
  echo "INFO: $OUTPUT no contiene <programme> (vacío)."
  [[ "$ALLOW_EMPTY" == "1" ]] && exit 0 || exit 12
fi

echo "OK ($COUNTRY): generado $OUTPUT ($(wc -c < "$OUTPUT") bytes)"
