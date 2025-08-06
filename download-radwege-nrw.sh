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

mkdir -p data tiles

# Download datasets
run curl --output-dir data -O https://www.radverkehrsnetz.nrw.de/downloads/knotenpunktnetz_nw.gpkg
run curl --output-dir data -O https://www.radverkehrsnetz.nrw.de/downloads/radnetz_nw.gpkg

# Convert GPKG to GeoJSON
run ogr2ogr -f GeoJSON -skipfailures data/knotenpunktnetz_nw.geojson data/knotenpunktnetz_nw.gpkg knotenpunktnetz_nw
run ogr2ogr -f GeoJSON -skipfailures data/knotenpunkte_nw.geojson data/knotenpunktnetz_nw.gpkg knotenpunkte_nw
run ogr2ogr -f GeoJSON -skipfailures data/radnetz_nw.geojson data/radnetz_nw.gpkg radnetz_nw

# Create MBTiles using Tippecanoe
run tippecanoe --maximum-zoom=18 --no-feature-limit --no-tile-size-limit --coalesce-densest --force -l knotenpunktnetz_nw --output=tiles/knotenpunktnetz_nw.mbtiles data/knotenpunktnetz_nw.geojson
run tippecanoe --maximum-zoom=18 --minimum-zoom=0 --drop-rate=0 --no-line-simplification --no-feature-limit --no-tile-size-limit --force -l knotenpunkte_nw --output=tiles/knotenpunkte_nw.mbtiles data/knotenpunkte_nw.geojson
run tippecanoe --maximum-zoom=18 --no-feature-limit --no-tile-size-limit --coalesce-densest --force -l radnetz_nw --output=tiles/radnetz_nw.mbtiles data/radnetz_nw.geojson

echo -e "${GREEN}✅ All steps completed successfully.${NC}"
