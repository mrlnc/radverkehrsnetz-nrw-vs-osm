#!/usr/bin/env bash
# Shows the current state of all downloaded data and tiles.
# Reads metadata written by the download scripts and does lightweight
# HEAD requests to check whether the NRW server has newer data.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA="$SCRIPT_DIR/data"
TILES="$SCRIPT_DIR/tiles"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

ok()      { printf "  ${GREEN}✅${NC}  $*\n"; }
missing() { printf "  ${RED}❌${NC}  $*\n"; }
warn()    { printf "  ${YELLOW}⚠ ${NC}  $*\n"; }
info()    { printf "      ${CYAN}$*${NC}\n"; }
header()  { printf "\n${BOLD}$*${NC}\n"; }

mb() {
    local file="$1"
    local size
    size=$(stat -c%s "$file" 2>/dev/null || stat -f%z "$file" 2>/dev/null || echo 0)
    echo "$(( size / 1048576 )) MB"
}

file_status() {
    local label="$1"
    local file="$2"
    if [ -f "$file" ]; then
        ok "$label  $(mb "$file")"
    else
        missing "$label  (not found)"
    fi
}

# Fetch the Last-Modified header from a URL without downloading the body.
server_last_modified() {
    local url="$1"
    curl -sI --connect-timeout 10 --max-time 15 "$url" 2>/dev/null \
        | grep -i '^last-modified:' | tail -1 | tr -d '\r' | sed 's/^[Ll]ast-[Mm]odified: *//'
}

# Compare server Last-Modified to local file mtime.
# Prints "NEWER", "current", or "unknown".
freshness() {
    local server_lm="$1"
    local local_file="$2"
    if [ -z "$server_lm" ]; then
        echo "unknown"
        return
    fi
    local server_epoch local_epoch
    server_epoch=$(date -d "$server_lm" +%s 2>/dev/null || echo 0)
    local_epoch=$(stat -c%Y "$local_file" 2>/dev/null || echo 0)
    if [ "$server_epoch" -gt "$local_epoch" ]; then
        echo "NEWER"
    else
        echo "current"
    fi
}

printf "${BOLD}=== Radverkehrsnetz NRW vs OSM — Data Status ===${NC}\n"

# ── OSM ──────────────────────────────────────────────────────────────────────
header "OSM  (Geofabrik NRW extract)"

OSM_META="$DATA/.osm_meta"
OSM_DOWNLOADED_AT=""
OSM_TIMESTAMP=""
OSM_PBF_SIZE=""
if [ -f "$OSM_META" ]; then
    # shellcheck source=/dev/null
    source "$OSM_META"
fi

PBF="$DATA/nordrhein-westfalen-latest.osm.pbf"
if [ -f "$PBF" ]; then
    ok "nordrhein-westfalen-latest.osm.pbf  $(mb "$PBF")"
    [ -n "$OSM_TIMESTAMP" ]    && info "OSM data as of   $OSM_TIMESTAMP"
    [ -n "$OSM_DOWNLOADED_AT" ] && info "Downloaded       $OSM_DOWNLOADED_AT"
else
    missing "nordrhein-westfalen-latest.osm.pbf"
    info "Run: docker compose -f docker-compose.dataprocessing.yml up"
fi

printf "\n  Tiles\n"
file_status "radnetz_rcn_osm.mbtiles    " "$TILES/radnetz_rcn_osm.mbtiles"
file_status "knotenpunktnetz_osm.mbtiles" "$TILES/knotenpunktnetz_osm.mbtiles"
file_status "knotenpunkte_osm.mbtiles   " "$TILES/knotenpunkte_osm.mbtiles"

# ── NRW ──────────────────────────────────────────────────────────────────────
header "NRW  (radverkehrsnetz.nrw.de)"

NRW_META="$DATA/.nrw_meta"
NRW_DOWNLOADED_AT=""
RADNETZ_LAST_MODIFIED=""
KNOTENPUNKT_LAST_MODIFIED=""
if [ -f "$NRW_META" ]; then
    # shellcheck source=/dev/null
    source "$NRW_META"
fi

RADNETZ_URL="https://www.radverkehrsnetz.nrw.de/downloads/radnetz_nw.gpkg"
KNOTEN_URL="https://www.radverkehrsnetz.nrw.de/downloads/knotenpunktnetz_nw.gpkg"

RADNETZ_FILE="$DATA/radnetz_nw.gpkg"
KNOTEN_FILE="$DATA/knotenpunktnetz_nw.gpkg"

if [ -f "$RADNETZ_FILE" ]; then
    ok "radnetz_nw.gpkg          $(mb "$RADNETZ_FILE")"
    [ -n "$RADNETZ_LAST_MODIFIED" ] && info "Server version   $RADNETZ_LAST_MODIFIED"
else
    missing "radnetz_nw.gpkg"
fi

if [ -f "$KNOTEN_FILE" ]; then
    ok "knotenpunktnetz_nw.gpkg  $(mb "$KNOTEN_FILE")"
    [ -n "$KNOTENPUNKT_LAST_MODIFIED" ] && info "Server version   $KNOTENPUNKT_LAST_MODIFIED"
else
    missing "knotenpunktnetz_nw.gpkg"
fi

[ -n "$NRW_DOWNLOADED_AT" ] && info "Downloaded       $NRW_DOWNLOADED_AT"

# Check if the server has newer NRW data (requires network access)
if [ -f "$RADNETZ_FILE" ] || [ -f "$KNOTEN_FILE" ]; then
    printf "\n  Checking server for updates..."
    SERVER_LM=$(server_last_modified "$RADNETZ_URL")
    printf "\r%40s\r" ""

    if [ -n "$SERVER_LM" ] && [ -f "$RADNETZ_FILE" ]; then
        case "$(freshness "$SERVER_LM" "$RADNETZ_FILE")" in
            NEWER)   warn "Server has a newer version ($SERVER_LM) — re-run download-radwege-nrw.sh" ;;
            current) info "Server version matches local file" ;;
            *)       info "Could not determine server version" ;;
        esac
    elif [ -z "$SERVER_LM" ]; then
        info "Server not reachable — skipping freshness check"
    fi
fi

printf "\n  Tiles\n"
file_status "radnetz_nw.mbtiles         " "$TILES/radnetz_nw.mbtiles"
file_status "knotenpunktnetz_nw.mbtiles " "$TILES/knotenpunktnetz_nw.mbtiles"
file_status "knotenpunkte_nw.mbtiles    " "$TILES/knotenpunkte_nw.mbtiles"

# ── Summary ───────────────────────────────────────────────────────────────────
printf "\n"

MISSING=0
for f in \
    "$DATA/nordrhein-westfalen-latest.osm.pbf" \
    "$DATA/radnetz_nw.gpkg" \
    "$DATA/knotenpunktnetz_nw.gpkg" \
    "$TILES/radnetz_rcn_osm.mbtiles" \
    "$TILES/knotenpunktnetz_osm.mbtiles" \
    "$TILES/knotenpunkte_osm.mbtiles" \
    "$TILES/radnetz_nw.mbtiles" \
    "$TILES/knotenpunktnetz_nw.mbtiles" \
    "$TILES/knotenpunkte_nw.mbtiles"; do
    [ -f "$f" ] || MISSING=$(( MISSING + 1 ))
done

if [ "$MISSING" -eq 0 ]; then
    printf "${GREEN}${BOLD}All data present.${NC}\n\n"
else
    printf "${YELLOW}${BOLD}$MISSING file(s) missing.${NC}  Run: docker compose -f docker-compose.dataprocessing.yml up\n\n"
fi
