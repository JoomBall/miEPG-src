#!/usr/bin/env bash
set -euo pipefail

# ===== Config =====
COUNTRY="${COUNTRY:-es}"
COUNTRY_UP="${COUNTRY_UP:-$(echo "${COUNTRY}" | tr '[:lower:]' '[:upper:]')}"
WORKDIR="${GITHUB_WORKSPACE:-.}"

# Archivos de entrada (por país o raíz)
EPGS_FILE="${EPGS_FILE:-${WORKDIR}/countries/${COUNTRY}/epgs.txt}"
[ -f "${EPGS_FILE}" ] || EPGS_FILE="${WORKDIR}/epgs.txt"

CHANNELS_FILE="${CHANNELS_FILE:-${WORKDIR}/countries/${COUNTRY}/canales.txt}"
[ -f "${CHANNELS_FILE}" ] || CHANNELS_FILE="${WORKDIR}/canales.txt"

OUTPUT="${OUTPUT:-${WORKDIR}/miEPG_${COUNTRY_UP}.xml}"
ALLOW_EMPTY="${ALLOW_EMPTY:-0}"

UA="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Safari/537.36"

echo "== País: ${COUNTRY}  =="
echo "EPGS_FILE    = ${EPGS_FILE}"
echo "CHANNELS_FILE= ${CHANNELS_FILE}"
echo "OUTPUT       = ${OUTPUT}"

# ===== Temp =====
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

CH_ALL="${TMP}/channels.all.xml"
PRG_ALL="${TMP}/programmes.all.xml"
: > "${CH_ALL}"
: > "${PRG_ALL}"

download_and_clean() {
  local url="$1"; local out="$2"
  # Descarga
  if echo "$url" | grep -qiE '\.gz($|\?)'; then
    curl -fsSL -A "$UA" "$url" | gzip -dc > "${out}.raw" || return 1
  else
    curl -fsSL -A "$UA" "$url" > "${out}.raw" || return 1
  fi

  # ¿Devolvió HTML?
  if head -n 1 "${out}.raw" | grep -qi '<!doctype html\|<html'; then
    echo "   ⚠️  Saltando (HTML recibido): $url" >&2
    return 2
  fi

  # Limpieza básica
  # - Quitar BOM, control chars (salvo \t\r\n), quitar cabeceras XML y <tv> wrappers
  sed '1s/^\xEF\xBB\xBF//' "${out}.raw" \
  | tr -d '\000-\010\013\014\016-\037\177' \
  | sed -E 's/<\?xml[^?]*\?>//g' \
  | sed -E 's#</?tv[^>]*>##g' \
  | sed -E 's/&(?!(#[0-9]+;|#x[0-9A-Fa-f]+;|[A-Za-z0-9]+;))/\&amp;/g' \
  > "${out}.inner"

  # Re-empaquetar para validar y recuperar
  {
    echo '<tv>'; cat "${out}.inner"; echo '</tv>';
  } > "${out}.wrap.xml"

  # Recover para garantizar bien formado
  xmllint --recover --nowarning "${out}.wrap.xml" > "${out}.ok.xml" 2>/dev/null || true

  # Extraer canales y programas
  # (No usamos XPath aquí para mantener dependencias mínimas; grep/awk sencillos)
  # Nota: líneas únicas para patrones
  sed 's/></>\n</g' "${out}.ok.xml" > "${out}.lines"

  awk '/^<channel /,/<\/channel>/' "${out}.lines" >> "${CH_ALL}"
  awk '/^<programme /,/<\/programme>/' "${out}.lines" >> "${PRG_ALL}"

  local pc pr
  pc=$(grep -c '^<channel ' "${out}.lines" || true)
  pr=$(grep -c '^<programme ' "${out}.lines" || true)
  echo "   → canales:${pc} programmes:${pr}"
}

# ===== 1) Recorrer fuentes =====
if [ ! -s "${EPGS_FILE}" ]; then
  echo "⚠️  ${EPGS_FILE} vacío/inexistente."
fi

