// Domänentrennung und Längenrahmen für Signaturen. Jede Signatur beginnt mit einem festen Präfix je Verwendungszweck, damit eine Signatur
// aus einem Zusammenhang nie in einem anderen gültig ist (eine Nachricht kann nicht als Epochen-Wrap oder Mitgliederliste ausgegeben werden).
// Zusammengesetzte Daten werden mit Längen gerahmt (u32 + Bytes), damit keine Verschiebung zwischen Feldern dieselben Bytes ergibt.
import 'dart:typed_data';

import 'bytes.dart';

/// Nachrichten (Hülle, huelle.dart).
const String kDomaeneNachricht = 'lx-familyhub|msg|v1';

/// Signierte Epochenschlüssel-Wraps (epochen.dart).
const String kDomaeneWrap = 'lx-familyhub|wrap|v1';

/// Signierte Mitgliederlisten einer Epoche (epochen.dart).
const String kDomaeneMitglieder = 'lx-familyhub|members|v1';

/// Verpflichtung auf einen Epochenschlüssel in der signierten Mitgliederliste (epochen.dart).
const String kDomaeneSchluesselCommitment = 'lx-familyhub|epochkey-commit|v1';

/// Signierte Beitritts-Bestätigung eines neuen Mitglieds (beitritt.dart, PR 6, Bausteine; Grund `join`).
const String kDomaeneBeitritt = 'lx-familyhub|join|v1';

/// MAC des Beitritts-Geheimnisses über den öffentlichen Schlüssel eines neuen Mitglieds (beitritt.dart). Eigene Domäne: ein MAC ist nie eine Signatur.
const String kDomaeneBeitrittMac = 'lx-familyhub|join-mac|v1';

/// Ein Feld mit vorangestellter Länge (u32, BE).
Uint8List gerahmt(List<int> feld) => verketten([u32Bytes(feld.length), feld]);

/// Signatureingabe = Präfix, dann jedes Feld längengerahmt.
Uint8List signaturEingabe(String domaene, List<List<int>> felder) => verketten([utf8Bytes(domaene), for (final f in felder) gerahmt(f)]);

/// Signierte Schlüssel-Freigabe beim Standort teilen (standort_krypto.dart).
const String kDomaeneStandortFreigabe = 'lx-familyhub|loc-share|v1';

/// Signierte Standort-Pakete (standort_krypto.dart).
const String kDomaeneStandortPaket = 'lx-familyhub|loc-pos|v1';

// Passwort-abgeleitete Sicherung (pw_sicherung.dart). Keine Signaturen, sondern Kontext-Labels der Schlüsselableitung (BLAKE2b mit Schlüssel = Master)
// und der AAD des Blobs. Die Labels müssen verschieden bleiben, damit aus dem Server-Wert (authKey) nie der Gerätewert (kek) folgt.

/// Kontext des `authKey` (geht an den Server).
const String kKontextPwAuth = 'lx-fampad|auth|v2';

/// Kontext des `kek` (Schlüssel zum Verpacken des Personenschlüssels, bleibt auf dem Gerät).
const String kKontextPwKek = 'lx-fampad|kek|v2';

/// Präfix der AAD des Blobs der Passwort-Sicherung.
const String kDomaenePwSicherung = 'lx-fampad|pwbackup|v2';
