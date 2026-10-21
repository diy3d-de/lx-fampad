import fs from 'node:fs';
const f='test/operator.test.ts'; let s=fs.readFileSync(f,'utf8');
const rep=(a,b)=>{ if(!s.includes(a)) throw new Error('fehlt: '+a.slice(0,60)); s=s.replace(a,b); };
rep("    await world.db.execute(sql`delete from drizzle.__drizzle_migrations where id = (select max(id) from drizzle.__drizzle_migrations)`);",
"    const letzte = (await world.db.execute<{ id: number; hash: string; created_at: string }>(sql`select id, hash, created_at from drizzle.__drizzle_migrations order by id desc limit 1`)).rows[0]!;\n    await world.db.execute(sql`delete from drizzle.__drizzle_migrations where id = ${letzte.id}`);");
rep("    await expect(lesen(false)).rejects.toBeTruthy();","    // Migrationszeile wieder einsetzen (die Tabelle liegt außerhalb der Test-Zurücksetzung)\n    await world.db.execute(sql`insert into drizzle.__drizzle_migrations (id, hash, created_at) values (${letzte.id}, ${letzte.hash}, ${letzte.created_at})`);\n    await expect(lesen(false)).rejects.toBeTruthy();");
rep("    expect(await lesen(true)).toBe(m1.applied - 1);","    expect(await lesen(true)).toBe(m1.applied);");
fs.writeFileSync(f,s);
