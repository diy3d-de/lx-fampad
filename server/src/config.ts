// Konfiguration ausschließlich über Umgebungsvariablen (siehe .env.example).
import { randomBytes } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { isAbsolute } from 'node:path';
import { MAX_OPS } from './sync/types.js';
import { MIN_PROTOCOL_VERSION } from './version.js';

/** Zeiten und Grenzen der Anmeldung (Standardwerte, nur Tests überschreiben sie). */
export interface AuthConfig {
  /** WebAuthn: Relying-Party-ID (registrierbare Domain, ohne Schema und Port). */
  rpId: string;
  rpName: string;
  /** Weitere erlaubte WebAuthn-Origins (z. B. android:apk-key-hash:... für die App); die Origin aus PUBLIC_URL gilt immer. */
  extraOrigins: string[];
  /** Hauptschlüssel (32 Byte): daraus werden per HKDF die Teilschlüssel abgeleitet (TOTP-Verschlüsselung, HMACs). */
  secretKey: Buffer;
  inviteDefaultHours: number;
  inviteMaxHours: number;
  /** Standard-Gültigkeit der Einladung aus dem Bootstrap (Stunden). */
  bootstrapInviteHours: number;
  accessTokenTtlSec: number;
  /** Cookie-Sitzung (Web): absolute Dauer und Leerlauf in Tagen. */
  webSessionMaxDays: number;
  webSessionIdleDays: number;
  /** Refresh-Token (App): absolute Dauer und Leerlauf in Tagen. */
  appSessionMaxDays: number;
  appSessionIdleDays: number;
  /** Toleranzfenster (Sekunden) für ein gerade rotiertes Refresh-Token derselben Geräte-ID, solange die Nachfolgerin unbenutzt ist (Antwort ging verloren). 0 = aus. */
  refreshGraceSec: number;
  /** So lange gilt eine erneute Bestätigung (Step-up) bzw. die Anmeldung als frisch. */
  stepUpMaxAgeSec: number;
  wsTicketTtlSec: number;
  challengeTtlSec: number;
  minPasswordLength: number;
  /** AUTH_LEGACY_PASSWORD_LOGIN (Standard an): Anmeldung und Passwortvergabe mit Klartext-Passwort (alte Apps). Aus = nur noch mit abgeleitetem authKey (Stichtag, den die Familie setzt). */
  legacyPasswordLogin: boolean;
  /** Fehlversuche, ab denen die verzögerte Sperre beginnt (je Konto bzw. je IP). */
  lockoutAccountThreshold: number;
  lockoutIpThreshold: number;
  /** Je Paar aus Konto und IP: sperrt früher als der Konto-Zähler und trifft nur die tippende IP. */
  lockoutPairThreshold: number;
  /** Fehlversuche verfallen nach dieser Zeit ohne neuen Fehlversuch. */
  lockoutWindowSec: number;
  /** Höchstdauer einer Sperre (Sekunden); kurz gehalten, damit niemand fremde Konten lange aussperren kann. */
  lockoutMaxDelaySec: number;
  /** Unauthentifiziert erzeugte WebAuthn-Challenges, die gleichzeitig offen sein dürfen: je IP (IPv6: /64) und insgesamt. */
  challengeMaxPerIp: number;
  challengeMaxGlobal: number;
  maxInvitePinAttempts: number;
  auditRetentionDays: number;
}

