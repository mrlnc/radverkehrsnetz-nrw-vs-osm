#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${CYAN}▶ $*${NC}" >&2; }
log_ok()    { echo -e "${GREEN}✅ $*${NC}" >&2; }
log_warn()  { echo -e "${YELLOW}⚠  $*${NC}" >&2; }
log_error() { echo -e "${RED}❌ $*${NC}" >&2; }

run() {
    log_info "Running: $*"
    "$@"
    local status=$?
    if [ $status -ne 0 ]; then
        log_error "Command failed (exit $status): $*"
        exit $status
    fi
}

# Show an animated countdown progress bar, then clear the line.
# Usage: sleep_with_progress <seconds>
sleep_with_progress() {
    local total="$1"
    local width=40
    local elapsed=0
    while [ "$elapsed" -lt "$total" ]; do
        local filled=$(( elapsed * width / total ))
        local bar
        bar="$(printf '%*s' "$filled" '' | tr ' ' '#')$(printf '%*s' $(( width - filled )) '')"
        printf "\r  ${YELLOW}⏳ Retrying in %3ds  [%s]${NC}" \
            "$(( total - elapsed ))" "$bar" >&2
        sleep 1
        elapsed=$(( elapsed + 1 ))
    done
    printf "\r%70s\r" "" >&2
}

# Validate that a downloaded file is a real GPKG (SQLite database), not an error page.
validate_gpkg() {
    local file="$1"

    if [ ! -f "$file" ]; then
        return 1
    fi

    local size
    size=$(stat -c%s "$file" 2>/dev/null || stat -f%z "$file")
    if [ "$size" -lt 10000 ]; then
        log_error "File $file is suspiciously small ($size bytes) — likely an error response:"
        cat "$file" >&2 2>/dev/null || true
        return 1
    fi

    if head -c 200 "$file" | grep -qi '<html'; then
        log_error "Server returned an HTML error page instead of $file:"
        head -c 500 "$file" >&2
        return 1
    fi

    if ! ogrinfo "$file" >/dev/null 2>&1; then
        log_error "File $file is not a valid GPKG (ogrinfo rejected it):"
        head -c 500 "$file" >&2
        return 1
    fi

    return 0
}

# Last-Modified header captured from the most recent successful download.
_LAST_MODIFIED=""

# Download a file with retry and exponential backoff.
# Sets _LAST_MODIFIED to the server's Last-Modified header on success.
# Usage: download_with_retry <url> <output_file>
download_with_retry() {
    local url="$1"
    local output="$2"
    local max_retries=5
    local attempt=1
    local delay=15
    _LAST_MODIFIED=""

    while [ "$attempt" -le "$max_retries" ]; do
        log_info "Downloading $url → $output (attempt $attempt/$max_retries)..."

        local header_file
        header_file=$(mktemp)

        local http_code
        http_code=$(curl --progress-bar --location \
            --connect-timeout 30 --max-time 300 \
            --write-out "%{http_code}" \
            --dump-header "$header_file" \
            -o "$output" "$url" 2>/dev/tty || echo "000")

        case "$http_code" in
            200)
                if validate_gpkg "$output"; then
                    _LAST_MODIFIED=$(grep -i '^last-modified:' "$header_file" \
                        | tail -1 | tr -d '\r' | sed 's/^[Ll]ast-[Mm]odified: *//')
                    rm -f "$header_file"
                    log_ok "Downloaded: $output ($(( $(stat -c%s "$output") / 1048576 )) MB)"
                    return 0
                fi
                log_warn "File validation failed. Retrying in ${delay}s..."
                ;;
            429|503)
                log_warn "Rate limited (HTTP $http_code). Retrying in ${delay}s..."
                ;;
            000)
                log_warn "Connection failed. Retrying in ${delay}s..."
                ;;
            *)
                log_warn "Unexpected HTTP $http_code. Retrying in ${delay}s..."
                ;;
        esac

        rm -f "$header_file" "$output"
        sleep_with_progress "$delay"
        delay=$((delay * 2))
        attempt=$((attempt + 1))
    done

    log_error "Failed to download a valid file from $url after $max_retries attempts"
    return 1
}

mkdir -p data tiles

META=data/.nrw_meta
DOWNLOADED=false
RADNETZ_LM=""
KNOTEN_LM=""

# radnetz_nw.gpkg
if validate_gpkg "data/radnetz_nw.gpkg" 2>/dev/null; then
    size_mb=$(( $(stat -c%s "data/radnetz_nw.gpkg") / 1048576 ))
    log_ok "radnetz_nw.gpkg already present (${size_mb} MB) — skipping download"
else
    download_with_retry \
        "https://www.radverkehrsnetz.nrw.de/downloads/radnetz_nw.gpkg" \
        "data/radnetz_nw.gpkg"
    RADNETZ_LM="$_LAST_MODIFIED"
    DOWNLOADED=true
fi

# knotenpunktnetz_nw.gpkg
if validate_gpkg "data/knotenpunktnetz_nw.gpkg" 2>/dev/null; then
    size_mb=$(( $(stat -c%s "data/knotenpunktnetz_nw.gpkg") / 1048576 ))
    log_ok "knotenpunktnetz_nw.gpkg already present (${size_mb} MB) — skipping download"
else
    download_with_retry \
        "https://www.radverkehrsnetz.nrw.de/downloads/knotenpunktnetz_nw.gpkg" \
        "data/knotenpunktnetz_nw.gpkg"
    KNOTEN_LM="$_LAST_MODIFIED"
    DOWNLOADED=true
fi

# Write/update metadata if any file was freshly downloaded, or if meta is missing
if [ "$DOWNLOADED" = true ] || [ ! -f "$META" ]; then
    log_info "Writing NRW metadata..."
    printf 'NRW_DOWNLOADED_AT="%s"\nRADNETZ_LAST_MODIFIED="%s"\nKNOTENPUNKT_LAST_MODIFIED="%s"\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${RADNETZ_LM:-}" "${KNOTEN_LM:-}" > "$META"
fi

# Convert GPKG layers to GeoJSON and build tiles (always regenerate — cheap local step)
run ogr2ogr -f GeoJSON -skipfailures data/radnetz_nw.geojson data/radnetz_nw.gpkg radnetz_nw
run tippecanoe --maximum-zoom=18 --no-feature-limit --no-tile-size-limit --coalesce-densest --force \
    -l radnetz_nw --output=tiles/radnetz_nw.mbtiles data/radnetz_nw.geojson

run ogr2ogr -f GeoJSON -skipfailures data/knotenpunktnetz_nw.geojson data/knotenpunktnetz_nw.gpkg knotenpunktnetz_nw
run ogr2ogr -f GeoJSON -skipfailures data/knotenpunkte_nw.geojson    data/knotenpunktnetz_nw.gpkg knotenpunkte_nw
run tippecanoe --maximum-zoom=18 --no-feature-limit --no-tile-size-limit --coalesce-densest --force \
    -l knotenpunktnetz_nw --output=tiles/knotenpunktnetz_nw.mbtiles data/knotenpunktnetz_nw.geojson
run tippecanoe --maximum-zoom=18 --minimum-zoom=0 --drop-rate=0 --no-line-simplification \
    --no-feature-limit --no-tile-size-limit --force \
    -l knotenpunkte_nw --output=tiles/knotenpunkte_nw.mbtiles data/knotenpunkte_nw.geojson

log_ok "All NRW steps completed successfully."
