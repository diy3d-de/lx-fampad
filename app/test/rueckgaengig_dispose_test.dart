// Rückgängig-Hinweis: Handlung nach dem Verschwinden des Bildschirms (Abmelden), Schließen beim Leeren der Daten, ehrliche Ablehnung und
// Prüfungen der Repositories (andere Person, Liste oder zuständige Person weg, Doppeltipp).
import 'package:drift/drift.dart' show DatabaseConnection, Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/app_database.dart';
import 'package:lx_fampad/data/lists/list_repository.dart';
import 'package:lx_fampad/data/sync/sync_store.dart';
import 'package:lx_fampad/data/tasks/aufgabe_repository.dart';
import 'package:lx_fampad/widgets/rueckgaengig.dart';

final _p = Provider<int>((ref) => 1);

class _S extends ConsumerStatefulWidget {
  final void Function(int) ergebnis;
  const _S(this.ergebnis);
  @override
  ConsumerState<_S> createState() => _SState();
}

class _SState extends ConsumerState<_S> {
  @override
  Widget build(BuildContext context) => TextButton(
    onPressed: () {
      // wie in den Bildschirmen: den Wert VOR dem Hinweis holen, nie `ref.read` in der Handlung
      final repo = ref.read(_p);
      final ergebnis = widget.ergebnis;
      rueckgaengigZeigen(context, text: 'x gelöscht', rueckgaengig: () async => ergebnis(repo));
    },
    child: const Text('los'),
  );
}

Widget _app(Widget body) => MaterialApp(home: Scaffold(body: body));