export interface Config {
  env: 'development' | 'production' | 'test';
  host: string;
  port: number;
  /** Laufzeit-Rolle (nur DML). */
  databaseUrl: string | undefined;
  /** Zeitlimit je Datenbankanweisung im Laufzeit-Pool (Millisekunden). */
  dbStatementTimeoutMs: number;
  /** Migrationsrolle (DDL, Eigentümer); nur migrate-cli. Ohne Angabe gilt databaseUrl (Rückfall für bestehende Installationen). */
  migrationDatabaseUrl: string | undefined;
  publicUrl: string;
  auth: AuthConfig;
  /** WebSocket: Verbindungen je Benutzer sowie Nachrichten je Socket und Zeitfenster. */
  wsMaxPerUser: number;
  wsMaxMessages: number;
  wsMessageWindowMs: number;
  filesDir: string;
  minAppVersion: string;
  /** Älteste Protokollversion, die der Server noch bedient (darunter: 426 update_required). */
  minProtocolVersion: number;
  webVersion: string | undefined;
  /** Datei, deren Inhalt die Version des ausgelieferten Web-Builds ist (schreibt deploy-web.sh). */
  webVersionFile: string | undefined;
  logLevel: 'fatal' | 'error' | 'warn' | 'info' | 'debug' | 'trace' | 'silent';
  /** Anfragen je Minute und IP für alle Routen. */
  rateLimitMax: number;
  /** Anfragen je Minute und IP für /api/v1/auth/* und /api/v1/ws-ticket. */
  authRateLimitMax: number;
  /** Anfragen je Minute und IP für POST /api/v1/sync. */
  syncRateLimitMax: number;
  /** Mengenbegrenzung des Sync je Gerät (je Person das Dreifache): Fassungsvermögen und Auffüllung je Minute für Ops und für Anfragen. */
  syncOpsBurst: number;
  syncOpsPerMinute: number;
  syncReqBurst: number;
  syncReqPerMinute: number;
  /** Höchstzahl Ops je Gerät in 24 Stunden (zählt applied_ops, auch abgelehnte). */
  syncOpsPerDay: number;
  /** Zeitlimits einer Op in der Datenbank (Sperre auf die Familienzeile, Anweisung); danach 503 mit Retry-After. */
  syncLockTimeoutMs: number;
  syncStatementTimeoutMs: number;
  /** Zeitlimit für die Datenbankprüfung in /api/v1/health. */
  healthTimeoutMs: number;
  /** Gleichzeitige WebSocket-Verbindungen je IP. */
  wsMaxPerIp: number;
  /** Push (UnifiedPush über das eigene ntfy): Loopback-URL und Token; fehlt eines, ist Push still aus. */
  ntfyUrl: string | undefined;
  ntfyToken: string | undefined;
  /** Host, den gemeldete UnifiedPush-Endpunkte haben müssen (SSRF-Schutz; gepostet wird nie dorthin, sondern an ntfyUrl). */
  ntfyPublicHost: string;
  /** Abstand der Server-Pings; bleibt ein Pong bis zum nächsten Ping aus, wird die Verbindung getrennt. */
  wsPingIntervalMs: number;
  /** Frist, in der sich ein WebSocket nach dem Verbinden anmelden muss. */
  wsAuthTimeoutMs: number;
  /** Standort teilen (nur Prozessspeicher): längste Dauer einer Freigabe, Freigaben je Familie, Mindestabstand der Positionen je Freigabe,
   *  Schonfrist nach Verbindungsverlust des Senders, Abstand der Prüfung (Ablauf, Mitgliedschaft). */
  locMaxDurationMs: number;
  /** Gesamtlaufzeit je Freigabe in Minuten (Start bis spätestes Ende, auch nach Verlängern). */
  locMaxTotalMinutes: number;
  locMaxSharesPerFamily: number;
  locMinIntervalMs: number;
  /** Höchstens so viele Positionen je Freigabe und Minute (die App sendet im schnellsten Modus alle 3 s, also 20 je Minute). */
  locMaxPerMinute: number;
  locGraceMs: number;
  /** Pause, bevor derselbe Sender dieselben Empfänger wieder per Push-Wecker anstoßen darf (Standard 10 Minuten; zum Testen kürzer). */
  locWakeCooldownMs: number;
  locSweepMs: number;
  locDirectoryTimeoutMs: number;
  /** Wetter (Netatmo, nur Server; standardmäßig aus). */
  weather: WeatherConfig;
  /** Abfuhrtermine (ICS einer Abfall-Plattform, nur Server; standardmäßig aus). */
  waste: WasteConfig;
  /** Einwurf (Home Assistant, Zähler-Postfach); Standard aus, dann sind alle Routen unter /ingest 404. */
  ingest: { enabled: boolean; ratePerHour: number };
  /** Vereinfachte Schlüsselverwaltung (Passwort-Sicherung, KDF-Parameter): Routen nur bei true, sonst 404 (Standard aus). */
  e2eePwBackup: boolean;
  /** Wraps mit Schlüsselversion (Wrap-ID v2, "Verlauf freigeben" und "Verlauf teilen"): nur bei true, sonst lehnt der Server sie ab (Standard aus; erst einschalten, wenn alle Apps der Familie aktualisiert sind). */
  e2eeWrapKeyVersion: boolean;
  /** Passkey-Sicherung (WebAuthn-PRF, Blobs in key_backups_prf): Routen nur bei true, sonst 404 (Standard aus). */
  e2eePrfBackup: boolean;
  /** Eltern-Wiederherstellung für Kinder (Hinterlegung, Anfrage mit Wartefrist): Routen nur bei true, sonst 404 (Standard aus). */
  e2eeParentRecovery: boolean;
  /** Wartefrist zwischen der Anfrage des Kindes und der Freigabe durch ein Elternteil (ganze Stunden, 24 bis 168). */
  parentRecoveryWaitHours: number;
  /** Betreiber-Ansicht (nur lesend): Pfade und Prüfungen, die der Status ohne root lesen darf (leer = nicht ermittelbar, "unbekannt"). */
  operator: OperatorConfig;
  /** Dateiablage (Dateien-Bereich und verschlüsselte Blobs; Schalter FILES_ENABLED, Standard aus, ohne Schalter antworten die Routen mit 404). */
  files: FilesConfig;
}

