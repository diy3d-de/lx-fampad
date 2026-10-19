// Terminerinnerungen: Dienst gegen die echte lokale Datenbank und einen Fake-Port (kein Plugin): erste Planung, Änderung/Löschen/Entfernen der
// Erinnerung räumt auf, unveränderte Daten lösen keinen neuen Aufruf aus, Einstellungen, Abmelden, Tippen auf die Benachrichtigung.
import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/app_database.dart';
import 'package:lx_fampad/data/auth/auth_state.dart';
import 'package:lx_fampad/data/erinnerungen/erinnerung_dienst.dart';
import 'package:lx_fampad/data/erinnerungen/erinnerung_einstellungen.dart';
import 'package:lx_fampad/data/erinnerungen/erinnerung_planung.dart';
import 'package:lx_fampad/features/calendar/calendar_state.dart';
import 'package:lx_fampad/features/calendar/erinnerung_steuerung.dart';
import 'package:lx_fampad/features/shell/shell_tab.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import 'support/fake_erinnerung_port.dart';
import 'support/fake_server.dart';
import 'support/harness.dart' show angemeldeteUmgebung;
import 'support/test_app.dart';

final jetzt = DateTime.utc(2026, 10, 19, 10);

TermineCompanion zeile(String id, {int? min = 15, String start = '2026-10-20T12:30:00Z', String ende = '2026-10-20T13:30:00Z', String owner = fixIdAdmin}) => TermineCompanion.insert(
  id: id,
  titel: 'Termin $id',
  startUtc: Value(DateTime.parse(start)),
  endUtc: Value(DateTime.parse(ende)),
  tzid: const Value('Europe/Berlin'),
  erinnerungMin: Value(min),
  ownerId: Value(owner),
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
    ]);
    c = env.container();
    addTearDown(c.dispose);
    await c.read(authProvider.notifier).start();
    c.listen(erinnerungSteuerungProvider, (_, _) {}); // wie ref.watch in HomeShell
    await bis(() => port.planungen.isNotEmpty, grund: 'erste Planung');
    await ruhe();
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
    final geloescht = port.geloescht;
    await c.read(authProvider.notifier).abmelden(nurLokal: true);
    await bis(() => port.geloescht > geloescht, grund: 'Löschen beim Abmelden');
  });

  test('Tippen auf die Benachrichtigung öffnet den Kalender (Monat, Tag des Termins); ungültiger Inhalt wird ignoriert', () async {
    port.tippe(erinnerungPayload('t1', DateTime.utc(2026, 11, 3)));
    expect(c.read(shellTabProvider), kKalenderTab);
    final a = c.read(kalenderAuswahlProvider);
    expect(a.ansicht, KalenderAnsicht.monat);
    expect(a.tag, DateTime.utc(2026, 11, 3));
    c.read(shellTabProvider.notifier).waehlen(0);
    port.tippe('unsinn');
    expect(c.read(shellTabProvider), 0);
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

  test('Einstellungen: Speicherfehler führen zu Standardwerten, gespeicherte Werte werden gelesen', () async {
    final s2 = MemoryErinnerungSpeicher()..wirft = true;
    final c2 = ProviderContainer(overrides: [erinnerungSpeicherProvider.overrideWithValue(s2)]);
    addTearDown(c2.dispose);
    expect(c2.read(erinnerungEinstellungenProvider), const ErinnerungEinstellungen());
    await c2.read(erinnerungEinstellungenProvider.notifier).bereit;
    expect(c2.read(erinnerungEinstellungenProvider).an, isTrue);
    await c2.read(erinnerungEinstellungenProvider.notifier).vorlaufSetzen(60); // wirft nicht, gilt im Speicher
    expect(c2.read(erinnerungEinstellungenProvider).standardVorlauf, 60);

    final s3 = MemoryErinnerungSpeicher()..daten.addAll({'erinnerung_an': 'nein', 'erinnerung_vorlauf': '1440'});
    final c3 = ProviderContainer(overrides: [erinnerungSpeicherProvider.overrideWithValue(s3)]);
    addTearDown(c3.dispose);
    c3.read(erinnerungEinstellungenProvider);
    await c3.read(erinnerungEinstellungenProvider.notifier).bereit;
    expect(c3.read(erinnerungEinstellungenProvider), const ErinnerungEinstellungen(an: false, standardVorlauf: 1440));

    final s4 = MemoryErinnerungSpeicher()..daten['erinnerung_vorlauf'] = '7'; // kein Auswahlwert: ignoriert
    final c4 = ProviderContainer(overrides: [erinnerungSpeicherProvider.overrideWithValue(s4)]);
    addTearDown(c4.dispose);
    c4.read(erinnerungEinstellungenProvider);
    await c4.read(erinnerungEinstellungenProvider.notifier).bereit;
    expect(c4.read(erinnerungEinstellungenProvider).standardVorlauf, isNull);
  });
}
