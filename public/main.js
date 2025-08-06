// first time working with JS+HTML, haven't read the "best practices" chapter yet :-)

// Context menu for OSM link
const contextMenu = document.getElementById('context-menu');
const osmLink = document.getElementById('osmLink');
const mapillaryLink = document.getElementById('mapillaryLink');

const targetLayers = {
    knotenpunktnetz_nw: {
        color: '#BF616A',
        kind: 'line',
        label: 'Knotenpunktnetz NRW'
    },
    knotenpunkte_nw: {
        color: '#B48EAD',
        kind: 'point',
        label: 'Knotenpunkte NRW'
    },
    radnetz_nw: {
        color: '#D08770',
        kind: 'line',
        label: 'Radnetz NRW'
    },
    radnetz_nw_netztyp_lokal: {
        color: '#D08770',
        kind: 'line',
        label: 'Radnetz NRW (Lokale Routen)'
    },
    radnetz_nw_netztyp_themenroute_auf_radverkehrsnetz_nrw: {
        color: '#D08770',
        kind: 'line',
        label: 'Radnetz NRW (Themenroute auf Radverkehrsnetz NRW)'
    },

    radnetz_nw_netztyp_themenroute: {
        color: '#D08770',
        kind: 'line',
        label: 'Radnetz NRW (Themenroute)'
    },
    radnetz_nw_netztyp_radverkehrsnetz_nrw: {
        color: '#D08770',
        kind: 'line',
        label: 'Radnetz NRW (Radverkehrsnetz NRW)'
    },
    radnetz_rcn_osm: {
        color: '#A3BE8C',
        kind: 'line',
        label: 'LCN/RCN von OSM'
    },
    knotenpunkte_osm: {
        color: '#5E81AC',
        kind: 'point',
        label: 'Knotenpunkte OSM'
    },
    knotenpunktnetz_osm: {
        color: '#5E81AC',
        kind: 'line',
        label: 'Knotenpunktnetz OSM'
    }
};

const presets = {
    gesamtnetz_vergleich: {
        layers: [
            'radnetz_nw',
            'radnetz_rcn_osm'
        ],
        label: 'Gesamtnetz'
    },
    gesamtnetz_vergleich_invers: {
        layers: [
            'radnetz_rcn_osm',
            'radnetz_nw'
        ],
        label: 'Gesamtnetz (umgedreht)'
    },
    gesamtnetz_vergleich_themenroute: {
        layers: [
            'radnetz_nw_themenroute',
            'radnetz_rcn_osm'
        ],
        label: 'Gesamtnetz Themenrouten NRW'
    },
    gesamtnetz_vergleich_themenroute_auf_radverkehrsnetz: {
        layers: [
            'radnetz_nw_netztyp_themenroute_auf_radverkehrsnetz_nrw',
            'radnetz_rcn_osm'
        ],
        label: 'Gesamtnetz Netztyp Themenrouten auf Radverkehrsnetz NRW'
    },
    gesamtnetz_vergleich_themenroute: {
        layers: [
            'radnetz_nw_netztyp_themenroute',
            'radnetz_rcn_osm'
        ],
        label: 'Gesamtnetz Netztyp Themenroute'
    },

    gesamtnetz_vergleich_radnetz: {
        layers: [
            'radnetz_nw_netztyp_radverkehrsnetz_nrw',
            'radnetz_rcn_osm'
        ],
        label: 'Gesamtnetz Netztyp Radverkehrsnetz NRW'
    },
    gesamtnetz_vergleich_radnetz_invers: {
        layers: [
            'radnetz_rcn_osm',
            'radnetz_nw_netztyp_radverkehrsnetz_nrw',
        ],
        label: 'Gesamtnetz Netztyp Radverkehrsnetz NRW Invers'
    },
    knotenpunktnetze_vergleich: {
        layers: [
            'knotenpunktnetz_nw',
            'knotenpunktnetz_osm'
        ],
        label: 'Knotenpunktnetze'
    },
    knotenpunktnetze_vergleich1: {
        layers: [
            'knotenpunktnetz_osm',
            'knotenpunktnetz_nw',
        ],
        label: 'Knotenpunktnetze (umgedreht)'
    },
    knotenpunkte_vergleich: {
        layers: [
            'knotenpunkte_nw',
            'knotenpunkte_osm',
        ],
        label: 'Knotenpunkte'
    }
}

const defaultLat = 51.2277;
const defaultLng = 6.7735;
const defaultZoom = 12;
var lat = defaultLat;
var lng = defaultLng;
var zoom = defaultZoom;
const defaultPreset = 'knotenpunktnetze_vergleich';
let activePreset = "knotenpunktnetze_vergleich";