/** Dateiablage: Grenzen (Bytes) und Schalter; der Ordner steht in `Config.filesDir` (FILES_DIR). */
export interface FilesConfig {
  enabled: boolean;
  /** Speicherkontingent je Familie (belegte Blobs plus reservierte Uploads). */
  quotaBytes: number;
  /** Größte Datei im Modus `server` (Klartextgröße). */
  maxBytes: number;
  /** Größte Übertragung im Modus `e2ee`: `maxBytes` plus kleiner Verschlüsselungs-Overhead. */
  maxE2eeBytes: number;
  /** Uploads werden abgelehnt, wenn auf dem Datenträger weniger frei ist. */
  minFreeBytes: number;
  /** Summe aller offenen Uploads (Staging) über alle Familien. */
  stagingMaxBytes: number;
  /** Kinder: höchstens so viele Bytes an Uploads je Stunde und je Tag (die Regel `rate.bytes` der Registry zählt Textlängen, hier geht es um Dateigrößen). */
  childBytesPerHour: number;
  childBytesPerDay: number;
}

export const FILES_CHUNK_BYTES = 4 * 1024 * 1024;
export const FILES_E2EE_OVERHEAD_BYTES = 1024 * 1024;
export const FILES_THUMB_MAX_BYTES = 256 * 1024;

export interface OperatorConfig {
  /** Zweite, lesbare Statusdatei der Sicherung (schreibt lx-fampad-backup als root nach /var/lib/lx-fampad-status/); nur wenn der Dienst sie lesen darf, sonst "unbekannt". */
  backupStatusFile: string | undefined;
  /** Signiertes Release-Manifest der Android-App (latest.json), nur die Versionsangaben werden gelesen. */
  releaseManifestFile: string | undefined;
  /** Ordner, dessen belegter/freier Platz angezeigt wird. */
  diskPath: string | undefined;
  /** Ordner der Kartendatei (*.pmtiles); nur Vorhandensein und Größe. */
  karteDir: string | undefined;
  /** Rückmeldung des NAS (schreibt der erzwungene Befehl lx-fampad-nasstatus-empfang in einen eigenen Ordner, den der Dienst nur liest): letzte Abholung und letzter Wiederherstellungstest. */
  nasStatusFile: string | undefined;
  /** Ordner der Dateiablage (nur die Gesamtgröße für den Verlauf, nie Namen). */
  filesDir: string | undefined;
  /** "host:port" einer lesenden TLS-Verbindung zur Prüfung des Zertifikatsendes (Standard in Produktion: 127.0.0.1:443, sonst aus). */
  tlsProbe: string | undefined;
}

export interface WeatherConfig {
  enabled: boolean;
  /** Angezeigter Ortsname (nie Straße, Koordinaten oder Stations-ID). */
  place: string;
  /** MAC der öffentlichen Station (Filter auf die Antwort von getpublicdata); nur mit enabled. */
  stationMac: string;
  /** Suchrechteck für getpublicdata (klein halten: eine Anfrage liefert alle öffentlichen Stationen darin). */
  bbox: { latSw: number; lonSw: number; latNe: number; lonNe: number };
  pollMs: number;
  /** Vorhersage und amtliche Warnungen (DWD über Bright Sky; nur Server, Schalter WEATHER_FORECAST_ENABLED, braucht WEATHER_ENABLED). */
  forecast: { enabled: boolean; lat: number; lon: number };
}

/** Abfuhrtermine (ICS-Abruf nur im Dienst lx-fampad-waste; standardmäßig aus). */
export interface WasteConfig {
  enabled: boolean;
  /** URL-Vorlage mit {YEAR} (enthält den Schlüssel der Quelle: Geheimnis, nie loggen, nie in Antworten). */
  icsUrl: string;
  /** Der einzige Host, den der Abruf anspricht (aus der URL abgeleitet). */
  host: string;
  /** Angezeigter Ortsname (nie die Straße); leer = keiner. */
  place: string;
  /** Browser-Kennung für den Abruf (die Quelle antwortet sonst mit 403). */
  userAgent: string;
  /** Takt des Abruf-Prozesses (er liest nur den Zustand aus der Datenbank; Abrufe folgen der Jahreslogik). */
  tickMs: number;
  /** Die Müll-Konfiguration ist ungültig (feste Meldung ohne Link): die Funktion ist dann aus. Der API-Prozess startet trotzdem und warnt nur; der Abruf-Dienst bricht ab. */
  configError?: string;
}

const WASTE_DEFAULT_UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36';

/**
 * WASTE_*: ohne WASTE_ENABLED=true ist der Müll aus; mit Schalter ist WASTE_ICS_URL Pflicht (https, ein Host, Platzhalter {YEAR}).
 * Eine ungültige Eingabe macht die Funktion nur AUS (`configError`, feste Meldung ohne Link): ein Tippfehler in dieser Zusatzfunktion darf den API-Start nie verhindern.
 * Der Abruf-Dienst (cli/waste-poller.ts) beendet sich bei `configError`; das Einrichtungsskript prüft den Link vorher mit dieser Funktion.
 */
export function wasteConfig(env: NodeJS.ProcessEnv, nodeEnv: Config['env']): WasteConfig {
  try {
    return wasteConfigStrikt(env, nodeEnv);
  } catch (err) {
    const tickMs = Number.isInteger(Number(env.WASTE_TICK_MS)) && Number(env.WASTE_TICK_MS) > 0 ? Number(env.WASTE_TICK_MS) : 60_000;
    // nur Meldungen aus dieser Datei (nennen nie den Link); alles andere bekommt einen festen Text
    const msg = err instanceof Error && /^WASTE_[A-Z_]+ /.test(err.message) ? err.message : 'Müll-Konfiguration ungültig';
    return { enabled: false, icsUrl: '', host: '', place: '', userAgent: WASTE_DEFAULT_UA, tickMs, configError: msg };
  }
}

