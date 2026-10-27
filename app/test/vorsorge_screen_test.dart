// Vorsorge und Impfungen (Abschnitt 6p): Oberfläche. Karten (Fällig oder überfällig, Bald, Später oder erledigt, Nur ein Hinweis), Personenauswahl ("Ich + meine Kinder"), Erledigt eintragen,
// Vorlagen hinzufügen (mit Profil-Abfrage), leerer Zustand, Pflichthinweis mit Quelle, Mehr-Blatt und Desktop-Seitenleiste; bei 360 px und Textskala 1.0/1.5/2.0.
// Daten kommen über überschriebene Provider (kein Schlüsselmaterial nötig), die Schreibwege über ein aufzeichnendes Repository. Feste Uhr: Samstag, 24.10.2026, 12:00 Uhr Berlin.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/constants.dart';
import 'package:lx_fampad/data/api/models.dart';
import 'package:lx_fampad/data/erinnerungen/erinnerung_dienst.dart' show erinnerungPortProvider;
import 'package:lx_fampad/data/vorsorge/vorsorge_modelle.dart';
import 'package:lx_fampad/data/vorsorge/vorsorge_repository.dart';
import 'package:lx_fampad/data/vorsorge/vorsorge_state.dart';
import 'package:lx_fampad/features/shell/shell_tab.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import 'support/fake_erinnerung_port.dart';
import 'support/fake_server.dart';
import 'support/harness.dart';

const _ich = fixIdAdmin;
const _kind = fixIdKind;

UserDto _u(String id, Role r, String name) => UserDto(id: id, email: null, displayName: name, colorIndex: id == _ich ? 0 : 1, role: r, status: MemberStatus.active);

var _n = 0;
VorsorgeAnsicht _e(String subjekt, VorsorgeEintragInhalt? i) => VorsorgeAnsicht(id: 'dddddddd-0000-4000-8000-${(++_n).toString().padLeft(12, '0')}', konversationId: 'k$subjekt', subjektId: subjekt, inhalt: i, hinweis: i == null ? 'nicht lesbar' : null, erstelltAt: DateTime.utc(2026, 10, 1));

VorsorgeProfilAnsicht _p(String subjekt, String geburt) => VorsorgeProfilAnsicht(subjektId: subjekt, inhalt: VorsorgeProfilInhalt(geburt: geburt));

class _Daten extends Notifier<VorsorgeDaten> {
  final VorsorgeDaten start;
  _Daten(this.start);
  @override
  VorsorgeDaten build() => start;
}

class _Repo implements VorsorgeRepository {
  final angelegt = <({String subjekt, VorsorgeEintragInhalt inhalt})>[];
  final profile = <({String subjekt, VorsorgeProfilInhalt profil})>[];
  final erledigt = <({String id, DateTime? tag, String? notiz})>[];
  final geloescht = <String>[];
  Object? fehler;

  @override
  Future<String> anlegen(String subjektId, VorsorgeEintragInhalt inhalt) async {
    if (fehler != null) throw fehler!;
    angelegt.add((subjekt: subjektId, inhalt: inhalt));
    return 'neu';
  }

  @override
  Future<void> profilSetzen(String subjektId, VorsorgeProfilInhalt profil) async {
    if (fehler != null) throw fehler!;
    profile.add((subjekt: subjektId, profil: profil));
  }

  @override
  Future<void> erledigtEintragen(String id, {DateTime? tag, String? notiz}) async {
    if (fehler != null) throw fehler!;
    erledigt.add((id: id, tag: tag, notiz: notiz));
  }

  @override
  Future<void> loeschen(String id) async => geloescht.add(id);

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError('${invocation.memberName}');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tzdata.initializeTimeZones();
  setUpAll(testVorbereiten);

  late _Repo repo;
  late NotifierProvider<_Daten, VorsorgeDaten> daten;

  VorsorgeDaten d(Role rolle, List<VorsorgeAnsicht> e, {bool kinder = false, Map<String, VorsorgeProfilAnsicht> profile = const {}}) => VorsorgeDaten(
    geladen: true,
    ich: _ich,
    ichRolle: rolle,
    personen: [_u(_ich, rolle, 'Anna'), if (kinder) _u(_kind, Role.child, 'Ben')],
    eintraege: e,
    profile: profile,
  );

