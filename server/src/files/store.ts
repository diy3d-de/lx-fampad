// Ablage auf dem Datenträger: FILES_DIR/{blobs/<2 Hex>/<uuid>, tmp/<uuid>.part|.enc}. Dateinamen sind IMMER Zufalls-UUIDs des Servers (nie ein Name oder Pfad des Clients);
// jede ID wird vor dem Zusammensetzen eines Pfades geprüft. tmp/ und blobs/ liegen im selben Dateisystem, damit das Umbenennen atomar ist. Verzeichnisse 0700, Dateien 0600.
import { mkdir, open, rename, stat, unlink, readdir, statfs } from 'node:fs/promises';
import { join } from 'node:path';

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

export const isStoreId = (id: string): boolean => UUID_RE.test(id);

export class FileStore {
  private ready = false;
  constructor(readonly root: string) {}

  private check(id: string): string {
    if (!UUID_RE.test(id)) throw new Error('Ungültige Blob-ID');
    return id;
  }

  get tmpDir(): string {
    return join(this.root, 'tmp');
  }
  get blobsDir(): string {
    return join(this.root, 'blobs');
  }

  /** Legt die Verzeichnisse an (idempotent). */
  async ensure(): Promise<void> {
    if (this.ready) return;
    await mkdir(this.tmpDir, { recursive: true, mode: 0o700 });
    await mkdir(this.blobsDir, { recursive: true, mode: 0o700 });
    this.ready = true;
  }

  partPath(id: string): string {
    return join(this.tmpDir, `${this.check(id)}.part`);
  }
  encPath(id: string): string {
    return join(this.tmpDir, `${this.check(id)}.enc`);
  }
  blobPath(id: string): string {
    return join(this.blobsDir, this.check(id).slice(0, 2), id);
  }

  /** Legt die leere Staging-Datei an (0600, nur neu). */
  async createPart(id: string): Promise<void> {
    await this.ensure();
    const fh = await open(this.partPath(id), 'wx', 0o600);
    await fh.close();
  }

  /** Schreibt einen Abschnitt an eine Stelle der Staging-Datei. */
  async writePart(id: string, position: number, data: Buffer): Promise<void> {
    const fh = await open(this.partPath(id), 'r+');
    try {
      let written = 0;
      while (written < data.length) {
        const { bytesWritten } = await fh.write(data, written, data.length - written, position + written);
        written += bytesWritten;
      }
    } finally {
      await fh.close();
    }
  }

  /** Verschiebt eine fertige Datei atomar an ihren Platz im Blob-Ordner (Datei und Ordner werden mit fsync gesichert). */
  async install(id: string, from: string): Promise<void> {
    const dst = this.blobPath(id);
    await mkdir(join(this.blobsDir, id.slice(0, 2)), { recursive: true, mode: 0o700 });
    await rename(from, dst);
    await this.syncDir(join(this.blobsDir, id.slice(0, 2)));
  }

  private async syncDir(dir: string): Promise<void> {
    try {
      const fh = await open(dir, 'r');
      try {
        await fh.sync();
      } finally {
        await fh.close();
      }
    } catch {
      // Verzeichnis-fsync gibt es nicht überall (Windows): die Datei selbst ist schon gesichert
    }
  }

  async sizeOf(path: string): Promise<number | null> {
    try {
      return (await stat(path)).size;
    } catch {
      return null;
    }
  }

  /** Löscht eine Datei; true, wenn sie da war. Andere Fehler als "nicht vorhanden" werden weitergegeben. */
  async remove(path: string): Promise<boolean> {
    try {
      await unlink(path);
      return true;
    } catch (err: unknown) {
      if ((err as { code?: string }).code === 'ENOENT') return false;
      throw err;
    }
  }

  /** Freier Platz des Datenträgers in Byte. */
  async freeBytes(): Promise<number> {
    await this.ensure();
    const s = await statfs(this.root);
    return Number(s.bavail) * Number(s.bsize);
  }

  /** Alle Dateien (ID und Alter) im Blob-Ordner und in tmp/; nur Namen, die wie IDs aussehen (Fremdes bleibt unberührt und wird nur gezählt). */
  async list(): Promise<{ blobs: Array<{ id: string; mtimeMs: number }>; staging: Array<{ name: string; mtimeMs: number }>; foreign: number }> {
    await this.ensure();
    const blobs: Array<{ id: string; mtimeMs: number }> = [];
    let foreign = 0;
    for (const sub of await readdir(this.blobsDir)) {
      let entries: string[];
      try {
        entries = await readdir(join(this.blobsDir, sub));
      } catch {
        foreign++;
        continue;
      }
      for (const name of entries) {
        if (!UUID_RE.test(name) || name.slice(0, 2) !== sub) {
          foreign++;
          continue;
        }
        const s = await stat(join(this.blobsDir, sub, name));
        blobs.push({ id: name, mtimeMs: s.mtimeMs });
      }
    }
    const staging: Array<{ name: string; mtimeMs: number }> = [];
    for (const name of await readdir(this.tmpDir)) {
      const s = await stat(join(this.tmpDir, name));
      staging.push({ name, mtimeMs: s.mtimeMs });
    }
    return { blobs, staging, foreign };
  }
}

/** Nacheinander-Ausführung (Finalisieren läuft mit Parallelität 1: Hashen und Verschlüsseln sind der RAM-/CPU-Spitzenwert des 2-GB-Servers). */
export class Serial {
  private tail: Promise<unknown> = Promise.resolve();
  run<T>(fn: () => Promise<T>): Promise<T> {
    const next = this.tail.then(fn, fn);
    this.tail = next.catch(() => undefined);
    return next;
  }
}
