// Gemeinsame Feld-Prüfungen der Entitäten (Zeitpunkte, Zeichenketten ohne NUL/Surrogate, Kennungen).
import { z } from 'zod';
import { safeString } from '../../routes/util.js';

export const iso = (v: unknown): unknown => (v instanceof Date ? v.toISOString() : v);

const MIN_DATE = Date.parse('2000-01-01T00:00:00Z');
const MAX_DATE = Date.parse('2200-01-01T00:00:00Z');

/** ISO-8601-Zeitpunkt (mit Zeitzone) im sinnvollen Bereich -> Date. */
export const timestamp = safeString()
  .pipe(z.iso.datetime({ offset: true }))
  .transform((s) => new Date(s))
  .refine((d) => d.getTime() >= MIN_DATE && d.getTime() < MAX_DATE, 'Zeitpunkt außerhalb des Bereichs');

export const uuid = z.uuid();
export const trimmed = (max: number) => safeString().pipe(z.string().trim().min(1).max(max));
