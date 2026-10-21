import fs from 'node:fs';
const f='test/operator.test.ts'; let s=fs.readFileSync(f,'utf8');
const rep=(a,b)=>{ if(!s.includes(a)) throw new Error('fehlt: '+a.slice(0,50)); s=s.replace(a,b); };
rep("      return (await a.client.get('/api/v1/admin/status')).json;\n    };","      world.advance(16_000); // Status-Cache (15 s) ablaufen lassen\n      return (await a.client.get('/api/v1/admin/status')).json;\n    };");
rep("    expect(categoryOf('role_changed')).toBe('aenderungen');","    expect(categoryOf('role_changed')).toBe('aenderungen');\n    expect(categoryOf('session_refresh_retry')).toBe('anmeldung');\n    expect(categoryOf('key_backup_read')).toBe('anmeldung');");
rep("import { eq } from 'drizzle-orm';","import { eq, sql } from 'drizzle-orm';\nimport { readFileSync } from 'node:fs';\nimport { loadConfig } from '../src/config.js';\nimport { realProbes } from '../src/operator/probes.js';");
rep("  describe('Protokoll', () => {", `  it('Status: Migrationsstand wird gelesen, ausstehende Migration erkannt, fehlende Leserechte heißen "unbekannt" mit Hinweis', async () => {
    const { a } = await familie();
    const m1 = (await a.client.get('/api/v1/admin/status')).json.database.migrations;
    expect(m1.applied).toBe(m1.expected);
    expect(m1).toMatchObject({ pending: false, grantMissing: false, latest: expect.stringMatching(/^\d{4}_/) });
    // letzte Migration "zurücknehmen": ausstehend
    await world.db.execute(sql\`delete from drizzle.__drizzle_migrations where id = (select max(id) from drizzle.__drizzle_migrations)\`);
    world.advance(16_000);
    const m2 = (await a.client.get('/api/v1/admin/status')).json.database.migrations;
    expect(m2).toMatchObject({ applied: m1.applied - 1, pending: true });
    // die Laufzeitrolle ohne Grant: Stand unbekannt, Hinweis grantMissing (kein 500)
    await world.db.execute(sql.raw('drop role if exists lx_rt_test'));
    await world.db.execute(sql.raw('create role lx_rt_test nosuperuser'));
    const lesen = (grant: boolean) =>
      world.db.transaction(async (tx) => {
        if (grant) {
          // genau die Anweisungen aus deploy/einrichtung-auth.sh
          const skript = readFileSync(new URL('../../deploy/einrichtung-auth.sh', import.meta.url), 'utf8');
          for (const m of skript.matchAll(/^\s+(GRANT [^;]+);$/gm)) if (m[1]!.includes('drizzle')) await tx.execute(sql.raw(m[1]!.replaceAll('$RUNTIME_ROLE', 'lx_rt_test')));
        }
        await tx.execute(sql.raw('set local role lx_rt_test'));
        const r = await tx.execute<{ n: number }>(sql\`select count(*)::int as n from drizzle.__drizzle_migrations\`);
        return r.rows[0]?.n;
      });
    await expect(lesen(false)).rejects.toBeTruthy();
    expect(await lesen(true)).toBe(m1.applied - 1);
    await world.db.execute(sql.raw('drop owned by lx_rt_test'));
    await world.db.execute(sql.raw('drop role lx_rt_test'));
  });

  it('Status: wird 15 s zwischengespeichert; "fresh" umgeht den Cache höchstens alle 5 s', async () => {
    const { a } = await familie();
    let n = 0;
    aktuell = probes({ ntfyReachable: async () => (n++, true) });
    await a.client.get('/api/v1/admin/status');
    await a.client.get('/api/v1/admin/status');
    expect(n).toBe(1);
    await a.client.get('/api/v1/admin/status?fresh=1');
    expect(n).toBe(1);
    world.advance(6000);
    await a.client.get('/api/v1/admin/status?fresh=1');
    expect(n).toBe(2);
    world.advance(10_000);
    await a.client.get('/api/v1/admin/status');
    expect(n).toBe(2);
    world.advance(6000);
    await a.client.get('/api/v1/admin/status');
    expect(n).toBe(3);
    expect((await a.client.get('/api/v1/admin/status?fresh=2')).status).toBe(400);
  });

  it('Status: nicht messbare Quellen zählen als unbekannt, nicht als "in Ordnung"', async () => {
    const { a } = await familie();
    aktuell = probes({ readText: async () => null, disk: async () => null, tlsValidTo: async () => null });
    const s = (await a.client.get('/api/v1/admin/status')).json;
    expect(s.overall).toBe('ok');
    expect(s.unknownCount).toBeGreaterThanOrEqual(3);
    aktuell = probes();
    world.advance(16_000);
    expect((await a.client.get('/api/v1/admin/status')).json.unknownCount).toBe(0);
  });

  it('TLS-Prüfung: ungültiger Port in der Konfiguration bricht den Start ab, die Messung wirft nie', async () => {
    expect(() => loadConfig({ NODE_ENV: 'test', AUTH_SECRET_KEY: TEST_KEY, OPERATOR_TLS_PROBE: '127.0.0.1:70000' })).toThrow(/OPERATOR_TLS_PROBE/);
    expect(() => loadConfig({ NODE_ENV: 'test', AUTH_SECRET_KEY: TEST_KEY, OPERATOR_TLS_PROBE: 'kein port' })).toThrow(/OPERATOR_TLS_PROBE/);
    expect(await realProbes.tlsValidTo('127.0.0.1:99999', 'familie.lx-labs.dev')).toBeNull();
    expect(await realProbes.tlsValidTo('127.0.0.1:1', 'familie.lx-labs.dev')).toBeNull();
  });

  describe('Protokoll', () => {`);
rep("    it('Familiengrenze:", `    it('Person nur, wenn sie Mitglied der Sitzungsfamilie ist (sonst ohne Person)', async () => {
      const c = await betreiber();
      const [fremd] = await world.db.insert(schema.families).values({ name: 'Fremd2' }).returning({ id: schema.families.id });
      const [u] = await world.db.insert(schema.users).values({ email: 'fremd@example.org', displayName: 'FremdeFrau' }).returning({ id: schema.users.id });
      await world.db.insert(schema.memberships).values({ familyId: fremd!.id, userId: u!.id, role: 'admin' });
      await world.db.insert(schema.auditLog).values({ familyId: null, actorId: u!.id, event: 'login_failed', ip: '192.0.2.77' });
      const res = await c.get('/api/v1/admin/audit?limit=100');
      expect(JSON.stringify(res.json)).not.toContain('FremdeFrau');
      expect((res.json.items as Array<{ event: string; actor: unknown; network: string }>).find((i) => i.network === '192.0.2.0/24')).toMatchObject({ event: 'login_failed', actor: null });
    });

    it('Familiengrenze:`);
rep("import { addMember, adminPassword, auditEvents, backends, World, type Harness }","import { addMember, adminPassword, auditEvents, backends, TEST_KEY, World, type Harness }");
fs.writeFileSync(f,s);
