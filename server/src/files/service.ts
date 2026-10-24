// Dateiablage: Uploads (tus-Teilprotokoll), Kontingent, Finalisieren und Auslieferung (Abschnitt 6n).
//
// Zwei Modi über dieselbe Mechanik (Upload, Kontingent, Auslieferung):
//  - `server`: der Server prüft die Magic-Bytes, rechnet die SHA-256 und legt die Datei blockweise AES-256-GCM-verschlüsselt ab (crypto.ts). Er kennt Name, Typ und Inhalt.
//  - `e2ee`:   der Client liefert schon verschlüsselte Bytes. Der Server speichert sie undurchsichtig (kein Typ, kein Name, kein Schlüssel, keine Magic-Byte-Prüfung, kein Vorschaubild),
//              kennt nur Größe und die SHA-256 der übertragenen Bytes.
// Wer einen Blob lesen darf, entscheidet der Datensatz, der ihn beansprucht hat (Registry-Haken `claim`, claim.ts): nie eine Rolle allein. Ein noch nicht beanspruchter Blob
// gehört nur der hochladenden Person. Jede fehlende Sicht ist ein 404.
import { createHash, randomUUID } from 'node:crypto';
import { and, count, eq, gt, inArray, sql } from 'drizzle-orm';
import { open } from 'node:fs/promises';
import { Readable } from 'node:stream';
import type { AuthContext, Executor } from '../auth/context.js';
import type { Role } from '../auth/types.js';
import { FILES_THUMB_MAX_BYTES } from '../config.js';
import { dateiBlob, dateien, dateiUpload } from '../db/schema.js';
import { inspectImage } from '../avatar/image.js';
import { AppError } from '../errors.js';
import { factsOf, loadRow } from '../sync/engine.js';
import { mayRead } from '../sync/permissions.js';
import type { Registry } from '../sync/registry.js';
import type { BlobKind, BlobModus } from './claim.js';
import { decryptRange, encryptFile, encryptedSize, newBlobKey, unwrapKey, wrapKey, WRAP_KID } from './crypto.js';
import { cleanMime, decideMime } from './names.js';
import { familyUsage, type Usage } from './usage.js';
import { FileStore, Serial } from './store.js';

export interface FilesPrincipal {
  userId: string;
  familyId: string;
  role: Role;
}

/** Austauschbare Teile (nur Tests): freier Platz und ein Haken nach dem Umbenennen, um Unterbrechungen nachzustellen. */
export interface FilesDeps {
  freeBytes?: () => Promise<number>;
  afterInstall?: (blobId: string) => Promise<void> | void;
}

export type UploadRow = typeof dateiUpload.$inferSelect;
export type BlobRow = typeof dateiBlob.$inferSelect;

export const UPLOAD_TTL_MS = 24 * 3_600_000;
export const MAX_UPLOADS_PER_USER = 3;
export const MAX_UPLOADS_PER_FAMILY = 6;
export const MAX_CREATES_PER_HOUR = 30;
/** Schlüssel der Sperre, die Kontingent und Mengenbegrenzung beim Anlegen eines Uploads serialisiert (alle Familien: Staging ist global). */
const QUOTA_LOCK = 7_364_201;

const gone = () => new AppError(404, 'not_found');

export class FilesService {
  readonly store: FileStore;
  private readonly serial = new Serial();
  private readonly busy = new Set<string>();

  constructor(
    private readonly ctx: Pick<AuthContext, 'db' | 'config' | 'keys' | 'now' | 'log'>,
    private readonly registry: Registry,
    private readonly deps: FilesDeps = {},
  ) {
    this.store = new FileStore(ctx.config.filesDir);
  }

  get enabled(): boolean {
    return this.ctx.config.files.enabled;
  }

  private get db() {
    return this.ctx.db;
  }

  // ------------------------------------------------------------ Kontingent

  /** Belegter und reservierter Platz einer Familie (Blobs, die niemand mehr braucht, zählen nicht). */
  usage(familyId: string, exec: Executor = this.db): Promise<Usage> {
    return familyUsage(exec, familyId, this.ctx.config.files.quotaBytes);
  }

  // ------------------------------------------------------------ Upload anlegen

