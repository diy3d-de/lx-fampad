// Belegter Platz der Dateiablage je Familie (nur Zahlen, nie Namen): Grundlage für Kontingent, Betreiber-Ansicht und Aufräumen.
import { and, count, eq, inArray, isNull, sql } from 'drizzle-orm';
import type { Executor } from '../auth/context.js';
import { dateiBlob, dateiUpload } from '../db/schema.js';

export interface Usage {
  /** Belegt: fertige Blobs (Größe des Inhalts), die noch jemand braucht. */
  usedBytes: number;
  /** Reserviert: angekündigte Größe laufender Uploads. */
  reservedBytes: number;
  quotaBytes: number;
  blobs: number;
  uploadsOpen: number;
}

/** Blobs, die niemand mehr braucht (`orphaned_at` gesetzt, bis zum Löschen in der Karenz), zählen nicht mit. */
export async function familyUsage(exec: Executor, familyId: string, quotaBytes: number): Promise<Usage> {
  const [b] = await exec
    .select({ n: count(), s: sql<string>`coalesce(sum(${dateiBlob.size}), 0)::text` })
    .from(dateiBlob)
    .where(and(eq(dateiBlob.familyId, familyId), isNull(dateiBlob.orphanedAt)));
  const [u] = await exec
    .select({ n: count(), s: sql<string>`coalesce(sum(${dateiUpload.length}), 0)::text` })
    .from(dateiUpload)
    .where(and(eq(dateiUpload.familyId, familyId), inArray(dateiUpload.status, ['open', 'finalizing'])));
  return { usedBytes: Number(b?.s ?? 0), reservedBytes: Number(u?.s ?? 0), quotaBytes, blobs: b?.n ?? 0, uploadsOpen: u?.n ?? 0 };
}
