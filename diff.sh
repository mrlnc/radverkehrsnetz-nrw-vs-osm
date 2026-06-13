#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${CYAN}▶ $*${NC}" >&2; }
log_ok()    { echo -e "${GREEN}✅ $*${NC}" >&2; }
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

log_info "Computing Knotenpunktnetz diff (NRW vs OSM)..."
mkdir -p diff

run python3 /app/diff.py \
    --nrw-file data/knotenpunktnetz_nw.geojson \
    --osm-file data/knotenpunktnetz_osm.geojson \
    --out-file diff/network_diff.geojson

run tippecanoe \
    --maximum-zoom=14 --minimum-zoom=7 \
    --no-feature-limit --no-tile-size-limit \
    --no-line-simplification --drop-rate=0 \
    --force -l network_diff \
    --output=tiles/network_diff.mbtiles \
    diff/network_diff.geojson

log_ok "Diff complete: diff/network_diff.geojson + tiles/network_diff.mbtiles"
