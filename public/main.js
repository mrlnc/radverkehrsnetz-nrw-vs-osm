const contextMenu = document.getElementById('context-menu');
const osmLink = document.getElementById('osmLink');
const mapillaryLink = document.getElementById('mapillaryLink');
const rvnLink = document.getElementById('rvnLink');

proj4.defs('EPSG:25832', '+proj=utm +zone=32 +ellps=GRS80 +units=m +no_defs');

const pmtilesProtocol = new pmtiles.Protocol();
maplibregl.addProtocol('pmtiles', pmtilesProtocol.tile);

const targetLayers = {
    baustellen_nw: {
        kind: 'point', source: 'nrw',
        label: 'Baustellen',
        description: 'Aktuelle Baustellen aus dem NRW-Radverkehrsnetz-Datensatz.'
    },
    knotenpunktnetz_nw: {
        kind: 'line', source: 'nrw',
        label: 'Knotenpunktnetz',
        description: 'Offizielle Verbindungslinien des nummerierten Knotenpunktnetzes NRW.'
    },
    knotenpunkte_nw: {
        kind: 'point', source: 'nrw',
        label: 'Knotenpunkte',
        description: 'Einzelne Knotenpunkte (Wegweiser-Standorte) des NRW-Netzes.'
    },
    radnetz_nw: {
        kind: 'line', source: 'nrw',
        label: 'Radnetz (gesamt)',
        description: 'Gesamtes Radverkehrsnetz NRW – alle Netztypen zusammen.'
    },
    radnetz_nw_netztyp_radverkehrsnetz_nrw: {
        kind: 'line', source: 'nrw',
        label: 'Radnetz (RVN NRW)',
        description: 'Nur Strecken des Typs „Radverkehrsnetz NRW" – das landesweite Hauptnetz.'
    },
    radnetz_nw_netztyp_lokal: {
        kind: 'line', source: 'nrw',
        label: 'Radnetz (Lokal)',
        description: 'Lokale Ergänzungsrouten aus dem NRW-Datensatz.'
    },
    radnetz_nw_netztyp_themenroute: {
        kind: 'line', source: 'nrw',
        label: 'Radnetz (Themenroute)',
        description: 'Thematische Routen (z.B. historische Pfade, Flussradwege).'
    },
    radnetz_nw_netztyp_themenroute_auf_radverkehrsnetz_nrw: {
        kind: 'line', source: 'nrw',
        label: 'Radnetz (Themenroute auf RVN)',
        description: 'Themenrouten, die gleichzeitig auf dem Hauptradverkehrsnetz verlaufen.'
    },
    radnetz_rcn_osm: {
        kind: 'line', source: 'osm',
        label: 'Radrouten (RCN)',
        description: 'Überregionale Radrouten (Regional Cycling Network) aus OSM.'
    },
    radnetz_lcn_osm: {
        kind: 'line', source: 'osm',
        label: 'Lokale Radrouten (LCN)',
        description: 'Lokale Radrouten (Local Cycling Network, network=lcn) aus OSM – Gegenstück zum „Lokalen Netz" im NRW-Datensatz.'
    },
    r_radwege_nrw_osm: {
        kind: 'line', source: 'osm',
        label: 'R-Radwege NRW',
        description: 'R-Radfernwege NRW wie sie in OSM erfasst sind (network=rcn, ref=R*).'
    },
    knotenpunkte_osm: {
        kind: 'point', source: 'osm',
        label: 'Knotenpunkte',
        description: 'Knotenpunkte in OSM (Nodes mit rcn_ref-Tag).'
    },
    knotenpunktnetz_osm: {
        kind: 'line', source: 'osm',
        label: 'Knotenpunktnetz',
        description: 'Knotenpunktnetz in OSM – Wege mit rcn_ref oder network=rcn.'
    },
    network_diff: {
        color: 'linear-gradient(to right,#BF616A 50%,#88C0D0 50%)', kind: 'line', source: 'diff',
        label: 'Knotenpunktnetz - Diff',
        description: '<span style="color:#f87171">■ Rot</span> Im NRW-Netz vorhanden, in OSM fehlend – potenzielle Lücke.<br><br><span style="color:#93c5fd">■ Blau</span> In OSM vorhanden, fehlt im NRW-Netz.<br><br>Abgleich mit 25&thinsp;m Puffer.'
    }
};

