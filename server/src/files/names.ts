// Namens- und Typ-Regeln der Dateiablage (Abschnitt 6n). Der Dateiname ist reiner Anzeigetext: er geht NIE in einen Pfad auf dem Datenträger (dort steht nur die Zufalls-UUID des Blobs).
import { z } from 'zod';
import { safeString } from '../routes/util.js';

/** Steuerzeichen (C0, DEL, C1), Zeilen-/Absatztrenner, Zero-Width-Zeichen und Bidi-Steuerzeichen werden entfernt. */
// eslint-disable-next-line no-control-regex
const UNSICHTBAR = /[\u0000-\u001f\u007f-\u009f\u200b-\u200f\u2028-\u202e\u2060-\u2064\u2066-\u2069\ufeff]/gu;
const RESERVIERT = /^(con|prn|aux|nul|com[0-9]|lpt[0-9])$/i;

export const NAME_MAX_CHARS = 200;
export const NAME_MAX_BYTES = 255;

/**
 * Bereinigt einen Namen (NFC, unsichtbare Zeichen und Bidi-Overrides entfernen, Ränder kürzen); null, wenn er danach nicht zulässig ist:
 * leer, `.`/`..`, enthält `/`, `\` oder NUL, endet auf Punkt, zu lang (200 Zeichen/255 Byte), Windows-reservierter Name (mit oder ohne Endung).
 */
export function cleanName(raw: string): string | null {
  if (raw.includes('\u0000')) return null;
  const name = raw.normalize('NFC').replace(UNSICHTBAR, '').trim();
  if (name === '' || name === '.' || name === '..') return null;
  if (name.includes('/') || name.includes('\\')) return null;
  if (name.endsWith('.')) return null;
  if ([...name].length > NAME_MAX_CHARS || Buffer.byteLength(name, 'utf8') > NAME_MAX_BYTES) return null;
  const stamm = name.split('.')[0]?.trimEnd() ?? '';
  if (RESERVIERT.test(stamm)) return null;
  return name;
}

/** Zod-Schema für Datei- und Ordnernamen (Eingabe wird bereinigt gespeichert). */
export const dateiName = safeString()
  .transform((s, ctx) => {
    const n = cleanName(s);
    if (n === null) {
      ctx.addIssue({ code: 'custom', message: 'Name ungültig' });
      return z.NEVER;
    }
    return n;
  })
  .pipe(z.string().min(1).max(NAME_MAX_CHARS));

/** Internetmedientyp ohne Parameter, Kleinbuchstaben, höchstens 127 Zeichen. */
const MIME_RE = /^[a-z0-9][a-z0-9!#$&^_.+-]{0,62}\/[a-z0-9][a-z0-9!#$&^_.+-]{0,62}$/;
export function cleanMime(raw: string): string | null {
  const m = raw.trim().toLowerCase();
  return MIME_RE.test(m) ? m : null;
}

/** Erkennt einige gängige Typen an den ersten Bytes (Magic-Bytes); null, wenn nichts passt. Der Server wertet nur diese Köpfe aus, sonst nichts. */
export function sniffMime(head: Buffer): string | null {
  if (head.length >= 8 && head.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]))) return 'image/png';
  if (head.length >= 3 && head[0] === 0xff && head[1] === 0xd8 && head[2] === 0xff) return 'image/jpeg';
  if (head.length >= 6 && /^GIF8[79]a$/.test(head.toString('latin1', 0, 6))) return 'image/gif';
  if (head.length >= 12 && head.toString('latin1', 0, 4) === 'RIFF' && head.toString('latin1', 8, 12) === 'WEBP') return 'image/webp';
  if (head.length >= 5 && head.toString('latin1', 0, 5) === '%PDF-') return 'application/pdf';
  if (head.length >= 4 && head[0] === 0x50 && head[1] === 0x4b && head[2] === 0x03 && head[3] === 0x04) return 'application/zip';
  if (head.length >= 2 && head[0] === 0x1f && head[1] === 0x8b) return 'application/gzip';
  if (head.length >= 12 && head.toString('latin1', 4, 8) === 'ftyp') {
    const brand = head.toString('latin1', 8, 12);
    return /^(heic|heix|hevc|hevx|mif1|msf1)$/.test(brand) ? 'image/heic' : 'video/mp4';
  }
  return null;
}

/**
 * Typ einer hochgeladenen Datei (Modus `server`): ein genannter Bildtyp (außer SVG, das als Text keine Magic-Bytes hat) und PDF müssen zu den Magic-Bytes passen
 * (sonst null = abgelehnt); bei anderen Typen gilt der genannte (er ist nur Anzeige, die Auslieferung ist immer `attachment`); ohne Angabe oder bei `application/octet-stream`
 * gilt der erkannte Typ, sonst `application/octet-stream`.
 */
export function decideMime(declared: string | null, head: Buffer): string | null {
  const detected = sniffMime(head);
  const d = declared && declared !== 'application/octet-stream' ? declared : null;
  if (d === null) return detected ?? 'application/octet-stream';
  const heif = (t: string) => t === 'image/heic' || t === 'image/heif';
  if (d.startsWith('image/') && d !== 'image/svg+xml') {
    if (detected === null) return null;
    return d === detected || (heif(d) && detected === 'image/heic') ? d : null;
  }
  if (d === 'application/pdf') return detected === 'application/pdf' ? d : null;
  return d;
}

/** Ergebnis der Prüfung eines `Range`-Kopfes (nur ein Bereich; mehrere Bereiche und alles Ungültige sind `unsatisfiable`). */
export type RangeResult = { kind: 'none' } | { kind: 'range'; start: number; end: number } | { kind: 'unsatisfiable' };

export function parseRange(header: string | undefined, size: number): RangeResult {
  if (header === undefined) return { kind: 'none' };
  const m = /^bytes=(\d{0,15})-(\d{0,15})$/.exec(header.trim());
  if (!m || size === 0) return { kind: 'unsatisfiable' };
  const [, a = '', b = ''] = m;
  if (a === '' && b === '') return { kind: 'unsatisfiable' };
  if (a === '') {
    const n = Number(b);
    if (n === 0) return { kind: 'unsatisfiable' };
    return { kind: 'range', start: Math.max(size - n, 0), end: size - 1 };
  }
  const start = Number(a);
  const end = b === '' ? size - 1 : Math.min(Number(b), size - 1);
  if (start >= size || (b !== '' && Number(b) < start)) return { kind: 'unsatisfiable' };
  return { kind: 'range', start, end };
}

/** `Content-Disposition: attachment` mit ASCII-Rückfall und UTF-8-Name (RFC 6266/8187); der Name ist bereits bereinigt (keine Steuerzeichen). */
export function contentDisposition(name: string, inline = false): string {
  const ascii = name.replace(/[^\x20-\x7e]|["\\%]/g, '_');
  const utf8 = encodeURIComponent(name).replace(/['()*]/g, (c) => `%${c.charCodeAt(0).toString(16).toUpperCase()}`);
  return `${inline ? 'inline' : 'attachment'}; filename="${ascii}"; filename*=UTF-8''${utf8}`;
}