void main() {
  tearDown(rueckgaengigSchliessen);

  testWidgets('Rückgängig nach dem Verschwinden des Bildschirms wirft nicht und führt die Handlung aus', (tester) async {
    var zeigen = true;
    late StateSetter set;
    int? gesehen;
    await tester.pumpWidget(
      ProviderScope(
        child: _app(
          StatefulBuilder(
            builder: (c, s) {
              set = s;
              return zeigen ? _S((v) => gesehen = v) : const SizedBox();
            },
          ),
        ),
      ),
    );
    await tester.tap(find.text('los'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 800));
    set(() => zeigen = false);
    await tester.pump();
    await tester.tap(find.text('Rückgängig'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
    expect(gesehen, 1);
  });

  testWidgets('rueckgaengigSchliessen (Daten leeren) schließt den offenen Hinweis', (tester) async {
    await tester.pumpWidget(_app(Builder(builder: (c) => TextButton(onPressed: () => rueckgaengigZeigen(c, text: 'Eintrag gelöscht', rueckgaengig: () async {}), child: const Text('los')))));
    await tester.tap(find.text('los'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 800));
    expect(find.text('Eintrag gelöscht'), findsOneWidget);
    rueckgaengigSchliessen();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Eintrag gelöscht'), findsNothing);
    rueckgaengigSchliessen(); // zweimal ist harmlos
  });

  testWidgets('abgelehnte Handlung: ein kurzer Hinweis nennt den Grund', (tester) async {
    await tester.pumpWidget(
      _app(
        Builder(
          builder: (c) => TextButton(
            onPressed: () => rueckgaengigZeigen(c, text: 'Eintrag gelöscht', rueckgaengig: () async => throw const RueckgaengigAbgelehnt('Rückgängig nicht möglich: Die Liste gibt es nicht mehr.')),
            child: const Text('los'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('los'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 800));
    await tester.tap(find.text('Rückgängig'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Rückgängig nicht möglich: Die Liste gibt es nicht mehr.'), findsOneWidget);
  });

  group('Repositories prüfen vor dem Wiederherstellen', () {
    late AppDatabase db;
    late SyncStore store;
    var ich = 'u-eins';
    var n = 0;
    String neueId() => '00000000-0000-4000-8000-${(++n).toString().padLeft(12, '0')}';
    late AufgabeRepository aufgaben;
    late ListenRepository listen;

    setUp(() {
      db = AppDatabase(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
      store = SyncStore(db);
      ich = 'u-eins';
      aufgaben = AufgabeRepository(db: db, store: store, ich: () => ich, beiAenderung: () {}, jetzt: () => DateTime.utc(2026, 10, 19, 8), neueId: neueId);
      listen = ListenRepository(db: db, store: store, ich: () => ich, beiAenderung: () {}, jetzt: () => DateTime.utc(2026, 10, 19, 8), neueId: neueId);
    });
    tearDown(() => db.close());

    Future<void> mitglieder(List<String> ids) =>
        db.metaSchreiben('members', '[${[for (final i in ids) '{"id":"$i","displayName":"P","colorIndex":0,"role":"parent","status":"active"}'].join(',')}]');

    Future<void> abgelehnt(Future<Object?> Function() f, String teil) async {
      await expectLater(f(), throwsA(isA<RueckgaengigAbgelehnt>().having((e) => e.meldung, 'meldung', contains(teil))));
    }

    test('Aufgabe: andere angemeldete Person lehnt ab, dieselbe stellt wieder her', () async {
      final id = await aufgaben.anlegen(const AufgabeEingabe(titel: 'Müll raus'));
      final a = (await db.select(db.aufgaben).get()).single;
      await aufgaben.loeschen(id);
      await abgelehnt(() => aufgaben.wiederherstellen(a, const [], besitzer: 'u-zwei'), 'andere Person');
      expect(await db.select(db.aufgaben).get(), isEmpty);
      expect(await aufgaben.wiederherstellen(a, const [], besitzer: 'u-eins'), isNotNull);
      expect(await db.select(db.aufgaben).get(), hasLength(1));
    });

    test('Aufgabe: zuständige Person nicht mehr aktiv lehnt ab; ohne bekannte Mitgliederliste wird nicht abgelehnt', () async {
      final id = await aufgaben.anlegen(const AufgabeEingabe(titel: 'Müll raus', zustaendig: 'u-weg'));
      final a = (await db.select(db.aufgaben).get()).single;
      await aufgaben.loeschen(id);
      await mitglieder(['u-eins']);
      await abgelehnt(() => aufgaben.wiederherstellen(a, const [], besitzer: 'u-eins'), 'zuständige Person');
      expect(await db.select(db.aufgaben).get(), isEmpty);
      await db.metaSchreiben('members', '[]');
      expect(await aufgaben.wiederherstellen(a, const [], besitzer: 'u-eins'), isNotNull);
    });

    test('Erledigt zurücknehmen: andere Person lehnt ab; ein zweiter Tipp auf denselben Haken ändert nichts (false)', () async {
      final id = await aufgaben.anlegen(const AufgabeEingabe(titel: 'Müll raus'));
      final a = (await db.select(db.aufgaben).get()).single;
      expect(await aufgaben.erledigt(a, true), isTrue);
      expect(await aufgaben.erledigt(a, true), isFalse, reason: 'Doppeltipp: kein zweiter Hinweis');
      await abgelehnt(() => aufgaben.erledigtZuruecknehmen(a, besitzer: 'u-zwei'), 'andere Person');
      await aufgaben.erledigtZuruecknehmen(a, besitzer: 'u-eins');
      expect((await (db.select(db.aufgaben)..where((t) => t.id.equals(id))).getSingle()).erledigtAt, isNull);
    });

    test('Listeneintrag: andere Person oder gelöschte Liste lehnt ab, keine verwaiste Zeile', () async {
      final l = await listen.listeAnlegen(name: 'Einkauf');
      await listen.eintragAnlegen(l, 'Milch');
      final e = (await db.select(db.listenEintraege).get()).single;
      await listen.eintragLoeschen(e.id);
      await abgelehnt(() => listen.eintragWiederherstellen(e, besitzer: 'u-zwei'), 'andere Person');
      await listen.listeLoeschen(l);
      await abgelehnt(() => listen.eintragWiederherstellen(e, besitzer: 'u-eins'), 'Liste gibt es nicht mehr');
      expect(await db.select(db.listenEintraege).get(), isEmpty);
    });

    test('Listeneintrag: bei vorhandener Liste wird wiederhergestellt; ein nicht mehr aktiv zugewiesenes Mitglied lehnt ab', () async {
      final l = await listen.listeAnlegen(name: 'Einkauf');
      await listen.eintragAnlegen(l, 'Milch');
      final e = (await db.select(db.listenEintraege).get()).single;
      expect(await listen.eintragWiederherstellen(e, besitzer: 'u-eins'), isNotEmpty);
      final mitPerson = e.copyWith(assigneeId: const Value('u-weg'));
      await mitglieder(['u-eins']);
      await abgelehnt(() => listen.eintragWiederherstellen(mitPerson, besitzer: 'u-eins'), 'zuständige Person');
    });
  });
}