while IFS= read -r url; do
  [ -z "${url}" ] && continue
  echo "== Fuente: ${url}"
  download_and_clean "${url}" "${TMP}/src$(date +%s%N)" || true
done < "${EPGS_FILE}"

# ===== 2) Si no hay programas, decidir qué hacer =====
TOTAL_PRG=$(grep -c '^<programme ' "${PRG_ALL}" || echo 0)
TOTAL_CH=$(grep -c '^<channel ' "${CH_ALL}" || echo 0)
echo "Totales: channels=${TOTAL_CH} programmes=${TOTAL_PRG}"

if [ "${TOTAL_PRG}" -eq 0 ] && [ "${ALLOW_EMPTY}" != "1" ]; then
  echo "❌ No hay programmes tras limpiar/recuperar. Aborto."
  exit 12
fi

# ===== 3) Mapeo canales (canales.txt) =====
# Formato: old,new,logo(opcional)
CH_MAPPED="${TMP}/channels.mapped.xml"
PRG_MAPPED="${TMP}/programmes.mapped.xml"
: > "${CH_MAPPED}"
: > "${PRG_MAPPED}"

if [ -s "${CHANNELS_FILE}" ]; then
  while IFS=, read -r old new logo; do
    [ -z "${old}" ] && continue

    # Extraer y remodelar canal
    awk -v o="$old" '
      BEGIN{RS="</channel>"; ORS="</channel>\n"}
      $0 ~ "<channel id=\""o"\"" {
        print $0
      }
    ' "${CH_ALL}" > "${TMP}/ch.one.xml" || true

    if [ -s "${TMP}/ch.one.xml" ]; then
      if [ -n "${logo:-}" ]; then
        sed -E "s#<channel id=\"[^\"]+\">#<channel id=\"${new}\">\n  <display-name>${new}</display-name>\n  <icon src=\"${logo}\" />#g" "${TMP}/ch.one.xml" \
        | sed -E "0,/<display-name>/ s//<display-name>${new}<\/display-name>\n  <icon src=\"${logo}\" \/>/" \
        >> "${CH_MAPPED}"
      else
        sed -E "s#<channel id=\"[^\"]+\">#<channel id=\"${new}\">\n  <display-name>${new}</display-name>#g" "${TMP}/ch.one.xml" \
        | sed -E "0,/<display-name>/ s//<display-name>${new}<\/display-name>/" \
        >> "${CH_MAPPED}"
      fi
    fi

    # Programmes para ese canal
    awk -v o="$old" -v n="$new" '
      BEGIN{RS="</programme>"; ORS="</programme>\n"}
      $0 ~ "<programme[^>]*channel=\""o"\"" {
        gsub("channel=\""o"\"", "channel=\""n"\"");
        print $0
      }
    ' "${PRG_ALL}" >> "${PRG_MAPPED}"

  done < "${CHANNELS_FILE}"
else
  # Sin mapeo: pasa tal cual
  cat "${CH_ALL}" > "${CH_MAPPED}"
  cat "${PRG_ALL}" > "${PRG_MAPPED}"
fi

# Deduplicar entradas idénticas simples
awk '!seen[$0]++' "${CH_MAPPED}" > "${CH_MAPPED}.uniq"
awk '!seen[$0]++' "${PRG_MAPPED}" > "${PRG_MAPPED}.uniq"

# ===== 4) Ensamblar salida =====
date_stamp="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
{
  echo '<?xml version="1.0" encoding="UTF-8"?>'
  echo "<tv generator-info-name=\"miEPG ${date_stamp}\" generator-info-url=\"https://github.com/JoomBall/miEPG-src\">"
  cat "${CH_MAPPED}.uniq"
  cat "${PRG_MAPPED}.uniq"
  echo '</tv>'
} > "${OUTPUT}"

echo "Salida: ${OUTPUT}"
echo "Channels: $(grep -c '^  <channel ' "${OUTPUT}" || echo 0)"
echo "Programmes: $(grep -c '^  <programme ' "${OUTPUT}" || echo 0)"
