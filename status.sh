#!/usr/bin/env bash
# Shows the current state of all downloaded data and tiles.
# Reads metadata written by the download scripts and does lightweight
# HEAD requests to check whether upstream sources have newer data.

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
    local size
    size=$(stat -c%s "$1" 2>/dev/null || stat -f%z "$1" 2>/dev/null || echo 0)
    echo "$(( size / 1048576 )) MB"
}

file_status() {
    local label="$1" file="$2"
    if [ -f "$file" ]; then
        ok "$label  $(mb "$file")"
    else
        missing "$label  (not found)"
    fi
}

# Fetch Last-Modified header without downloading the body.
server_last_modified() {
    curl -sIL --connect-timeout 10 --max-time 15 "$1" 2>/dev/null \
        | grep -i '^last-modified:' | tail -1 | tr -d '\r' \
        | sed 's/^[Ll]ast-[Mm]odified: *//'
}

# Compare two date strings (HTTP or ISO 8601). Prints "NEWER" or "current".
is_newer() {
    local remote="$1" local_date="$2"
    local remote_ts local_ts
    remote_ts=$(date -d "$remote"     +%s 2>/dev/null || echo 0)
    local_ts=$(date  -d "$local_date" +%s 2>/dev/null || echo 0)
    [ "$remote_ts" -gt "$local_ts" ] && echo "NEWER" || echo "current"
}

STALE=()   # collects which sources need updating

# Check one upstream source.
# Usage: check_freshness <label> <url> <local_date_iso>
check_freshness() {
    local label="$1" url="$2" local_date="$3"
    local server_lm result remote_fmt

    server_lm=$(server_last_modified "$url")

    if [ -z "$server_lm" ]; then
        info "$label — server not reachable, skipping"
        return
    fi

    remote_fmt=$(date -d "$server_lm" '+%Y-%m-%d' 2>/dev/null || echo "$server_lm")

    if [ -z "$local_date" ]; then
        warn "$label — no local date recorded, assuming stale (server: $remote_fmt)"
        STALE+=("$label")
        return
    fi

    result=$(is_newer "$server_lm" "$local_date")
    if [ "$result" = "NEWER" ]; then
        warn "$label — server has newer data ($remote_fmt)"
        STALE+=("$label")
    else
        info "$label — up to date (server: $remote_fmt)"
    fi
}

printf "${BOLD}=== Radverkehrsnetz NRW vs OSM — Data Status ===${NC}\n"

# ── OSM ──────────────────────────────────────────────────────────────────────
header "OSM  (Geofabrik NRW extract)"

OSM_META="$DATA/.osm_meta"
OSM_DOWNLOADED_AT=""; OSM_TIMESTAMP=""; OSM_PBF_SIZE=""; OSM_SERVER_LAST_MODIFIED=""
[ -f "$OSM_META" ] && source "$OSM_META"

PBF="$DATA/nordrhein-westfalen-latest.osm.pbf"
if [ -f "$PBF" ]; then
    ok "nordrhein-westfalen-latest.osm.pbf  $(mb "$PBF")"
    [ -n "$OSM_TIMESTAMP" ]     && info "OSM data as of   $OSM_TIMESTAMP"
    [ -n "$OSM_DOWNLOADED_AT" ] && info "Downloaded       $OSM_DOWNLOADED_AT"
else
    missing "nordrhein-westfalen-latest.osm.pbf"
fi

printf "\n  Tiles\n"
file_status "radnetz_rcn_osm.mbtiles    " "$TILES/radnetz_rcn_osm.mbtiles"
file_status "knotenpunktnetz_osm.mbtiles" "$TILES/knotenpunktnetz_osm.mbtiles"
file_status "knotenpunkte_osm.mbtiles   " "$TILES/knotenpunkte_osm.mbtiles"

# ── NRW ──────────────────────────────────────────────────────────────────────
header "NRW  (radverkehrsnetz.nrw.de)"

NRW_META="$DATA/.nrw_meta"
NRW_DOWNLOADED_AT=""; RADNETZ_LAST_MODIFIED=""; KNOTENPUNKT_LAST_MODIFIED=""; BAUSTELLEN_LAST_MODIFIED=""
[ -f "$NRW_META" ] && source "$NRW_META"

RADNETZ_FILE="$DATA/radnetz_nw.gpkg"
KNOTEN_FILE="$DATA/knotenpunktnetz_nw.gpkg"
BAUSTELLEN_FILE="$DATA/baustellen_nw.gpkg"

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

