#!/usr/bin/env bash
# EPG_script.sh (robusto frente a errores por fuente)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${ROOT_DIR:-$SCRIPT_DIR}"

EPGS_FILE="${EPGS_FILE:-$ROOT_DIR/../../epgs.txt}"           # ← epgs.txt en la raíz del repo
CHANNELS_FILE="${CHANNELS_FILE:-$ROOT_DIR/../../canales.txt}" # ← canales.txt en la raíz del repo
OUTPUT="${OUTPUT:-$ROOT_DIR/../../miEPG.xml}"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

echo "Usando:"
echo "  EPGS_FILE=$EPGS_FILE"
echo "  CHANNELS_FILE=$CHANNELS_FILE"
echo "  OUTPUT=$OUTPUT"

[ -f "$EPGS_FILE" ] || { echo "No existe $EPGS_FILE"; exit 10; }
[ -f "$CHANNELS_FILE" ] || { echo "No existe $CHANNELS_FILE"; exit 11; }

# Normaliza CRLF y elimina vacías/comentarios
sed -i 's/\r$//' "$EPGS_FILE" || true
sed -i 's/\r$//' "$CHANNELS_FILE" || true
grep -v -E '^\s*$|^\s*#' "$EPGS_FILE" > "$TMPDIR/epgs.clean"
grep -v -E '^\s*$|^\s*#' "$CHANNELS_FILE" > "$TMPDIR/canales.clean"

EPG_TEMP_ALL="$TMPDIR/EPG_all.xml"
: > "$EPG_TEMP_ALL"

# --- Descarga tolerante ---
HAS_ANY_SOURCE=0
while IFS= read -r url; do
  url="${url%%#*}"; url="$(echo -n "$url" | xargs || true)"
  [ -z "$url" ] && continue

  echo "Fuente: $url"
  if [[ "$url" =~ \.gz($|\?) ]]; then
    if curl -fsSL --max-time 60 "$url" | gzip -dc >> "$EPG_TEMP_ALL"; then
      echo "OK (gz) → añadido"
      HAS_ANY_SOURCE=1
    else
      echo "WARN: fallo al descargar/descomprimir $url (continuo)"
    fi
  else
    if curl -fsSL --max-time 60 "$url" >> "$EPG_TEMP_ALL"; then
      echo "OK → añadido"
      HAS_ANY_SOURCE=1
    else
      echo "WARN: fallo al descargar $url (continuo)"
    fi
  fi
  echo >> "$EPG_TEMP_ALL"
done < "$TMPDIR/epgs.clean"

# Si ninguna fuente funcionó, aborta con mensaje claro
if [ "$HAS_ANY_SOURCE" -eq 0 ]; then
  echo "ERROR: ninguna fuente de epgs.txt se pudo descargar correctamente"; exit 12
fi

# Añade saltos entre tags para grepear bloques
sed -i 's/></>\n</g' "$EPG_TEMP_ALL"

if ! grep -q "<channel id=" "$EPG_TEMP_ALL"; then
  echo "ERROR: no se detectaron <channel> en las fuentes (¿XML malformado o vacío?)"; exit 13
fi

# --- Mapeo de canales ---
CHANNELS_OUT="$TMPDIR/channels.out.xml"
PROGS_OUT="$TMPDIR/programmes.out.xml"
: > "$CHANNELS_OUT"
: > "$PROGS_OUT"

# Formato: old_id,new_name,logo_url(opcional)
COUNTER_OK=0
COUNTER_SKIP=0

while IFS=, read -r old new logo; do
  old="$(echo -n "$old" | xargs)"; [ -z "$old" ] && continue
  new="$(echo -n "$new" | xargs)"
  logo="$(echo -n "${logo:-}" | xargs)"

  contar_prog="$(grep -c "<programme[^>]*channel=\"${old}\"" "$EPG_TEMP_ALL" || true)"

  if [ "${contar_prog:-0}" -gt 0 ]; then
    echo "OK: $old  →  $new  (programas: $contar_prog)"
    COUNTER_OK=$((COUNTER_OK+1))

    # Canal: primer bloque
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
    echo "SKIP (sin programas para id): $old"
    COUNTER_SKIP=$((COUNTER_SKIP+1))
  fi
done < "$TMPDIR/canales.clean"

echo "Resumen mapeo → OK:$COUNTER_OK  SKIP:$COUNTER_SKIP"

# Si no se añadió ningún canal/programa, mejor fallar con código claro
if [ "$COUNTER_OK" -eq 0 ]; then
  echo "ERROR: no se mapeó ningún canal (probable desajuste de OLD ids en canales.txt)"; exit 14
fi

# Dedup canales por id
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
