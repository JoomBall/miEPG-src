#!/usr/bin/env bash
# Script simple de debug para AU
set -euo pipefail

echo "[DEBUG] Testing Australia EPG sources with corrected URLs..."

# Test URLs corregidas
URLS=(
    "https://raw.githubusercontent.com/matthuisman/i.mjh.nz/master/au/all/epg.xml.gz"
    "https://raw.githubusercontent.com/matthuisman/i.mjh.nz/master/Foxtel/epg.xml.gz"
    "https://raw.githubusercontent.com/matthuisman/i.mjh.nz/master/SamsungTVPlus/all.xml.gz"
    "https://raw.githubusercontent.com/matthuisman/i.mjh.nz/master/PlutoTV/all.xml.gz"
    "https://i.mjh.nz/generate?site=abc.net.au&region=syd"
)

for url in "${URLS[@]}"; do
    echo "[DEBUG] Testing: $url"
    if curl -fsSL --head "$url" >/dev/null 2>&1; then
        echo "[OK] URL accessible: $url"
        # Test actual download and decompression for .gz files
        if [[ "$url" == *.gz ]]; then
            echo "[DEBUG] Testing download/decompression..."
            if curl -fsSL "$url" | gzip -dc | head -5 >/dev/null 2>&1; then
                echo "[OK] Successfully downloaded and decompressed"
            else
                echo "[ERROR] Failed to download/decompress"
            fi
        fi
    else
        echo "[ERROR] URL failed: $url"
    fi
    echo "---"
done

echo "[DEBUG] Testing US PlutoTV for comparison..."
curl -fsSL "https://raw.githubusercontent.com/matthuisman/i.mjh.nz/master/PlutoTV/us.xml.gz" | gzip -dc | head -20 || echo "[ERROR] Failed to download/decompress US PlutoTV"

echo "[DEBUG] Done"