function wasteConfigStrikt(env: NodeJS.ProcessEnv, nodeEnv: Config['env']): WasteConfig {
  const enabled = boolFlag(env, 'WASTE_ENABLED');
  const tickMs = positiveInt(env, 'WASTE_TICK_MS', 60_000);
  const off: WasteConfig = { enabled: false, icsUrl: '', host: '', place: '', userAgent: WASTE_DEFAULT_UA, tickMs };
  if (!enabled) return off;
  if (tickMs < 10_000 && nodeEnv === 'production') throw new Error('WASTE_TICK_MS darf in Produktion nicht unter 10000 liegen');
  const raw = (env.WASTE_ICS_URL ?? '').trim();
  if (!raw) throw new Error('WASTE_ICS_URL fehlt');
  if (raw.length > 1000 || !raw.includes('{YEAR}')) throw new Error('WASTE_ICS_URL ungültig (https-Adresse mit dem Platzhalter {YEAR}, höchstens 1000 Zeichen)');
  let host: string;
  try {
    const u = new URL(raw.replaceAll('{YEAR}', '2026'));
    const v = new URL(raw.replaceAll('{YEAR}', '2099'));
    host = u.hostname;
    const istIp = /^[\d.]+$/.test(host) || host.includes(':') || host.startsWith('[');
    if (u.protocol !== 'https:' || u.username || u.password || u.hash || (u.port !== '' && u.port !== '443') || istIp || !host.includes('.') || host.endsWith('.') || host === 'localhost' || v.hostname !== host) {
      throw new Error('x');
    }
  } catch {
    throw new Error('WASTE_ICS_URL ungültig (nur https, ein Hostname, keine Zugangsdaten, kein Port, Platzhalter {YEAR})');
  }
  const place = (env.WASTE_PLACE?.trim() ?? '').normalize('NFC');
  if (place.length > 60 || /[<>]/.test(place) || [...place].some((c) => c < ' ')) throw new Error('WASTE_PLACE ungültig');
  const ua = env.WASTE_USER_AGENT?.trim() || WASTE_DEFAULT_UA;
  if (ua.length > 250 || [...ua].some((c) => c < ' ' || c > '~')) throw new Error('WASTE_USER_AGENT ungültig (nur druckbares ASCII, höchstens 250 Zeichen)');
  return { enabled, icsUrl: raw, host, place, userAgent: ua, tickMs };
}

/** NTFY_URL: nur http(s) ohne Zugangsdaten, Pfad und Query; ohne Angabe oder Token ist Push aus. */
function ntfyUrl(env: NodeJS.ProcessEnv): string | undefined {
  const raw = env.NTFY_URL?.trim();
  if (!raw) return undefined;
  let u: URL;
  try {
    u = new URL(raw);
  } catch {
    throw new Error('NTFY_URL ungültig');
  }
  if ((u.protocol !== 'http:' && u.protocol !== 'https:') || u.username || u.password || u.search || u.hash || u.pathname !== '/') {
    throw new Error('NTFY_URL ungültig (nur http(s)://Host[:Port] ohne Zugangsdaten und Pfad)');
  }
  return u.origin;
}

/** In Produktion nur Loopback (der Wecker trägt das Token; ein fremdes Ziel wäre eine Token-Abgabe). */
const LOOPBACK_HOSTS = ['127.0.0.1', '[::1]', 'localhost'];

function ntfyUrlPruefen(url: string | undefined, nodeEnv: Config['env']): string | undefined {
  if (url !== undefined && nodeEnv === 'production' && !LOOPBACK_HOSTS.includes(new URL(url).hostname === '::1' ? '[::1]' : new URL(url).hostname)) {
    throw new Error('NTFY_URL muss in Produktion eine Loopback-Adresse sein (127.0.0.1, [::1] oder localhost)');
  }
  return url;
}

function ntfyPublicHost(env: NodeJS.ProcessEnv): string {
  const host = (env.NTFY_PUBLIC_HOST?.trim() || 'ntfy.familyhub.lx-labs.dev').toLowerCase();
  if (!/^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$/.test(host)) throw new Error(`NTFY_PUBLIC_HOST ungültig: ${host}`);
  return host;
}

/** Boolescher Schalter: true/1/false/0 (leer = Standard aus), alles andere bricht den Start ab. */
function boolFlag(env: NodeJS.ProcessEnv, name: string): boolean {
  const raw = env[name]?.trim().toLowerCase();
  if (raw === undefined || raw === '' || raw === 'false' || raw === '0') return false;
  if (raw === 'true' || raw === '1') return true;
  throw new Error(`${name} ungültig: erlaubt sind true oder false`);
}

