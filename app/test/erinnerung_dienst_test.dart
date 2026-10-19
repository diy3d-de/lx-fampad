// Terminerinnerungen: Dienst gegen die echte lokale Datenbank und einen Fake-Port (kein Plugin): erste Planung, Änderung/Löschen/Entfernen der
// Erinnerung räumt auf, unveränderte Daten lösen keinen neuen Aufruf aus, Einstellungen, Abmelden, Sitzungsverlust, Kontowechsel,
// Plugin-Fehler mit Wiederholversuch, Rennen mit dem Löschen, Entprellen, Tippen auf die Benachrichtigung.
import 'dart:async';

import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/api/api_client.dart' show SessionLostReason;
import 'package:lx_fampad/data/app_database.dart';
import 'package:lx_fampad/data/auth/auth_state.dart';
import 'package:lx_fampad/data/erinnerungen/erinnerung_dienst.dart';
import 'package:lx_fampad/data/erinnerungen/erinnerung_einstellungen.dart';
import 'package:lx_fampad/data/erinnerungen/erinnerung_planung.dart';
import 'package:lx_fampad/data/sync_state.dart' show lokaleDatenWiper;
import 'package:lx_fampad/features/calendar/calendar_state.dart';
import 'package:lx_fampad/features/calendar/erinnerung_steuerung.dart';
import 'package:lx_fampad/features/shell/shell_tab.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import 'support/fake_erinnerung_port.dart';
import 'support/fake_server.dart';
import 'support/harness.dart' show angemeldeteUmgebung;
import 'support/test_app.dart';

final jetzt = DateTime.utc(2026, 10, 19, 10);

const t1 = '3f2b8c1e-9d4a-4b6f-8a1c-2e7d5f0a9b13';

