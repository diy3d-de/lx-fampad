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

/// Ein Feld mit vorangestellter Länge (u32, BE).
Uint8List gerahmt(List<int> feld) => verketten([u32Bytes(feld.length), feld]);

/// Signatureingabe = Präfix, dann jedes Feld längengerahmt.
Uint8List signaturEingabe(String domaene, List<List<int>> felder) => verketten([utf8Bytes(domaene), for (final f in felder) gerahmt(f)]);