/** Wie [boolFlag], aber mit Standard (leer/fehlend = [standard]); alles außer true/1/false/0 bricht den Start ab (fail-closed). */
function boolFlagDefault(env: NodeJS.ProcessEnv, name: string, standard: boolean): boolean {
  const raw = env[name]?.trim().toLowerCase();
  if (raw === undefined || raw === '') return standard;
  if (raw === 'false' || raw === '0') return false;
  if (raw === 'true' || raw === '1') return true;
  throw new Error(`${name} ungültig: erlaubt sind true oder false`);
}

/** OPERATOR_*: Pfade für die Betreiber-Ansicht; "off" schaltet eine Quelle ab. In Entwicklung/Test ist die TLS-Prüfung aus. */
function operatorConfig(env: NodeJS.ProcessEnv, nodeEnv: Config['env']): OperatorConfig {
  const pick = (name: string, standard: string | undefined): string | undefined => {
    const raw = env[name]?.trim();
    if (raw === undefined || raw === '') return standard;
    return raw.toLowerCase() === 'off' ? undefined : raw;
  };
  const tlsProbe = pick('OPERATOR_TLS_PROBE', nodeEnv === 'production' ? '127.0.0.1:443' : undefined);
  if (tlsProbe !== undefined && !/^[A-Za-z0-9.[\]:-]+:\d{1,5}$/.test(tlsProbe)) throw new Error('OPERATOR_TLS_PROBE ungültig (Format host:port oder off)');
  if (tlsProbe !== undefined && Number(tlsProbe.slice(tlsProbe.lastIndexOf(':') + 1)) > 65535) throw new Error('OPERATOR_TLS_PROBE ungültig (Port höchstens 65535)');
  return {
    backupStatusFile: pick('OPERATOR_BACKUP_STATUS_FILE', '/var/lib/lx-fampad-status/backup.status'),
    releaseManifestFile: pick('OPERATOR_RELEASE_MANIFEST', '/srv/fampad/releases/android/latest.json'),
    diskPath: pick('OPERATOR_DISK_PATH', '/srv'),
    karteDir: pick('OPERATOR_KARTE_DIR', '/srv/fampad/karte'),
    nasStatusFile: pick('OPERATOR_NAS_STATUS_FILE', '/var/lib/lx-fampad-nasstatus/nas.status'),
    filesDir: pick('OPERATOR_FILES_DIR', '/srv/fampad/files'),
    tlsProbe,
  };
}

/** WEATHER_*: ohne WEATHER_ENABLED=true ist das Wetter aus; mit Schalter sind MAC und Rechteck Pflicht (fail-closed). */
function weatherConfig(env: NodeJS.ProcessEnv, nodeEnv: Config['env']): WeatherConfig {
  const enabled = boolFlag(env, 'WEATHER_ENABLED');
  const pollMs = positiveInt(env, 'WEATHER_POLL_MS', 10 * 60_000);
  const off = { enabled: false, place: '', stationMac: '', bbox: { latSw: 0, lonSw: 0, latNe: 0, lonNe: 0 }, pollMs, forecast: { enabled: false, lat: 0, lon: 0 } };
  if (!enabled) {
    if (boolFlag(env, 'WEATHER_FORECAST_ENABLED')) throw new Error('WEATHER_FORECAST_ENABLED braucht WEATHER_ENABLED=true (Ortsangabe)');
    return off;
  }
  if (pollMs < 5 * 60_000 && nodeEnv === 'production') throw new Error('WEATHER_POLL_MS darf in Produktion nicht unter 300000 liegen');
  const place = (env.WEATHER_PLACE?.trim() || 'Westerburg').normalize('NFC');
  if (place.length > 60 || /[<>]/.test(place) || [...place].some((c) => c < ' ')) throw new Error('WEATHER_PLACE ungültig');
  const mac = (env.WEATHER_STATION_MAC ?? '').trim().toLowerCase();
  if (!/^([0-9a-f]{2}:){5}[0-9a-f]{2}$/.test(mac)) throw new Error('WEATHER_STATION_MAC fehlt oder ist ungültig (Format aa:bb:cc:dd:ee:ff)');
  const parts = (env.WEATHER_BBOX ?? '').split(',').map((p) => Number(p.trim()));
  if (parts.length !== 4 || parts.some((n) => !Number.isFinite(n))) throw new Error('WEATHER_BBOX fehlt oder ist ungültig (Format: lat_sw,lon_sw,lat_ne,lon_ne)');
  const [latSw, lonSw, latNe, lonNe] = parts as [number, number, number, number];
  if (latSw >= latNe || lonSw >= lonNe || latSw < -90 || latNe > 90 || lonSw < -180 || lonNe > 180 || latNe - latSw > 0.5 || lonNe - lonSw > 0.5) {
    throw new Error('WEATHER_BBOX ungültig (Südwest unter Nordost, höchstens 0,5 Grad je Richtung)');
  }
  // Vorhersage: Mitte des Suchrechtecks, auf 2 Nachkommastellen gerundet (ca. 1 km); nur diese gerundete Angabe verlässt den Server
  const gerundet = (n: number) => Math.round(n * 100) / 100;
  const forecast = { enabled: boolFlag(env, 'WEATHER_FORECAST_ENABLED'), lat: gerundet((latSw + latNe) / 2), lon: gerundet((lonSw + lonNe) / 2) };
  return { enabled, place, stationMac: mac, bbox: { latSw, lonSw, latNe, lonNe }, pollMs, forecast };
}