  Future<ProviderContainer> start(WidgetTester tester, VorsorgeDaten start, {String role = 'parent', double skala = 1.0, Size groesse = const Size(360, 800)}) async {
    repo = _Repo();
    daten = NotifierProvider<_Daten, VorsorgeDaten>(() => _Daten(start));
    final env = await angemeldeteUmgebung(role: role);
    env.extraOverrides.addAll([
      erinnerungPortProvider.overrideWithValue(FakeErinnerungPort()..verfuegbar = false),
      vorsorgeDatenProvider.overrideWith((ref) => ref.watch(daten)),
      vorsorgeAnsichtProvider.overrideWith((ref) => ref.watch(daten)),
      vorsorgeRepositoryProvider.overrideWithValue(repo),
    ]);
    final c = await starteApp(tester, env, skala: skala, groesse: groesse);
    if (groesse.width >= kDesktopBreakpoint) {
      c.read(shellTabProvider.notifier).waehlen(kVorsorgeTab);
      await warte(tester);
    } else {
      await zumBereich(tester, 'Vorsorge');
    }
    return c;
  }

  // Anna (Elternteil) ist am 04.04.1985 geboren: Check-up ab 35 noch nie eingetragen (fällig), Hautkrebs-Screening vor Kurzem (später), ein eigener Termin in vier Wochen (bald), FSME nur als Hinweis
  VorsorgeDaten mitEintraegen({bool kinder = false}) => d(
    Role.parent,
    [
      _e(_ich, const VorsorgeEintragInhalt(vorlage: 'checkup_35', art: VorsorgeArt.vorsorge)),
      _e(_ich, const VorsorgeEintragInhalt(vorlage: 'hautkrebs', art: VorsorgeArt.vorsorge, erledigt: ['2026-09-01'])),
      _e(_ich, const VorsorgeEintragInhalt(name: 'Augenarzt', art: VorsorgeArt.sonstiges, naechstes: '2026-11-20')),
      _e(_ich, const VorsorgeEintragInhalt(vorlage: 'fsme_risiko', art: VorsorgeArt.impfung)),
      if (kinder) _e(_kind, const VorsorgeEintragInhalt(vorlage: 'u4', art: VorsorgeArt.vorsorge)),
    ],
    kinder: kinder,
    profile: {_ich: _p(_ich, '1985-04-04'), if (kinder) _kind: _p(_kind, '2026-08-01')},
  );

  group('Übersicht', () {
    testWidgets('Karten, Stand, Hinweise zur Verlässlichkeit und der Pflichthinweis mit Quelle', (tester) async {
      await start(tester, mitEintraegen());
      expect(labelFinder('Fällig oder überfällig · 1'), findsOneWidget);
      expect(labelFinder('Bald · 1'), findsOneWidget);
      expect(labelFinder('Später oder erledigt · 1'), findsOneWidget);
      expect(labelFinder('Nur ein Hinweis · 1'), findsOneWidget);
      expect(find.text('Gesundheits-Check-up (ab 35 Jahren)'), findsOneWidget);
      expect(find.textContaining('Fällig seit'), findsOneWidget);
      expect(find.text('Augenarzt'), findsOneWidget);
      expect(find.textContaining('Ab 20.11.2026'), findsOneWidget);
      expect(find.text('FSME (Risikogebiet)'), findsOneWidget);
      expect(find.text('Geboren am 04.04.1985'), findsOneWidget);
      // ungeprüfte und Hinweis-Einträge sagen es ehrlich
      expect(find.textContaining('Nur ein Hinweis, kein festes Zeitfenster.'), findsOneWidget);
      // der Pflichthinweis steht immer da
      expect(find.textContaining('keine ärztliche Beratung'), findsOneWidget);
      expect(find.textContaining('Stand Oktober 2026'), findsOneWidget);
      pruefeLayout(tester, 'Übersicht');
    });

    testWidgets('leerer Zustand erklärt in zwei Sätzen und bietet das Hinzufügen an; ohne Geburtsdatum der Hinweis darauf', (tester) async {
      await start(tester, d(Role.parent, const []));
      expect(find.text('Noch nichts eingetragen'), findsOneWidget);
      expect(find.textContaining('Ende-zu-Ende verschlüsselt'), findsOneWidget);
      expect(find.textContaining('Noch kein Geburtsdatum'), findsOneWidget);
      expect(find.textContaining('keine ärztliche Beratung'), findsOneWidget);
      pruefeLayout(tester, 'leer');
    });

    testWidgets('nicht lesbare Einträge werden gezeigt, ohne Inhalt', (tester) async {
      await start(tester, d(Role.parent, [_e(_ich, null)], profile: {_ich: _p(_ich, '1985-04-04')}));
      expect(find.textContaining('lässt sich gerade nicht lesen'), findsOneWidget);
    });

    testWidgets('Eltern sehen Chips für sich und ihre Kinder und wechseln die Person; die Kinder-Einträge stehen nur dort', (tester) async {
      await start(tester, mitEintraegen(kinder: true));
      expect(find.bySemanticsLabel('Meine Vorsorge'), findsOneWidget);
      expect(find.bySemanticsLabel('Vorsorge von Ben'), findsOneWidget);
      expect(find.text('U4 (3. bis 4. Monat)'), findsNothing);
      await tippe(tester, find.bySemanticsLabel('Vorsorge von Ben'));
      expect(find.text('U4 (3. bis 4. Monat)'), findsOneWidget);
      expect(find.text('Augenarzt'), findsNothing);
      expect(find.text('Geboren am 01.08.2026'), findsOneWidget);
      pruefeLayout(tester, 'Kind');
    });

    testWidgets('ein Kind sieht nur sich selbst: keine Chips', (tester) async {
      await start(tester, VorsorgeDaten(geladen: true, ich: _ich, ichRolle: Role.child, personen: [_u(_ich, Role.child, 'Ben')], eintraege: [_e(_ich, const VorsorgeEintragInhalt(vorlage: 'u4', art: VorsorgeArt.vorsorge))], profile: {_ich: _p(_ich, '2026-08-01')}), role: 'child');
      expect(find.bySemanticsLabel('Meine Vorsorge'), findsNothing);
      expect(find.text('U4 (3. bis 4. Monat)'), findsOneWidget);
    });
  });

