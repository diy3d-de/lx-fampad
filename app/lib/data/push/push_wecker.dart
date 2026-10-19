// Ablauf nach einem Wecker (Vordergrund und Hintergrund-Start): abgleichen und, wenn es Neues gab, die Schnittstelle für lokale
// Benachrichtigungen aufrufen. Der Wecker selbst enthält nichts; was neu ist, steht erst nach dem Abgleich in der lokalen Datenbank.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../sync/sync_store.dart';

/// Schnittstelle für lokale Benachrichtigungen über neue Ereignisse (neue Chat-Nachrichten, Termine ...).
///
/// ERWEITERUNGSSTELLE: Der Erinnerungs-Zweig (flutter_local_notifications, Branch phase-erinnerungen) und später der Chat überschreiben
/// [ereignisBenachrichtigerProvider] mit einer Umsetzung, die denselben Plugin und denselben Benachrichtigungskanal benutzt. Hier gibt es
/// bewusst nur diese Schnittstelle (kein Plugin): ohne Umsetzung passiert nach einem Wecker nur der Abgleich.
///
/// Wird nach einem Wecker aufgerufen, wenn der Abgleich den Stand der Familie erhöht hat ([vorher] -> [rev]); läuft auch im Hintergrund-Start
/// (App geschlossen). Die Umsetzung entscheidet anhand der lokalen Daten, was für DIESE Person neu ist (eigene Nachrichten nicht anzeigen,
/// Stummschaltung beachten) und führt ihre eigene Buchführung (z. B. zuletzt gemeldeter Zeitstempel).
abstract class EreignisBenachrichtiger {
  Future<void> neueEreignisse(int rev, {required int vorher});
}

class KeineEreignisBenachrichtigung implements EreignisBenachrichtiger {
  const KeineEreignisBenachrichtigung();

  @override
  Future<void> neueEreignisse(int rev, {required int vorher}) async {}
}

final ereignisBenachrichtigerProvider = Provider<EreignisBenachrichtiger>((ref) => const KeineEreignisBenachrichtigung());

/// Gleicht ab (Rückruf [abgleich]) und meldet neue Ereignisse. Fehler des Abgleichs stoppen nichts (der nächste Auslöser holt es nach);
/// ein Fehler der Benachrichtigung bricht den Wecker nicht ab.
Future<void> weckerAbgleichen({
  required SyncStore store,
  required Future<void> Function() abgleich,
  required EreignisBenachrichtiger ereignisse,
}) async {
  final vorher = await store.sinceRev();
  await abgleich();
  final nachher = await store.sinceRev();
  if (nachher > vorher) {
    try {
      await ereignisse.neueEreignisse(nachher, vorher: vorher);
    } catch (_) {
      // eine fehlgeschlagene Benachrichtigung darf den Abgleich nicht unbrauchbar machen
    }
  }
}
