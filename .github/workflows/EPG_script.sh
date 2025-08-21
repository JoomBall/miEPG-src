#!/usr/bin/env bash
# EPG_script.sh — robusto con fallback API GitHub, BOM/CRLF y gz/xml
set -euo pipefail

# === Rutas por defecto (script ubicado en .github/workflows/) ===
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${ROOT_DIR:-$SCRIPT_DIR/../..}"   # → raíz del repo

EPGS_FILE="${EPGS_FILE:-$ROOT_DIR/epgs.txt}"
CHANNELS_FILE="${CHANNELS_FILE:-$ROOT_DIR/canales.txt}"
OUTPUT="${OUTPUT:-$ROOT_DIR/miEPG.xml}"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

echo "Usando:"
echo "  EPGS_FILE=$EPGS_FILE"
echo "  CHANNELS_FILE=$CHANNELS_FILE"
echo "  OUTPUT=$OUTPUT"

[ -f "$EPGS_FILE" ] || { echo "No existe $EPGS_FILE"; exit 10; }
[ -f "$CHANNELS_FILE" ] || { echo "No existe $CHANNELS_FILE"; exit 11; }

# === Normalización de entradas ===
# CRLF → LF
sed -i 's/\r$//' "$EPGS_FILE" || true
sed -i 's/\r$//' "$CHANNELS_FILE" || true
# Quitar posible BOM UTF-8
sed -i '1s/^\xEF\xBB\xBF//' "$EPGS_FILE" || true
sed -i '1s/^\xEF\xBB\xBF//' "$CHANNELS_FILE" || true
# Quitar vacías/comentarios
grep -v -E '^\s*$|^\s*#' "$EPGS_FILE"     > "$TMPDIR/epgs.clean" || true
grep -v -E '^\s*$|^\s*#' "$CHANNELS_FILE" > "$TMPDIR/canales.clean" || true

EPG_TEMP_ALL="$TMPDIR/EPG_all.xml"
: > "$EPG_TEMP_ALL"

UA="Mozilla/5.0 (GitHubActions)"

# === Descarga con tolerancia y fallback a API contents de GitHub ===
fetch_and_append() {
  # $1=url ; $2=gz? yes/no
  local url="$1" is_gz="$2"
  if [ "$is_gz" = "yes" ]; then
    curl -fsSL -A "$UA" --max-time 60 "$url" | gzip -dc >> "$EPG_TEMP_ALL"
  else
    curl -fsSL -A "$UA" --max-time 60 "$url" >> "$EPG_TEMP_ALL"
  fi
}

