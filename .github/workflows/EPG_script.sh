#!/usr/bin/env bash
set -euo pipefail

# === Config por entorno (puedes sobreescribir en el workflow) ===
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$SCRIPT_DIR"

EPGS_FILE="${EPGS_FILE:-$ROOT_DIR/epgs.txt}"           # p.ej: config/epgs.txt
CHANNELS_FILE="${CHANNELS_FILE:-$ROOT_DIR/canales.txt}" # p.ej: config/canales.txt
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

# Normaliza CRLF y elimina líneas vacías / espacios
sed -i 's/\r$//' "$EPGS_FILE" || true
sed -i 's/\r$//' "$CHANNELS_FILE" || true
grep -v -E '^\s*$' "$EPGS_FILE" > "$TMPDIR/epgs.clean"
grep -v -E '^\s*$' "$CHANNELS_FILE" > "$TMPDIR/canales.clean"

# === Descarga y concatena fuentes ===
EPG_TEMP_ALL="$TMPDIR/EPG_all.txt"
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

# === Mapeo de canales y extracción de programas ===
CHANNELS_OUT="$TMPDIR/channels.xml"
PROGS_OUT="$TMPDIR/programmes.xml"
: > "$CHANNELS_OUT"
: > "$PROGS_OUT"

# Formato canales.txt: old_name,new_name,logo_url(opcional)
while IFS=, read -r old new logo; do
  old="$(echo -n "$old" | xargs)"; [ -z "$old" ] && continue
  new="$(echo -n "$new" | xargs)"
  logo="$(echo -n "${logo:-}" | xargs)"

  contar_channel="$(grep -c "<channel id=\"${old}\">" "$EPG_TEMP_ALL" || true)"
  if [ "${contar_channel:-0}" -gt 0 ]; then
    # Canal: toma el primer bloque y ajusta display-name / icon
    awk -v o="$old" '
      $0 ~ "<channel id=\""o"\">" {inblk=1}
      inblk {print}
      inblk && $0 ~ "</channel>" {exit}
    ' "$EPG_TEMP_ALL" > "$TMPDIR/ch.tmp" || true

    if [ -s "$TMPDIR/ch.tmp" ]; then
      # fuerza id/display-name
      {
        echo "  <channel id=\"${new}\">"
        echo "    <display-name>${new}</display-name>"
        if [ -n "$logo" ]; then
          echo "    <icon src=\"${logo}\" />"
        else
          # intenta conservar un icon existente si lo hubiera
          grep -m1 '<icon ' "$TMPDIR/ch.tmp" || true
        fi
        echo "  </channel>"
      } >> "$CHANNELS_OUT"
    fi

    # Programas: extrae todos los bloques y cambia el atributo channel
    awk -v o="$old" '
      $0 ~ "<programme" && $0 ~ "channel=\""o"\"" {inblk=1; sub("channel=\""o"\"", ""); print; next}
      inblk {print}
      inblk && $0 ~ "</programme>" {inblk=0}
    ' "$EPG_TEMP_ALL" > "$TMPDIR/prog.tmp" || true

    if [ -s "$TMPDIR/prog.tmp" ]; then
      # reinyecta el channel con el nombre nuevo tras la cabecera de <programme ...>
      # (quitamos el cierre ">" en la primera línea y lo reabrimos con channel="new"
      awk -v n="$new" '
        NR==1{
          sub(/>$/, "", $0);
          print $0 " channel=\"" n "\">";
          next
        }
        {print}
      ' "$TMPDIR/prog.tmp" >> "$PROGS_OUT"
    fi
  else
    echo "Saltando canal: $old (0 coincidencias)"
  fi
done < "$TMPDIR/canales.clean"

# Dedup canales (por id exacto)
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
  echo "<tv generator-info-name=\"miEPG ${date_stamp}\" generator-info-url=\"https://github.com/davidmuma/miEPG\">"
  cat "$TMPDIR/channels.dedup.xml"
  cat "$PROGS_OUT"
  echo '</tv>'
} > "$OUTPUT"

echo "Generado $OUTPUT ($(wc -c < "$OUTPUT") bytes)"