  async createUpload(p: FilesPrincipal, input: { length: number; modus: BlobModus; kind: BlobKind; mime: string | null }): Promise<UploadRow> {
    const cfg = this.ctx.config.files;
    const now = this.ctx.now();
    const limit = input.modus === 'e2ee' ? cfg.maxE2eeBytes : cfg.maxBytes;
    if (input.length > limit) throw new AppError(413, 'file_too_large', 'Die Datei ist zu groß.');
    if (input.kind === 'thumb' && input.length > FILES_THUMB_MAX_BYTES) throw new AppError(413, 'file_too_large', 'Das Vorschaubild ist zu groß.');
    if (input.modus === 'e2ee' && input.length < 1) throw new AppError(400, 'invalid_request');
    // Platz auf dem Datenträger zuerst (ohne Sperre): zu wenig frei = keine neuen Uploads
    const free = await (this.deps.freeBytes ?? (() => this.store.freeBytes()))();
    if (free < cfg.minFreeBytes + input.length) throw new AppError(507, 'insufficient_storage', 'Auf dem Server ist gerade nicht genug Platz frei.');
    const id = randomUUID();
    const row = await this.db.transaction(async (tx) => {
      await tx.execute(sql`select pg_advisory_xact_lock(${QUOTA_LOCK})`);
      const [mine] = await tx
        .select({ n: count() })
        .from(dateiUpload)
        .where(and(eq(dateiUpload.uploaderId, p.userId), inArray(dateiUpload.status, ['open', 'finalizing']), gt(dateiUpload.expiresAt, now)));
      if ((mine?.n ?? 0) >= MAX_UPLOADS_PER_USER) throw new AppError(429, 'too_many_uploads', 'Es laufen schon mehrere Uploads. Bitte warte, bis sie fertig sind.', { 'retry-after': '30' });
      const [fam] = await tx
        .select({ n: count() })
        .from(dateiUpload)
        .where(and(eq(dateiUpload.familyId, p.familyId), inArray(dateiUpload.status, ['open', 'finalizing']), gt(dateiUpload.expiresAt, now)));
      if ((fam?.n ?? 0) >= MAX_UPLOADS_PER_FAMILY) throw new AppError(429, 'too_many_uploads', 'In der Familie laufen schon mehrere Uploads. Bitte gleich erneut versuchen.', { 'retry-after': '30' });
      const hour = new Date(now.getTime() - 3_600_000);
      const [made] = await tx
        .select({ n: count() })
        .from(dateiUpload)
        .where(and(eq(dateiUpload.uploaderId, p.userId), gt(dateiUpload.createdAt, hour)));
      if ((made?.n ?? 0) >= MAX_CREATES_PER_HOUR) throw new AppError(429, 'rate_limited', 'Zu viele Uploads in kurzer Zeit. Bitte später erneut versuchen.', { 'retry-after': '600' });
      if (p.role === 'child') {
        for (const [span, max] of [
          [3_600_000, cfg.childBytesPerHour],
          [86_400_000, cfg.childBytesPerDay],
        ] as const) {
          const [used] = await tx
            .select({ s: sql<string>`coalesce(sum(${dateiUpload.length}), 0)::text` })
            .from(dateiUpload)
            .where(and(eq(dateiUpload.uploaderId, p.userId), gt(dateiUpload.createdAt, new Date(now.getTime() - span)), sql`${dateiUpload.status} <> 'aborted'`));
          if (Number(used?.s ?? 0) + input.length > max) throw new AppError(429, 'rate_limited', 'Du hast gerade schon viel hochgeladen. Bitte später erneut versuchen.', { 'retry-after': '1800' });
        }
      }
      const u = await this.usage(p.familyId, tx);
      if (u.usedBytes + u.reservedBytes + input.length > cfg.quotaBytes) throw new AppError(413, 'quota_exceeded', 'Der Speicher der Familie ist voll.');
      const [staging] = await tx
        .select({ s: sql<string>`coalesce(sum(${dateiUpload.length}), 0)::text` })
        .from(dateiUpload)
        .where(inArray(dateiUpload.status, ['open', 'finalizing']));
      if (Number(staging?.s ?? 0) + input.length > cfg.stagingMaxBytes) throw new AppError(503, 'staging_full', 'Der Server nimmt gerade keine weiteren Uploads an. Bitte später erneut versuchen.', { 'retry-after': '120' });
      const [ins] = await tx
        .insert(dateiUpload)
        .values({
          id,
          familyId: p.familyId,
          uploaderId: p.userId,
          modus: input.modus,
          kind: input.kind,
          declaredMime: input.modus === 'server' ? input.mime : null,
          length: input.length,
          offset: 0,
          status: 'open',
          createdAt: now,
          updatedAt: now,
          expiresAt: new Date(now.getTime() + UPLOAD_TTL_MS),
        })
        .returning();
      if (!ins) throw new Error('Upload nicht angelegt');
      return ins;
    });
    try {
      await this.store.createPart(id);
    } catch (err) {
      await this.db.delete(dateiUpload).where(eq(dateiUpload.id, id));
      throw err;
    }
    return row;
  }

