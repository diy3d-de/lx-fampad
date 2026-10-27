// Feste Kennungen für Datensätze, die es je Familie, Paar oder Person und Chat nur einmal gibt. Geräte, die denselben Datensatz offline anlegen,
// vergeben damit dieselbe ID: der Server behandelt das zweite Anlegen als Wiederholung (nichts geht verloren, kein Duplikat).
import 'dart:convert';

import 'package:crypto/crypto.dart';

/// UUID (Version 5 nach dem Muster, SHA-256 statt SHA-1) aus einem Schlüsseltext; gleiche Eingabe, gleiche ID.
String uuidAusSchluessel(String schluessel) {
  final b = sha256.convert(utf8.encode('lx-fampad:$schluessel')).bytes.sublist(0, 16);
  b[6] = (b[6] & 0x0f) | 0x50;
  b[8] = (b[8] & 0x3f) | 0x80;
  String h(int i) => b[i].toRadixString(16).padLeft(2, '0');
  return '${h(0)}${h(1)}${h(2)}${h(3)}-${h(4)}${h(5)}-${h(6)}${h(7)}-${h(8)}${h(9)}-${h(10)}${h(11)}${h(12)}${h(13)}${h(14)}${h(15)}';
}

/// ID des Familienchats einer Familie.
String familienchatId(String familyId) => uuidAusSchluessel('familienchat:$familyId');

/// ID des Direktchats zweier Personen (unabhängig von der Reihenfolge).
String direktChatId(String a, String b) {
  final paar = [a.toLowerCase(), b.toLowerCase()]..sort();
  return uuidAusSchluessel('direkt:${paar[0]}:${paar[1]}');
}

/// ID des Lesestands einer Person in einem Chat.
String lesestandId(String konversationId, String userId) => uuidAusSchluessel('lesestand:${konversationId.toLowerCase()}:${userId.toLowerCase()}');

/// ID der Epoche einer Konversation (je Konversation und Epoche genau eine: der erste Schreiber gewinnt).
String epocheId(String konversationId, int epoche) => uuidAusSchluessel('epoche:${konversationId.toLowerCase()}:$epoche');

/// ID des Schlüssel-Wraps einer Epoche für eine Person.
String wrapId(String konversationId, int epoche, String empfaengerId) =>
    uuidAusSchluessel('wrap:${konversationId.toLowerCase()}:$epoche:${empfaengerId.toLowerCase()}');

/// ID des Schlüssel-Wraps einer Epoche für eine Person UND eine bestimmte Schlüsselversion (Wrap-ID v2, "Verlauf freigeben"). Die ID v1 ([wrapId]) kennt die
/// Schlüsselversion nicht: hat die Person einen neuen Schlüssel, ist ihre ID für die älteren Epochen schon belegt. v2 trennt die Zeilen je Version; alte Zeilen und
/// Apps bis 0.7.0 bleiben bei v1. Der VERTEILER (Absender) steht in der ID: jeder Verteiler hat seinen eigenen Platz, niemand kann den eines anderen mit Müll
/// vorab belegen (der Empfänger probiert alle Wraps seiner Version durch). Muss exakt dem Server entsprechen (server/src/sync/entities/chat-ids.ts, Known-Answer-Tests).
String wrapIdV2(String konversationId, int epoche, String empfaengerId, int keyVersion, String verteilerId) =>
    uuidAusSchluessel('wrap2:${konversationId.toLowerCase()}:$epoche:${empfaengerId.toLowerCase()}:$keyVersion:${verteilerId.toLowerCase()}');

/// ID der Medikamenten-Konversation einer Person (Abschnitt 6k): je Person genau eine, daraus abgeleitet (muss exakt dem Server entsprechen, server/src/sync/entities/chat-ids.ts).
String medsChatId(String subjektId) => uuidAusSchluessel('meds:${subjektId.toLowerCase()}');

/// ID des Vorsorge-Profils einer Medikamenten-Konversation (Abschnitt 6p): je Person genau eines, daraus abgeleitet (muss exakt dem Server entsprechen, server/src/sync/entities/chat-ids.ts).
String vorsorgeProfilId(String konversationId) => uuidAusSchluessel('vorsorge-profil:${konversationId.toLowerCase()}');

/// ID der Zähler-Konversation einer Familie (Abschnitt 6l): je Familie genau eine, daraus abgeleitet (muss exakt dem Server entsprechen, server/src/sync/entities/chat-ids.ts).
String zaehlerChatId(String familyId) => uuidAusSchluessel('zaehler:${familyId.toLowerCase()}');

/// ID der Tresor-Konversation einer Familie (Abschnitt 6m): je Familie genau eine, daraus abgeleitet (muss exakt dem Server entsprechen, server/src/sync/entities/chat-ids.ts).
String tresorChatId(String familyId) => uuidAusSchluessel('tresor:${familyId.toLowerCase()}');

/// ID der Reaktion einer Person auf eine Nachricht (je Person und Nachricht genau eine).
String reaktionId(String nachrichtId, String userId) => uuidAusSchluessel('reaktion:${nachrichtId.toLowerCase()}:${userId.toLowerCase()}');

/// ID der Stimme einer Person zu einer Umfrage-Nachricht (je Person und Umfrage genau eine).
String stimmeId(String nachrichtId, String userId) => uuidAusSchluessel('stimme:${nachrichtId.toLowerCase()}:${userId.toLowerCase()}');

/// ID der Anheftung einer Nachricht (je Nachricht genau eine).
String pinId(String nachrichtId) => uuidAusSchluessel('pin:${nachrichtId.toLowerCase()}');

/// ID des Familien-Status einer Person (Abschnitt 6o): je Person genau einer, daraus abgeleitet (muss exakt dem Server entsprechen, server/src/sync/entities/chat-ids.ts).
String statusId(String userId) => uuidAusSchluessel('status:${userId.toLowerCase()}');
