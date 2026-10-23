// Feste, abgeleitete Kennungen des Chats (müssen exakt denen der App entsprechen: app/lib/data/chat/chat_ids.dart; Known-Answer-Tests auf beiden Seiten).
// UUID im Muster von Version 5 (SHA-256 statt SHA-1): die ersten 16 Byte von SHA-256('lx-fampad:' + Schlüssel), Version-Nibble 5, Variante 10xx.
// Der Server lässt für Familienchat, Direktchat und Lesestand nur diese IDs zu: niemand kann eine ID eines anderen Paares oder einer anderen
// Familie vorab belegen. Gruppen bekommen Zufalls-UUIDs (Version 4); das Nibble 5 ist für abgeleitete IDs reserviert.
import { createHash } from 'node:crypto';

export function uuidAusSchluessel(schluessel: string): string {
  const b = createHash('sha256').update(`lx-fampad:${schluessel}`).digest().subarray(0, 16);
  b[6] = (b[6]! & 0x0f) | 0x50;
  b[8] = (b[8]! & 0x3f) | 0x80;
  const h = b.toString('hex');
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20, 32)}`;
}

export const familienchatId = (familyId: string): string => uuidAusSchluessel(`familienchat:${familyId}`);

export function direktChatId(a: string, b: string): string {
  const paar = [a.toLowerCase(), b.toLowerCase()].sort();
  return uuidAusSchluessel(`direkt:${paar[0]}:${paar[1]}`);
}

export const lesestandId = (konversationId: string, userId: string): string => uuidAusSchluessel(`lesestand:${konversationId.toLowerCase()}:${userId.toLowerCase()}`);

/** Feste ID der Epoche einer Konversation (je Konversation und Epoche genau eine: der erste Schreiber gewinnt). */
export const epocheId = (konversationId: string, epoche: number): string => uuidAusSchluessel(`epoche:${konversationId.toLowerCase()}:${epoche}`);

/** Feste ID des Schlüssel-Wraps einer Epoche für eine Person. */
export const wrapId = (konversationId: string, epoche: number, empfaengerId: string): string =>
  uuidAusSchluessel(`wrap:${konversationId.toLowerCase()}:${epoche}:${empfaengerId.toLowerCase()}`);

/**
 * Feste ID des Schlüssel-Wraps einer Epoche für eine Person UND eine bestimmte Schlüsselversion (Wrap-ID v2, PR 7 "Verlauf freigeben").
 * Die ID v1 (`wrapId`) kennt die Schlüsselversion nicht: Hat eine Person ihren Schlüssel gewechselt (oder nach einem Reset einen neuen), ist ihre ID für die
 * älteren Epochen schon belegt, und dieselbe Epoche ließe sich nicht noch einmal für den neuen Schlüssel verpacken. v2 trennt die Zeilen je Version; die
 * alten Zeilen (ohne `keyVersion`) bleiben unverändert gültig. Der VERTEILER (Absender) steht in der ID: jeder Verteiler hat seinen eigenen Platz, niemand kann den eines
 * anderen mit Müll vorab belegen (der Empfänger probiert alle Wraps seiner Version durch). Muss exakt der App entsprechen (chat_ids.dart, Known-Answer-Tests auf beiden Seiten).
 */
export const wrapIdV2 = (konversationId: string, epoche: number, empfaengerId: string, keyVersion: number, verteilerId: string): string =>
  uuidAusSchluessel(`wrap2:${konversationId.toLowerCase()}:${epoche}:${empfaengerId.toLowerCase()}:${keyVersion}:${verteilerId.toLowerCase()}`);

/** Feste ID der Medikamenten-Konversation einer Person (Abschnitt 6i): je Person genau eine, daraus abgeleitet (niemand kann sie für eine andere Person vorab belegen). */
export const medsChatId = (subjektId: string): string => uuidAusSchluessel(`meds:${subjektId.toLowerCase()}`);

/** Zufalls-UUID Version 4 (Gruppen, Nachrichten). */
export const istUuidV4 = (id: string): boolean => /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(id);

/** Feste ID der Reaktion einer Person auf eine Nachricht (je Person und Nachricht genau eine). */
export const reaktionId = (nachrichtId: string, userId: string): string => uuidAusSchluessel(`reaktion:${nachrichtId.toLowerCase()}:${userId.toLowerCase()}`);

/** Feste ID der Stimme einer Person zu einer Umfrage-Nachricht (je Person und Umfrage genau eine). */
export const stimmeId = (nachrichtId: string, userId: string): string => uuidAusSchluessel(`stimme:${nachrichtId.toLowerCase()}:${userId.toLowerCase()}`);

/** Feste ID der Anheftung einer Nachricht (je Nachricht genau eine). */
export const pinId = (nachrichtId: string): string => uuidAusSchluessel(`pin:${nachrichtId.toLowerCase()}`);