  // ------------------------------------------------------------ Upload lesen und fortsetzen

  /** Der eigene, noch gültige Upload (alles andere ist ein 404: auch ein Upload einer anderen Person derselben Familie). */
  async ownUpload(p: FilesPrincipal, id: string): Promise<UploadRow> {
    const [row] = await this.db
      .select()
      .from(dateiUpload)
      .where(and(eq(dateiUpload.id, id), eq(dateiUpload.familyId, p.familyId), eq(dateiUpload.uploaderId, p.userId)))
      .limit(1);
    if (!row || row.status === 'aborted') throw gone();
    if ((row.status === 'open' || row.status === 'finalizing') && row.expiresAt <= this.ctx.now() && !this.busy.has(id)) {
      await this.abort(row);
      throw gone();
    }
    return row;
  }

  /** HEAD: Stand des Uploads; ein beim Abschluss unterbrochener Upload wird dabei erneut abgeschlossen. */
  async head(p: FilesPrincipal, id: string): Promise<UploadRow> {
    let row = await this.ownUpload(p, id);
    if (row.status === 'finalizing' && !this.busy.has(id)) {
      try {
        await this.finalize(row);
      } catch (err) {
        if (!(err instanceof AppError)) this.ctx.log.warn({ err }, 'Upload: Abschluss fehlgeschlagen');
      }
      row = await this.ownUpload(p, id);
    }
    return row;
  }

  /** Hängt einen Abschnitt an (PATCH). Gibt den neuen Stand zurück; `blob` ist gesetzt, wenn der Upload damit abgeschlossen wurde. */
  async append(p: FilesPrincipal, id: string, offset: number, body: Buffer): Promise<{ upload: UploadRow; blob?: BlobRow }> {
    const row = await this.ownUpload(p, id);
    if (row.status === 'done') throw new AppError(409, 'upload_done', 'Der Upload ist schon abgeschlossen.');
    if (offset !== row.offset) throw new AppError(409, 'offset_mismatch', 'Der Upload steht an einer anderen Stelle.', { 'upload-offset': String(row.offset) });
    if (row.status === 'finalizing') {
      // abgeschlossen, aber noch nicht fertig verarbeitet (z. B. unterbrochen): nur ein leerer Abschnitt löst den erneuten Abschluss aus
      if (body.length > 0) throw new AppError(409, 'offset_mismatch', 'Der Upload steht an einer anderen Stelle.', { 'upload-offset': String(row.offset) });
      const blob = await this.finalize(row);
      return { upload: await this.ownUpload(p, id), blob };
    }
    if (offset + body.length > row.length) throw new AppError(413, 'file_too_large', 'Es kamen mehr Bytes an, als angekündigt waren.');
    if (this.busy.has(id)) throw new AppError(423, 'locked', 'Der Upload wird gerade bearbeitet.');
    this.busy.add(id);
    try {
      if (body.length > 0) await this.store.writePart(id, offset, body);
      const newOffset = offset + body.length;
      const complete = newOffset === row.length;
      const [updated] = await this.db
        .update(dateiUpload)
        .set({ offset: newOffset, status: complete ? 'finalizing' : 'open', updatedAt: this.ctx.now() })
        .where(and(eq(dateiUpload.id, id), eq(dateiUpload.status, 'open'), eq(dateiUpload.offset, offset)))
        .returning();
      if (!updated) throw new AppError(409, 'offset_mismatch', 'Der Upload steht an einer anderen Stelle.');
      if (!complete) return { upload: updated };
      const blob = await this.finalize(updated);
      return { upload: await this.ownUpload(p, id), blob };
    } finally {
      this.busy.delete(id);
    }
  }

  /** Beendet einen Upload (tus „termination“); ein fertiger, aber noch nicht beanspruchter Blob verschwindet mit. */
  async terminate(p: FilesPrincipal, id: string): Promise<void> {
    const row = await this.ownUpload(p, id);
    if (row.status === 'done') {
      const [freed] = await this.db
        .delete(dateiBlob)
        .where(and(eq(dateiBlob.id, id), eq(dateiBlob.familyId, p.familyId), eq(dateiBlob.state, 'ready')))
        .returning({ id: dateiBlob.id });
      if (!freed) throw new AppError(409, 'upload_claimed', 'Die Datei wird schon verwendet.');
      await this.store.remove(this.store.blobPath(id));
    } else if (this.busy.has(id)) {
      throw new AppError(423, 'locked', 'Der Upload wird gerade bearbeitet.');
    }
    await this.abort(row);
  }