  group('Aktionen', () {
    testWidgets('Erledigt eintragen: ein Tipp öffnet den Dialog mit heutigem Datum, Eintragen schreibt', (tester) async {
      await start(tester, mitEintraegen());
      await tippe(tester, find.byTooltip('Erledigt eintragen: Gesundheits-Check-up (ab 35 Jahren)'));
      expect(find.text('Erledigt eintragen'), findsWidgets);
      expect(find.text('24.10.2026'), findsOneWidget, reason: 'vorbelegt mit heute');
      await tippe(tester, find.widgetWithText(FilledButton, 'Eintragen'));
      expect(repo.erledigt, hasLength(1));
      expect(repo.erledigt.single.notiz, isNull);
    });

    testWidgets('Hinzufügen mit Profil: empfohlene Vorlagen zuerst, Tipp legt den Eintrag an', (tester) async {
      await start(tester, d(Role.parent, const [], profile: {_ich: _p(_ich, '1985-04-04')}));
      await tippe(tester, find.widgetWithText(FilledButton, 'Hinzufügen'));
      expect(labelFinder('Empfohlen für das Alter'), findsOneWidget);
      expect(find.textContaining('Weitere Vorlagen'), findsOneWidget);
      expect(find.textContaining('keine ärztliche Beratung'), findsWidgets);
      await tester.scrollUntilVisible(find.text('Eigener Eintrag'), 200, scrollable: find.descendant(of: find.byType(BottomSheet), matching: find.byType(Scrollable)).first);
      expect(find.text('Eigener Eintrag'), findsOneWidget);
      await tippe(tester, find.text('Hautkrebs-Screening'));
      expect(repo.angelegt.single.subjekt, _ich);
      expect(repo.angelegt.single.inhalt.vorlage, 'hautkrebs');
      expect(repo.angelegt.single.inhalt.art, VorsorgeArt.vorsorge);
    });

    testWidgets('Hinzufügen ohne Profil fragt zuerst nach dem Geburtsdatum (mit Begründung)', (tester) async {
      await start(tester, d(Role.parent, const []));
      await tippe(tester, find.widgetWithText(FilledButton, 'Hinzufügen'));
      expect(find.textContaining('Der Server sieht sie nie'), findsOneWidget);
      expect(find.text('Datum wählen'), findsOneWidget);
      await tippe(tester, find.widgetWithText(FilledButton, 'Speichern'));
      expect(find.text('Wähle das Geburtsdatum.'), findsOneWidget);
      expect(repo.profile, isEmpty);
      pruefeLayout(tester, 'Profil');
    });

    testWidgets('Fehler beim Speichern stehen im Dialog, nie als Absturz', (tester) async {
      await start(tester, mitEintraegen());
      await tippe(tester, find.byTooltip('Erledigt eintragen: Gesundheits-Check-up (ab 35 Jahren)'));
      repo.fehler = StateError('geheim');
      await tippe(tester, find.widgetWithText(FilledButton, 'Eintragen'));
      expect(find.textContaining('Das hat gerade nicht geklappt'), findsOneWidget);
      expect(find.textContaining('geheim'), findsNothing);
    });

    testWidgets('Detail: Hinweis, Quelle, Erledigt-Liste und Löschen mit Rückfrage', (tester) async {
      await start(tester, mitEintraegen());
      await tippe(tester, find.text('Hautkrebs-Screening'));
      expect(find.textContaining('Ab 35 Jahren alle 2 Jahre.'), findsOneWidget);
      expect(find.textContaining('bundesgesundheitsministerium.de'), findsOneWidget, reason: 'Quelle als Text');
      expect(find.text('01.09.2026'), findsOneWidget);
      expect(find.text('Link kopieren'), findsOneWidget);
      await tippe(tester, find.text('Eintrag löschen'));
      expect(find.text('Eintrag löschen?'), findsOneWidget);
      expect(repo.geloescht, isEmpty);
      await tippe(tester, find.widgetWithText(FilledButton, 'Löschen'));
      expect(repo.geloescht, hasLength(1));
      pruefeLayout(tester, 'Detail');
    });
  });

