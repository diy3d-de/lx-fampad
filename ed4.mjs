import fs from 'node:fs';
function edit(file, pairs) {
  let s = fs.readFileSync(file, 'utf8');
  for (const [a, b] of pairs) {
    if (!s.includes(a)) throw new Error('fehlt in ' + file + ': ' + a.slice(0, 60));
    s = s.replace(a, b);
  }
  fs.writeFileSync(file, s);
}
edit('src/operator/status.ts', [
  ["migrations: { applied: number | null; expected: number | null; latest: string | null; pending: boolean | null };",
   "migrations: { applied: number | null; expected: number | null; latest: string | null; pending: boolean | null; grantMissing: boolean };"],
  ["  overall: 'ok' | 'warn' | 'error';\n", "  overall: 'ok' | 'warn' | 'error';\n  /** Anzahl der Quellen ohne Messwert (nicht lesbar): \"in Ordnung\" gilt nur für das, was gemessen wurde. */\n  unknownCount: number;\n"],
  ["  let applied: number | null = null;\n", "  let applied: number | null = null;\n  let grantMissing = false;\n"],
  ["    } catch {\n      applied = null;\n    }\n  }\n  const exp",
   "    } catch (err) {\n      applied = null;\n      grantMissing = isPermissionDenied(err);\n    }\n  }\n  const exp"],
  ["    pending: exp && applied !== null ? applied < exp.count : null,\n", "    pending: exp && applied !== null ? applied < exp.count : null,\n    grantMissing,\n"],
  ["readText(oc.releaseManifestFile, 16 * 1024)", "readText(oc.releaseManifestFile, 64 * 1024)"],
  ["  const overall = levels.includes('error') ? 'error' : levels.includes('warn') ? 'warn' : 'ok';\n",
   "  const overall = levels.includes('error') ? 'error' : levels.includes('warn') ? 'warn' : 'ok';\n  const unknownCount = levels.filter((l) => l === 'unknown').length + (migrations.applied === null ? 1 : 0);\n"],
  ["    overall,\n    server: {", "    overall,\n    unknownCount,\n    server: {"],
  ["/** Anzahl und letzter Eintrag", "/** PostgreSQL 42501 (insufficient_privilege), auch wenn der Treiber den Fehler als Ursache einpackt. */\nfunction isPermissionDenied(err: unknown): boolean {\n  for (let e: unknown = err, i = 0; e && typeof e === 'object' && i < 4; i++) {\n    if ((e as { code?: unknown }).code === '42501') return true;\n    e = (e as { cause?: unknown }).cause;\n  }\n  return false;\n}\n\n/** Anzahl und letzter Eintrag"],
]);
edit('src/operator/probes.ts', [
  ["      const socket = connect({ host, port, servername, rejectUnauthorized: false }, () => {\n        const end = new Date(socket.getPeerCertificate().valid_to);\n        finish(Number.isNaN(end.getTime()) ? null : end);\n      });\n      const timer = setTimeout(() => finish(null), TIMEOUT_MS);\n      socket.on('error', () => finish(null));",
   "      let socket: ReturnType<typeof connect>;\n      try {\n        socket = connect({ host, port, servername, rejectUnauthorized: false }, () => {\n          const end = new Date(socket.getPeerCertificate().valid_to);\n          finish(Number.isNaN(end.getTime()) ? null : end);\n        });\n      } catch {\n        // z. B. ungültiger Port oder Host: nie werfen, nur \"unbekannt\"\n        resolve(null);\n        return;\n      }\n      timer = setTimeout(() => finish(null), TIMEOUT_MS);\n      socket.on('error', () => finish(null));"],
  ["      let done = false;\n", "      let done = false;\n      let timer: NodeJS.Timeout | undefined;\n"],
  ["        clearTimeout(timer);\n        socket.destroy();", "        clearTimeout(timer);\n        socket?.destroy();"],
]);
edit('src/config.ts', [
  ["throw new Error('OPERATOR_TLS_PROBE ungültig (Format host:port oder off)');", "throw new Error('OPERATOR_TLS_PROBE ungültig (Format host:port oder off)');\n  if (tlsProbe !== undefined && Number(tlsProbe.slice(tlsProbe.lastIndexOf(':') + 1)) > 65535) throw new Error('OPERATOR_TLS_PROBE ungültig (Port höchstens 65535)');"],
]);
edit('src/operator/audit-view.ts', [
  ["const LOGIN_EVENTS = ['login_ok',", "const LOGIN_EVENTS = ['session_refresh_retry', 'invite_expired', 'key_backup_read', 'key_backup_pw_read', 'login_ok',"],
  ["import { auditLog, users } from '../db/schema.js';", "import { auditLog, memberships, users } from '../db/schema.js';"],
  ["    .leftJoin(users, eq(users.id, auditLog.actorId))\n", "    .leftJoin(users, eq(users.id, auditLog.actorId))\n    // Name nur, wenn die Person Mitglied der Familie der Sitzung ist (sonst erscheint der Eintrag ohne Person)\n    .leftJoin(memberships, and(eq(memberships.userId, auditLog.actorId), eq(memberships.familyId, familyId)))\n"],
  ["      actorName: users.displayName,\n", "      actorName: sql<string | null>`case when ${memberships.id} is null then null else ${users.displayName} end`,\n"],
]);
