// IP-Adressen für Sperren und Begrenzungen: IPv6 wird auf das /64-Präfix zusammengefasst (ein Anschluss bekommt meist ein
// ganzes /64 und kann beliebig viele Adressen darin nutzen), IPv4-in-IPv6 (::ffff:a.b.c.d) gilt als IPv4.
import { isIPv4, isIPv6 } from 'node:net';

/** Zerlegt eine IPv6-Adresse in acht 16-Bit-Gruppen; null, wenn sie nicht lesbar ist. */
function ipv6Groups(address: string): number[] | null {
  let a = address;
  const zone = a.indexOf('%');
  if (zone >= 0) a = a.slice(0, zone);
  // eingebettetes IPv4 am Ende (::ffff:1.2.3.4) in zwei Gruppen umwandeln
  const lastColon = a.lastIndexOf(':');
  const tail = a.slice(lastColon + 1);
  if (isIPv4(tail)) {
    const o = tail.split('.').map(Number) as [number, number, number, number];
    a = `${a.slice(0, lastColon + 1)}${((o[0] << 8) | o[1]).toString(16)}:${((o[2] << 8) | o[3]).toString(16)}`;
  }
  const halves = a.split('::');
  if (halves.length > 2) return null;
  const parse = (s: string) => (s === '' ? [] : s.split(':'));
  const head = parse(halves[0] ?? '');
  const rest = halves.length === 2 ? parse(halves[1] ?? '') : [];
  const missing = 8 - head.length - rest.length;
  if (halves.length === 1 ? missing !== 0 : missing < 1) return null;
  const groups = [...head, ...Array<string>(halves.length === 2 ? missing : 0).fill('0'), ...rest].map((g) => parseInt(g, 16));
  if (groups.length !== 8 || groups.some((g) => !Number.isInteger(g) || g < 0 || g > 0xffff)) return null;
  return groups;
}

/**
 * Normalisiert eine Client-IP zum Schlüssel für Sperren und Rate-Limits: IPv4 bleibt, IPv4-mapped wird zu IPv4,
 * IPv6 wird auf das /64-Präfix gekürzt ("2001:db8:0:1::/64"). Unlesbares bleibt unverändert.
 */
export function normalizeIp(ip: string | undefined): string {
  if (!ip) return 'unbekannt';
  if (isIPv4(ip)) return ip;
  if (!isIPv6(ip.split('%')[0] ?? ip)) return ip;
  const g = ipv6Groups(ip);
  if (!g) return ip;
  // ::ffff:a.b.c.d (IPv4-mapped)
  if (g.slice(0, 5).every((x) => x === 0) && g[5] === 0xffff) {
    return `${g[6]! >> 8}.${g[6]! & 255}.${g[7]! >> 8}.${g[7]! & 255}`;
  }
  return `${g.slice(0, 4).map((x) => x.toString(16)).join(':')}::/64`;
}