const LOG_LEVELS = ['fatal', 'error', 'warn', 'info', 'debug', 'trace', 'silent'] as const;
const SEMVER = /^\d+\.\d+\.\d+$/;
const NODE_ENVS = ['development', 'production', 'test'] as const;

function nonNegativeInt(env: NodeJS.ProcessEnv, name: string, fallback: number): number {
  const raw = env[name];
  if (raw === undefined || raw === '') return fallback;
  const n = Number(raw);
  if (!Number.isSafeInteger(n) || n < 0) throw new Error(`${name} ungültig: ${raw}`);
  return n;
}

/** FILES_*: Dateiablage. Aus (Standard) = keine Routen; an braucht in Produktion einen absoluten FILES_DIR und stimmige Grenzen. Große Zahlen als Literale (Web-Ganzzahl-Regel). */
function filesConfig(env: NodeJS.ProcessEnv, nodeEnv: Config['env']): FilesConfig {
  const enabled = boolFlag(env, 'FILES_ENABLED');
  const quotaBytes = positiveInt(env, 'FILES_QUOTA_BYTES', 10_737_418_240);
  const maxBytes = positiveInt(env, 'FILES_MAX_BYTES', 104_857_600);
  const minFreeBytes = nonNegativeInt(env, 'FILES_MIN_FREE_BYTES', 5_368_709_120);
  const stagingMaxBytes = positiveInt(env, 'FILES_STAGING_MAX_BYTES', 2_147_483_648);
  const childBytesPerHour = positiveInt(env, 'FILES_CHILD_BYTES_PER_HOUR', 524_288_000);
  const childBytesPerDay = positiveInt(env, 'FILES_CHILD_BYTES_PER_DAY', 1_073_741_824);
  if (enabled) {
    if (maxBytes > quotaBytes) throw new Error('FILES_MAX_BYTES darf nicht über FILES_QUOTA_BYTES liegen');
    if (stagingMaxBytes < maxBytes) throw new Error('FILES_STAGING_MAX_BYTES muss mindestens FILES_MAX_BYTES betragen');
    const dir = env.FILES_DIR?.trim();
    if (nodeEnv === 'production' && (!dir || !isAbsolute(dir))) throw new Error('FILES_DIR muss mit FILES_ENABLED ein absoluter Pfad sein');
  }
  return { enabled, quotaBytes, maxBytes, maxE2eeBytes: maxBytes + FILES_E2EE_OVERHEAD_BYTES, minFreeBytes, stagingMaxBytes, childBytesPerHour, childBytesPerDay };
}

function positiveInt(env: NodeJS.ProcessEnv, name: string, fallback: number): number {
  const raw = env[name];
  if (raw === undefined || raw === '') return fallback;
  const n = Number(raw);
  if (!Number.isInteger(n) || n < 1) throw new Error(`${name} ungültig: ${raw}`);
  return n;
}

/** Fassungsvermögen der Op-Bucket: mindestens so groß wie die größte Anfrage (MAX_OPS), sonst ginge sie nie durch. */
function syncOpsBurst(env: NodeJS.ProcessEnv): number {
  const n = positiveInt(env, 'SYNC_OPS_BURST', 100);
  if (n < MAX_OPS) throw new Error(`SYNC_OPS_BURST ungültig: mindestens ${MAX_OPS}`);
  return n;
}

const PLACEHOLDER_KEYS = ['CHANGE_ME', 'changeme', 'secret'];

/** Mindestlänge neuer Passwörter: einstellbar, aber nie unter 10. */
export const MIN_PASSWORD_LENGTH_FLOOR = 10;
function minPasswordLength(env: NodeJS.ProcessEnv): number {
  const n = positiveInt(env, 'MIN_PASSWORD_LENGTH', 12);
  if (n < MIN_PASSWORD_LENGTH_FLOOR) throw new Error(`MIN_PASSWORD_LENGTH darf nicht unter ${MIN_PASSWORD_LENGTH_FLOOR} liegen: ${n}`);
  return n;
}

