// E2EE, Passkey-Sicherung (Schalter E2EE_PRF_BACKUP, Standard aus): der Personenschlüssel, verpackt mit einem Schlüssel aus der WebAuthn-PRF-Ausgabe EINES Passkeys.
// Der Server sieht die PRF-Ausgabe, den daraus abgeleiteten Schlüssel und den Klartext nie: der Blob ist für ihn undurchsichtiger Text, die Kennung des Passkeys
// (`credentialId`) ist öffentlich. Blob und Kennung erscheinen nie im Log oder Audit. Zeilen werden nie gelöscht, nur ersetzt (`superseded`) oder durch einen
// Schlüsselwechsel `stale` gesetzt (siehe rotateKeys in keys.ts); jede ersetzte oder veraltete Zeile bleibt über das Archiv (keys-archive.ts) abrufbar.
// Zustandsautomat wie bei der Passwort-Sicherung (keys-pw.ts): `PUT` legt nur `pending` an und lässt die bisherige Sicherung dieses Passkeys unberührt, erst die
// Bestätigung nach der Round-Trip-Probe der App macht sie atomar zur aktuellen.
import { and, eq, inArray, isNull } from 'drizzle-orm';
import { credentials, keyBackupsPrf, personKeys } from '../db/schema.js';
import { AppError } from '../errors.js';
import { writeAudit } from './audit.js';
import type { AuthContext, Executor, RequestMeta } from './context.js';
import { recordDebouncedEvent, recordSecurityEvent, viaOf, wakeAfterCommit, wakeTopics } from './security-events.js';
import { requireStepUp } from './sessions.js';
import type { SessionPrincipal } from './types.js';

const notFound = () => new AppError(404, 'not_found');

/** Eine noch nicht bestätigte Passkey-Sicherung verfällt (wird `superseded`, nie gelöscht) nach dieser Zeit (Aufräumjob). */
export const PRF_PENDING_TTL_MS = 3_600_000;

export interface PrfBackupInput {
  credentialId: string;
  blob: string;
  keyVersion: number;
}

/** Ist `credentialId` ein aktiver (nicht widerrufener) Passkey dieser Person? */
async function passkeyActive(exec: Executor, userId: string, credentialId: string): Promise<boolean> {
  const [c] = await exec
    .select({ id: credentials.id })
    .from(credentials)
    .where(and(eq(credentials.userId, userId), eq(credentials.type, 'passkey'), eq(credentials.externalId, credentialId), isNull(credentials.revokedAt)));
  return c !== undefined;
}

/**
 * Neue Passkey-Sicherung ablegen (Step-up). Sie muss zur aktuellen key_version gehören und zu einem aktiven Passkey der Person (sonst 409). Sie entsteht als `pending`;
 * die bisherige aktuelle Zeile dieses Passkeys (active/stale) bleibt UNBERÜHRT und gültig, bis die neue bestätigt ist. Eine eigene ältere pending-Zeile wird
 * `superseded`. In EINER Transaktion mit Audit; gleichzeitige Anfragen derselben Person laufen nacheinander (Sperre auf person_keys).
 */
export async function setPrfBackup(ctx: AuthContext, p: SessionPrincipal, input: PrfBackupInput, meta: RequestMeta): Promise<{ id: string }> {
  requireStepUp(ctx, p);
  return ctx.db.transaction(async (tx) => {
    const [k] = await tx.select({ v: personKeys.keyVersion }).from(personKeys).where(eq(personKeys.userId, p.userId)).for('update');
    if (!k) throw new AppError(409, 'no_keys', 'Du hast noch keinen Schlüssel eingerichtet.');
    if (k.v !== input.keyVersion) throw new AppError(409, 'key_version_mismatch', 'Die Schlüsselversion stimmt nicht mehr, bitte neu laden.');
    if (!(await passkeyActive(tx, p.userId, input.credentialId))) throw new AppError(409, 'passkey_unknown', 'Dieser Passkey gehört nicht (mehr) zu deinem Konto.');
    const now = ctx.now();
    await tx
      .update(keyBackupsPrf)
      .set({ state: 'superseded', updatedAt: now })
      .where(and(eq(keyBackupsPrf.userId, p.userId), eq(keyBackupsPrf.state, 'pending')));
    const [row] = await tx
      .insert(keyBackupsPrf)
      .values({ userId: p.userId, familyId: p.familyId, credentialId: input.credentialId, blob: input.blob, keyVersion: k.v, state: 'pending', createdAt: now, updatedAt: now })
      .returning({ id: keyBackupsPrf.id });
    if (!row) throw notFound();
    await writeAudit(ctx, tx, { event: 'key_backup_prf_set', familyId: p.familyId, actorId: p.userId, deviceId: p.deviceId, ip: meta.ip, detail: { keyVersion: k.v } });
    return row;
  });
}

