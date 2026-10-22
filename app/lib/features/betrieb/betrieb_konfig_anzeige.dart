// Anzeige-Hilfen der Konfigurationsansicht (Betrieb, Paket 2b): feste deutsche Bezeichnungen zu den Namen der Umgebungsvariablen und Gruppen sowie das
// Zahlenformat je Einheit. Unbekannte Namen (neuere Server) zeigt die App unter ihrem Namen, nie ein Servertext.
import '../../data/betrieb/familien_stand.dart';

const _gruppen = <String, String>{
  'switches': 'Schalter',
  'server': 'Server',
  'auth': 'Anmeldung',
  'sync': 'Abgleich',
  'websocket': 'Live-Verbindung',
  'location': 'Standort teilen',
  'weather': 'Wetter',
};

String konfigGruppeText(String id) => _gruppen[id] ?? id;

const _namen = <String, String>{
  'E2EE_PW_BACKUP': 'Passwort-Sicherung',
  'AUTH_LEGACY_PASSWORD_LOGIN': 'Klartext-Passwort-Anmeldung',
  'WEATHER_ENABLED': 'Wetter',
  'NTFY': 'Push-Wecker (ntfy) eingerichtet',
  'OPERATOR_TLS_PROBE': 'Zertifikatsprüfung',
  'NODE_ENV': 'Umgebung',
  'PUBLIC_URL': 'Öffentliche Adresse',
  'LOG_LEVEL': 'Protokollstufe',
  'MIN_APP_VERSION': 'Mindestversion der App',
  'MIN_PROTOCOL_VERSION': 'Mindest-Protokollversion',
  'RATE_LIMIT_MAX': 'Anfragen je Minute und Adresse',
  'AUTH_RATE_LIMIT_MAX': 'Anmeldungen je Minute und Adresse',
  'DB_STATEMENT_TIMEOUT_MS': 'Zeitlimit je Datenbankanweisung',
  'HEALTH_TIMEOUT_MS': 'Zeitlimit der Datenbankprüfung',
  'AUDIT_RETENTION_DAYS': 'Aufbewahrung des Protokolls',
  'MIN_PASSWORD_LENGTH': 'Mindestlänge neuer Passwörter',
  'accessTokenTtl': 'Gültigkeit der Anmeldung (Zugangstoken)',
  'stepUpMaxAge': 'Gültigkeit der Bestätigung (Step-up)',
  'lockoutAccountThreshold': 'Fehlversuche bis zur Kontosperre',
  'lockoutMaxDelay': 'Längste Sperre nach Fehlversuchen',
  'CHALLENGE_MAX_PER_IP': 'Offene Anmelde-Abfragen je Adresse',
  'SYNC_RATE_LIMIT_MAX': 'Abgleich-Anfragen je Minute und Adresse',
  'SYNC_OPS_BURST': 'Änderungen auf einmal je Gerät',
  'SYNC_OPS_PER_MINUTE': 'Änderungen je Minute und Gerät',
  'SYNC_REQ_BURST': 'Abgleiche auf einmal je Gerät',
  'SYNC_REQ_PER_MINUTE': 'Abgleiche je Minute und Gerät',
  'SYNC_OPS_PER_DAY': 'Änderungen je Tag und Gerät',
  'SYNC_LOCK_TIMEOUT_MS': 'Zeitlimit Sperre beim Abgleich',
  'SYNC_STATEMENT_TIMEOUT_MS': 'Zeitlimit Anweisung beim Abgleich',
  'WS_MAX_PER_USER': 'Verbindungen je Person',
  'WS_MAX_PER_IP': 'Verbindungen je Adresse',
  'WS_MAX_MESSAGES': 'Nachrichten je Zeitfenster',
  'WS_MESSAGE_WINDOW_MS': 'Zeitfenster der Nachrichten',
  'WS_PING_INTERVAL_MS': 'Abstand der Lebenszeichen',
  'LOC_MAX_DURATION_MS': 'Längste Freigabe',
  'LOC_MAX_SHARES_PER_FAMILY': 'Freigaben je Familie',
  'LOC_MIN_INTERVAL_MS': 'Mindestabstand der Positionen',
  'LOC_MAX_PER_MINUTE': 'Positionen je Minute und Freigabe',
  'LOC_GRACE_MS': 'Schonfrist nach Verbindungsverlust',
  'LOC_WAKE_COOLDOWN_MS': 'Pause zwischen Push-Weckern',
  'WEATHER_POLL_MS': 'Abstand der Wetter-Abrufe',
};

/// Bezeichnung zu einem Eintrag; unbekannte zeigt die App unter ihrem Namen.
String konfigNameText(String key) => _namen[key] ?? key;

String _zahl(num v) {
  final s = v == v.roundToDouble() ? v.round().toString() : v.toStringAsFixed(1).replaceAll('.', ',');
  // Tausendertrenner (Punkt) für große Zahlen
  final neg = s.startsWith('-');
  final ziffern = neg ? s.substring(1) : s;
  final teile = ziffern.split(',');
  final ganz = teile.first.replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => '.');
  return '${neg ? '-' : ''}$ganz${teile.length > 1 ? ',${teile[1]}' : ''}';
}

String _dauer(num sekunden) {
  if (sekunden >= 86400 && sekunden % 86400 == 0) return '${_zahl(sekunden / 86400)} ${sekunden == 86400 ? 'Tag' : 'Tage'}';
  if (sekunden >= 3600 && sekunden % 3600 == 0) return '${_zahl(sekunden / 3600)} Std.';
  if (sekunden >= 60 && sekunden % 60 == 0) return '${_zahl(sekunden / 60)} Min.';
  if (sekunden >= 1 && sekunden == sekunden.roundToDouble()) return '${_zahl(sekunden)} s';
  return '${_zahl(sekunden * 1000)} ms';
}

/// Der Wert zum Anzeigen (Schalter als "an"/"aus" legt die Oberfläche selbst als Pille dar).
String konfigWertText(KonfigWert w) {
  final v = w.wert;
  if (v is bool) return v ? 'an' : 'aus';
  if (v is String) return v;
  if (v is num) {
    return switch (w.einheit) {
      'ms' => _dauer(v / 1000),
      's' => _dauer(v),
      'd' => '${_zahl(v)} ${v == 1 ? 'Tag' : 'Tage'}',
      'perMinute' => '${_zahl(v)} / Min.',
      'perDay' => '${_zahl(v)} / Tag',
      _ => _zahl(v),
    };
  }
  return 'unbekannt';
}
