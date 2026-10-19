// Ablauf nach einem Wecker (Vordergrund und Hintergrund-Start): abgleichen und, wenn es Neues gab, die Schnittstelle für lokale
// Benachrichtigungen aufrufen. Der Wecker selbst enthält nichts; was neu ist, steht erst nach dem Abgleich in der lokalen Datenbank.
import 'dart:async';

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

/// Drosselt und serialisiert die Abgleiche nach Weckern (Single-Flight): höchstens ein Lauf zugleich, zwischen zwei Starten mindestens
/// [abstand]; was währenddessen eintrifft, wird zu genau einem weiteren Lauf zusammengefasst. Schützt vor einer Flut von Weckern
/// (auch fremder Apps, die die exportierte Empfänger-Komponente ansprechen) und vor überlappenden Hintergrund-Läufen.
class WeckerLauf {
  final Duration abstand;
  final Future<void> Function() lauf;
  DateTime? _letzterStart;
  bool _laeuft = false;
  bool _nochmal = false;
  Timer? _timer;
  bool _beendet = false;

  WeckerLauf({this.abstand = const Duration(seconds: 10), required this.lauf});

  /// Ein Wecker ist eingetroffen.
  void ausloesen() {
    if (_beendet) return;
    if (_laeuft) {
      _nochmal = true;
      return;
    }
    if (_timer != null) return; // ein Lauf ist schon geplant
    final letzter = _letzterStart;
    final rest = letzter == null ? Duration.zero : abstand - DateTime.now().difference(letzter);
    if (rest <= Duration.zero) {
      unawaited(_starten());
    } else {
      _timer = Timer(rest, () {
        _timer = null;
        unawaited(_starten());
      });
    }
  }

  Future<void> _starten() async {
    _laeuft = true;
    _letzterStart = DateTime.now();
    try {
      await lauf();
    } catch (_) {
      // der nächste Wecker oder Start der App gleicht ab
    } finally {
      _laeuft = false;
      if (_nochmal && !_beendet) {
        _nochmal = false;
        ausloesen();
      }
    }
  }

  void beenden() {
    _beendet = true;
    _timer?.cancel();
    _timer = null;
  }
}

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
