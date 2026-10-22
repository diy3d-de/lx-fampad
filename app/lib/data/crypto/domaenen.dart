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

// Passkey-Sicherung (prf_sicherung.dart): Kontext-Labels der Schlüsselableitung aus der PRF-Ausgabe eines Passkeys (BLAKE2b mit Schlüssel = PRF-Ausgabe) und AAD des Blobs.
// Die PRF-Ausgabe selbst wird nie direkt als Schlüssel benutzt.

/// Salt der PRF-Auswertung (fest; der WebAuthn-Client hängt selbst "WebAuthn PRF" davor und hasht).
const String kPrfSaltText = 'lx-fampad|prf-salt|v1';

/// Kontext des `kek` aus der PRF-Ausgabe (Schlüssel zum Verpacken des Personenschlüssels, bleibt auf dem Gerät).
const String kKontextPrfKek = 'lx-fampad|prf-kek|v1';

/// Präfix der AAD des Blobs der Passkey-Sicherung.
const String kDomaenePrfSicherung = 'lx-fampad|prfbackup|v3';

// Eltern-Wiederherstellung (eltern_wiederherstellung.dart): Signaturen und Ableitungen, je mit eigenem Präfix.

/// Signierte Hinterlegung des Kindes für ein Elternteil.
const String kDomaeneHinterlegung = 'lx-familyhub|escrow|v1';

/// Signierte Übergabe des Elternteils an den flüchtigen Schlüssel des Kindes.
const String kDomaeneFreigabe = 'lx-familyhub|escrow-release|v1';

/// Verpflichtung des Kindes auf seinen flüchtigen öffentlichen Schlüssel.
const String kDomaeneVerpflichtung = 'lx-familyhub|escrow-commit|v1';

/// Kurzcode (SAS) zum Vergleich zwischen Kind und Elternteil.
const String kDomaeneKurzcode = 'lx-familyhub|escrow-sas|v1';