  /** Verwirft einen Upload: Staging-Datei weg, Zeile bleibt als `aborted` (zählt für die Mengenbegrenzung) bis zum Aufräumen. */
  async abort(row: UploadRow): Promise<void> {
    await this.db.update(dateiUpload).set({ status: 'aborted', updatedAt: this.ctx.now() }).where(eq(dateiUpload.id, row.id));
    await this.store.remove(this.store.partPath(row.id));
    await this.store.remove(this.store.encPath(row.id));
  }

  // ------------------------------------------------------------ Abschluss

  /**
   * Schließt einen vollständig übertragenen Upload ab (immer einzeln: Parallelität 1). Modus `server`: Magic-Bytes bzw. Bildprüfung, SHA-256, Blockverschlüsselung;
   * Modus `e2ee`: nur SHA-256 der Bytes. Danach fsync, atomares Umbenennen und in EINER Transaktion Blob-Zeile + Upload `done`. Bei Unterbrechung bleibt der Upload `finalizing`
   * (Staging-Datei bleibt, die halbfertige Zieldatei wird entfernt) und lässt sich über HEAD oder einen leeren PATCH erneut abschließen.
   */
  finalize(row: UploadRow): Promise<BlobRow> {
    return this.serial.run(() => this.finalizeNow(row.id));
  }

  private async finalizeNow(id: string): Promise<BlobRow> {
    const [row] = await this.db.select().from(dateiUpload).where(eq(dateiUpload.id, id)).limit(1);
    if (!row || row.status === 'aborted') throw gone();
    const [existing] = await this.db.select().from(dateiBlob).where(eq(dateiBlob.id, id)).limit(1);
    if (row.status === 'done' && existing) return existing;
    if (row.status !== 'finalizing' || row.offset !== row.length) throw new AppError(409, 'upload_not_complete', 'Der Upload ist noch nicht vollständig.');
    const part = this.store.partPath(id);
    const enc = this.store.encPath(id);
    const modus = row.modus as BlobModus;
    const kind = row.kind as BlobKind;
    if ((await this.store.sizeOf(part)) !== row.length) {
      await this.abort(row);
      throw new AppError(500, 'upload_corrupt', 'Der Upload ist beschädigt. Bitte noch einmal hochladen.');
    }
    // halbfertige Reste eines früheren Versuchs
    await this.store.remove(enc);
    const reject = async (status: number, code: string, message: string): Promise<never> => {
      await this.abort(row);
      throw new AppError(status, code, message);
    };
    let sha256: string;
    let mime: string | null = null;
    let diskSize: number;
    let wrapped: Buffer | null = null;
    let from: string;
    if (modus === 'e2ee') {
      // undurchsichtig: nur die Prüfsumme der übertragenen Bytes
      sha256 = await hashFile(part);
      diskSize = row.length;
      from = part;
    } else {
      const head = await readHead(part, row.length, kind === 'thumb' ? row.length : 512);
      if (kind === 'thumb') {
        const info = inspectImage(head);
        if (!info) return reject(422, 'invalid_file', 'Das Vorschaubild ist kein gültiges Bild.');
        mime = info.mime;
      } else {
        mime = decideMime(row.declaredMime, head);
        if (mime === null) return reject(422, 'mime_mismatch', 'Der Dateityp passt nicht zum Inhalt.');
      }
      const key = newBlobKey();
      sha256 = await encryptFile(part, enc, key, id, row.length);
      diskSize = encryptedSize(row.length);
      wrapped = wrapKey(this.ctx.keys, id, key, WRAP_KID);
      from = enc;
    }
    try {
      await this.store.install(id, from);
      await this.deps.afterInstall?.(id);
      const now = this.ctx.now();
      const blob = await this.db.transaction(async (tx) => {
        const [done] = await tx
          .update(dateiUpload)
          .set({ status: 'done', updatedAt: now })
          .where(and(eq(dateiUpload.id, id), eq(dateiUpload.status, 'finalizing')))
          .returning({ id: dateiUpload.id });
        if (!done) throw new AppError(404, 'not_found');
        const [ins] = await tx
          .insert(dateiBlob)
          .values({
            id,
            familyId: row.familyId,
            uploaderId: row.uploaderId,
            modus,
            kind,
            size: row.length,
            diskSize,
            sha256,
            mime,
            dekWrap: wrapped,
            kid: wrapped ? WRAP_KID : null,
            state: 'ready',
            createdAt: now,
          })
          .returning();
        if (!ins) throw new Error('Blob nicht angelegt');
        return ins;
      });
      await this.store.remove(part);
      return blob;
    } catch (err) {
      // die fertige Datei wieder entfernen: ohne Zeile in der Datenbank wäre sie eine Waise (der Upload bleibt abschließbar)
      await this.store.remove(this.store.blobPath(id)).catch(() => undefined);
      if (modus === 'server') await this.store.remove(enc).catch(() => undefined);
      if (err instanceof AppError) throw err;
      this.ctx.log.error({ err }, 'Upload: Abschluss fehlgeschlagen');
      throw new AppError(503, 'finalize_failed', 'Der Upload konnte nicht abgeschlossen werden. Bitte gleich erneut versuchen.', { 'retry-after': '5' });
    }
  }