/** Liest den Hauptschlüssel aus AUTH_SECRET_KEY (Base64/Hex) oder AUTH_SECRET_KEY_FILE; mindestens 32 Byte. */
function loadSecretKey(env: NodeJS.ProcessEnv, nodeEnv: Config['env']): Buffer {
  let raw = env.AUTH_SECRET_KEY?.trim();
  const file = env.AUTH_SECRET_KEY_FILE?.trim();
  if (!raw && file) {
    try {
      raw = readFileSync(file, 'utf8').trim();
    } catch {
      throw new Error('AUTH_SECRET_KEY_FILE nicht lesbar');
    }
  }
  if (!raw) {
    // fail-closed: nur Entwicklung und Test erzeugen einen flüchtigen Schlüssel (Sitzungen überleben keinen Neustart)
    if (nodeEnv === 'production') throw new Error('AUTH_SECRET_KEY (oder AUTH_SECRET_KEY_FILE) fehlt');
    return randomBytes(32);
  }
  if (PLACEHOLDER_KEYS.some((p) => raw.includes(p))) throw new Error('AUTH_SECRET_KEY ist ein Platzhalter');
  const key = /^[0-9a-fA-F]{64,}$/.test(raw) ? Buffer.from(raw, 'hex') : Buffer.from(raw, 'base64');
  if (key.length < 32) throw new Error('AUTH_SECRET_KEY muss mindestens 32 Byte lang sein (Base64 oder Hex)');
  if (key.every((b) => b === key[0])) throw new Error('AUTH_SECRET_KEY ist unzulässig (gleichförmig)');
  return key;
}

