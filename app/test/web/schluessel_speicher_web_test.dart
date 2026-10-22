// Browser-Test des Schlüsselspeichers im Web (echtes IndexedDB und WebCrypto, kein Fake): gehört zur Verlustmatrix "Web: IndexedDB gelöscht,
// Speicher nicht dauerhaft". Läuft NICHT unter `flutter test` auf der VM (dort wird die Datei übersprungen), sondern nur im Browser:
//   flutter test --platform chrome test/web/schluessel_speicher_web_test.dart
// (Chrome muss installiert sein; die CI führt diese Datei bisher nicht aus.)
// Geprüft wird, was für "kein stiller Verlust" zählt: Ein gelöschter Speicher meldet "nicht vorhanden" (null), nie einen Fehler und nie einen neuen Schlüssel;
// ein vorhandener, aber unlesbarer Eintrag (Wrapper-Schlüssel weg, vertauscht) meldet einen DAUERHAFTEN Fehler (statt null), damit die App ihn in die
// Quarantäne verschiebt; das Verschieben behält den Eintrag unverändert; die Abfrage des dauerhaften Speichers wirft nie.
@TestOn('browser')
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/crypto/schluessel_speicher.dart';
import 'package:lx_fampad/data/crypto/schluessel_speicher_web.dart';
import 'package:web/web.dart' as web;

const _dbName = 'lx-fampad-e2ee';
const _store = 'kv';

/// Eine zweite, rohe Verbindung zur Datenbank (wie ein anderer Tab oder die Entwicklerwerkzeuge des Browsers).
Future<web.IDBDatabase> _roh() {
  final c = Completer<web.IDBDatabase>();
  final req = web.window.indexedDB.open(_dbName, 1);
  req.onupgradeneeded = ((web.Event _) => (req.result! as web.IDBDatabase).createObjectStore(_store)).toJS;
  req.onsuccess = ((web.Event _) => c.complete(req.result! as web.IDBDatabase)).toJS;
  req.onerror = ((web.Event _) => c.completeError(StateError('roh: open'))).toJS;
  return c.future;
}

Future<void> _aufTransaktion(void Function(web.IDBObjectStore s) aktion) async {
  final db = await _roh();
  final c = Completer<void>();
  final tx = db.transaction(_store.toJS, 'readwrite');
  tx.oncomplete = ((web.Event _) => c.complete()).toJS;
  tx.onerror = ((web.Event _) => c.completeError(StateError('roh: tx'))).toJS;
  aktion(tx.objectStore(_store));
  await c.future;
  db.close();
}

/// Entspricht "Websitedaten löschen": alles in der Ablage (Einträge und Wrapper-Schlüssel) ist weg.
Future<void> _leeren() => _aufTransaktion((s) => s.clear());

/// Nur der Wrapper-Schlüssel geht verloren (die verschlüsselten Einträge bleiben, z. B. teilweise gelöschte Daten).
Future<void> _wrapperLoeschen() => _aufTransaktion((s) => s.delete('__wrap'.toJS));

/// Legt den rohen Wert eines Eintrags unter einem anderen Namen ab (Vertauschung ohne Entschlüsselung).
Future<void> _rohKopieren(String von, String nach) async {
  final db = await _roh();
  final c = Completer<void>();
  final tx = db.transaction(_store.toJS, 'readwrite');
  tx.oncomplete = ((web.Event _) => c.complete()).toJS;
  tx.onerror = ((web.Event _) => c.completeError(StateError('roh: kopieren'))).toJS;
  final s = tx.objectStore(_store);
  final r = s.get('e:$von'.toJS);
  r.onsuccess = ((web.Event _) => s.put(r.result, 'e:$nach'.toJS)).toJS;
  await c.future;
  db.close();
}

Uint8List _bytes(int n, [int start = 1]) => Uint8List.fromList([for (var i = 0; i < n; i++) (start + i) % 256]);

Future<SchluesselSpeicherFehler> _fehler(Future<Object?> f) async {
  try {
    await f;
  } on SchluesselSpeicherFehler catch (e) {
    return e;
  }
  throw StateError('Es wurde kein SchluesselSpeicherFehler geworfen');
}