TermineCompanion zeile(
  String id, {
  int? min = 15,
  String start = '2026-10-20T12:30:00Z',
  String ende = '2026-10-20T13:30:00Z',
  String? owner = fixIdAdmin,
  String audience = 'family',
}) => TermineCompanion.insert(
  id: id,
  titel: 'Termin $id',
  startUtc: Value(DateTime.parse(start)),
  endUtc: Value(DateTime.parse(ende)),
  tzid: const Value('Europe/Berlin'),
  erinnerungMin: Value(min),
  ownerId: Value(owner),
  audience: Value(audience),
  createdAt: DateTime.utc(2026, 10, 1),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  tzdata.initializeTimeZones();

  late TestUmgebung env;
  late FakeErinnerungPort port;
  late MemoryErinnerungSpeicher speicher;
  late ProviderContainer c;

  Future<void> bis(bool Function() bedingung, {String grund = 'Bedingung'}) async {
    for (var i = 0; i < 100; i++) {
      if (bedingung()) return;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    fail('Zeitüberschreitung: $grund');
  }

  /// Wartet, bis keine weiteren Aufrufe mehr kommen.
  Future<void> ruhe() async {
    var n = -1;
    for (var i = 0; i < 20 && n != port.planungen.length + port.geloescht; i++) {
      n = port.planungen.length + port.geloescht;
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }
  }

  setUp(() async {
    env = await angemeldeteUmgebung();
    port = FakeErinnerungPort();
    speicher = MemoryErinnerungSpeicher();
    env.extraOverrides.addAll([
      erinnerungPortProvider.overrideWithValue(port),
      erinnerungSpeicherProvider.overrideWithValue(speicher),
      erinnerungUhrProvider.overrideWithValue(() => jetzt),
      erinnerungEntprellenProvider.overrideWithValue(Duration.zero),
      erinnerungWiederholenProvider.overrideWithValue(const Duration(milliseconds: 150)),
    ]);
    c = env.container();
    addTearDown(c.dispose);
    await c.read(authProvider.notifier).start();
    c.listen(erinnerungSteuerungProvider, (_, _) {}); // wie ref.watch am Wurzel-Widget
    await bis(() => port.planungen.isNotEmpty, grund: 'erste Planung');
    await ruhe();
  });

  test('Status "unbekannt" (Systemaufruf scheitert kurz): keine Neuplanung; echter Wechsel plant neu', () async {
    final n = port.planungen.length;
    port.statusUnbekannt = true;
    await c.read(erinnerungDienstProvider).abgleichen();
    await ruhe();
    expect(port.planungen.length, n);
    port.statusUnbekannt = false;
    port.erlaubt = false;
    await c.read(erinnerungDienstProvider).abgleichen();
    await bis(() => port.planungen.length > n, grund: 'Neuplanung nach echtem Wechsel');
  });

  test('erste Planung ohne Termine ist leer (räumt Altlasten ab)', () {
    expect(port.planungen.first, isEmpty);
    expect(port.exaktFlags.first, isTrue);
  });

  test('neuer Termin mit Erinnerung wird geplant, Änderung ersetzt, Entfernen der Erinnerung und Löschen räumen auf', () async {
    final n0 = port.planungen.length;
    await env.db.into(env.db.termine).insert(zeile('t1'));
    await bis(() => port.planungen.length > n0, grund: 'Planung nach Anlegen');
    expect(port.letzte, hasLength(1));
    expect(port.letzte!.single.zeit, DateTime.utc(2026, 10, 20, 12, 15));

    // Zeit geändert (Sync oder Bearbeiten): neue Planung enthält nur noch die neue Zeit
    final n1 = port.planungen.length;
    await (env.db.update(env.db.termine)..where((t) => t.id.equals('t1'))).write(TermineCompanion(startUtc: Value(DateTime.utc(2026, 10, 21, 8)), endUtc: Value(DateTime.utc(2026, 10, 21, 9))));
    await bis(() => port.planungen.length > n1, grund: 'Planung nach Änderung');
    expect(port.letzte!.single.zeit, DateTime.utc(2026, 10, 21, 7, 45));

    // Erinnerung entfernt: leer
    final n2 = port.planungen.length;
    await (env.db.update(env.db.termine)..where((t) => t.id.equals('t1'))).write(const TermineCompanion(erinnerungMin: Value(null)));
    await bis(() => port.planungen.length > n2, grund: 'Planung nach Entfernen der Erinnerung');
    expect(port.letzte, isEmpty);

    // wieder an, dann Termin gelöscht (Tombstone verschwindet aus der Tabelle): leer
    final n3 = port.planungen.length;
    await (env.db.update(env.db.termine)..where((t) => t.id.equals('t1'))).write(const TermineCompanion(erinnerungMin: Value(15)));
    await bis(() => port.planungen.length > n3);
    expect(port.letzte, hasLength(1));
    final n4 = port.planungen.length;
    await (env.db.delete(env.db.termine)..where((t) => t.id.equals('t1'))).go();
    await bis(() => port.planungen.length > n4, grund: 'Planung nach Löschen');
    expect(port.letzte, isEmpty);
  });

  test('Änderungen ohne Wirkung auf die Planung (Termin ohne Erinnerung, fremder Termin) lösen keinen neuen Aufruf aus', () async {
    await env.db.into(env.db.termine).insert(zeile('t1'));
    await bis(() => port.letzte?.length == 1);
    await ruhe();
    final n = port.planungen.length;
    await env.db.into(env.db.termine).insert(zeile('t2', min: null));
    await env.db.into(env.db.termine).insert(zeile('t3', owner: 'jemand-anderes'));
    await ruhe();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(port.planungen.length, n);
  });

  test('Erinnerungen aus: alles gelöscht und nichts mehr geplant; wieder an: neu geplant', () async {
    await env.db.into(env.db.termine).insert(zeile('t1'));
    await bis(() => port.letzte?.length == 1);
    await ruhe();
    final geloescht = port.geloescht;
    await c.read(erinnerungEinstellungenProvider.notifier).anSetzen(false);
    await bis(() => port.geloescht > geloescht, grund: 'Löschen bei "aus"');
    await ruhe();
    final n = port.planungen.length;
    await env.db.into(env.db.termine).insert(zeile('t4', start: '2026-10-22T12:30:00Z', ende: '2026-10-22T13:30:00Z'));
    await ruhe();
    expect(port.planungen.length, n, reason: 'bei "aus" wird nicht geplant');
    expect(speicher.daten['erinnerung_an'], 'nein');
    await c.read(erinnerungEinstellungenProvider.notifier).anSetzen(true);
    await bis(() => port.planungen.length > n, grund: 'Planung nach "an"');
    expect(port.letzte, hasLength(2));
  });

  test('ohne genaue Alarme wird ungenau geplant', () async {
    port.exakt = false;
    await env.db.into(env.db.termine).insert(zeile('t1'));
    await bis(() => port.letzte?.length == 1);
    expect(port.exaktFlags.last, isFalse);
  });

  test('Abmelden entfernt alle Erinnerungen', () async {
    await env.db.into(env.db.termine).insert(zeile('t1'));
    await bis(() => port.letzte?.length == 1);
    final geloescht = port.geloescht;
    await c.read(authProvider.notifier).abmelden(nurLokal: true);
    await bis(() => port.geloescht > geloescht, grund: 'Löschen beim Abmelden');
  });

  test('Tippen auf die Benachrichtigung öffnet den Kalender (Monat, Tag des Termins); ungültiger Inhalt wird ignoriert', () async {
    port.tippe(erinnerungPayload(t1, DateTime.utc(2026, 11, 3)));
    expect(c.read(shellTabProvider), kKalenderTab);
    final a = c.read(kalenderAuswahlProvider);
    expect(a.ansicht, KalenderAnsicht.monat);
    expect(a.tag, DateTime.utc(2026, 11, 3));
    c.read(shellTabProvider.notifier).waehlen(0);
    port.tippe('unsinn');
    port.tippe('termin|../../x|2026-11-03'); // keine UUID
    expect(c.read(shellTabProvider), 0);
  });

  test('Plugin scheitert: Zustand gilt nicht als gesetzt, ein einmaliger Wiederholversuch holt es nach', () async {
    port.planenOk = false;
    await env.db.into(env.db.termine).insert(zeile('t1'));
    await bis(() => port.ereignisse.contains('planen-misslungen'), grund: 'misslungener Versuch');
    port.planenOk = true;
    await bis(() => port.ereignisse.contains('planen-ende'), grund: 'Wiederholversuch');
    expect(port.letzte, hasLength(1));
  });

  test('Plugin wirft: kein Absturz, der Wiederholversuch plant danach', () async {
    port.planenWirft = true;
    await env.db.into(env.db.termine).insert(zeile('t1'));
    await bis(() => port.ereignisse.contains('planen-fehler'));
    port.planenWirft = false;
    await bis(() => port.letzte?.length == 1, grund: 'Wiederholversuch nach Ausnahme');
    expect(port.letzte, hasLength(1));
  });

  test('Ein weiterer Auslöser während eines Laufs, der mit Ausnahme endet, geht nicht verloren', () async {
    final n0 = port.ereignisse.where((e) => e == 'planen-start').length;
    port.planenBremse = Completer<void>();
    port.planenWirft = true;
    final dienst = c.read(erinnerungDienstProvider);
    await env.db.into(env.db.termine).insert(zeile('t1'));
    await bis(() => port.ereignisse.where((e) => e == 'planen-start').length > n0, grund: 'Lauf gestartet');
    unawaited(dienst.abgleichen()); // zweiter Auslöser mitten im Lauf
    port.planenWirft = false;
    port.planenBremse!.complete();
    await bis(() => port.ereignisse.contains('planen-ende'), grund: 'Folgelauf');
    expect(port.letzte, hasLength(1));
  });

  test('Plugin nicht bereit: nichts geplant, später (Wiederholversuch) klappt es', () async {
    final env2 = await angemeldeteUmgebung();
    final p2 = FakeErinnerungPort()..initOk = false;
    env2.extraOverrides.addAll([
      erinnerungPortProvider.overrideWithValue(p2),
      erinnerungSpeicherProvider.overrideWithValue(MemoryErinnerungSpeicher()),
      erinnerungUhrProvider.overrideWithValue(() => jetzt),
      erinnerungEntprellenProvider.overrideWithValue(Duration.zero),
      erinnerungWiederholenProvider.overrideWithValue(const Duration(milliseconds: 150)),
    ]);
    final c2 = env2.container();
    addTearDown(c2.dispose);
    await c2.read(authProvider.notifier).start();
    await env2.db.into(env2.db.termine).insert(zeile('t1'));
    c2.listen(erinnerungSteuerungProvider, (_, _) {});
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(p2.planungen, isEmpty);
    p2.initOk = true;
    await bis(() => p2.letzte?.length == 1, grund: 'Planung nach Wiederholversuch');
  });

  test('Rennen: Abmelden/Leeren wartet auf den laufenden Planungslauf und löscht danach', () async {
    final dienst = c.read(erinnerungDienstProvider);
    final n0 = port.ereignisse.where((e) => e == 'planen-start').length;
    port.planenBremse = Completer<void>();
    await env.db.into(env.db.termine).insert(zeile('t1'));
    await bis(() => port.ereignisse.where((e) => e == 'planen-start').length > n0, grund: 'Lauf hängt im Plugin');
    final entfernt = dienst.alleEntfernen();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(port.ereignisse.last, 'planen-start', reason: 'Löschen darf nicht in den laufenden Lauf hineinfahren');
    port.planenBremse!.complete();
    await entfernt;
    expect(port.ereignisse.sublist(port.ereignisse.lastIndexOf('planen-start')), ['planen-start', 'planen-ende', 'loeschen']);
  });

  test('Wiper (Leeren der lokalen Daten) entfernt die Erinnerungen', () async {
    await env.db.into(env.db.termine).insert(zeile('t1'));
    await bis(() => port.letzte?.length == 1);
    final geloescht = port.geloescht;
    final wiper = Provider<Future<void> Function()>((ref) => lokaleDatenWiper(ref));
    await c.read(wiper)();
    expect(port.geloescht, greaterThan(geloescht));
  });

  test('Sitzungsverlust (401): Alarme und Daten bleiben, nichts wird gelöscht', () async {
    await env.db.into(env.db.termine).insert(zeile('t1'));
    await bis(() => port.letzte?.length == 1);
    await ruhe();
    final geloescht = port.geloescht;
    c.read(apiClientProvider).onSessionLost?.call(SessionLostReason.abgelaufen);
    await bis(() => c.read(authProvider).status == AuthStatus.abgemeldet, grund: 'abgemeldet');
    expect(c.read(authProvider).hinweis, isNotNull);
    await ruhe();
    await c.read(erinnerungDienstProvider).abgleichen();
    expect(port.geloescht, geloescht);
  });

  test('Kontowechsel: Erinnerungen der früheren Person werden gelöscht, das Konto wird gemerkt', () async {
    expect(speicher.daten['erinnerung_konto'], fixIdAdmin);
    final geloescht = port.geloescht;
    speicher.daten['erinnerung_konto'] = 'eine-andere-person';
    await c.read(erinnerungDienstProvider).abgleichen();
    expect(port.geloescht, greaterThan(geloescht));
    expect(speicher.daten['erinnerung_konto'], fixIdAdmin);
  });

  test('Genauigkeit und Sperrbildschirm-Einstellung gehören zum Planvergleich', () async {
    await env.db.into(env.db.termine).insert(zeile('t1'));
    await bis(() => port.letzte?.length == 1);
    await ruhe();
    final dienst = c.read(erinnerungDienstProvider);
    var n = port.planungen.length;
    await dienst.abgleichen(); // nichts geändert: kein Aufruf
    expect(port.planungen.length, n);
    port.exakt = false; // z. B. Erlaubnis entzogen; wird beim Wiederkehren in die App neu geprüft
    await dienst.abgleichen();
    expect(port.planungen.length, n + 1);
    expect(port.exaktFlags.last, isFalse);
    n = port.planungen.length;
    await c.read(erinnerungEinstellungenProvider.notifier).sperrbildschirmSetzen(true);
    await bis(() => port.planungen.length > n, grund: 'Planung nach Sperrbildschirm-Einstellung');
    expect(port.sperrFlags.last, isTrue);
    expect(port.sperrFlags.first, isFalse, reason: 'Standard: Titel nicht auf dem Sperrbildschirm');
  });

  test('Termin, der für diese Person unsichtbar wird (z. B. "parents" auf dem Kind-Gerät), verschwindet aus der Planung', () async {
    await env.db.into(env.db.termine).insert(zeile('t1', audience: 'parents'));
    await bis(() => port.letzte?.length == 1);
    final n = port.planungen.length;
    await (env.db.delete(env.db.termine)..where((t) => t.id.equals('t1'))).go(); // Sync meldet "hidden": die Zeile wird lokal gelöscht
    await bis(() => port.planungen.length > n, grund: 'Planung nach hidden');
    expect(port.letzte, isEmpty);
  });

  test('Termin ohne Ersteller: nur Teilnehmer werden erinnert', () async {
    await env.db.into(env.db.termine).insert(zeile('t1', owner: null));
    await ruhe();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(port.letzte, isEmpty);
    await env.db.into(env.db.terminTeilnehmer).insert(TerminTeilnehmerCompanion.insert(id: 'x1', terminId: 't1', userId: fixIdAdmin));
    await bis(() => port.letzte?.length == 1, grund: 'als Teilnehmer erinnert');
  });

  test('Entprellen: viele Änderungen hintereinander (ICS-Import) ergeben wenige Läufe', () async {
    final env2 = await angemeldeteUmgebung();
    final p2 = FakeErinnerungPort();
    env2.extraOverrides.addAll([
      erinnerungPortProvider.overrideWithValue(p2),
      erinnerungSpeicherProvider.overrideWithValue(MemoryErinnerungSpeicher()),
      erinnerungUhrProvider.overrideWithValue(() => jetzt),
      erinnerungEntprellenProvider.overrideWithValue(const Duration(milliseconds: 250)),
    ]);
    final c2 = env2.container();
    addTearDown(c2.dispose);
    await c2.read(authProvider.notifier).start();
    c2.listen(erinnerungSteuerungProvider, (_, _) {});
    await bis(() => p2.planungen.isNotEmpty);
    final n = p2.planungen.length;
    for (var i = 0; i < 8; i++) {
      await env2.db.into(env2.db.termine).insert(zeile('i$i', start: '2026-10-2${i + 1}T12:30:00Z', ende: '2026-10-2${i + 1}T13:30:00Z'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    await bis(() => p2.letzte?.length == 8, grund: 'alle acht geplant');
    expect(p2.planungen.length - n, lessThanOrEqualTo(2), reason: 'nicht jeder Einzelschritt ein Lauf');
  });

  test('nicht verfügbar (Web): nichts passiert', () async {
    final web = FakeErinnerungPort()..verfuegbar = false;
    final env2 = await angemeldeteUmgebung();
    env2.extraOverrides.addAll([erinnerungPortProvider.overrideWithValue(web), erinnerungSpeicherProvider.overrideWithValue(MemoryErinnerungSpeicher())]);
    final c2 = env2.container();
    addTearDown(c2.dispose);
    await c2.read(authProvider.notifier).start();
    c2.listen(erinnerungSteuerungProvider, (_, _) {});
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(web.planungen, isEmpty);
    expect(web.initialisiert, 0);
  });

  test('Einstellungen: Speicherfehler führen zu Standardwerten, gespeicherte Werte werden gelesen, frühe Eingaben bleiben', () async {
    final s2 = MemoryErinnerungSpeicher()..wirft = true;
    final c2 = ProviderContainer(overrides: [erinnerungSpeicherProvider.overrideWithValue(s2)]);
    addTearDown(c2.dispose);
    expect(c2.read(erinnerungEinstellungenProvider), const ErinnerungEinstellungen());
    await c2.read(erinnerungEinstellungenProvider.notifier).bereit;
    expect(c2.read(erinnerungEinstellungenProvider).an, isTrue);
    expect(c2.read(erinnerungEinstellungenProvider).sperrbildschirmTitel, isFalse);
    await c2.read(erinnerungEinstellungenProvider.notifier).vorlaufSetzen(60); // wirft nicht, gilt im Speicher
    expect(c2.read(erinnerungEinstellungenProvider).standardVorlauf, 60);

    final s3 = MemoryErinnerungSpeicher()..daten.addAll({'erinnerung_an': 'nein', 'erinnerung_vorlauf': '1440', 'erinnerung_sperrbildschirm': 'ja'});
    final c3 = ProviderContainer(overrides: [erinnerungSpeicherProvider.overrideWithValue(s3)]);
    addTearDown(c3.dispose);
    c3.read(erinnerungEinstellungenProvider);
    await c3.read(erinnerungEinstellungenProvider.notifier).bereit;
    expect(c3.read(erinnerungEinstellungenProvider), const ErinnerungEinstellungen(an: false, standardVorlauf: 1440, sperrbildschirmTitel: true));

    final s4 = MemoryErinnerungSpeicher()..daten['erinnerung_vorlauf'] = '7'; // kein Auswahlwert: ignoriert
    final c4 = ProviderContainer(overrides: [erinnerungSpeicherProvider.overrideWithValue(s4)]);
    addTearDown(c4.dispose);
    c4.read(erinnerungEinstellungenProvider);
    await c4.read(erinnerungEinstellungenProvider.notifier).bereit;
    expect(c4.read(erinnerungEinstellungenProvider).standardVorlauf, isNull);

    // eine Eingabe, bevor das Lesen fertig ist, wird vom Ergebnis des Lesens nicht überschrieben
    final s5 = MemoryErinnerungSpeicher()..daten['erinnerung_an'] = 'nein';
    final c5 = ProviderContainer(overrides: [erinnerungSpeicherProvider.overrideWithValue(s5)]);
    addTearDown(c5.dispose);
    final n5 = c5.read(erinnerungEinstellungenProvider.notifier);
    unawaited(n5.anSetzen(true));
    await n5.bereit;
    expect(c5.read(erinnerungEinstellungenProvider).an, isTrue);
  });
}
