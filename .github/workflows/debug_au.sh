#!/usr/bin/env bash
# Script simple de debug para AU
set -euo pipefail

echo "[DEBUG] Testing Australia EPG sources..."

# Test cada URL individualmente
URLS=(
    "https://i.mjh.nz/au/all/epg.xml.gz"
    "https://i.mjh.nz/Foxtel/epg.xml.gz"
    "https://i.mjh.nz/SamsungTVPlus/all.xml.gz"
    "https://i.mjh.nz/PlutoTV/all.xml.gz"
    "https://i.mjh.nz/generate?site=abc.net.au&region=syd"
)

for url in "${URLS[@]}"; do
    echo "[DEBUG] Testing: $url"
    if curl -fsSL --head "$url" >/dev/null 2>&1; then
        echo "[OK] URL accessible: $url"
    else
        echo "[ERROR] URL failed: $url"
    fi
done

echo "[DEBUG] Testing actual EPG download..."
curl -fsSL "https://i.mjh.nz/PlutoTV/us.xml.gz" | gzip -dc | head -20 || echo "[ERROR] Failed to download/decompress"

echo "[DEBUG] Done"