// Okabe–Ito palette: chosen for maximum mutual contrast (colorblind-safe),
// not per-layer identity. A layer's color isn't fixed in advance — it's
// handed out from this pool the moment the layer is activated (see
// syncMapLayers), so whatever combination gets toggled on always draws
// distinguishable colors, regardless of which combination that turns out
// to be. Once assigned, a color stays with its layer until deactivated —
// activating/deactivating or reordering OTHER layers never reassigns it.
// network_diff is excluded: it's already categorically colored by diff_type.
const COLOR_POOL = ['#E69F00', '#0072B2', '#009E73', '#D55E00', '#CC79A7', '#56B4E9', '#F0E442', '#000000'];
const INACTIVE_COLOR = '#D1D5DB'; // gray-300 — not yet assigned a slot
const DYNAMIC_COLOR_LAYERS = Object.keys(targetLayers).filter(id => id !== 'network_diff');
const activeColors = new Map(); // layerId -> assigned color, persists across syncs for stability

function paintPropForKind(kind) {
    return kind === 'line' ? 'line-color' : 'circle-color';
}

function setSwatchColor(layerId, color) {
    const li = document.querySelector(`li[data-layer-id="${layerId}"]`);
    const swatch = li?.querySelector('.layer-swatch');
    if (!swatch) return;
    swatch.style.backgroundImage = '';
    swatch.style.background = color;
    // Only active layers hold a color, so only those can be re-colored.
    const wrap = swatch.parentElement;
    wrap.style.cursor = color === INACTIVE_COLOR ? '' : 'pointer';
    wrap.title = color === INACTIVE_COLOR ? '' : 'Farbe wechseln';
}

// Jump to the next pool color, preferring one no other active layer uses,
// so a single click is enough to get something distinguishable.
function cycleLayerColor(layerId) {
    const current = activeColors.get(layerId);
    if (!current || !mapInstance) return;
    const usedByOthers = new Set([...activeColors].filter(([id]) => id !== layerId).map(([, c]) => c));
    const start = COLOR_POOL.indexOf(current);
    let next = COLOR_POOL[(start + 1) % COLOR_POOL.length];
    for (let i = 1; i <= COLOR_POOL.length; i++) {
        const candidate = COLOR_POOL[(start + i) % COLOR_POOL.length];
        if (!usedByOthers.has(candidate)) { next = candidate; break; }
    }
    activeColors.set(layerId, next);
    if (mapInstance.getLayer(layerId)) {
        mapInstance.setPaintProperty(layerId, paintPropForKind(targetLayers[layerId].kind), next);
    }
    setSwatchColor(layerId, next);
}

// Presets set up a specific comparison in one click: the layer array order
// is the stacking order (first = on top, see syncMapLayers), so putting
// layer A on top of layer B means "wherever A has no data, B shows through" —
// i.e. B's uncovered bits are exactly what's missing from A.
const presets = [
    {
        id: 'missing_in_osm',
        label: 'Lücken im OSM-Knotenpunktnetz',
        layers: ['knotenpunktnetz_osm', 'knotenpunktnetz_nw']
    },
    {
        id: 'missing_in_nrw',
        label: 'Lücken im NRW-Knotenpunktnetz',
        layers: ['knotenpunktnetz_nw', 'knotenpunktnetz_osm']
    },
    {
        id: 'missing_lokal_in_osm',
        label: 'Lücken im OSM-Lokalnetz',
        layers: ['radnetz_lcn_osm', 'radnetz_nw_netztyp_lokal']
    },
    {
        id: 'missing_lokal_in_nrw',
        label: 'Lücken im NRW-Lokalnetz',
        layers: ['radnetz_nw_netztyp_lokal', 'radnetz_lcn_osm']
    }
];

const defaultLat = 51.2277;
const defaultLng = 6.7735;
const defaultZoom = 12;
const defaultActiveLayers = ['baustellen_nw', 'knotenpunktnetz_nw', 'knotenpunktnetz_osm'];

var lat = defaultLat;
var lng = defaultLng;
var zoom = defaultZoom;
var initialActiveLayers = defaultActiveLayers;

// ── Layer tooltips ────────────────────────────────────────────────────────────

function showLayerTooltip(anchor, html) {
    const tooltip = document.getElementById('layerTooltip');
    tooltip.innerHTML = html;
    tooltip.style.visibility = 'hidden';
    tooltip.classList.remove('hidden');
    const rect = anchor.getBoundingClientRect();
    const panel = document.getElementById('layerPanel').getBoundingClientRect();
    const top = Math.min(rect.top, window.innerHeight - tooltip.offsetHeight - 8);
    tooltip.style.left = `${panel.right + 8}px`;
    tooltip.style.top = `${top}px`;
    tooltip.style.visibility = '';
}