if [ -f "$BAUSTELLEN_FILE" ]; then
    ok "baustellen_nw.gpkg       $(mb "$BAUSTELLEN_FILE")"
    [ -n "$BAUSTELLEN_LAST_MODIFIED" ] && info "Server version   $BAUSTELLEN_LAST_MODIFIED"
else
    missing "baustellen_nw.gpkg"
fi

[ -n "$NRW_DOWNLOADED_AT" ] && info "Downloaded       $NRW_DOWNLOADED_AT"

printf "\n  Tiles\n"
file_status "radnetz_nw.mbtiles         " "$TILES/radnetz_nw.mbtiles"
file_status "knotenpunktnetz_nw.mbtiles " "$TILES/knotenpunktnetz_nw.mbtiles"
file_status "knotenpunkte_nw.mbtiles    " "$TILES/knotenpunkte_nw.mbtiles"
file_status "baustellen_nw.mbtiles      " "$TILES/baustellen_nw.mbtiles"

# ── Freshness checks (network) ────────────────────────────────────────────────
header "Update check"

# Use stored Last-Modified if available, otherwise fall back to download date
nrw_ref="${RADNETZ_LAST_MODIFIED:-$NRW_DOWNLOADED_AT}"
knoten_ref="${KNOTENPUNKT_LAST_MODIFIED:-$NRW_DOWNLOADED_AT}"
baustellen_ref="${BAUSTELLEN_LAST_MODIFIED:-$NRW_DOWNLOADED_AT}"

printf "  Checking upstream sources..."
osm_lm=$(server_last_modified \
    "https://download.geofabrik.de/europe/germany/nordrhein-westfalen-latest.osm.pbf")
radnetz_lm=$(server_last_modified \
    "https://www.radverkehrsnetz.nrw.de/downloads/radnetz_nw.gpkg")
knoten_lm=$(server_last_modified \
    "https://www.radverkehrsnetz.nrw.de/downloads/knotenpunktnetz_nw.gpkg")
baustellen_lm=$(server_last_modified \
    "https://www.radverkehrsnetz.nrw.de/downloads/baustellen_nw.gpkg")
printf "\r%40s\r" ""

# Evaluate each
_check() {
    local label="$1" server_lm="$2" local_date="$3"
    local remote_fmt result
    remote_fmt=$(date -d "$server_lm" '+%Y-%m-%d' 2>/dev/null || echo "$server_lm")
    if [ -z "$server_lm" ]; then
        info "$label — server not reachable"
        return
    fi
    if [ -z "$local_date" ]; then
        warn "$label — no local date recorded, run the pipeline"
        STALE+=("$label"); return
    fi
    result=$(is_newer "$server_lm" "$local_date")
    if [ "$result" = "NEWER" ]; then
        warn "$label — update available ($remote_fmt)"
        STALE+=("$label")
    else
        info "$label — up to date ($remote_fmt)"
    fi
}

_check "nordrhein-westfalen.osm.pbf" "$osm_lm"       "${OSM_SERVER_LAST_MODIFIED:-$OSM_DOWNLOADED_AT}"
_check "radnetz_nw.gpkg"             "$radnetz_lm"   "$nrw_ref"
_check "knotenpunktnetz_nw.gpkg"     "$knoten_lm"    "$knoten_ref"
_check "baustellen_nw.gpkg"          "$baustellen_lm" "$baustellen_ref"

# ── Summary ───────────────────────────────────────────────────────────────────
printf "\n"

MISSING_COUNT=0
for f in \
    "$DATA/nordrhein-westfalen-latest.osm.pbf" \
    "$DATA/radnetz_nw.gpkg" \
    "$DATA/knotenpunktnetz_nw.gpkg" \
    "$TILES/radnetz_rcn_osm.mbtiles" \
    "$TILES/knotenpunktnetz_osm.mbtiles" \
    "$TILES/knotenpunkte_osm.mbtiles" \
    "$TILES/radnetz_nw.mbtiles" \
    "$TILES/knotenpunktnetz_nw.mbtiles" \
    "$TILES/knotenpunkte_nw.mbtiles" \
    "$TILES/baustellen_nw.mbtiles"; do
    [ -f "$f" ] || MISSING_COUNT=$(( MISSING_COUNT + 1 ))
done

if [ "$MISSING_COUNT" -gt 0 ]; then
    printf "${RED}${BOLD}$MISSING_COUNT file(s) missing.${NC}\n\n"
fi

if [ "${#STALE[@]}" -gt 0 ] || [ "$MISSING_COUNT" -gt 0 ]; then
    printf "${YELLOW}${BOLD}Updates available. Run the download pipeline to refresh.${NC}\n\n"
else
    printf "${GREEN}${BOLD}All data present and up to date.${NC}\n\n"
fi
