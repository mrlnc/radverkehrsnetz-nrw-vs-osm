#!/usr/bin/env bash
# Check whether newer source data is available, without downloading anything.
# Run from the repo root. Prompts to start the download pipeline if updates exist.
set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

NRW_META="data/.nrw_meta"
OSM_META="data/.osm_meta"

UPDATES_AVAILABLE=()

# ── Helpers ───────────────────────────────────────────────────────────────────

# Fetch Last-Modified header for a URL (follows redirects, no download).
remote_last_modified() {
    curl -sIL --connect-timeout 10 --max-time 20 "$1" \
        | grep -i '^last-modified:' | tail -1 \
        | sed 's/^[Ll]ast-[Mm]odified: *//' | tr -d '\r'
}

# Convert an HTTP date or ISO 8601 date to a unix timestamp.
to_ts() {
    date -d "$1" +%s 2>/dev/null || echo 0
}

# Read a value from a key="value" meta file.
read_meta() {
    local file="$1" key="$2"
    grep "^${key}=" "$file" 2>/dev/null | head -1 | sed 's/^[^=]*="\(.*\)"/\1/'
}

# Check one source. Prints a status line and appends to UPDATES_AVAILABLE if stale.
# Usage: check_source <label> <url> <stored_date_iso_or_http>
check_source() {
    local label="$1" url="$2" stored="$3"

    printf "  %-40s " "$label"

    local remote_lm
    remote_lm=$(remote_last_modified "$url")

    if [ -z "$remote_lm" ]; then
        echo "(no Last-Modified header — cannot check)"
        return
    fi

    local remote_ts stored_ts
    remote_ts=$(to_ts "$remote_lm")

    if [ -z "$stored" ]; then
        echo -e "${YELLOW}unknown local date — assuming update needed${NC}"
        UPDATES_AVAILABLE+=("$label")
        return
    fi

    stored_ts=$(to_ts "$stored")

    if [ "$remote_ts" -gt "$stored_ts" ]; then
        local remote_fmt
        remote_fmt=$(date -d "$remote_lm" '+%Y-%m-%d %H:%M UTC' 2>/dev/null || echo "$remote_lm")
        echo -e "${YELLOW}update available  (server: ${remote_fmt})${NC}"
        UPDATES_AVAILABLE+=("$label")
    else
        local remote_fmt
        remote_fmt=$(date -d "$remote_lm" '+%Y-%m-%d' 2>/dev/null || echo "$remote_lm")
        echo -e "${GREEN}up to date        (server: ${remote_fmt})${NC}"
    fi
}

# ── Read stored metadata ──────────────────────────────────────────────────────

nrw_downloaded_at=""
radnetz_lm=""
knoten_lm=""
baustellen_lm=""
osm_downloaded_at=""

if [ -f "$NRW_META" ]; then
    nrw_downloaded_at=$(read_meta "$NRW_META" "NRW_DOWNLOADED_AT")
    radnetz_lm=$(read_meta       "$NRW_META" "RADNETZ_LAST_MODIFIED")
    knoten_lm=$(read_meta        "$NRW_META" "KNOTENPUNKT_LAST_MODIFIED")
    baustellen_lm=$(read_meta    "$NRW_META" "BAUSTELLEN_LAST_MODIFIED")
fi

if [ -f "$OSM_META" ]; then
    osm_downloaded_at=$(read_meta "$OSM_META" "OSM_DOWNLOADED_AT")
fi

# Fall back to download date when specific Last-Modified wasn't captured
[ -z "$radnetz_lm" ] && radnetz_lm="$nrw_downloaded_at"
[ -z "$knoten_lm"  ] && knoten_lm="$nrw_downloaded_at"

# ── Run checks ────────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}Checking for updates...${NC}"
echo ""

check_source \
    "radnetz_nw.gpkg (NRW)" \
    "https://www.radverkehrsnetz.nrw.de/downloads/radnetz_nw.gpkg" \
    "$radnetz_lm"

check_source \
    "knotenpunktnetz_nw.gpkg (NRW)" \
    "https://www.radverkehrsnetz.nrw.de/downloads/knotenpunktnetz_nw.gpkg" \
    "$knoten_lm"

check_source \
    "baustellen_nw.gpkg (NRW)" \
    "https://www.radverkehrsnetz.nrw.de/downloads/baustellen_nw.gpkg" \
    "$baustellen_lm"

check_source \
    "nordrhein-westfalen.osm.pbf (Geofabrik)" \
    "https://download.geofabrik.de/europe/germany/nordrhein-westfalen-latest.osm.pbf" \
    "$osm_downloaded_at"

echo ""

# ── Prompt ────────────────────────────────────────────────────────────────────

if [ "${#UPDATES_AVAILABLE[@]}" -eq 0 ]; then
    echo -e "${GREEN}All sources are up to date.${NC}"
    echo ""
    exit 0
fi

echo -e "${YELLOW}Updates available for: ${UPDATES_AVAILABLE[*]}${NC}"
echo ""

# Non-interactive (e.g. cron): just report, don't prompt
if [ ! -t 0 ]; then
    exit 1
fi

printf "Run the download pipeline now? [y/N] "
read -r answer
echo ""

if [[ "$answer" =~ ^[Yy]$ ]]; then
    echo -e "${CYAN}Starting data pipeline...${NC}"
    docker compose -f docker-compose.dataprocessing.yml run --rm dataprocessor \
        sh -c "./download-osm.sh && ./download-radwege-nrw.sh"
    echo ""
    echo -e "${CYAN}Restarting tileserver and clearing tile cache...${NC}"
    docker compose -f docker-compose.runtime.yml restart tileserver
    docker compose -f docker-compose.runtime.yml exec nginx \
        sh -c "rm -rf /var/cache/nginx/tileserver"
    docker compose -f docker-compose.runtime.yml restart nginx
    echo -e "${GREEN}Done.${NC}"
else
    echo "Skipped."
fi