export interface PrfBackupOut {
  id: string;
  credentialId: string;
  blob: string;
  keyVersion: number;
  state: 'pending' | 'active' | 'stale';
}

/**
 * Passkey-Sicherung zu EINEM Passkey abrufen (Step-up). Abruf und Audit stehen in einer Transaktion. Standard: die aktuelle (active/stale) Sicherung dieses Passkeys;
 * `pending`: die eigene noch unbestätigte für den Round-Trip der App (kein Sicherheitsereignis, das ist die App selbst). Der Abruf der aktuellen erzeugt das Sicherheitsereignis
 * `key_backup_prf_read` (höchstens eines je 10 Minuten) samt Wecker auf die anderen Geräte der Person. Nur Sicherungen zu AKTIVEN Passkeys der Person werden geliefert.
 */
export async function getPrfBackup(ctx: AuthContext, p: SessionPrincipal, credentialId: string, meta: RequestMeta, which: 'current' | 'pending' = 'current'): Promise<PrfBackupOut> {
  requireStepUp(ctx, p);
  const topics = which === 'current' ? await wakeTopics(ctx.db, p.userId, p.deviceId) : [];
  let recorded = false;
  const out = await ctx.db.transaction(async (tx): Promise<PrfBackupOut> => {
    if (!(await passkeyActive(tx, p.userId, credentialId))) throw notFound();
    const [b] = await tx
      .select({ id: keyBackupsPrf.id, blob: keyBackupsPrf.blob, keyVersion: keyBackupsPrf.keyVersion, state: keyBackupsPrf.state })
      .from(keyBackupsPrf)
      .where(
        and(
          eq(keyBackupsPrf.userId, p.userId),
          eq(keyBackupsPrf.credentialId, credentialId),
          which === 'pending' ? eq(keyBackupsPrf.state, 'pending') : inArray(keyBackupsPrf.state, ['active', 'stale']),
        ),
      );
    if (!b) throw notFound();
    await writeAudit(ctx, tx, { event: 'key_backup_prf_read', familyId: p.familyId, actorId: p.userId, deviceId: p.deviceId, ip: meta.ip, detail: { keyVersion: b.keyVersion, which } });
    if (which === 'current') recorded = await recordDebouncedEvent(ctx, tx, { familyId: p.familyId, userId: p.userId, kind: 'key_backup_prf_read', via: viaOf(p), actorId: p.userId });
    return { id: b.id, credentialId, blob: b.blob, keyVersion: b.keyVersion, state: b.state === 'stale' ? 'stale' : b.state === 'pending' ? 'pending' : 'active' };
  });
  if (recorded) wakeAfterCommit(ctx, p.familyId, p.userId, topics, { light: true });
  return out;
}

/**
 * Bestätigt die eigene Sicherung `id` (Step-up), erst nach der Round-Trip-Probe der App: in EINER Transaktion wird die bisherige aktuelle Zeile desselben Passkeys
 * (active/stale) `superseded` und die `pending`-Zeile `active` mit `verified_at`. Fremde oder unbekannte ID: 404; nicht (mehr) pending, verfallen, zu einer anderen
 * Schlüsselversion oder zu einem inzwischen widerrufenen Passkey gehörend: 409. Eine schon bestätigte aktuelle Zeile bestätigt erneut folgenlos (verlorene Antwort).
 */
