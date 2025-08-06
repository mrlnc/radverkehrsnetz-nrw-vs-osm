#!/usr/bin/env bash

# Define colors
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Function to run a command and check its status
run() {
    echo -e "${CYAN}▶ Running:${NC} $*" >&2
    "$@"
    local status=$?
    if [ $status -ne 0 ]; then
        echo -e "${RED}❌ Error:${NC} Command failed with exit code $status: $*" >&2
        exit $status
    fi
}

# Download dataset, all RCN routes in NRW
run curl -o /app/data/radnetz_rcn_osm.json -G "https://overpass-api.de/api/interpreter" --data-urlencode 'data=[out:json][timeout:180];area["ISO3166-2"="DE-NW"]->.nrw;(relation["network"="rcn"]["abandoned:route"!~"bicycle"](area.nrw);relation["network"="rcn"]["abandoned:route"!~"bicycle"](area.nrw););out body;>;out skel qt;'
# Convert GPKG to GeoJSON
osmtogeojson /app/data/radnetz_rcn_osm.json > /app/data/radnetz_rcn_osm.geojson
# Create MBTiles using Tippecanoe
run tippecanoe --maximum-zoom=18 --no-feature-limit --no-tile-size-limit --coalesce-densest --force -l radnetz_rcn_osm --output=/app/tiles/radnetz_rcn_osm.mbtiles data/radnetz_rcn_osm.geojson

# Download dataset, Knotenpunktnetz
run curl -o data/knotenpunktnetz_osm.json -G "https://overpass-api.de/api/interpreter" --data-urlencode 'data=[out:json][timeout:180];area["ISO3166-2"="DE-NW"]->.nrw;(relation["network"="rcn"]["abandoned:route"!~"bicycle"]["network:type"="node_network"](area.nrw);relation["network"="rcn"]["abandoned:route"!~"bicycle"]["network:type"="node_network"](area.nrw););out body;>;out skel qt;'
osmtogeojson /app/data/knotenpunktnetz_osm.json > /app/data/knotenpunktnetz_osm.geojson
run tippecanoe --maximum-zoom=18 --no-feature-limit --no-tile-size-limit --coalesce-densest --force -l knotenpunktnetz_osm --output=/app/tiles/knotenpunktnetz_osm.mbtiles data/knotenpunktnetz_osm.geojson

# Download dataset, Knotenpunkte
run curl -o data/knotenpunkte_osm.json -G "https://overpass-api.de/api/interpreter" --data-urlencode 'data=[out:json][timeout:180];area["ISO3166-2"="DE-NW"]->.nrw;(node["network:type"="node_network"](area.nrw););out body;>;out skel qt;'
osmtogeojson /app/data/knotenpunkte_osm.json > /app/data/knotenpunkte_osm.geojson
run tippecanoe --maximum-zoom=18  --minimum-zoom=0 --drop-rate=0 --no-line-simplification --no-feature-limit --no-tile-size-limit --force -l knotenpunkte_osm --output=/app/tiles/knotenpunkte_osm.mbtiles data/knotenpunkte_osm.geojson

echo -e "${GREEN}✅ All steps completed successfully.${NC}" >&2