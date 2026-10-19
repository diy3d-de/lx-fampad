// Fehler-Serializer für das Log. Datenbankfehler von Drizzle ("Failed query: ... params: ...") tragen die SQL-Parameter in
// der Meldung und im Stack-Kopf; dort stehen E-Mail-Adressen, Hashes und Tokens. Sie dürfen nie im Log landen.

const MAX_DEPTH = 3;
const MAX_MESSAGE = 300;

interface ErrLike {
  name?: unknown;
  message?: unknown;
  code?: unknown;
  stack?: unknown;
  cause?: unknown;
  params?: unknown;
  query?: unknown;
}

const str = (v: unknown): string | undefined => (typeof v === 'string' ? v : undefined);

/** Stack ohne Kopfzeile(n): die erste Zeile wiederholt die Meldung, nur die "at"-Zeilen bleiben. */
function stackFrames(stack: unknown): string | undefined {
  const s = str(stack);
  if (!s) return undefined;
  const i = s.search(/\n\s+at /);
  return i < 0 ? undefined : s.slice(i + 1);
}

/** Fehler mit SQL-Text oder -Parametern (Drizzle, pg): nur Art und Code, keine Werte. */
const hasSql = (e: ErrLike): boolean => 'params' in e || 'query' in e;

export interface SerializedErr {
  [key: string]: unknown;
  type: string;
  message: string;
  stack: string;
}

export function serializeErr(err: unknown, depth = 0): SerializedErr {
  if (typeof err !== 'object' || err === null) return { type: 'Error', message: String(err).slice(0, MAX_MESSAGE), stack: '' };
  const e = err as ErrLike;
  const out: SerializedErr = { type: str(e.name) ?? 'Error', message: '', stack: '' };
  if (hasSql(e)) {
    // message von DrizzleQueryError enthält Abfrage und Parameter: nicht ausgeben; Aufschluss gibt die Ursache (pg-Fehler)
    if (e.code !== undefined) out.code = e.code;
    const c = e.cause as ErrLike | undefined;
    if (c && typeof c === 'object') {
      out.cause = {
        name: str(c.name),
        code: c.code,
        message: str(c.message)?.slice(0, MAX_MESSAGE),
      };
    }
    out.message = 'Datenbankfehler (Abfrage und Parameter werden nicht protokolliert)';
    const frames = stackFrames(e.stack);
    if (frames) out.stack = `${str(e.name) ?? 'Error'}\n${frames}`;
    return out;
  }
  out.message = str(e.message) ?? '';
  if (e.code !== undefined) out.code = e.code;
  const frames = stackFrames(e.stack);
  const header = `${str(e.name) ?? 'Error'}: ${str(e.message) ?? ''}`;
  if (frames) out.stack = `${header}\n${frames}`;
  if (e.cause !== undefined && depth < MAX_DEPTH) out.cause = serializeErr(e.cause, depth + 1);
  return out;
}