  for (final skala in [1.5, 2.0]) {
    testWidgets('Layout bei 360 px und Textskala $skala (Übersicht, Hinzufügen, Dialog)', (tester) async {
      await start(tester, mitEintraegen(kinder: true), skala: skala);
      pruefeLayout(tester, 'Übersicht $skala');
      await tippe(tester, find.widgetWithText(FilledButton, 'Hinzufügen'));
      pruefeLayout(tester, 'Blatt $skala');
    });
  }

  group('Kind: nur ansehen', () {
    VorsorgeDaten kind() => VorsorgeDaten(
      geladen: true,
      ich: _ich,
      ichRolle: Role.child,
      personen: [_u(_ich, Role.child, 'Ben')],
      eintraege: [_e(_ich, const VorsorgeEintragInhalt(vorlage: 'u4', art: VorsorgeArt.vorsorge)), _e(_ich, const VorsorgeEintragInhalt(vorlage: 'mmr', art: VorsorgeArt.impfung, erledigt: ['2026-09-01']))],
      profile: {_ich: _p(_ich, '2026-08-01')},
    );

    for (final skala in [1.0, 1.5, 2.0]) {
      testWidgets('Übersicht ohne Schreibwege, mit ruhigem Satz (360 px, Textskala $skala)', (tester) async {
        final h = tester.ensureSemantics();
        await start(tester, kind(), role: 'child', skala: skala);
        expect(find.text('Deine Eltern tragen das ein. Du kannst hier nachsehen.'), findsOneWidget);
        expect(find.text('U4 (3. bis 4. Monat)'), findsOneWidget);
        expect(find.widgetWithText(FilledButton, 'Hinzufügen'), findsNothing);
        expect(find.text('Ändern'), findsNothing);
        expect(find.textContaining('Erledigt eintragen'), findsNothing);
        expect(find.byTooltip(RegExp(r'^Erledigt eintragen')), findsNothing);
        pruefeLayout(tester, 'Kind $skala');
        await tippe(tester, find.text('U4 (3. bis 4. Monat)'));
        expect(find.text('Erledigt eintragen'), findsNothing);
        expect(find.text('Bearbeiten'), findsNothing);
        expect(find.text('Eintrag löschen'), findsNothing);
        expect(find.textContaining('Quelle'), findsWidgets);
        pruefeLayout(tester, 'Kind Detail $skala');
        h.dispose();
      });
    }

    testWidgets('leer: keine Auswahl, kein Knopf', (tester) async {
      await start(tester, VorsorgeDaten(geladen: true, ich: _ich, ichRolle: Role.child, personen: [_u(_ich, Role.child, 'Ben')]), role: 'child');
      expect(find.text('Sobald deine Eltern etwas eintragen, siehst du es hier.'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Hinzufügen'), findsNothing);
      expect(find.text('Eintragen'), findsNothing);
    });
  });

  group('Einstieg', () {
    testWidgets('Mehr-Blatt: Eintrag Vorsorge für alle Rollen, ohne Zahl', (tester) async {
      await start(tester, d(Role.child, const []), role: 'child');
      expect(find.text('Vorsorge'), findsWidgets);
    });

    testWidgets('Desktop: Eintrag in der Seitenleiste, Bereich im Inhaltsbereich, Seitenleiste bleibt', (tester) async {
      await start(tester, mitEintraegen(), groesse: const Size(1280, 900));
      expect(find.text('Vorsorge'), findsWidgets);
      expect(find.text('Gesundheits-Check-up (ab 35 Jahren)'), findsOneWidget);
      expect(find.byType(NavigationRail).evaluate().isNotEmpty || find.text('Medikamente').evaluate().isNotEmpty, isTrue);
    });
  });
}