HAS_ANY_SOURCE=0
while IFS= read -r url; do
  url="${url%%#*}"; url="$(echo -n "$url" | xargs || true)"
  [ -z "$url" ] && continue

  echo "Fuente: $url"
  is_gz="no"; echo "$url" | grep -qiE '\.gz($|\?)' && is_gz="yes"

  if fetch_and_append "$url" "$is_gz"; then
    echo "OK (raw)"
    HAS_ANY_SOURCE=1
  else
    echo "WARN: descarga raw fallida"
    # Fallback especial para raw.githubusercontent.com → API contents
    if echo "$url" | grep -q '^https://raw\.githubusercontent\.com/'; then
      if [[ "$url" =~ ^https://raw\.githubusercontent\.com/([^/]+)/([^/]+)/([^/]+)/(.*)$ ]]; then
        owner="${BASH_REMATCH[1]}"; repo="${BASH_REMATCH[2]}"; branch="${BASH_REMATCH[3]}"; path="${BASH_REMATCH[4]}"
        api_url="https://api.github.com/repos/${owner}/${repo}/contents/${path}?ref=${branch}"
        echo "Intento API GitHub: $api_url"
        hdr=(-H "Accept: application/vnd.github.raw")
        # GITHUB_TOKEN lo inyecta Actions por defecto
        [ -n "${GITHUB_TOKEN:-}" ] && hdr+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")

        if [ "$is_gz" = "yes" ]; then
          if curl -fsSL "${hdr[@]}" -A "$UA" --max-time 60 "$api_url" | gzip -dc >> "$EPG_TEMP_ALL"; then
            echo "OK (API gz)"
            HAS_ANY_SOURCE=1
          else
            echo "WARN: API (gz) también falló"
          fi
        else
          if curl -fsSL "${hdr[@]}" -A "$UA" --max-time 60 "$api_url" >> "$EPG_TEMP_ALL"; then
            echo "OK (API)"
            HAS_ANY_SOURCE=1
          else
            echo "WARN: API también falló"
          fi
        fi
      else
        echo "WARN: no pude parsear la URL raw para fallback API"
      fi
    fi
  fi

  echo >> "$EPG_TEMP_ALL"
done < "$TMPDIR/epgs.clean"

if [ "$HAS_ANY_SOURCE" -eq 0 ]; then
  echo "ERROR: ninguna fuente de epgs.txt se pudo descargar correctamente"; exit 12
fi

# Separar tags para facilitar grep/awk
sed -i 's/></>\n</g' "$EPG_TEMP_ALL"

if ! grep -q "<channel id=" "$EPG_TEMP_ALL"; then
  echo "ERROR: no se detectaron <channel> en las fuentes (¿XML vacío o malformado?)"; exit 13
fi

# === Mapeo canales y programas ===
CHANNELS_OUT="$TMPDIR/channels.out.xml"
PROGS_OUT="$TMPDIR/programmes.out.xml"
: > "$CHANNELS_OUT"
: > "$PROGS_OUT"

COUNTER_OK=0
COUNTER_SKIP=0

# Formato canales.txt: old_id,new_name,logo_url(opcional)
while IFS=, read -r old new logo; do
  old="$(echo -n "$old" | xargs)"; [ -z "$old" ] && continue
  new="$(echo -n "$new" | xargs)"
  logo="$(echo -n "${logo:-}" | xargs)"

  contar_prog="$(grep -c "<programme[^>]*channel=\"${old}\"" "$EPG_TEMP_ALL" || true)"

  if [ "${contar_prog:-0}" -gt 0 ]; then
    echo "OK: $old  →  $new  (programas: $contar_prog)"
    COUNTER_OK=$((COUNTER_OK+1))

    # Canal (primer bloque)
    awk -v o="$old" '
      $0 ~ "<channel id=\""o"\">" {inblk=1}
      inblk {print}
      inblk && $0 ~ "</channel>" {exit}
    ' "$EPG_TEMP_ALL" > "$TMPDIR/ch.tmp" || true

    if [ -s "$TMPDIR/ch.tmp" ]; then
      {
        echo "  <channel id=\"${new}\">"
        echo "    <display-name>${new}</display-name>"
        if [ -n "$logo" ]; then
          echo "    <icon src=\"${logo}\" />"
        else
          grep -m1 '<icon ' "$TMPDIR/ch.tmp" || true
        fi
        echo "  </channel>"
      } >> "$CHANNELS_OUT"
    fi

    # Programas (cambia atributo channel a new)
    awk -v o="$old" '
      $0 ~ "<programme" && $0 ~ "channel=\""o"\"" {inblk=1; sub("channel=\""o"\"", ""); print; next}
      inblk {print}
      inblk && $0 ~ "</programme>" {inblk=0}
    ' "$EPG_TEMP_ALL" > "$TMPDIR/prog.tmp" || true

    if [ -s "$TMPDIR/prog.tmp" ]; then
      awk -v n="$new" '
        NR==1{ sub(/>$/, "", $0); print $0 " channel=\"" n "\">"; next }
        {print}
      ' "$TMPDIR/prog.tmp" >> "$PROGS_OUT"
    fi
  else
    echo "SKIP (sin programas para id): $old"
    COUNTER_SKIP=$((COUNTER_SKIP+1))
  fi
done < "$TMPDIR/canales.clean"

echo "Resumen mapeo → OK:$COUNTER_OK  SKIP:$COUNTER_SKIP"
[ "$COUNTER_OK" -gt 0 ] || { echo "ERROR: no se mapeó ningún canal (ids OLD no coinciden con la guía)"; exit 14; }

# Dedup canales por id exacto
awk '
  /<channel id="/{
    match($0, /<channel id="([^"]+)">/, m);
    if (seen[m[1]]++) next
  }
  {print}
' "$CHANNELS_OUT" > "$TMPDIR/channels.dedup.xml"

# === Salida final ===
date_stamp=$(date +"%d/%m/%Y %R")
{
  echo '<?xml version="1.0" encoding="UTF-8"?>'
  echo "<tv generator-info-name=\"miEPG ${date_stamp}\" generator-info-url=\"https://github.com/JoomBall/miEPG-src\">"
  cat "$TMPDIR/channels.dedup.xml"
  cat "$PROGS_OUT"
  echo '</tv>'
} > "$OUTPUT"

echo "Generado $OUTPUT ($(wc -c < "$OUTPUT") bytes)"