export async function markPrfBackupVerified(ctx: AuthContext, p: SessionPrincipal, id: string, meta: RequestMeta): Promise<void> {
  requireStepUp(ctx, p);
  const topics = await wakeTopics(ctx.db, p.userId, p.deviceId);
  let promoted = false;
  await ctx.db.transaction(async (tx) => {
    const [k] = await tx.select({ v: personKeys.keyVersion }).from(personKeys).where(eq(personKeys.userId, p.userId)).for('update');
    const [row] = await tx
      .select({ state: keyBackupsPrf.state, keyVersion: keyBackupsPrf.keyVersion, verifiedAt: keyBackupsPrf.verifiedAt, credentialId: keyBackupsPrf.credentialId, createdAt: keyBackupsPrf.createdAt })
      .from(keyBackupsPrf)
      .where(and(eq(keyBackupsPrf.id, id), eq(keyBackupsPrf.userId, p.userId)))
      .for('update');
    if (!row) throw notFound();
    if (row.state === 'active' && row.verifiedAt) return;
    const abgelaufen = ctx.now().getTime() - row.createdAt.getTime() > PRF_PENDING_TTL_MS;
    if (row.state !== 'pending' || abgelaufen || !k || k.v !== row.keyVersion || !(await passkeyActive(tx, p.userId, row.credentialId))) {
      throw new AppError(409, 'backup_not_current', 'Diese Sicherung ist nicht mehr aktuell.');
    }
    const now = ctx.now();
    await tx
      .update(keyBackupsPrf)
      .set({ state: 'superseded', updatedAt: now })
      .where(and(eq(keyBackupsPrf.userId, p.userId), eq(keyBackupsPrf.credentialId, row.credentialId), inArray(keyBackupsPrf.state, ['active', 'stale'])));
    const rows = await tx
      .update(keyBackupsPrf)
      .set({ state: 'active', verifiedAt: now, updatedAt: now })
      .where(and(eq(keyBackupsPrf.id, id), eq(keyBackupsPrf.userId, p.userId), eq(keyBackupsPrf.state, 'pending')))
      .returning({ keyVersion: keyBackupsPrf.keyVersion });
    if (!rows[0]) throw new AppError(409, 'backup_not_current', 'Diese Sicherung ist nicht mehr aktuell.');
    await writeAudit(ctx, tx, { event: 'key_backup_prf_verified', familyId: p.familyId, actorId: p.userId, deviceId: p.deviceId, ip: meta.ip, detail: { keyVersion: rows[0].keyVersion } });
    // eine neue Sicherung ist ein Ereignis für die Person: die anderen Geräte erfahren es (ohne Inhalt)
    await recordSecurityEvent(ctx, tx, { familyId: p.familyId, userId: p.userId, kind: 'key_backup_prf_set', via: viaOf(p), actorId: p.userId });
    promoted = true;
  });
  if (promoted) wakeAfterCommit(ctx, p.familyId, p.userId, topics, { light: true });
}

/** Zustand der Passkey-Sicherungen der Person für `GET /me/keys` (nur Zeiten und öffentliche Kennungen, nie Blobs). */
export async function prfBackupStatus(
  exec: Executor,
  userId: string,
  currentVersion: number | null,
): Promise<{ verifiedAt: Date | null; credentialIds: string[]; stale: boolean; synced: boolean }> {
  const rows = await exec
    .select({ credentialId: keyBackupsPrf.credentialId, keyVersion: keyBackupsPrf.keyVersion, state: keyBackupsPrf.state, verifiedAt: keyBackupsPrf.verifiedAt, deviceType: credentials.deviceType, backedUp: credentials.backedUp })
    .from(keyBackupsPrf)
    .innerJoin(
      credentials,
      and(eq(credentials.userId, keyBackupsPrf.userId), eq(credentials.type, 'passkey'), eq(credentials.externalId, keyBackupsPrf.credentialId), isNull(credentials.revokedAt)),
    )
    .where(and(eq(keyBackupsPrf.userId, userId), inArray(keyBackupsPrf.state, ['active', 'stale'])));
  const gut = rows.filter((r) => r.state === 'active' && currentVersion !== null && r.keyVersion === currentVersion && r.verifiedAt !== null);
  const verifiedAt = gut.reduce<Date | null>((m, r) => (r.verifiedAt && (!m || r.verifiedAt > m) ? r.verifiedAt : m), null);
  // "synced": mindestens ein bestätigter Passkey ist laut Authenticator synchronisiert (BE und BS: multiDevice und gesichert): nur dann ist die Sicherung auch ohne dieses Gerät erreichbar
  return { verifiedAt, credentialIds: gut.map((r) => r.credentialId), stale: rows.some((r) => r.state === 'stale'), synced: gut.some((r) => r.deviceType === 'multiDevice' && r.backedUp === true) };
}
