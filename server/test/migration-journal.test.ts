// Drizzle wendet eine Migration nur an, wenn ihr "when" größer ist als das der zuletzt angewendeten. Sind die Werte nicht streng
// aufsteigend (z. B. nach dem Zusammenführen zweier Branches), wird eine Migration auf bestehenden Datenbanken stillschweigend übersprungen.
import { readFileSync, readdirSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import { migrationsFolder } from './helpers.js';

interface Entry {
  idx: number;
  tag: string;
  when: number;
}

describe('Migrations-Journal', () => {
  const journal = JSON.parse(readFileSync(`${migrationsFolder}/meta/_journal.json`, 'utf8')) as { entries: Entry[] };

  it('"when" ist streng aufsteigend (in Journal-Reihenfolge)', () => {
    for (let i = 1; i < journal.entries.length; i++) {
      const a = journal.entries[i - 1] as Entry;
      const b = journal.entries[i] as Entry;
      expect(b.when, `${b.tag} muss nach ${a.tag} liegen`).toBeGreaterThan(a.when);
    }
  });

  it('Tags sind eindeutig und entsprechen den SQL-Dateien (Nummern aufsteigend)', () => {
    const tags = journal.entries.map((e) => e.tag);
    expect(new Set(tags).size).toBe(tags.length);
    const files = readdirSync(migrationsFolder).filter((f) => f.endsWith('.sql')).map((f) => f.replace(/\.sql$/, '')).sort();
    expect([...tags].sort()).toEqual(files);
    const nummern = tags.map((t) => Number(t.slice(0, 4)));
    for (let i = 1; i < nummern.length; i++) expect(nummern[i] as number).toBeGreaterThan(nummern[i - 1] as number);
  });
});
