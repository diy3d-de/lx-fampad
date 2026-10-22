// Lesende Messungen für die Betreiber-Ansicht. Jede Funktion liest nur und liefert bei jedem Fehler null (= "unbekannt"); sie wirft nie
// und gibt nie Pfade, Fehlertexte oder Inhalte weiter. Keine Shell-Befehle, kein Neustart. Tests ersetzen die Messungen (AppDeps.operatorProbes).
import { constants } from 'node:fs';
import { open, readdir, stat, statfs } from 'node:fs/promises';
import { connect } from 'node:tls';

export interface DiskInfo {
  totalBytes: number;
  freeBytes: number;
}

export interface Probes {
  /** Textdatei bis maxBytes lesen (Statusdatei der Sicherung, Release-Manifest). Mit `noFollow` wird ein Symlink als letztes Pfadstück nicht gelesen (null), und es muss eine reguläre Datei sein. */
  readText(path: string, maxBytes: number, noFollow?: boolean): Promise<string | null>;
  disk(path: string): Promise<DiskInfo | null>;
  /** Größe der größten *.pmtiles-Datei im Ordner; null = keine. */
  karteBytes(dir: string): Promise<number | null>;
  /** Gesamtgröße aller Dateien unter dem Ordner (nur die Summe, nie Namen; Links werden nicht verfolgt); null = nicht ermittelbar, nicht vorhanden oder mehr als `maxEntries` Einträge. */
  dirBytes(dir: string, maxEntries: number): Promise<number | null>;
  /** Zertifikatsende (lesende TLS-Verbindung), null = nicht ermittelbar. */
  tlsValidTo(probe: string, servername: string): Promise<Date | null>;
  /** Antwortet der lokale ntfy auf /v1/health? */
  ntfyReachable(url: string): Promise<boolean>;
}

const TIMEOUT_MS = 3000;

export const realProbes: Probes = {
  async readText(path, maxBytes, noFollow = false) {
    try {
      // O_NOFOLLOW gibt es unter Windows nicht (dort 0): die Statusdateien liegen nur auf dem Linux-Server
      const fh = await open(path, constants.O_RDONLY | (noFollow ? (constants.O_NOFOLLOW ?? 0) : 0));
      try {
        if (noFollow && !(await fh.stat()).isFile()) return null;
        const buf = Buffer.alloc(maxBytes);
        const { bytesRead } = await fh.read(buf, 0, maxBytes, 0);
        return buf.subarray(0, bytesRead).toString('utf8');
      } finally {
        await fh.close();
      }
    } catch {
      return null;
    }
  },
  async disk(path) {
    try {
      const s = await statfs(path);
      return { totalBytes: s.blocks * s.bsize, freeBytes: s.bavail * s.bsize };
    } catch {
      return null;
    }
  },
  async karteBytes(dir) {
    try {
      let best: number | null = null;
      for (const name of await readdir(dir)) {
        if (!name.toLowerCase().endsWith('.pmtiles')) continue;
        const st = await stat(`${dir}/${name}`);
        if (st.isFile() && (best === null || st.size > best)) best = st.size;
      }
      return best;
    } catch {
      return null;
    }
  },
  async dirBytes(dir, maxEntries) {
    try {
      let total = 0;
      let seen = 0;
      // eigene Frist: die Messung blockiert den Dateisystem-Pool nie länger (zusätzlich zum Zeitlimit des Aufrufers)
      const deadline = Date.now() + 20_000;
      const stack = [dir];
      for (let d = stack.pop(); d !== undefined; d = stack.pop()) {
        for (const e of await readdir(d, { withFileTypes: true })) {
          if (++seen > maxEntries || Date.now() > deadline) return null;
          if (e.isSymbolicLink()) continue;
          const p = `${d}/${e.name}`;
          if (e.isDirectory()) stack.push(p);
          else if (e.isFile()) total += (await stat(p)).size;
        }
      }
      return total;
    } catch {
      return null;
    }
  },
  tlsValidTo(probe, servername) {
    return new Promise((resolve) => {
      const idx = probe.lastIndexOf(':');
      const host = probe.slice(0, idx).replace(/^\[|\]$/g, '');
      const port = Number(probe.slice(idx + 1));
      let done = false;
      const finish = (value: Date | null) => {
        if (done) return;
        done = true;
        clearTimeout(timer);
        socket?.destroy();
        resolve(value);
      };
      const timer = setTimeout(() => finish(null), TIMEOUT_MS);
      // Nur das Zertifikat lesen: es wird nichts gesendet und nichts geprüft (rejectUnauthorized aus), die Verbindung geht nach localhost.
      let socket: ReturnType<typeof connect> | undefined;
      try {
        socket = connect({ host, port, servername, rejectUnauthorized: false }, () => {
          const end = new Date(socket?.getPeerCertificate().valid_to ?? Number.NaN);
          finish(Number.isNaN(end.getTime()) ? null : end);
        });
      } catch {
        // z. B. ungültiger Port oder Host: nie werfen, nur "unbekannt"
        finish(null);
        return;
      }
      socket.on('error', () => finish(null));
    });
  },
  async ntfyReachable(url) {
    try {
      const res = await fetch(`${url}/v1/health`, { signal: AbortSignal.timeout(TIMEOUT_MS), redirect: 'error' });
      await res.body?.cancel();
      return res.ok;
    } catch {
      return false;
    }
  },
};
