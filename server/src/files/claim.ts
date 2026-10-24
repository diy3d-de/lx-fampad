// Beanspruchen von Blobs durch Sync-Datensätze (Registry-Haken `claim`, Abschnitt 6n).
//
// Ein hochgeladener Blob (Zustand `ready`) gehört vorerst nur der hochladenden Person. Legt sie einen Datensatz an, der ihn braucht (Datei-Fassung, Tresor-Anhang), beansprucht die Engine
// ihn INNERHALB der Sync-Transaktion mit einem einzigen `UPDATE … RETURNING`: nur wenn der Blob derselben Familie gehört, von dieser Person stammt, noch frei ist und zu Modus und
// Art passt. Zwei gleichzeitige Beanspruchungen können nie beide gewinnen (die Zeile ist gesperrt, die zweite sieht `claimed`). Scheitert eine Beanspruchung, werden die schon
// erfolgten dieser Op wieder freigegeben (die abgelehnte Op wird trotzdem festgeschrieben, ihre Beanspruchung darf nicht bleiben).
// Danach hängt die Lesberechtigung des Blobs am Datensatz (`claim_entity`/`claim_id`): lesen darf ihn nur, wer den Datensatz lesen darf.
import { and, eq, inArray } from 'drizzle-orm';
import type { Executor } from '../auth/context.js';
import { dateiBlob } from '../db/schema.js';

export type BlobModus = 'server' | 'e2ee';
export type BlobKind = 'datei' | 'thumb' | 'opak';

export interface ClaimedBlob {
  id: string;
  size: number;
  sha256: string;
  mime: string | null;
}

/** Beschreibung eines Feldes, das einen Blob beansprucht (Registry-Haken `claim`). */
export interface ClaimField {
  field: string;
  modus: BlobModus;
  kind: BlobKind;
}

export interface ClaimWish {
  field: string;
  blobId: string;
  modus: BlobModus;
  kind: BlobKind;
}

/** Beansprucht alle genannten Blobs für den Datensatz oder keinen (null). */
export async function claimBlobs(
  tx: Executor,
  who: { familyId: string; userId: string; entity: string; entityId: string; now: Date },
  wishes: readonly ClaimWish[],
): Promise<Map<string, ClaimedBlob> | null> {
  const out = new Map<string, ClaimedBlob>();
  for (const w of wishes) {
    const [row] = await tx
      .update(dateiBlob)
      .set({ state: 'claimed', claimEntity: who.entity, claimId: who.entityId, claimedAt: who.now, orphanedAt: null })
      .where(
        and(
          eq(dateiBlob.familyId, who.familyId),
          eq(dateiBlob.id, w.blobId),
          eq(dateiBlob.state, 'ready'),
          eq(dateiBlob.uploaderId, who.userId),
          eq(dateiBlob.modus, w.modus),
          eq(dateiBlob.kind, w.kind),
        ),
      )
      .returning({ id: dateiBlob.id, size: dateiBlob.size, sha256: dateiBlob.sha256, mime: dateiBlob.mime });
    if (!row) {
      await releaseClaims(tx, who.familyId, [...out.values()].map((b) => b.id));
      return null;
    }
    out.set(w.field, row);
  }
  return out;
}

/** Gibt genau diese Blobs wieder frei (zurück auf `ready`); nur für das Zurückrollen einer Op, die nach dem Beanspruchen noch scheiterte (nie für die Blobs eines vorhandenen Datensatzes). */
export async function releaseClaims(tx: Executor, familyId: string, blobIds: readonly string[]): Promise<void> {
  if (blobIds.length === 0) return;
  await tx
    .update(dateiBlob)
    .set({ state: 'ready', claimEntity: null, claimId: null, claimedAt: null })
    .where(and(eq(dateiBlob.familyId, familyId), inArray(dateiBlob.id, [...blobIds]), eq(dateiBlob.state, 'claimed')));
}