export function loadConfig(env: NodeJS.ProcessEnv = process.env): Config {
  // fail-closed: ohne NODE_ENV gilt "production" (strenge Prüfungen); unbekannte Werte werden abgelehnt.
  // Gelockert wird nur bei ausdrücklich gesetztem "development" oder "test".
  const rawEnv = env.NODE_ENV || 'production';
  if (!(NODE_ENVS as readonly string[]).includes(rawEnv)) {
    throw new Error(`NODE_ENV ungültig: ${rawEnv} (erlaubt: ${NODE_ENVS.join(', ')})`);
  }
  const nodeEnv = rawEnv as Config['env'];

  const port = Number(env.PORT ?? 4400);
  if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error(`PORT ungültig: ${env.PORT}`);

  const publicUrl = env.PUBLIC_URL ?? 'http://localhost:4400';
  try {
    new URL(publicUrl);
  } catch {
    throw new Error(`PUBLIC_URL ungültig: ${publicUrl}`);
  }

  const rpId = env.WEBAUTHN_RP_ID?.trim() || new URL(publicUrl).hostname;
  if (!/^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$/i.test(rpId)) throw new Error(`WEBAUTHN_RP_ID ungültig: ${rpId}`);

  const minAppVersion = env.MIN_APP_VERSION ?? '0.1.0';
  if (!SEMVER.test(minAppVersion)) throw new Error(`MIN_APP_VERSION ungültig: ${minAppVersion}`);

  const level = env.LOG_LEVEL ?? 'info';
  if (!(LOG_LEVELS as readonly string[]).includes(level)) throw new Error(`LOG_LEVEL ungültig: ${level}`);

  const e2eePwBackup = boolFlag(env, 'E2EE_PW_BACKUP');
  const e2eeWrapKeyVersion = boolFlag(env, 'E2EE_WRAP_KEY_VERSION');
  const e2eePrfBackup = boolFlag(env, 'E2EE_PRF_BACKUP');
  const e2eeParentRecovery = boolFlag(env, 'E2EE_PARENT_RECOVERY');
  const waitRaw = env.E2EE_PARENT_RECOVERY_WAIT_HOURS?.trim();
  const parentRecoveryWaitHours = waitRaw === undefined || waitRaw === '' ? 24 : Number(waitRaw);
  if (!Number.isInteger(parentRecoveryWaitHours) || parentRecoveryWaitHours < 24 || parentRecoveryWaitHours > 168) {
    throw new Error('E2EE_PARENT_RECOVERY_WAIT_HOURS ungültig (ganze Stunden von 24 bis 168)');
  }
  const legacyPasswordLogin = boolFlagDefault(env, 'AUTH_LEGACY_PASSWORD_LOGIN', true);
  // fail-closed: ohne authKey-Anmeldung (hängt am Schalter E2EE_PW_BACKUP) würde das Abschalten des Klartext-Logins alle Passwort-Konten aussperren
  if (!legacyPasswordLogin && !e2eePwBackup) throw new Error('AUTH_LEGACY_PASSWORD_LOGIN=false braucht E2EE_PW_BACKUP=true (sonst kann sich niemand mehr mit Passwort anmelden)');
  return {
    env: nodeEnv,
    host: env.HOST ?? '127.0.0.1',
    port,
    databaseUrl: env.DATABASE_URL || undefined,
    dbStatementTimeoutMs: positiveInt(env, 'DB_STATEMENT_TIMEOUT_MS', 30_000),
    migrationDatabaseUrl: env.MIGRATION_DATABASE_URL || undefined,
    publicUrl,
    auth: {
      rpId,
      rpName: env.WEBAUTHN_RP_NAME?.trim() || 'lx-familyhub',
      extraOrigins: (env.WEBAUTHN_ORIGINS ?? '')
        .split(',')
        .map((o) => o.trim())
        .filter(Boolean),
      secretKey: loadSecretKey(env, nodeEnv),
      inviteDefaultHours: 24,
      inviteMaxHours: 168,
      bootstrapInviteHours: 168,
      accessTokenTtlSec: 15 * 60,
      webSessionMaxDays: 30,
      webSessionIdleDays: 7,
      appSessionMaxDays: 90,
      appSessionIdleDays: 30,
      refreshGraceSec: 30,
      stepUpMaxAgeSec: 5 * 60,
      wsTicketTtlSec: 30,
      challengeTtlSec: 5 * 60,
      minPasswordLength: minPasswordLength(env),
      legacyPasswordLogin,
      lockoutAccountThreshold: 10,
      lockoutIpThreshold: 20,
      lockoutPairThreshold: 5,
      lockoutWindowSec: 15 * 60,
      lockoutMaxDelaySec: 90,
      challengeMaxPerIp: positiveInt(env, 'CHALLENGE_MAX_PER_IP', 20),
      challengeMaxGlobal: positiveInt(env, 'CHALLENGE_MAX_GLOBAL', 2000),
      maxInvitePinAttempts: 5,
      auditRetentionDays: positiveInt(env, 'AUDIT_RETENTION_DAYS', 365),
    },
    wsMaxPerUser: positiveInt(env, 'WS_MAX_PER_USER', 8),
    wsMaxMessages: positiveInt(env, 'WS_MAX_MESSAGES', 30),
    wsMessageWindowMs: positiveInt(env, 'WS_MESSAGE_WINDOW_MS', 10_000),
    filesDir: env.FILES_DIR ?? './data/files',
    minAppVersion,
    minProtocolVersion: positiveInt(env, 'MIN_PROTOCOL_VERSION', MIN_PROTOCOL_VERSION),
    webVersion: env.WEB_VERSION || undefined,
    webVersionFile: env.WEB_VERSION_FILE || undefined,
    logLevel: level as Config['logLevel'],
    rateLimitMax: positiveInt(env, 'RATE_LIMIT_MAX', 300),
    authRateLimitMax: positiveInt(env, 'AUTH_RATE_LIMIT_MAX', 10),
    syncRateLimitMax: positiveInt(env, 'SYNC_RATE_LIMIT_MAX', 120),
    syncOpsBurst: syncOpsBurst(env),
    syncOpsPerMinute: positiveInt(env, 'SYNC_OPS_PER_MINUTE', 120),
    syncReqBurst: positiveInt(env, 'SYNC_REQ_BURST', 30),
    syncReqPerMinute: positiveInt(env, 'SYNC_REQ_PER_MINUTE', 120),
    syncOpsPerDay: positiveInt(env, 'SYNC_OPS_PER_DAY', 5000),
    syncLockTimeoutMs: positiveInt(env, 'SYNC_LOCK_TIMEOUT_MS', 5000),
    syncStatementTimeoutMs: positiveInt(env, 'SYNC_STATEMENT_TIMEOUT_MS', 10_000),
    healthTimeoutMs: positiveInt(env, 'HEALTH_TIMEOUT_MS', 2000),
    ntfyUrl: ntfyUrlPruefen(ntfyUrl(env), nodeEnv),
    ntfyToken: env.NTFY_TOKEN?.trim() || undefined,
    ntfyPublicHost: ntfyPublicHost(env),
    wsMaxPerIp: positiveInt(env, 'WS_MAX_PER_IP', 10),
    wsPingIntervalMs: positiveInt(env, 'WS_PING_INTERVAL_MS', 30_000),
    wsAuthTimeoutMs: positiveInt(env, 'WS_AUTH_TIMEOUT_MS', 5000),
    locMaxDurationMs: positiveInt(env, 'LOC_MAX_DURATION_MS', 12 * 60 * 60 * 1000),
    locMaxTotalMinutes: positiveInt(env, 'LOC_MAX_TOTAL_MINUTES', 24 * 60),
    locMaxSharesPerFamily: positiveInt(env, 'LOC_MAX_SHARES_PER_FAMILY', 50),
    locMinIntervalMs: positiveInt(env, 'LOC_MIN_INTERVAL_MS', 1000),
    locMaxPerMinute: positiveInt(env, 'LOC_MAX_PER_MINUTE', 40),
    locGraceMs: positiveInt(env, 'LOC_GRACE_MS', 90_000),
    locWakeCooldownMs: positiveInt(env, 'LOC_WAKE_COOLDOWN_MS', 10 * 60 * 1000),
    locSweepMs: positiveInt(env, 'LOC_SWEEP_MS', 5000),
    locDirectoryTimeoutMs: positiveInt(env, 'LOC_DIRECTORY_TIMEOUT_MS', 5000),
    weather: weatherConfig(env, nodeEnv),
    waste: wasteConfig(env, nodeEnv),
    ingest: { enabled: boolFlag(env, 'INGEST_ENABLED'), ratePerHour: positiveInt(env, 'INGEST_RATE_PER_HOUR', 120) },
    e2eePwBackup,
    e2eeWrapKeyVersion,
    e2eePrfBackup,
    e2eeParentRecovery,
    parentRecoveryWaitHours,
    operator: operatorConfig(env, nodeEnv),
    files: filesConfig(env, nodeEnv),
  };
}

/** Lockerungen (z. B. Origin-Prüfung) gibt es nur in Entwicklung und Test. */
export function isLax(config: Pick<Config, 'env'>): boolean {
  return config.env === 'development' || config.env === 'test';
}
