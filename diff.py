"""
Spatial diff: NRW official cycling network vs OSM RCN routes.

OSM is loaded lean (lines only, 8 props) to avoid the 1700-column DataFrame
explosion from its raw GeoJSON. Both datasets are then held in memory together
(~1 GB total) and diffed via STRtree — no global buffer union.

Outputs diff/network_diff.geojson with diff_type=nrw_only|osm_only.

Usage: python diff.py [--buffer-m N] [--netztyp TYPE]
"""

import argparse
import json
import time
from collections import defaultdict

import geopandas as gpd
import numpy as np
from shapely import STRtree, buffer, union_all
from shapely.geometry import shape

DEFAULT_NRW_FILE = "data/radnetz_nw.geojson"
DEFAULT_OSM_FILE = "data/radnetz_rcn_osm.geojson"
DEFAULT_OUT_FILE = "diff/network_diff.geojson"
CRS_METRIC = "EPSG:25832"
CRS_OUT    = "EPSG:4326"

OSM_KEEP_PROPS = {"highway", "name", "ref", "bicycle", "surface",
                  "cycleway", "cycleway:both", "oneway"}


def log(msg):
    print(msg, flush=True)


def elapsed(t0):
    return f"{time.time() - t0:.1f}s"


def load_nrw(path, netztyp_filter=None):
    t0 = time.time()
    log(f"Loading NRW ...")
    gdf = gpd.read_file(path).to_crs(CRS_METRIC)
    if netztyp_filter:
        gdf = gdf[gdf["netztyp"] == netztyp_filter].reset_index(drop=True)
    log(f"  {len(gdf)} features  [{elapsed(t0)}]")
    return gdf


def load_osm(path):
    """Lean loader: lines only, selected props — avoids 1700-column DataFrame."""
    t0 = time.time()
    log(f"Loading OSM (lean) ...")
    with open(path) as f:
        raw = json.load(f)
    rows = []
    for feat in raw["features"]:
        if feat["geometry"]["type"] not in ("LineString", "MultiLineString"):
            continue
        rows.append({
            "geometry": shape(feat["geometry"]),
            **{k: feat["properties"].get(k) for k in OSM_KEEP_PROPS},
        })
    gdf = gpd.GeoDataFrame(rows, crs="EPSG:4326").to_crs(CRS_METRIC)
    log(f"  {len(gdf)} features  [{elapsed(t0)}]")
    return gdf


def compute_diff(source, target_bufs, target_tree, diff_type, src_props):
    """
    For each source feature, subtract nearby target buffers.
    Returns GeoDataFrame of uncovered (or partially uncovered) source geometries.
    """
    t0 = time.time()
    log(f"Computing {diff_type} ({len(source)} source features) ...")

    src_geoms = source.geometry.values
    src_idx, tgt_idx = target_tree.query(src_geoms, predicate="intersects")

    hits = defaultdict(list)
    for si, ti in zip(src_idx.tolist(), tgt_idx.tolist()):
        hits[si].append(ti)

    results = []
    n = len(source)
    for i in range(n):
        if i % 50000 == 0 and i > 0:
            log(f"  {i:,}/{n:,} ...")
        geom = src_geoms[i]
        if i not in hits:
            diff_geom = geom
        else:
            diff_geom = geom.difference(union_all(target_bufs[hits[i]]))
        if not diff_geom.is_empty:
            row = source.iloc[i][src_props].to_dict()
            row["diff_type"] = diff_type
            row["geometry"]  = diff_geom
            results.append(row)

    if not results:
        log(f"  (none)  [{elapsed(t0)}]")
        return gpd.GeoDataFrame(columns=src_props + ["diff_type", "geometry"],
                                crs=CRS_METRIC)

    out = gpd.GeoDataFrame(results, crs=CRS_METRIC)
    km = out.geometry.length.sum() / 1000
    log(f"  {len(out)} segments, {km:,.0f} km  [{elapsed(t0)}]")
    return out


def build_index(gdf, buffer_m, label):
    t0 = time.time()
    log(f"Building {label} index (buffer={buffer_m}m) ...")
    bufs = buffer(gdf.geometry.values, buffer_m)
    tree = STRtree(bufs)
    log(f"  done  [{elapsed(t0)}]")
    return bufs, tree


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--buffer-m", type=float, default=25.0,
                        help="Match radius in metres (default: 25)")
    parser.add_argument("--netztyp", default=None,
                        help="Filter NRW by netztyp value")
    parser.add_argument("--nrw-file", default=DEFAULT_NRW_FILE)
    parser.add_argument("--osm-file", default=DEFAULT_OSM_FILE)
    parser.add_argument("--out-file", default=DEFAULT_OUT_FILE)
    args = parser.parse_args()

    log(f"=== NRW vs OSM diff  buffer={args.buffer_m}m ===")
    log(f"    NRW: {args.nrw_file}")
    log(f"    OSM: {args.osm_file}")
    t_total = time.time()

    osm = load_osm(args.osm_file)
    nrw = load_nrw(args.nrw_file, args.netztyp)

    nrw_props = [c for c in nrw.columns if c != "geometry"]
    osm_props = [c for c in osm.columns if c != "geometry"]
    log(f"NRW props: {nrw_props}")
    log(f"OSM props: {osm_props}")

    osm_bufs, osm_tree = build_index(osm, args.buffer_m, "OSM")
    nrw_only = compute_diff(nrw, osm_bufs, osm_tree, "nrw_only", nrw_props)
    del osm_bufs, osm_tree

    nrw_bufs, nrw_tree = build_index(nrw, args.buffer_m, "NRW")
    osm_only = compute_diff(osm, nrw_bufs, nrw_tree, "osm_only", osm_props)
    del nrw_bufs, nrw_tree

    log("Writing output ...")
    combined = gpd.GeoDataFrame(
        gpd.pd.concat([nrw_only, osm_only], ignore_index=True),
        crs=CRS_METRIC,
    ).to_crs(CRS_OUT)

    combined.to_file(args.out_file, driver="GeoJSON")

    n_nrw = (combined["diff_type"] == "nrw_only").sum()
    n_osm = (combined["diff_type"] == "osm_only").sum()
    log("")
    log("=== Summary ===")
    log(f"  NRW-only : {n_nrw:,} segments")
    log(f"  OSM-only : {n_osm:,} segments")
    log(f"  Output   : {args.out_file}")
    log(f"  Total    : {elapsed(t_total)}")


if __name__ == "__main__":
    main()