function hideLayerTooltip() {
    document.getElementById('layerTooltip').classList.add('hidden');
}

// ── Drag and drop ─────────────────────────────────────────────────────────────

let dragSrc = null;
let mapInstance = null;

function createLayerItem(layerId) {
    const { color, kind, label, source, description } = targetLayers[layerId];
    // network_diff has a fixed gradient swatch (already categorically colored);
    // everything else starts neutral until it's activated and gets a pool slot.
    const initialColor = color || INACTIVE_COLOR;
    const li = document.createElement('li');
    li.dataset.layerId = layerId;
    li.draggable = true;
    li.className = 'flex items-center gap-2 px-2 py-1.5 text-sm bg-gray-100 rounded cursor-grab select-none';

    // Fixed-width symbol column so dots and lines stay aligned
    const symbolWrap = document.createElement('span');
    // align-self:stretch makes the whole row height clickable, not just the 3px swatch
    symbolWrap.style.cssText = 'flex-shrink:0;width:1.25rem;display:flex;align-items:center;justify-content:center;align-self:stretch;';
    symbolWrap.addEventListener('click', () => cycleLayerColor(layerId));
    const swatch = document.createElement('span');
    swatch.className = 'layer-swatch';
    if (kind === 'line') {
        swatch.style.cssText = `display:block;width:1.25rem;height:3px;border-radius:9999px;background:${initialColor.startsWith('linear') ? 'transparent' : initialColor}`;
        if (initialColor.startsWith('linear')) swatch.style.backgroundImage = initialColor;
    } else {
        swatch.style.cssText = `display:block;width:8px;height:8px;border-radius:9999px;background:${initialColor}`;
    }
    symbolWrap.appendChild(swatch);

    const labelSpan = document.createElement('span');
    labelSpan.className = 'flex-1 truncate';
    labelSpan.textContent = label;

    const badge = document.createElement('span');
    badge.textContent = source === 'nrw' ? 'NRW' : source === 'diff' ? 'DIFF' : 'OSM';
    badge.style.cssText = source === 'nrw'
        ? 'flex-shrink:0;font-size:0.6rem;font-weight:600;padding:1px 5px;border-radius:3px;background:#fef3c7;color:#92400e;'
        : source === 'diff'
        ? 'flex-shrink:0;font-size:0.6rem;font-weight:600;padding:1px 5px;border-radius:3px;background:#ede9fe;color:#5b21b6;'
        : 'flex-shrink:0;font-size:0.6rem;font-weight:600;padding:1px 5px;border-radius:3px;background:#dbeafe;color:#1e40af;';

    if (description) {
        const infoBtn = document.createElement('button');
        infoBtn.textContent = 'ⓘ';
        infoBtn.style.cssText = 'flex-shrink:0;font-size:0.7rem;color:#9ca3af;padding:0 1px;line-height:1;cursor:default;';
        infoBtn.addEventListener('mouseenter', () => showLayerTooltip(infoBtn, description));
        infoBtn.addEventListener('mouseleave', hideLayerTooltip);
        li.append(symbolWrap, labelSpan, infoBtn, badge);
    } else {
        li.append(symbolWrap, labelSpan, badge);
    }

    li.addEventListener('dragstart', e => {
        dragSrc = li;
        e.dataTransfer.effectAllowed = 'move';
        e.dataTransfer.setData('text/plain', layerId);
        requestAnimationFrame(() => li.classList.add('opacity-40'));
    });

    li.addEventListener('dragend', () => {
        li.classList.remove('opacity-40');
        clearDragIndicators();
        dragSrc = null;
    });

    return li;
}

function clearDragIndicators() {
    document.querySelectorAll('#activeLayers li, #availableLayers li').forEach(el => {
        el.classList.remove('drag-over-top', 'drag-over-bottom');
    });
}

function setupDropTarget(list) {
    list.addEventListener('dragover', e => {
        e.preventDefault();
        e.dataTransfer.dropEffect = 'move';
        clearDragIndicators();

        const target = e.target.closest('li[data-layer-id]');
        if (target && target !== dragSrc) {
            const rect = target.getBoundingClientRect();
            if (e.clientY < rect.top + rect.height / 2) {
                target.classList.add('drag-over-top');
            } else {
                target.classList.add('drag-over-bottom');
            }
        }
    });

    list.addEventListener('dragleave', e => {
        if (!list.contains(e.relatedTarget)) {
            clearDragIndicators();
        }
    });

    list.addEventListener('drop', e => {
        e.preventDefault();
        clearDragIndicators();
        if (!dragSrc) return;

        const target = e.target.closest('li[data-layer-id]');

        if (target && target !== dragSrc) {
            const rect = target.getBoundingClientRect();
            if (e.clientY < rect.top + rect.height / 2) {
                list.insertBefore(dragSrc, target);
            } else {
                list.insertBefore(dragSrc, target.nextSibling);
            }
        } else if (!list.contains(dragSrc)) {
            list.appendChild(dragSrc);
        }

        if (mapInstance) syncMapLayers(mapInstance);
    });
}

