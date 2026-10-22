// Rückmeldung des NAS (Betrieb Paket 3, Backups): das NAS schickt nach jeder Abholung und jedem Wiederherstellungstest eine kleine Statusdatei an den Server
// (zweiter SSH-Schlüssel mit erzwungenem Befehl, `deploy/backup/lx-fampad-nasstatus-empfang.sh`; der Server hält keine Zugangsdaten zum NAS). Die Datei steht in einem
// eigenen Ordner, den der Dienst NUR liest. Hier wird sie streng ausgewertet: höchstens 4 KB, nur Zeilen `schluessel=wert`, nur bekannte Schlüssel, Zahlen und feste Codes,
// Zeitpunkte plausibel (nie in der Zukunft). Alles andere heißt "ungültig" und ergibt "unbekannt", nie einen Alarm. Unbekannte, aber gut geformte Schlüssel
// (eine neuere Fassung des NAS-Skripts) werden ignoriert und nie angezeigt; ein Fehler in einem BEKANNTEN Schlüssel macht die ganze Datei ungültig.
//
// Grenze: Die Angaben stammen vom NAS. Ein übernommenes NAS könnte "ok" vortäuschen; die Anzeige ist ein Hinweis mit Alter, kein Beweis (Wiederherstellungstest von Hand
// halbjährlich, docs/BACKUP.md).
import type { Level } from './status.js';

/** Größte erlaubte Datei (die Prüfung liest ein Byte mehr und verwirft größere). */
export const NAS_STATUS_MAX_BYTES = 4096;
/** Abholung: älter als so viele Stunden ist eine Warnung (wie die Sicherung auf dem Server). */
export const NAS_PULL_WARN_HOURS = 36;
export const NAS_PULL_ERROR_HOURS = 72;
/** Wiederherstellungstest (wöchentlich): älter als so viele Tage ist eine Warnung. */
export const NAS_RESTORE_WARN_DAYS = 10;
export const NAS_RESTORE_ERROR_DAYS = 21;

const LINE = /^[a-z_]+=[0-9A-Za-z:._-]*$/;
const EPOCH_MIN = 1_600_000_000;
/** Toleranz für eine vorgehende Uhr des NAS. */
const FUTURE_TOLERANCE_S = 3600;

type EpochKey = 'pull_run_epoch' | 'pull_success_epoch' | 'pull_newest_epoch' | 'restore_run_epoch' | 'restore_success_epoch' | 'reported_epoch' | 'received_epoch';
type CountKey = 'pull_count';
type ResultKey = 'pull_result' | 'restore_result';
type YesNoKey = 'restore_config_check';

export interface NasPull {
  result: 'ok' | 'fehler' | null;
  lastRunAt: string | null;
  lastSuccessAt: string | null;
  /** Alter des letzten Erfolgs in Stunden (null: nie gemeldet). */
  ageHours: number | null;
  /** Zeitpunkt der neuesten Sicherung im NAS-Archiv. */
  newestBackupAt: string | null;
  /** Anzahl der Stände im NAS-Archiv. */
  count: number | null;
  state: Level;
}

export interface NasRestore {
  result: 'ok' | 'fehler' | null;
  lastRunAt: string | null;
  lastSuccessAt: string | null;
  ageDays: number | null;
  /** Wurde auch das Konfigurationsarchiv geprüft? (null: nicht gemeldet) */
  configChecked: boolean | null;
  state: Level;
}

export interface NasStatus {
  /** Gibt es eine gültige Rückmeldung? false: nicht eingerichtet, nicht lesbar oder ungültig (alles "unbekannt", nie ein Alarm). */
  configured: boolean;
  /** Die Datei war vorhanden, aber unlesbar im Sinne der strengen Prüfung. */
  invalid: boolean;
  /** Wann der Server die Rückmeldung bekommen hat (Uhr des Servers). */
  receivedAt: string | null;
  pull: NasPull;
  restore: NasRestore;
}

const EMPTY_PULL: NasPull = { result: null, lastRunAt: null, lastSuccessAt: null, ageHours: null, newestBackupAt: null, count: null, state: 'unknown' };
const EMPTY_RESTORE: NasRestore = { result: null, lastRunAt: null, lastSuccessAt: null, ageDays: null, configChecked: null, state: 'unknown' };

export const NAS_ABSENT: NasStatus = { configured: false, invalid: false, receivedAt: null, pull: EMPTY_PULL, restore: EMPTY_RESTORE };
const NAS_INVALID: NasStatus = { ...NAS_ABSENT, invalid: true };