  // ------------------------------------------------------------ Auslieferung

  /**
   * Darf die Person den Blob lesen? Ein beanspruchter Blob folgt dem Datensatz, der ihn beansprucht hat (lebt, Rechte-Regeltabelle und Teilnehmer-Grenze der Entität);
   * ein freier nur der hochladenden Person. Alles andere ergibt null (404). Liefert auch den Anzeigenamen der Datei (nur Modus `server`).
   */
  async authorizeRead(p: FilesPrincipal, blobId: string): Promise<{ blob: BlobRow; filename: string | null } | null> {
    const [blob] = await this.db
      .select()
      .from(dateiBlob)
      .where(and(eq(dateiBlob.id, blobId), eq(dateiBlob.familyId, p.familyId)))
      .limit(1);
    if (!blob) return null;
    if (blob.state === 'ready') return blob.uploaderId === p.userId ? { blob, filename: null } : null;
    const def = blob.claimEntity ? this.registry.get(blob.claimEntity) : undefined;
    if (!def || !blob.claimId) return null;
    const env = { tx: this.db as Executor, registry: this.registry, familyId: p.familyId };
    const row = await loadRow(env.tx, def, p.familyId, blob.claimId);
    if (!row || row.deletedAt) return null;
    if (!mayRead(def.rules, { userId: p.userId, role: p.role }, await factsOf(env, def, row))) return null;
    let filename: string | null = null;
    if (blob.claimEntity === 'datei_version' && blob.kind === 'datei') {
      const [d] = await this.db
        .select({ name: dateien.name })
        .from(dateien)
        .where(and(eq(dateien.familyId, p.familyId), eq(dateien.id, String(row.dateiId))))
        .limit(1);
      filename = d?.name ?? null;
    }
    return { blob, filename };
  }

  /** Bytes [start, end] des Blobs (Modus `server` blockweise entschlüsselt, Modus `e2ee` unverändert). */
  readRange(blob: BlobRow, start: number, end: number): Readable {
    const path = this.store.blobPath(blob.id);
    if (blob.modus === 'e2ee') return Readable.from(rawRange(path, start, end));
    if (!blob.dekWrap || blob.kid === null) throw new Error('Schlüssel fehlt');
    const key = unwrapKey(this.ctx.keys, blob.id, blob.dekWrap, blob.kid);
    return Readable.from(decryptRange(path, key, blob.id, blob.size, start, end));
  }
}

// ---------------------------------------------------------------- Hilfen

async function hashFile(path: string): Promise<string> {
  const hash = createHash('sha256');
  const fh = await open(path, 'r');
  try {
    const buf = Buffer.alloc(1024 * 1024);
    for (let pos = 0; ; ) {
      const { bytesRead } = await fh.read(buf, 0, buf.length, pos);
      if (bytesRead === 0) break;
      hash.update(buf.subarray(0, bytesRead));
      pos += bytesRead;
    }
  } finally {
    await fh.close();
  }
  return hash.digest('hex');
}

async function readHead(path: string, size: number, want: number): Promise<Buffer> {
  const n = Math.min(size, want);
  const buf = Buffer.alloc(n);
  if (n === 0) return buf;
  const fh = await open(path, 'r');
  try {
    let got = 0;
    while (got < n) {
      const { bytesRead } = await fh.read(buf, got, n - got, got);
      if (bytesRead === 0) break;
      got += bytesRead;
    }
    return buf.subarray(0, got);
  } finally {
    await fh.close();
  }
}

async function* rawRange(path: string, start: number, end: number): AsyncGenerator<Buffer> {
  const fh = await open(path, 'r');
  try {
    for (let pos = start; pos <= end; ) {
      const buf = Buffer.alloc(Math.min(65_536, end - pos + 1));
      const { bytesRead } = await fh.read(buf, 0, buf.length, pos);
      if (bytesRead === 0) throw new Error('Datei zu kurz');
      yield buf.subarray(0, bytesRead);
      pos += bytesRead;
    }
  } finally {
    await fh.close();
  }
}

export { cleanMime };
