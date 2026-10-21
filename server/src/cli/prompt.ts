// Eingabe ohne Echo für Geheimnisse in der Kommandozeile. Mit Terminal: Zeichen werden nicht angezeigt; ohne Terminal (Pipe): eine Zeile je Aufruf.
import { createInterface, type Interface } from 'node:readline';

let pipe: Interface | undefined;
const zeilen: string[] = [];
let wartend: ((l: string) => void) | undefined;

function zeileAusPipe(): Promise<string> {
  if (!pipe) {
    pipe = createInterface({ input: process.stdin });
    pipe.on('line', (l) => {
      if (wartend) {
        const w = wartend;
        wartend = undefined;
        w(l);
      } else zeilen.push(l);
    });
    pipe.on('close', () => wartend?.(''));
  }
  const l = zeilen.shift();
  if (l !== undefined) return Promise.resolve(l);
  return new Promise((resolve) => {
    wartend = resolve;
  });
}

export async function frageVerdeckt(frage: string): Promise<string> {
  process.stdout.write(frage);
  if (!process.stdin.isTTY) {
    const l = (await zeileAusPipe()).trim();
    process.stdout.write('\n');
    return l;
  }
  return new Promise((resolve, reject) => {
    const stdin = process.stdin;
    let puffer = '';
    const ende = () => {
      stdin.setRawMode(false);
      stdin.pause();
      stdin.off('data', onData);
      process.stdout.write('\n');
    };
    const onData = (chunk: Buffer) => {
      for (const c of chunk.toString('utf8')) {
        if (c === '\r' || c === '\n') {
          ende();
          resolve(puffer.trim());
          return;
        }
        if (c === '\u0003') {
          ende();
          reject(new Error('Abgebrochen.'));
          return;
        }
        if (c === '\u007f' || c === '\b') puffer = puffer.slice(0, -1);
        else if (c >= ' ') puffer += c;
      }
    };
    stdin.setRawMode(true);
    stdin.resume();
    stdin.on('data', onData);
  });
}
