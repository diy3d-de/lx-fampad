// Gemeinsame Hilfe für ausgehende Abrufe (Wetter, Abfuhrtermine): Antwort höchstens bis zu einer Größe lesen.

/** Liest den Rumpf höchstens bis zur Grenze (Content-Length und Strom); null bei Überschreitung. */
export async function leseBegrenzt(res: Response, maxBytes: number): Promise<string | null> {
  const len = Number(res.headers.get('content-length'));
  if (Number.isFinite(len) && len > maxBytes) {
    await res.body?.cancel().catch(() => undefined);
    return null;
  }
  if (!res.body) return '';
  const reader = res.body.getReader();
  const teile: Uint8Array[] = [];
  let summe = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    summe += value.byteLength;
    if (summe > maxBytes) {
      await reader.cancel().catch(() => undefined);
      return null;
    }
    teile.push(value);
  }
  return Buffer.concat(teile).toString('utf8');
}
