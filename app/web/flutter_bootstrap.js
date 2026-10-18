{{flutter_js}}
{{flutter_build_config}}

// Eigene Bootstrap-Datei: Fallback-Schriften (Zeichen, die Inter nicht enthält, z. B. Emoji) kommen von der
// eigenen Domain statt von fonts.gstatic.com. Ordner /font-fallback/ siehe deploy/README.md.
// Kein Service Worker (kein serviceWorkerSettings): wird nur mit Zustimmung registriert (TDDDG).
_flutter.loader.load({
  config: {
    fontFallbackBaseUrl: window.location.origin + '/font-fallback/',
  },
});