// Apply active layer list to the map and save to URL.
// First item in the list is rendered on top (like Photoshop layer order).
function syncMapLayers(map) {
    const activeIds = [...document.getElementById('activeLayers')
        .querySelectorAll('li[data-layer-id]')]
        .map(li => li.dataset.layerId);

    Object.keys(targetLayers).forEach(id => {
        if (map.getLayer(id)) map.setLayoutProperty(id, 'visibility', 'none');
    });

    // Iterate in reverse: last item moved to top last, so first item ends up on top.
    [...activeIds].reverse().forEach(id => {
        if (map.getLayer(id)) {
            map.setLayoutProperty(id, 'visibility', 'visible');
            map.moveLayer(id);
        }
    });

    // Dynamic color pool, but stable: a color is assigned once, when a layer
    // activates, and kept until it deactivates. Activating/deactivating or
    // reordering other layers never touches an already-assigned color.
    const activeSet = new Set(activeIds.filter(id => DYNAMIC_COLOR_LAYERS.includes(id)));

    [...activeColors.keys()].forEach(id => {
        if (!activeSet.has(id)) {
            activeColors.delete(id);
            setSwatchColor(id, INACTIVE_COLOR);
        }
    });

    activeSet.forEach(id => {
        if (activeColors.has(id)) return;
        const used = new Set(activeColors.values());
        const color = COLOR_POOL.find(c => !used.has(c)) || COLOR_POOL[activeColors.size % COLOR_POOL.length];
        activeColors.set(id, color);
    });

    activeSet.forEach(id => {
        const color = activeColors.get(id);
        if (map.getLayer(id)) map.setPaintProperty(id, paintPropForKind(targetLayers[id].kind), color);
        setSwatchColor(id, color);
    });

    const urlParams = new URLSearchParams(window.location.search);
    if (activeIds.length > 0) {
        urlParams.set('layers', activeIds.join(','));
    } else {
        urlParams.delete('layers');
    }
    window.history.replaceState({}, '', `?${urlParams.toString()}`);
}

// Replace the active layer set with a preset's layers, in the given order.
function applyPreset(map, layerIds) {
    const activeList = document.getElementById('activeLayers');
    const availableList = document.getElementById('availableLayers');
    const activeSet = new Set(layerIds);

    activeList.innerHTML = '';
    availableList.innerHTML = '';

    layerIds.forEach(id => {
        if (targetLayers[id]) activeList.appendChild(createLayerItem(id));
    });
    Object.keys(targetLayers).forEach(id => {
        if (!activeSet.has(id)) availableList.appendChild(createLayerItem(id));
    });

    syncMapLayers(map);
}

function initPresetButtons(map) {
    const container = document.getElementById('presetButtons');
    presets.forEach(preset => {
        const btn = document.createElement('button');
        btn.textContent = preset.label;
        btn.className = 'w-full text-left text-sm px-2 py-1.5 rounded-lg border border-[#5E81AC]/30 bg-[#5E81AC]/10 text-[#5E81AC] font-medium hover:bg-[#5E81AC] hover:text-white hover:border-[#5E81AC] transition-colors';
        btn.addEventListener('click', () => applyPreset(map, preset.layers));
        container.appendChild(btn);
    });
}

function initLayerPanel(map) {
    const activeList = document.getElementById('activeLayers');
    const availableList = document.getElementById('availableLayers');
    const activeSet = new Set(initialActiveLayers);

    initialActiveLayers.forEach(id => {
        if (targetLayers[id]) activeList.appendChild(createLayerItem(id));
    });

    Object.keys(targetLayers).forEach(id => {
        if (!activeSet.has(id)) availableList.appendChild(createLayerItem(id));
    });

    setupDropTarget(activeList);
    setupDropTarget(availableList);
    initPresetButtons(map);

    syncMapLayers(map);
}

// ── Map setup ─────────────────────────────────────────────────────────────────