void main() {
  setUp(_leeren);

  test('Roundtrip; ein fehlender Eintrag ist null (kein Fehler)', () async {
    final s = WebSchluesselSpeicher();
    expect(await s.lesen('e2ee.pk.anna'), isNull);
    await s.schreiben('e2ee.pk.anna', _bytes(64));
    expect(await s.lesen('e2ee.pk.anna'), _bytes(64));
    expect(await s.lesen('e2ee.pk.ben'), isNull);
  });

  test('IndexedDB geleert (Websitedaten gelöscht): null, nie ein Fehler und nie ein neuer Schlüssel; neues Schreiben funktioniert wieder', () async {
    final s = WebSchluesselSpeicher();
    await s.schreiben('e2ee.pk.anna', _bytes(64));
    await s.schreiben('e2ee.quarantaene.anna.5', _bytes(8));
    await _leeren();
    // dieselbe Instanz (hält noch die alte Verbindung) und eine frische sehen "nicht vorhanden"
    expect(await s.lesen('e2ee.pk.anna'), isNull);
    expect(await WebSchluesselSpeicher().lesen('e2ee.pk.anna'), isNull);
    expect(await s.namenMitPraefix('e2ee.'), isEmpty);
    // die App darf danach neu verbinden: ein neuer Wrapper-Schlüssel entsteht, der neue Eintrag ist lesbar
    await s.schreiben('e2ee.pk.anna', _bytes(64, 9));
    expect(await WebSchluesselSpeicher().lesen('e2ee.pk.anna'), _bytes(64, 9));
  });

  test('Wrapper-Schlüssel verloren, Eintrag noch da: DAUERHAFTER Fehler (nicht null), damit die App ihn in die Quarantäne verschiebt', () async {
    final s = WebSchluesselSpeicher();
    await s.schreiben('e2ee.pk.anna', _bytes(64));
    await _wrapperLoeschen();
    final f = await _fehler(WebSchluesselSpeicher().lesen('e2ee.pk.anna'));
    expect(f.dauerhaft, isTrue);
    // der Eintrag existiert weiter und lässt sich unverändert verschieben
    final neu = WebSchluesselSpeicher();
    expect(await neu.verschiebe('e2ee.pk.anna', 'e2ee.quarantaene.anna.7'), isTrue);
    expect(await neu.namenMitPraefix('e2ee.quarantaene.anna.'), ['e2ee.quarantaene.anna.7']);
    expect((await _fehler(neu.lesen('e2ee.quarantaene.anna.7'))).dauerhaft, isTrue, reason: 'der Eintrag liegt noch da (kein null)');
    expect(await neu.lesen('e2ee.pk.anna'), isNull);
  });

  test('Verschieben (Quarantäne) behält den Inhalt: unter dem neuen Namen mit der AAD des alten Namens lesbar; Mehrfachverschieben ebenso', () async {
    final s = WebSchluesselSpeicher();
    await s.schreiben('e2ee.pk.anna', _bytes(64));
    expect(await s.verschiebe('e2ee.pk.anna', 'e2ee.quarantaene.anna.1'), isTrue);
    expect(await s.lesen('e2ee.pk.anna'), isNull);
    expect(await s.lesen('e2ee.quarantaene.anna.1'), _bytes(64));
    expect(await s.verschiebe('e2ee.quarantaene.anna.1', 'e2ee.quarantaene.anna.2'), isTrue);
    expect(await s.lesen('e2ee.quarantaene.anna.2'), _bytes(64));
    expect(await s.verschiebe('gibt.es.nicht', 'egal'), isFalse);
  });

  test('vertauschter Eintrag (roh unter anderem Namen abgelegt): nicht lesbar (AAD = Name), dauerhafter Fehler; das Original bleibt', () async {
    final s = WebSchluesselSpeicher();
    await s.schreiben('e2ee.pk.anna', _bytes(64));
    await _rohKopieren('e2ee.pk.anna', 'e2ee.pk.ben');
    expect((await _fehler(s.lesen('e2ee.pk.ben'))).dauerhaft, isTrue);
    expect(await s.lesen('e2ee.pk.anna'), _bytes(64));
  });

  test('einzelnes Löschen entfernt nur den einen Eintrag; Wrapper-Schlüssel und andere Einträge bleiben lesbar', () async {
    final s = WebSchluesselSpeicher();
    await s.schreiben('a', _bytes(4));
    await s.schreiben('b', _bytes(4, 50));
    await s.loeschen('a');
    expect(await s.lesen('a'), isNull);
    expect(await s.lesen('b'), _bytes(4, 50));
  });

  test('zwei Tabs ohne Wrapper-Schlüssel schreiben gleichzeitig: beide Einträge bleiben lesbar (ein gemeinsamer Wrapper)', () async {
    final tab1 = WebSchluesselSpeicher();
    final tab2 = WebSchluesselSpeicher();
    await Future.wait([tab1.schreiben('e1', _bytes(32, 1)), tab2.schreiben('e2', _bytes(32, 100))]);
    final tab3 = WebSchluesselSpeicher();
    expect(await tab3.lesen('e1'), _bytes(32, 1));
    expect(await tab3.lesen('e2'), _bytes(32, 100));
  });

  test('dauerhafter Speicher: die Abfrage wirft nie, ist stabil und fragt nie nach; die Anforderung kommt höchstens einmal je Sitzung', () async {
    final s = WebSchluesselSpeicher();
    final erste = await s.dauerhaftigkeit();
    expect(erste, isNot(SpeicherDauer.nichtZutreffend), reason: 'im Browser gibt es diese Frage');
    expect(await s.dauerhaftigkeit(), erste, reason: 'gemerkt, nicht erneut abgefragt');
    final angefordert = await s.dauerhaftAnfordern();
    expect(angefordert, isIn([SpeicherDauer.gewaehrt, SpeicherDauer.verweigert, SpeicherDauer.unbekannt]));
    expect(await s.dauerhaftAnfordern(), angefordert, reason: 'höchstens einmal je Sitzung');
    expect(await s.dauerhaftigkeit(), angefordert, reason: 'das Ergebnis der Anforderung ersetzt die gemerkte Abfrage');
  });
}
