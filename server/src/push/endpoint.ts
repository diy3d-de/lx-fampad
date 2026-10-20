// Prüfung des UnifiedPush-Endpunkts, den ein Gerät meldet (SSRF-Schutz).
//
// Der Server sendet NIE an die gemeldete URL. Aus ihr wird nur das Topic gelesen; gepostet wird an die Loopback-URL des eigenen ntfy
// (NTFY_URL). Trotzdem wird die gemeldete URL streng geprüft, damit niemand fremde Topics einträgt oder Eingaben ins Log/DB schmuggelt.
//
// Erlaubt ist genau: https://<NTFY_PUBLIC_HOST>/up<12 bis 64 Zeichen [A-Za-z0-9_-]>, optional mit der Query ?up=1 (so meldet die
// ntfy-App ihren Endpunkt). Kein Port, keine Zugangsdaten, kein Fragment, keine Prozent-Kodierung, kein weiterer Pfad, keine IP.
// Die ntfy-App erzeugt "up" + 12 Zeichen (ntfy-Quellcode: unifiedPushTopicLength = 14); die Obergrenze 64 ist nur Spielraum.

export const TOPIC_RE = /^up[A-Za-z0-9_-]{12,64}$/;
const MAX_ENDPOINT_LENGTH = 200;

function escapeRe(s: string): string {
  return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

/** Liefert das Topic eines gültigen Endpunkts, sonst null. Rein auf dem Rohtext (kein URL-Parser, damit keine Parser-Tricks greifen). */
export function topicFromEndpoint(raw: unknown, publicHost: string): string | null {
  if (typeof raw !== 'string' || raw.length > MAX_ENDPOINT_LENGTH) return null;
  const m = new RegExp(`^https://${escapeRe(publicHost.toLowerCase())}/(up[A-Za-z0-9_-]{12,64})(?:\\?up=1)?$`).exec(raw);
  const topic = m?.[1];
  return topic !== undefined && TOPIC_RE.test(topic) ? topic : null;
}
