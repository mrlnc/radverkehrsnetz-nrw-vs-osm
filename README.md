![Screenshot of the app](image.png)

> [!CAUTION]
> This project is mostly about me trying out Claude Code and similar tools.

Compare the official NRW cycling network (Radverkehrsnetz NRW) against OpenStreetMap data. Highlights paths present in the NRW dataset but missing or incomplete in OSM.

---

## Requirements

- Docker and Docker Compose
- ~4 GB free disk space (downloads + tiles + nginx cache)

---

## Setup

### 1. Add local DNS entry

Add to `/etc/hosts` (Linux/macOS) or `C:\Windows\System32\drivers\etc\hosts` (Windows):

```
127.0.0.1  osm.app.internal
```

### 2. Download and process data

```bash
docker compose -f docker-compose.dataprocessing.yml run --rm dataprocessor \
  sh -c "./download-osm.sh && ./download-radwege-nrw.sh"
```

Downloads the NRW GPKG files and NRW OSM extract (~860 MB), then builds vector tiles. Files are skipped if the server has no newer version; tiles are always regenerated from whatever data is present.

### 3. Start the application

```bash
docker compose -f docker-compose.runtime.yml up -d
```

The app is then available at **http://osm.app.internal:8080**

---

## Operations

### Check data status

```bash
docker compose -f docker-compose.dataprocessing.yml run --rm dataprocessor ./status.sh
```

Shows which files are present, when they were downloaded, and whether the upstream sources have newer versions available.

### Update data

Re-run the download command from step 2. The scripts compare the server's `Last-Modified` header against what was last downloaded and only fetch what has changed.

To force a re-download regardless of version, delete the metadata file first:

```bash
rm data/.nrw_meta   # force re-download of NRW data
rm data/.osm_meta   # force re-download of OSM extract
```

After updating data, restart the tileserver and clear the tile cache:

```bash
docker compose -f docker-compose.runtime.yml restart tileserver
docker compose -f docker-compose.runtime.yml exec nginx sh -c "rm -rf /var/cache/nginx/tileserver"
docker compose -f docker-compose.runtime.yml restart nginx
```

---

## Architecture

| Component | Image | Role |
|---|---|---|
| `dataprocessor` | Ubuntu 24.04 + gdal/osmium/tippecanoe | Downloads data, converts GPKG/OSM → GeoJSON → MBTiles |
| `tileserver` | maptiler/tileserver-gl | Serves vector tiles from MBTiles files |
| `nginx` | nginx | Serves the frontend, proxies tile requests, caches tiles |

Tile requests go through nginx (`/tiles/` path), which proxies to the tileserver and caches responses on disk for up to a week.

### Data pipeline

**NRW official data:**
GPKG (EPSG:25832) → `ogr2ogr` (reproject to WGS84) → GeoJSON → `tippecanoe` → MBTiles

**OSM data:**
Geofabrik PBF → `osmium` (filter by tags) → PBF → `osmium export` → GeoJSON → `tippecanoe` → MBTiles

### Tile sources

| MBTiles file | Content |
|---|---|
| `radnetz_nw.mbtiles` | NRW cycling network lines |
| `knotenpunktnetz_nw.mbtiles` | NRW junction network lines |
| `knotenpunkte_nw.mbtiles` | NRW junction nodes |
| `baustellen_nw.mbtiles` | NRW roadworks (points) |
| `radnetz_rcn_osm.mbtiles` | OSM regional cycling routes |
| `r_radwege_nrw_osm.mbtiles` | OSM R-Radwege NRW routes |
| `knotenpunktnetz_osm.mbtiles` | OSM cycling junction network |
| `knotenpunkte_osm.mbtiles` | OSM cycling junction nodes |

---

## Frontend

Static files in `public/`. No build step — uses `@tailwindcss/browser` (bundled in `public/thirdparty/`) to process Tailwind classes at runtime. Custom styles are in `public/main.css`.

Map style is defined in `public/style.json`.

---

## Data sources and licenses

- **Radverkehrsnetz NRW**: [radverkehrsnetz.nrw.de](https://www.radverkehrsnetz.nrw.de) — [DL-DE→Zero-2.0](https://www.govdata.de/dl-de/zero-2-0)
- **OpenStreetMap**: [openstreetmap.org](https://www.openstreetmap.org) — [ODbL](https://www.openstreetmap.org/copyright)
- **Geofabrik NRW extract**: [download.geofabrik.de](https://download.geofabrik.de/europe/germany/nordrhein-westfalen.html)
