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

# Validate that a file is a real OSM PBF, not an error page.
validate_osm_pbf() {
    local file="$1"
    local min_size=104857600  # 100 MB — NRW is ~400 MB

    if [ ! -f "$file" ]; then
        return 1
    fi

    local size
    size=$(stat -c%s "$file" 2>/dev/null || stat -f%z "$file")
    if [ "$size" -lt "$min_size" ]; then
        log_error "PBF file too small ($size bytes) — likely an error response:"
        head -c 500 "$file" >&2
        return 1
    fi

    if ! osmium fileinfo -e "$file" >/dev/null 2>&1; then
        log_error "File $file is not a valid OSM PBF (failed full scan)"
        return 1
    fi

    return 0
}

# Download a file with retry and exponential backoff.
# Usage: download_with_retry <url> <output_file> [validator_function]
download_with_retry() {
    local url="$1"
    local output="$2"
    local validator="${3:-}"
    local max_retries=5
    local attempt=1
    local delay=15

    while [ "$attempt" -le "$max_retries" ]; do
        log_info "Downloading $url → $output (attempt $attempt/$max_retries)..."

        local header_file
        header_file=$(mktemp)
        local http_code
        http_code=$(curl --progress-bar --location \
            --connect-timeout 30 --max-time 1800 \
            --write-out "%{http_code}" \
            --dump-header "$header_file" \
            -o "$output" "$url" 2>/dev/tty || echo "000")

        case "$http_code" in
            200)
                if [ -z "$validator" ] || "$validator" "$output"; then
                    _LAST_MODIFIED=$(grep -i '^last-modified:' "$header_file" \
                        | tail -1 | tr -d '\r' | sed 's/^[Ll]ast-[Mm]odified: *//')
                    rm -f "$header_file"
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

mkdir -p /app/data /app/tiles

PBF=/app/data/nordrhein-westfalen-latest.osm.pbf
META=/app/data/.osm_meta
_LAST_MODIFIED=""

# Load stored Last-Modified from previous run.
OSM_SERVER_LAST_MODIFIED=""
[ -f "$META" ] && source "$META"

# Fetch Last-Modified header without downloading the body.
head_last_modified() {
    curl -sIL --connect-timeout 10 --max-time 15 "$1" 2>/dev/null \
        | grep -i '^last-modified:' | tail -1 | tr -d '\r' \
        | sed 's/^[Ll]ast-[Mm]odified: *//'
}

# Returns 0 (needs download) if server version is newer than stored, 1 if up to date.
server_is_newer() {
    local server_lm="$1" stored="$2"
    [ -z "$server_lm" ] && return 1   # server unreachable — assume current, skip
    [ -z "$stored"    ] && return 0   # no stored date — always download
    local s l
    s=$(date -d "$server_lm" +%s 2>/dev/null || echo 0)
    l=$(date -d "$stored"    +%s 2>/dev/null || echo 0)
    [ "$s" -gt "$l" ]
}

# Download NRW extract from Geofabrik (~400 MB, updated daily)
_server_lm=$(head_last_modified \
    "https://download.geofabrik.de/europe/germany/nordrhein-westfalen-latest.osm.pbf")
if validate_osm_pbf "$PBF" && ! server_is_newer "$_server_lm" "$OSM_SERVER_LAST_MODIFIED"; then
    size_mb=$(( $(stat -c%s "$PBF") / 1048576 ))
    log_ok "PBF up to date (${size_mb} MB) — skipping download"
else
    download_with_retry \
        "https://download.geofabrik.de/europe/germany/nordrhein-westfalen-latest.osm.pbf" \
        "$PBF" \
        validate_osm_pbf
fi

# Write metadata after every run (updates OSM replication timestamp and server LM)
log_info "Writing OSM metadata..."
osm_ts=$(osmium fileinfo -g header.option.osmosis_replication_timestamp "$PBF" 2>/dev/null \
    | tr -d '[:space:]' || true)
pbf_size=$(stat -c%s "$PBF" 2>/dev/null || stat -f%z "$PBF")
printf 'OSM_DOWNLOADED_AT="%s"\nOSM_TIMESTAMP="%s"\nOSM_PBF_SIZE="%s"\nOSM_SERVER_LAST_MODIFIED="%s"\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${osm_ts:-unknown}" "$pbf_size" \
    "${_LAST_MODIFIED:-$OSM_SERVER_LAST_MODIFIED}" > "$META"

# Dataset: all RCN routes in NRW (always regenerate — cheap local step)
run osmium tags-filter "$PBF" r/network=rcn \
    -o /app/data/radnetz_rcn_osm.osm.pbf --overwrite
run osmium export /app/data/radnetz_rcn_osm.osm.pbf \
    -o /app/data/radnetz_rcn_osm.geojson --overwrite
run tippecanoe --maximum-zoom=18 --no-feature-limit --no-tile-size-limit --coalesce-densest --force \
    -l radnetz_rcn_osm --output=/app/tiles/radnetz_rcn_osm.mbtiles /app/data/radnetz_rcn_osm.geojson

# Dataset: Knotenpunktnetz — two-pass AND filter (network=rcn AND network:type=node_network)
run osmium tags-filter "$PBF" r/network=rcn \
    -o /app/data/tmp_rcn.osm.pbf --overwrite
run osmium tags-filter /app/data/tmp_rcn.osm.pbf r/network:type=node_network \
    -o /app/data/knotenpunktnetz_osm.osm.pbf --overwrite
rm -f /app/data/tmp_rcn.osm.pbf
run osmium export /app/data/knotenpunktnetz_osm.osm.pbf \
    -o /app/data/knotenpunktnetz_osm.geojson --overwrite
run tippecanoe --maximum-zoom=18 --no-feature-limit --no-tile-size-limit --coalesce-densest --force \
    -l knotenpunktnetz_osm --output=/app/tiles/knotenpunktnetz_osm.mbtiles /app/data/knotenpunktnetz_osm.geojson

# Dataset: Knotenpunkte (individual junction nodes)
run osmium tags-filter "$PBF" n/network:type=node_network \
    -o /app/data/knotenpunkte_osm.osm.pbf --overwrite
run osmium export /app/data/knotenpunkte_osm.osm.pbf \
    -o /app/data/knotenpunkte_osm.geojson --overwrite
run tippecanoe --maximum-zoom=18 --minimum-zoom=0 --drop-rate=0 --no-line-simplification \
    --no-feature-limit --no-tile-size-limit --force \
    -l knotenpunkte_osm --output=/app/tiles/knotenpunkte_osm.mbtiles /app/data/knotenpunkte_osm.geojson

log_ok "All OSM steps completed successfully."