/** Liest die Statusdatei; `text` null = nicht vorhanden oder nicht lesbar. Rein (die Uhr kommt als Parameter). */
export function parseNasStatus(text: string | null, now: Date): NasStatus {
  if (text === null) return NAS_ABSENT;
  if (Buffer.byteLength(text, 'utf8') > NAS_STATUS_MAX_BYTES || text.includes('\0')) return NAS_INVALID;
  const kv = new Map<string, string>();
  for (const raw of text.split('\n')) {
    const line = raw.endsWith('\r') ? raw.slice(0, -1) : raw;
    if (line === '') continue;
    if (!LINE.test(line)) return NAS_INVALID;
    const i = line.indexOf('=');
    const key = line.slice(0, i);
    if (kv.has(key)) return NAS_INVALID; // doppelter Schlüssel: nie raten, welcher gilt
    kv.set(key, line.slice(i + 1));
  }
  if (kv.size === 0) return NAS_INVALID;

  const nowS = Math.floor(now.getTime() / 1000);
  let bad = false;
  const epoch = (k: EpochKey): number | null => {
    const v = kv.get(k);
    if (v === undefined) return null;
    if (!/^\d{10,11}$/.test(v) || Number(v) < EPOCH_MIN || Number(v) > nowS + FUTURE_TOLERANCE_S) {
      bad = true;
      return null;
    }
    return Number(v);
  };
  const count = (k: CountKey): number | null => {
    const v = kv.get(k);
    if (v === undefined) return null;
    if (!/^\d{1,5}$/.test(v)) {
      bad = true;
      return null;
    }
    return Number(v);
  };
  const result = (k: ResultKey): 'ok' | 'fehler' | null => {
    const v = kv.get(k);
    if (v === undefined) return null;
    if (v !== 'ok' && v !== 'fehler') {
      bad = true;
      return null;
    }
    return v;
  };
  const yesNo = (k: YesNoKey): boolean | null => {
    const v = kv.get(k);
    if (v === undefined) return null;
    if (v !== 'ja' && v !== 'nein') {
      bad = true;
      return null;
    }
    return v === 'ja';
  };
  const iso = (s: number | null): string | null => (s === null ? null : new Date(s * 1000).toISOString());

  const received = epoch('received_epoch');
  const pullRun = epoch('pull_run_epoch');
  const pullOk = epoch('pull_success_epoch');
  const pullNewest = epoch('pull_newest_epoch');
  const pullResult = result('pull_result');
  const pullCount = count('pull_count');
  const restRun = epoch('restore_run_epoch');
  const restOk = epoch('restore_success_epoch');
  const restResult = result('restore_result');
  const restConfig = yesNo('restore_config_check');
  epoch('reported_epoch');
  if (bad) return NAS_INVALID;

  let pullState: Level = 'unknown';
  let ageHours: number | null = null;
  if (pullResult !== null) {
    ageHours = pullOk === null ? null : Math.max(0, Math.round((nowS - pullOk) / 3600));
    const ageS = pullOk === null ? null : Math.max(0, nowS - pullOk);
    if (pullResult === 'fehler') pullState = 'error';
    else if (ageS === null) pullState = 'unknown';
    else pullState = ageS > NAS_PULL_ERROR_HOURS * 3600 ? 'error' : ageS > NAS_PULL_WARN_HOURS * 3600 ? 'warn' : 'ok';
  }
  let restState: Level = 'unknown';
  let ageDays: number | null = null;
  if (restResult !== null) {
    ageDays = restOk === null ? null : Math.max(0, Math.floor((nowS - restOk) / 86_400));
    const ageS = restOk === null ? null : Math.max(0, nowS - restOk);
    if (restResult === 'fehler') restState = 'error';
    else if (ageS === null) restState = 'unknown';
    else restState = ageS > NAS_RESTORE_ERROR_DAYS * 86_400 ? 'error' : ageS > NAS_RESTORE_WARN_DAYS * 86_400 ? 'warn' : 'ok';
  }

  return {
    configured: true,
    invalid: false,
    receivedAt: iso(received),
    pull: { result: pullResult, lastRunAt: iso(pullRun), lastSuccessAt: iso(pullOk), ageHours, newestBackupAt: iso(pullNewest), count: pullCount, state: pullState },
    restore: { result: restResult, lastRunAt: iso(restRun), lastSuccessAt: iso(restOk), ageDays, configChecked: restConfig, state: restState },
  };
}
