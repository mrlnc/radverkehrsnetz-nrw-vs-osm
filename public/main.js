const contextMenu = document.getElementById('context-menu');
const osmLink = document.getElementById('osmLink');
const mapillaryLink = document.getElementById('mapillaryLink');

const targetLayers = {
    baustellen_nw: {
        color: '#EBCB8B', kind: 'point', source: 'nrw',
        label: 'Baustellen'
    },
    knotenpunktnetz_nw: {
        color: '#BF616A', kind: 'line', source: 'nrw',
        label: 'Knotenpunktnetz'
    },
    knotenpunkte_nw: {
        color: '#D08770', kind: 'point', source: 'nrw',
        label: 'Knotenpunkte'
    },
    radnetz_nw: {
        color: '#BF616A', kind: 'line', source: 'nrw',
        label: 'Radnetz (gesamt)'
    },
    radnetz_nw_netztyp_radverkehrsnetz_nrw: {
        color: '#BF616A', kind: 'line', source: 'nrw',
        label: 'Radnetz (RVN NRW)'
    },
    radnetz_nw_netztyp_lokal: {
        color: '#BF616A', kind: 'line', source: 'nrw',
        label: 'Radnetz (Lokal)'
    },
    radnetz_nw_netztyp_themenroute: {
        color: '#BF616A', kind: 'line', source: 'nrw',
        label: 'Radnetz (Themenroute)'
    },
    radnetz_nw_netztyp_themenroute_auf_radverkehrsnetz_nrw: {
        color: '#BF616A', kind: 'line', source: 'nrw',
        label: 'Radnetz (Themenroute auf RVN)'
    },
    radnetz_rcn_osm: {
        color: '#88C0D0', kind: 'line', source: 'osm',
        label: 'Radrouten (RCN)'
    },
    knotenpunkte_osm: {
        color: '#81A1C1', kind: 'point', source: 'osm',
        label: 'Knotenpunkte'
    },
    knotenpunktnetz_osm: {
        color: '#5E81AC', kind: 'line', source: 'osm',
        label: 'Knotenpunktnetz'
    }
};

const defaultLat = 51.2277;
const defaultLng = 6.7735;
const defaultZoom = 12;
const defaultActiveLayers = ['baustellen_nw', 'knotenpunktnetz_nw', 'knotenpunktnetz_osm'];

var lat = defaultLat;
var lng = defaultLng;
var zoom = defaultZoom;
var initialActiveLayers = defaultActiveLayers;

// ── Drag and drop ─────────────────────────────────────────────────────────────

let dragSrc = null;
let mapInstance = null;

function createLayerItem(layerId) {
    const { color, kind, label, source } = targetLayers[layerId];
    const li = document.createElement('li');
    li.dataset.layerId = layerId;
    li.draggable = true;
    li.className = 'flex items-center gap-2 px-2 py-1.5 text-sm bg-gray-100 rounded cursor-grab select-none';

    // Fixed-width symbol column so dots and lines stay aligned
    const symbolWrap = document.createElement('span');
    symbolWrap.style.cssText = 'flex-shrink:0;width:1.25rem;display:flex;align-items:center;justify-content:center;';
    const swatch = document.createElement('span');
    if (kind === 'line') {
        swatch.style.cssText = `display:block;width:1.25rem;height:3px;border-radius:9999px;background:${color}`;
    } else {
        swatch.style.cssText = `display:block;width:8px;height:8px;border-radius:9999px;background:${color}`;
    }
    symbolWrap.appendChild(swatch);

    const labelSpan = document.createElement('span');
    labelSpan.className = 'flex-1 truncate';
    labelSpan.textContent = label;

    const badge = document.createElement('span');
    badge.textContent = source === 'nrw' ? 'NRW' : 'OSM';
    badge.style.cssText = source === 'nrw'
        ? 'flex-shrink:0;font-size:0.6rem;font-weight:600;padding:1px 5px;border-radius:3px;background:#fef3c7;color:#92400e;'
        : 'flex-shrink:0;font-size:0.6rem;font-weight:600;padding:1px 5px;border-radius:3px;background:#dbeafe;color:#1e40af;';

    li.append(symbolWrap, labelSpan, badge);

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
        el.style.borderTop = '';
        el.style.borderBottom = '';
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
                target.style.borderTop = '2px solid #60a5fa';
            } else {
                target.style.borderBottom = '2px solid #60a5fa';
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

    const urlParams = new URLSearchParams(window.location.search);
    if (activeIds.length > 0) {
        urlParams.set('layers', activeIds.join(','));
    } else {
        urlParams.delete('layers');
    }
    window.history.replaceState({}, '', `?${urlParams.toString()}`);
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

    syncMapLayers(map);
}

// ── Map setup ─────────────────────────────────────────────────────────────────

function setupMap(lat, lng, zoom) {
    const map = new maplibregl.Map({
        container: 'map',
        style: 'style.json',
        center: [lng, lat],
        zoom: zoom
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
        osmLink.href = osmUrl;
        mapillaryLink.href = mapillaryUrl;

        contextMenu.innerHTML = `<a href="${osmUrl}" target="_blank">Open in OSM</a><br><a href="${mapillaryUrl}" target="_blank">Open in Mapillary</a>`;
        contextMenu.style.left = `${e.point.x}px`;
        contextMenu.style.top = `${e.point.y}px`;
        contextMenu.classList.remove('hidden');
    });

    map.on('load', () => {
        initLayerPanel(map);
        document.getElementById('map').classList.remove('hidden');
        map.resize();
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
            el.textContent = 'Stand: ' + parts.join(' · ');
            el.classList.remove('hidden');
        }
    }).catch(() => {});
});

document.getElementById('startBtn').addEventListener('click', function () {
    document.getElementById('disclaimer').classList.add('hidden');
    document.getElementById('layerPanel').classList.remove('hidden');
    setupMap(lat, lng, zoom);
});
