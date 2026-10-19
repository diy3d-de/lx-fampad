// Prüfung hochgeladener Benutzerbilder: Dateityp nur an den Magic-Bytes (nie am Dateinamen oder Content-Type allein), Maße aus dem Dateikopf.
// Es wird nichts dekodiert und nichts neu kodiert (der Server hat keine Bildbibliothek): Die App verkleinert und kodiert neu (entfernt dabei EXIF/Standort),
// der Server lässt nur PNG, JPEG und WebP in kleiner Größe zu. SVG und alles andere wird abgelehnt.

export type AvatarMime = 'image/png' | 'image/jpeg' | 'image/webp';

/** Harte Grenzen: Bytes und Kantenlänge. Die App liefert etwa 512 x 512 Pixel und deutlich weniger Bytes. */
export const AVATAR_MAX_BYTES = 512 * 1024;
export const AVATAR_MAX_DIM = 1024;

/** Kennungen der Platzhalter (die Zeichnungen liegen in der App): Vater, Mutter, Kind. */
export const AVATAR_PRESETS = ['V01', 'V08', 'V12', 'M01', 'M08', 'M13', 'K07', 'K08', 'K12', 'K13'] as const;
export type AvatarPreset = (typeof AVATAR_PRESETS)[number];
export const isAvatarPreset = (v: string): v is AvatarPreset => (AVATAR_PRESETS as readonly string[]).includes(v);

export const AVATAR_MIMES: readonly AvatarMime[] = ['image/png', 'image/jpeg', 'image/webp'];

export interface ImageInfo {
  mime: AvatarMime;
  width: number;
  height: number;
}

const PNG_SIG = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];

/** Erkennt PNG/JPEG/WebP an den Magic-Bytes und liest die Maße; null bei allem anderen, einem kaputten Kopf oder zu großen Maßen. */
export function inspectImage(b: Buffer): ImageInfo | null {
  if (b.length >= 24 && PNG_SIG.every((v, i) => b[i] === v)) return png(b);
  if (b.length >= 4 && b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff) return jpeg(b);
  if (b.length >= 30 && b.toString('latin1', 0, 4) === 'RIFF' && b.toString('latin1', 8, 12) === 'WEBP') return webp(b);
  return null;
}

function valid(mime: AvatarMime, width: number, height: number): ImageInfo | null {
  return width >= 1 && height >= 1 && width <= AVATAR_MAX_DIM && height <= AVATAR_MAX_DIM ? { mime, width, height } : null;
}

function png(b: Buffer): ImageInfo | null {
  // erster Block muss IHDR mit Länge 13 sein
  if (b.readUInt32BE(8) !== 13 || b.toString('latin1', 12, 16) !== 'IHDR') return null;
  return valid('image/png', b.readUInt32BE(16), b.readUInt32BE(20));
}

function jpeg(b: Buffer): ImageInfo | null {
  let i = 2;
  while (i + 4 <= b.length) {
    if (b[i] !== 0xff) return null;
    const marker = b[i + 1] ?? 0;
    if (marker === 0xff) {
      i += 1; // Füllbyte
      continue;
    }
    if (marker === 0xd8 || marker === 0x01 || (marker >= 0xd0 && marker <= 0xd7)) {
      i += 2; // Marker ohne Länge
      continue;
    }
    if (marker === 0xd9 || marker === 0xda) return null; // Ende oder Bilddaten vor einem SOF
    const len = b.readUInt16BE(i + 2);
    if (len < 2) return null;
    const isSof = marker >= 0xc0 && marker <= 0xcf && marker !== 0xc4 && marker !== 0xc8 && marker !== 0xcc;
    if (isSof) {
      if (i + 9 > b.length) return null;
      return valid('image/jpeg', b.readUInt16BE(i + 7), b.readUInt16BE(i + 5));
    }
    i += 2 + len;
  }
  return null;
}

function webp(b: Buffer): ImageInfo | null {
  if (b.readUInt32LE(4) + 8 > b.length) return null; // abgeschnitten
  const chunk = b.toString('latin1', 12, 16);
  if (chunk === 'VP8 ') {
    // Frame-Kopf: 3 Byte Frame-Tag, Startcode 9d 01 2a, dann 14-Bit-Breite und -Höhe
    if (b[23] !== 0x9d || b[24] !== 0x01 || b[25] !== 0x2a) return null;
    return valid('image/webp', b.readUInt16LE(26) & 0x3fff, b.readUInt16LE(28) & 0x3fff);
  }
  if (chunk === 'VP8L') {
    if (b[20] !== 0x2f) return null;
    const bits = b.readUInt32LE(21);
    return valid('image/webp', (bits & 0x3fff) + 1, ((bits >>> 14) & 0x3fff) + 1);
  }
  if (chunk === 'VP8X') return valid('image/webp', b.readUIntLE(24, 3) + 1, b.readUIntLE(27, 3) + 1);
  return null;
}