function setupMap() {
    const map = new maplibregl.Map({
        container: 'map',
        style: 'style.json',
        center: [lng, lat],
        zoom: zoom
    });

    map.getCanvas().addEventListener('click', () => {
        contextMenu.classList.add('hidden');
    });

    map.on('contextmenu', (e) => {
        let { lng, lat } = map.getCenter();
        const zoom = (map.getZoom() + 2).toFixed(2);

        const osmUrl = `https://www.openstreetmap.org/#map=${zoom}/${lat}/${lng}`;
        const mapillaryUrl = `https://www.mapillary.com/app/?lat=${lat}&lng=${lng}&z=${zoom}`;
        osmLink.href = osmUrl;
        mapillaryUrl.href = mapillaryUrl

        contextMenu.innerHTML = `<a href="${osmUrl}" target="_blank">Open in OSM</a><br><a href="${mapillaryUrl}" target="_blank">Open in Mapillary</a>`;
        contextMenu.style.left = `${e.point.x}px`;
        contextMenu.style.top = `${e.point.y}px`;
        contextMenu.classList.remove('hidden');
    });

    map.on('load', () => {
        listPresets(map);
        setActivePreset(map, activePreset);
        updateLegend(map);
        document.getElementById('map').classList.remove('hidden');

        map.resize();
    });

    // Update the URL when the map is moved
    map.on('moveend', () => {
        const urlParams = new URLSearchParams(window.location.search);

        const center = map.getCenter();
        const zoom = map.getZoom().toFixed(2);
        urlParams.set('lat', center.lat.toFixed(5));
        urlParams.set('lng', center.lng.toFixed(5));
        urlParams.set('zoom', zoom);
        urlParams.set('preset', activePreset);
        window.history.replaceState({}, '', `?${urlParams.toString()}`);
    });
}

function setActivePreset(map, preset) {
    const allLayers = Object.keys(targetLayers);
    allLayers.forEach(layer => {
        if (map.getLayer(layer)) {
            map.setLayoutProperty(layer, 'visibility', 'none');
        } else {
            console.warn(`Layer ${layer} does not exist`);
        }
    });

    activePreset = preset;

    let layers = presets[preset].layers;
    layers.forEach(layer => {
        if (map.getLayer(layer)) {
            map.setLayoutProperty(layer, 'visibility', 'visible');
            map.moveLayer(layer);
        } else {
            console.warn(`Layer ${layer} does not exist`);
        }
    });

    updateLegend(map);
}

function listPresets(map) {
    const container = document.getElementById('presetList');
    container.innerHTML = '';

    for (const [key, value] of Object.entries(presets)) {
        const item = document.createElement('div');
        item.className = "w-full flex items-center justify-between px-4 py-2 text-sm font-medium text-gray-700 bg-gray-100 rounded hover:bg-gray-200 transition";
        // button to handle click
        item.innerHTML = `
            ${value.label}
            <button class="ml-auto text-gray-500 hover:text-gray-700 focus:outline-none">
            </button>
        `;
        item.addEventListener('click', () => {
            setActivePreset(map, key);
            activePreset = key;
            const urlParams = new URLSearchParams(window.location.search);
            urlParams.set('preset', key);
            window.history.replaceState({}, '', `?${urlParams.toString()}`);
        });
        container.appendChild(item);
    }
}

function updateLegend(map) {
    const mapStyleLayers = map.getStyle().layers;
    const visibleLayerIds = mapStyleLayers
        .filter(layer =>
            Object.keys(targetLayers).includes(layer.id) &&
            map.getLayoutProperty(layer.id, 'visibility') !== 'none'
        )
        .map(layer => layer.id)

    const container = document.getElementById('mapKey');
    container.innerHTML = '';

    for (const layerId of visibleLayerIds) {
        const { color, kind, label } = targetLayers[layerId];

        const item = document.createElement('div');
        item.dataset.layerId = layerId;
        item.className =
            'flex items-center px-3 py-1 text-sm border text-gray-700 rounded';
        if (kind === 'line') {
            item.innerHTML = `
                <span class="inline-block w-6 h-3 rounded-full mr-2" style="background-color: ${color};"></span>
                ${label}
            `;
        } else if (kind === 'point') {
            item.innerHTML = `
                <span class="collapse h-3 w-3"></span><span class="inline-block w-3 h-3 rounded-full mr-2" style="background-color: ${color};"></span>
                ${label}
            `;
        }
        container.appendChild(item);
    }
}

document.addEventListener('DOMContentLoaded', () => {
    const urlParams = new URLSearchParams(window.location.search);

    activePreset = urlParams.get('preset') || defaultPreset;
    lat = parseFloat(urlParams.get('lat')) || defaultLat;
    lng = parseFloat(urlParams.get('lng')) || defaultLng;
    zoom = parseFloat(urlParams.get('zoom')) || defaultZoom;
});


function toggleVisibility(id) {
    const element = document.getElementById(id);
    if (element.classList.contains('hidden')) {
        element.classList.remove('hidden');
    } else {
        element.classList.add('hidden');
    }
}

document.getElementById('legal').addEventListener('click', function () {
    toggleVisibility('legal-content');
});

document.getElementById('info').addEventListener('click', function () {
    toggleVisibility('info-content');
});

document.getElementById('startBtn').addEventListener('click', function () {
    document.getElementById('cookieModal').classList.add('hidden');
    document.getElementById('info-container').classList.remove('hidden');
    document.getElementById('mapMenu').classList.remove('hidden');
    setupMap(lat, lng, zoom, activePreset);
});
