// Karte (Spike): MapLibre GL JS im CSP-Build braucht die Adresse seines Worker-Skripts (gleiche Domain, kein blob:).
// Muss nach maplibre-gl-csp.js und vor dem Flutter-Start laden (index.html). Eigene Datei, weil die CSP keine Inline-Skripte erlaubt.
if (window.maplibregl) {
  window.maplibregl.setWorkerUrl(new URL('karte/maplibre-gl-csp-worker.js', document.baseURI).href);
}
