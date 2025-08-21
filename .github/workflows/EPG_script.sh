#!/usr/bin/env bash
set -euo pipefail

# === Config por entorno (por defecto: raíz del repo) ===
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$SCRIPT_DIR"

EPGS_FILE="${EPGS_FILE:-$ROOT_DIR/epgs.txt}"           # permite override por env
CHANNELS_FILE="${CHANNELS_FILE:-$ROOT_DIR/canales.txt}"
OUTPUT="${OUTPUT:-$ROOT_DIR/miEPG.xml}"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

echo "Usando:"
echo "  EPGS_FILE=$EPGS_FILE"
echo "  CHANNELS_FILE=$CHANNELS_FILE"
echo "  OUTPUT=$OUTPUT"

# === Comprobaciones ===
[ -f "$EPGS_FILE" ] || { echo "No existe $EPGS_FILE"; exit 10; }
[ -f "$CHANNELS_FILE" ] || { echo "No existe $CHANNELS_FILE"; exit 11; }

# Normaliza CRLF y elimina líneas vacías / comentarios
sed -i 's/\r$//' "$EPGS_FILE" || true
sed -i 's/\r$//' "$CHANNELS_FILE" || true
grep -v -E '^\s*$|^\s*#' "$EPGS_FILE" > "$TMPDIR/epgs.clean"
grep -v -E '^\s*$|^\s*#' "$CHANNELS_FILE" > "$TMPDIR/canales.clean"

# === Descarga y concatena fuentes ===
EPG_TEMP_ALL="$TMPDIR/EPG_all.xml"
: > "$EPG_TEMP_ALL"

while IFS= read -r url; do
  url="${url%%#*}"; url="$(echo -n "$url" | xargs || true)"
  [ -z "$url" ] && continue
  echo "Fuente: $url"
  if [[ "$url" =~ \.gz($|\?) ]]; then
    curl -fsSL --max-time 60 "$url" | gzip -dc >> "$EPG_TEMP_ALL"
  else
    curl -fsSL --max-time 60 "$url" >> "$EPG_TEMP_ALL"
  fi
  echo >> "$EPG_TEMP_ALL"
done < "$TMPDIR/epgs.clean"

# Añade saltos entre tags para poder grepear bloques
sed -i 's/></>\n</g' "$EPG_TEMP_ALL"

# Si el merge quedó vacío, no seguimos
if ! grep -q "<channel id=" "$EPG_TEMP_ALL"; then
  echo "No se detectaron <channel> en las fuentes. Revisa epgs.txt"; exit 12
fi

# === Mapeo de canales y extracción de programas ===
CHANNELS_OUT="$TMPDIR/channels.out.xml"
PROGS_OUT="$TMPDIR/programmes.out.xml"
: > "$CHANNELS_OUT"
: > "$PROGS_OUT"

# Formato: old_id,new_name,logo_url(opcional)
while IFS=, read -r old new logo; do
  old="$(echo -n "$old" | xargs)"; [ -z "$old" ] && continue
  new="$(echo -n "$new" | xargs)"
  logo="$(echo -n "${logo:-}" | xargs)"

  # ¿Tiene programas?
  contar_prog="$(grep -c "<programme[^>]*channel=\"${old}\"" "$EPG_TEMP_ALL" || true)"
  if [ "${contar_prog:-0}" -gt 0 ]; then
    echo "OK: $old  ->  $new  (programas: $contar_prog)"

    # Canal: toma primer bloque
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

    # Programas: cambia el atributo channel a "new"
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
    echo "Saltando canal (sin programas): $old"
  fi
done < "$TMPDIR/canales.clean"

# Dedup canales por id exacto
awk '
  /<channel id="/{
    match($0, /<channel id="([^"]+)">/, m);
    if (seen[m[1]]++) next
  }
  {print}
' "$CHANNELS_OUT" > "$TMPDIR/channels.dedup.xml"

# Construye salida final
date_stamp=$(date +"%d/%m/%Y %R")
{
  echo '<?xml version="1.0" encoding="UTF-8"?>'
  echo "<tv generator-info-name=\"miEPG ${date_stamp}\" generator-info-url=\"https://github.com/JoomBall/miEPG-src\">"
  cat "$TMPDIR/channels.dedup.xml"
  cat "$PROGS_OUT"
  echo '</tv>'
} > "$OUTPUT"

echo "Generado $OUTPUT ($(wc -c < "$OUTPUT") bytes)"