function setupMap(lat, lng, zoom) {
    const map = new maplibregl.Map({
        container: 'map',
        style: 'style.json',
        center: [lng, lat],
        zoom: zoom,
        attributionControl: false // custom credit line in the bottom bar covers this
    });

    mapInstance = map;

    map.getCanvas().addEventListener('click', () => {
        contextMenu.classList.add('hidden');
    });

    map.on('contextmenu', (e) => {
        const { lng, lat } = e.lngLat;
        const zoom = (map.getZoom() + 2).toFixed(2);

        const osmUrl = `https://www.openstreetmap.org/#map=${zoom}/${lat}/${lng}`;
        const mapillaryUrl = `https://www.mapillary.com/app/?lat=${lat}&lng=${lng}&z=${zoom}`;
        const [rvnX, rvnY] = proj4('EPSG:4326', 'EPSG:25832', [lng, lat]).map(Math.round);
        const rvnUrl = `https://www.radroutenplaner.nrw.de/Link/rrpAufrufMarker.html?x=${rvnX}&y=${rvnY}`;
        osmLink.href = osmUrl;
        mapillaryLink.href = mapillaryUrl;
        rvnLink.href = rvnUrl;

        contextMenu.style.left = `${e.point.x}px`;
        contextMenu.style.top = `${e.point.y}px`;
        contextMenu.classList.remove('hidden');
    });

    let mapLoaded = false;

    map.on('load', () => {
        mapLoaded = true;
        initLayerPanel(map);
        document.getElementById('map').classList.remove('hidden');
        document.getElementById('mapLoading').classList.add('hidden');
        map.resize();
    });

    map.on('error', (e) => {
        console.error('MapLibre error:', e.error);
        if (!mapLoaded) {
            document.getElementById('mapLoadingSpinner').classList.add('hidden');
            document.getElementById('mapLoadingText').textContent = 'Karte konnte nicht geladen werden.';
        }
    });

    map.on('moveend', () => {
        const urlParams = new URLSearchParams(window.location.search);
        const center = map.getCenter();
        urlParams.set('lat', center.lat.toFixed(5));
        urlParams.set('lng', center.lng.toFixed(5));
        urlParams.set('zoom', map.getZoom().toFixed(2));
        window.history.replaceState({}, '', `?${urlParams.toString()}`);
    });
}

// ── Modals ────────────────────────────────────────────────────────────────────

function openModal(id) {
    document.getElementById(id).classList.remove('hidden');
}

function closeModal(id) {
    document.getElementById(id).classList.add('hidden');
}

function handleModalBackdropClick(e, id) {
    if (e.target === e.currentTarget) closeModal(id);
}

// ── Layer panel collapse ──────────────────────────────────────────────────────

document.getElementById('layerPanelHeader')?.addEventListener('click', () => {
    const body = document.getElementById('layerPanelBody');
    const chevron = document.getElementById('layerPanelChevron');
    const collapsed = body.classList.toggle('hidden');
    chevron.textContent = collapsed ? '▼' : '▲';
});

// ── Boot ──────────────────────────────────────────────────────────────────────

document.addEventListener('DOMContentLoaded', () => {
    const urlParams = new URLSearchParams(window.location.search);
    lat = parseFloat(urlParams.get('lat')) || defaultLat;
    lng = parseFloat(urlParams.get('lng')) || defaultLng;
    zoom = parseFloat(urlParams.get('zoom')) || defaultZoom;

    const layersParam = urlParams.get('layers');
    if (layersParam) {
        initialActiveLayers = layersParam.split(',').filter(id => targetLayers[id]);
    }

    fetch('meta.json').then(r => r.json()).then(meta => {
        const el = document.getElementById('dataTimestamp');
        const parts = [];
        if (meta.osm_timestamp) {
            const d = new Date(meta.osm_timestamp);
            parts.push('OSM: ' + d.toLocaleDateString('de-DE', { day: 'numeric', month: 'short', year: 'numeric' }));
        }
        if (meta.nrw_downloaded_at) {
            const d = new Date(meta.nrw_downloaded_at);
            parts.push('NRW: ' + d.toLocaleDateString('de-DE', { day: 'numeric', month: 'short', year: 'numeric' }));
        }
        if (parts.length > 0) {
            el.textContent = 'Stand der Karten · ' + parts.join(' · ');
            el.classList.remove('hidden');
        }
    }).catch(() => {});
});

document.getElementById('startBtn').addEventListener('click', function () {
    document.getElementById('disclaimer').classList.add('hidden');
    document.getElementById('layerPanel').classList.remove('hidden');
    document.getElementById('mapLoading').classList.remove('hidden');
    setupMap(lat, lng, zoom);
});
