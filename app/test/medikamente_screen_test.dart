// Medikamenten-Plan, Teil 2: Oberfläche. Heute (Gruppen, Filter, Abhaken, Nachtragen, Warnkarte), Detail, Editor (Pflichtangaben, feste Sichtbarkeit, Frist nur für Kinder), Mehr-Blatt mit Zahl,
// Desktop-Seitenleiste, Startseiten-Kachel; Rollen (Erwachsener nur Eigenes, Elternteil mit Kindern, Kind nur Eigenes); bei 360 px und Textskala 1.0/1.5/2.0.
// Daten kommen über überschriebene Provider (kein Schlüsselmaterial nötig), die Schreibwege über ein aufzeichnendes Repository.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/constants.dart';
import 'package:lx_fampad/data/api/models.dart';
import 'package:lx_fampad/data/chat/chat_krypto.dart' show SchluesselFehlt;
import 'package:lx_fampad/data/erinnerungen/erinnerung_dienst.dart' show erinnerungPortProvider;
import 'package:lx_fampad/data/medikamente/medikament_logik.dart';
import 'package:lx_fampad/data/medikamente/medikament_modelle.dart';
import 'package:lx_fampad/data/medikamente/medikament_repository.dart';
import 'package:lx_fampad/data/medikamente/medikament_state.dart';
import 'package:lx_fampad/data/tasks/aufgabe_repository.dart';
import 'package:lx_fampad/features/medikamente/medikamente_screen.dart';
import 'package:lx_fampad/features/shell/shell_tab.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import 'support/fake_erinnerung_port.dart';
import 'support/fake_server.dart';
import 'support/harness.dart';
import 'support/test_app.dart';

const _ich = fixIdAdmin;
const _kind = fixIdKind;
const _med1 = 'dddddddd-0000-4000-8000-000000000001';
const _med2 = 'dddddddd-0000-4000-8000-000000000002';
const _med3 = 'dddddddd-0000-4000-8000-000000000003';

UserDto _u(String id, Role r, String name) => UserDto(id: id, email: null, displayName: name, colorIndex: id == _ich ? 0 : 1, role: r, status: MemberStatus.active);

MedEintrag _e(String id, String subjekt, MedikamentInhalt m, {List<EinnahmeAnsicht> einnahmen = const []}) =>
    MedEintrag(MedikamentAnsicht(id: id, konversationId: 'k$subjekt', subjektId: subjekt, inhalt: m, erstelltAt: DateTime.utc(2026, 10, 1)), einnahmen);

String _heute() => tagText(familienTag(TestUmgebung.testJetzt));

// Frühe Uhrzeit: immer schon vorbei (offen und fällig oder verpasst); späte: noch nicht fällig
MedikamentInhalt _blut({String zeit = '00:01'}) => MedikamentInhalt(name: 'Blutdrucktablette', dosis: '5 mg', zeiten: [zeit, '23:59'], beginn: '2026-10-01');

MedikamentInhalt _vitamin() => MedikamentInhalt(
  name: 'Vitamin D',
  dosis: '1 Tropfen',
  zeiten: const ['00:02'],
  beginn: '2026-10-01',
  bestand: 5,
  bestandStand: TestUmgebung.testJetzt.toUtc(),
  packung: 30,
);

MedikamentInhalt _spray() => const MedikamentInhalt(name: 'Nasenspray', dosis: '1 Hub', rhythmus: Rhythmus.bedarf(), beginn: '2026-10-01');

class _Daten extends Notifier<MedDaten> {
  final MedDaten start;
  _Daten(this.start);
  @override
  MedDaten build() => start;
  void setzen(MedDaten d) => state = d;
}

class _Repo implements MedikamentRepository {
  final calls = <String>[];
  final erfasst = <({String id, Slot? slot, EinnahmeStatus status, DateTime? um})>[];
  final angelegt = <({String subjekt, MedikamentInhalt inhalt})>[];
  final geaendert = <MedikamentInhalt>[];
  Object? fehler;

  @override
  Future<String> einnahmeErfassen(String medikamentId, {Slot? slot, EinnahmeStatus status = EinnahmeStatus.genommen, DateTime? um, double? menge}) async {
    if (fehler != null) throw fehler!;
    erfasst.add((id: medikamentId, slot: slot, status: status, um: um));
    return 'e';
  }

  @override
  Future<void> slotZuruecknehmen(String medikamentId, Slot slot) async => calls.add('zurueck:$medikamentId:${slot.schluessel}');

  @override
  Future<void> einnahmeZuruecknehmen(String einnahmeId) async => calls.add('einzel:$einnahmeId');

  @override
  Future<String> anlegen(String subjektId, MedikamentInhalt inhalt) async {
    if (fehler != null) throw fehler!;
    angelegt.add((subjekt: subjektId, inhalt: inhalt));
    return 'neu';
  }

  @override
  Future<void> aendern(String id, MedikamentInhalt neu) async => geaendert.add(neu);

  @override
  Future<void> pausieren(String id, {DateTime? ab, DateTime? bis}) async => calls.add('pause:$id');

  @override
  Future<void> beenden(String id, {DateTime? ab}) async => calls.add('ende:$id');

  @override
  Future<void> fortsetzen(String id) async => calls.add('fort:$id');

  @override
  Future<void> loeschen(String id) async => calls.add('loeschen:$id');

  @override
  Future<void> vorratAuffuellen(String id, {int packungen = 0, double stueck = 0}) async => calls.add('auffuellen:$id:$packungen:$stueck');

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError('${invocation.memberName}');
}

class _AufgabenRepo implements AufgabeRepository {
  final eingaben = <AufgabeEingabe>[];

  @override
  Future<String> anlegen(AufgabeEingabe e) async {
    eingaben.add(e);
    return 'a';
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError('${invocation.memberName}');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tzdata.initializeTimeZones();
  setUpAll(testVorbereiten);

  late _Repo repo;
  late _AufgabenRepo aufgaben;
  late NotifierProvider<_Daten, MedDaten> daten;

  MedDaten d(Role rolle, List<MedEintrag> e, {bool kinder = false}) => MedDaten(
    geladen: true,
    ich: _ich,
    ichRolle: rolle,
    personen: [_u(_ich, rolle, 'Anna'), if (kinder) _u(_kind, Role.child, 'Ben')],
    eintraege: e,
  );

  Future<(TestUmgebung, ProviderContainer)> start(WidgetTester tester, MedDaten start, {String role = 'parent', double skala = 1.0, Size groesse = const Size(360, 800), String? tab, bool zumBereichGehen = true}) async {
    repo = _Repo();
    aufgaben = _AufgabenRepo();
    daten = NotifierProvider<_Daten, MedDaten>(() => _Daten(start));
    final env = await angemeldeteUmgebung(role: role);
    env.extraOverrides.addAll([
      erinnerungPortProvider.overrideWithValue(FakeErinnerungPort()..verfuegbar = false),
      medDatenProvider.overrideWith((ref) => ref.watch(daten)),
      medAnsichtProvider.overrideWith((ref) => ref.watch(daten)),
      medikamentRepositoryProvider.overrideWithValue(repo),
      aufgabeRepositoryProvider.overrideWithValue(aufgaben),
    ]);
    final c = await starteApp(tester, env, skala: skala, groesse: groesse);
    if (zumBereichGehen) {
      if (groesse.width >= kDesktopBreakpoint) {
        c.read(shellTabProvider.notifier).waehlen(kMedikamenteTab);
        await warte(tester);
      } else {
        await zumBereich(tester, 'Medikamente');
      }
    }
    return (env, c);
  }

  MedDaten eigene() => d(Role.parent, [_e(_med1, _ich, _blut())]);

  group('Heute', () {
    testWidgets('Tagesliste nach Tageszeit, Abhaken schreibt eine Einnahme zum Slot', (tester) async {
      await start(tester, eigene());
      expect(find.text('Medikamente'), findsWidgets);
      expect(find.text('Nachts · 00:01'), findsOneWidget);
      expect(find.text('Abends · 22:00'), findsNothing);
      expect(find.text('Blutdrucktablette · 5 mg'), findsNWidgets(2));
      expect(find.text('0 von 2 erledigt'), findsOneWidget);
      await tippe(tester, find.byKey(ValueKey('med-haken:$_med1:${_heute()}T00:01')));
      expect(repo.erfasst.single.id, _med1);
      expect(repo.erfasst.single.slot!.schluessel, '${_heute()}T00:01');
      expect(repo.erfasst.single.status, EinnahmeStatus.genommen);
      pruefeLayout(tester, 'Heute');
    });

    testWidgets('abgehakte Einnahme: erledigt mit Uhrzeit, Tipp darauf fragt vor dem Zurücknehmen', (tester) async {
      final hakt = EinnahmeAnsicht(
        id: 'e1',
        medikamentId: _med1,
        inhalt: EinnahmeInhalt(status: EinnahmeStatus.genommen, um: TestUmgebung.testJetzt.toUtc(), geplant: '${_heute()}T00:01'),
        erstelltAt: TestUmgebung.testJetzt.toUtc(),
      );
      await start(tester, d(Role.parent, [_e(_med1, _ich, _blut(), einnahmen: [hakt])]));
      expect(find.textContaining('Ich · erledigt '), findsOneWidget);
      expect(find.text('1 von 2 erledigt'), findsOneWidget);
      await tippe(tester, find.byKey(ValueKey('med-haken:$_med1:${_heute()}T00:01')));
      expect(find.text('Einnahme zurücknehmen?'), findsOneWidget);
      expect(repo.calls, isEmpty);
      await tippe(tester, find.widgetWithText(FilledButton, 'Zurücknehmen'));
      expect(repo.calls, ['zurueck:$_med1:${_heute()}T00:01']);
    });

    testWidgets('bei Bedarf steht getrennt und trägt eine Einnahme ohne Slot ein', (tester) async {
      await start(tester, d(Role.parent, [_e(_med2, _ich, _spray())]));
      expect(labelFinder('Bei Bedarf'), findsOneWidget);
      expect(find.text('Heute ist nichts zu nehmen. Pausierte und beendete Pläne findest du unter „Alle Medikamente“.'), findsNothing);
      await tippe(tester, find.byKey(const ValueKey('med-bedarf:$_med2')));
      expect(repo.erfasst.single.slot, isNull);
      expect(find.textContaining('Einnahme eingetragen'), findsOneWidget);
    });

    testWidgets('Warnkarte bei knappem Vorrat', (tester) async {
      await start(tester, d(Role.parent, [_e(_med3, _ich, _vitamin())]));
      expect(find.text('Vorrat oder Rezept beachten'), findsOneWidget);
      expect(find.textContaining('Vitamin D: Vorrat reicht noch'), findsOneWidget);
      expect(find.byWidgetPredicate((w) => w is Text && RegExp(r'^Vorrat \d').hasMatch(w.data ?? '')), findsOneWidget);
      pruefeLayout(tester, 'Warnkarte');
    });

    testWidgets('leerer Zustand: Hinweis und Knopf', (tester) async {
      await start(tester, d(Role.parent, const []));
      expect(find.text('Noch keine Medikamente'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Medikament'), findsOneWidget);
    });

    testWidgets('nicht lesbarer Plan: Hinweis ohne Inhalt, kein Absturz', (tester) async {
      final kaputt = MedEintrag(MedikamentAnsicht(id: _med1, konversationId: 'k', subjektId: _ich, inhalt: null, hinweis: 'nicht lesbar', erstelltAt: DateTime.utc(2026, 10, 1)), const []);
      await start(tester, d(Role.parent, [kaputt]));
      expect(find.textContaining('Nicht lesbar'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('Rollen und Personenfilter', () {
    testWidgets('Erwachsener ohne Kinder: nur Eigenes, kein Filter', (tester) async {
      await start(tester, d(Role.parent, [_e(_med1, _ich, _blut())]));
      expect(find.text('Alle'), findsNothing);
      expect(find.text('Ben'), findsNothing);
      expect(find.text('Blutdrucktablette · 5 mg'), findsWidgets);
    });

    testWidgets('Elternteil sieht eigene und Kinder-Pläne; der Filter wählt eine Person', (tester) async {
      await start(tester, d(Role.parent, [_e(_med1, _ich, _blut()), _e(_med2, _kind, _vitamin())], kinder: true));
      expect(find.text('Alle'), findsOneWidget);
      expect(find.text('Anna'), findsOneWidget);
      expect(find.text('Ben'), findsOneWidget);
      expect(find.text('Vitamin D · 1 Tropfen'), findsWidgets);
      expect(find.text('Blutdrucktablette · 5 mg'), findsWidgets);
      expect(find.textContaining('Ben · '), findsWidgets);
      await tippe(tester, find.bySemanticsLabel('Medikamente von Ben'));
      expect(find.text('Vitamin D · 1 Tropfen'), findsWidgets);
      expect(find.text('Blutdrucktablette · 5 mg'), findsNothing);
      await tippe(tester, find.bySemanticsLabel('Meine Medikamente'));
      expect(find.text('Vitamin D · 1 Tropfen'), findsNothing);
      expect(find.text('Blutdrucktablette · 5 mg'), findsWidgets);
      await tippe(tester, find.text('Alle'));
      expect(find.text('Vitamin D · 1 Tropfen'), findsWidgets);
      pruefeLayout(tester, 'Filter');
    });

    testWidgets('Kind: nur Eigenes (die Datenschicht liefert nichts anderes), kein Filter', (tester) async {
      await start(tester, d(Role.child, [_e(_med1, _ich, _blut())]), role: 'child');
      expect(find.text('Alle'), findsNothing);
      expect(find.text('Blutdrucktablette · 5 mg'), findsWidgets);
    });

    testWidgets('ein Filter auf eine Person, die es nicht mehr gibt, gilt nicht (alles bleibt sichtbar)', (tester) async {
      final (_, c) = await start(tester, d(Role.parent, [_e(_med1, _ich, _blut())]));
      c.read(medFilterProvider.notifier).waehlen('99999999-0000-4000-8000-000000000009');
      await warte(tester);
      expect(find.text('Blutdrucktablette · 5 mg'), findsWidgets);
    });
  });

  group('Detail', () {
    testWidgets('Vorrat als Balken, Rhythmus, wer erinnert und wer es sieht (fest), 7-Tage-Verlauf, Aktionen', (tester) async {
      await start(tester, d(Role.parent, [_e(_med3, _kind, _vitamin())], kinder: true));
      await tippe(tester, find.byKey(const ValueKey('med-plan:$_med3')).evaluate().isEmpty ? find.text('Vitamin D · 1 Tropfen').first : find.byKey(const ValueKey('med-plan:$_med3')));
      expect(find.text('Vitamin D'), findsWidgets);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(find.textContaining('Reicht noch'), findsOneWidget);
      expect(find.textContaining('Warnung ab 7 Tagen'), findsOneWidget);
      expect(find.text('Ben, alle Eltern und Admins'), findsOneWidget);
      expect(find.text('Ben, alle Eltern und Admins (fest)'), findsOneWidget);
      expect(labelFinder('Letzte 7 Tage'), findsOneWidget);
      expect(find.text('Packung aufgefüllt'), findsOneWidget);
      expect(find.text('Einnahme nachtragen'), findsOneWidget);
      expect(find.text('Pausieren'), findsOneWidget);
      expect(find.text('Beenden'), findsOneWidget);
      pruefeLayout(tester, 'Detail');
    });

    testWidgets('eigener Plan: Erinnerung und Sicht nur für mich; Pausieren fragt und ruft die Datenschicht', (tester) async {
      await start(tester, eigene());
      await tippe(tester, find.text('Blutdrucktablette · 5 mg').first);
      expect(find.text('nur dich'), findsOneWidget);
      expect(find.text('nur dich (fest)'), findsOneWidget);
      await tippe(tester, find.text('Pausieren'));
      expect(find.text('Pausieren?'), findsOneWidget);
      await tippe(tester, find.widgetWithText(FilledButton, 'Pausieren'));
      expect(repo.calls, ['pause:$_med1']);
    });

    testWidgets('Packung aufgefüllt: ganze Packungen, ruft die Datenschicht', (tester) async {
      await start(tester, d(Role.parent, [_e(_med3, _ich, _vitamin())]));
      await tippe(tester, find.text('Vitamin D · 1 Tropfen').first);
      await tippe(tester, find.text('Packung aufgefüllt'));
      await tester.enterText(find.byType(TextField), '2');
      await tippe(tester, find.widgetWithText(FilledButton, 'Auffüllen'));
      expect(repo.calls, ['auffuellen:$_med3:2:0.0']);
    });

    testWidgets('Einnahme nachtragen: Slot wählen, speichern; die Datenschicht bekommt Slot und Zeitpunkt', (tester) async {
      await start(tester, eigene());
      await tippe(tester, find.text('Blutdrucktablette · 5 mg').first);
      await tippe(tester, find.text('Einnahme nachtragen'));
      expect(find.text('Einnahme nachtragen'), findsWidgets);
      await tippe(tester, find.text('23:59'));
      await tippe(tester, find.widgetWithText(FilledButton, 'Speichern'));
      // der Nachtrag-Dialog rechnet mit der echten Uhr (Produktivcode), nicht mit der Test-Uhr
      expect(repo.erfasst.single.slot!.schluessel, '${tagText(familienTag(DateTime.now()))}T23:59');
      expect(repo.erfasst.single.um, isNotNull);
    });

    testWidgets('Einnahme nachtragen: ein Fehler der Datenschicht erscheint im Dialog', (tester) async {
      await start(tester, eigene());
      await tippe(tester, find.text('Blutdrucktablette · 5 mg').first);
      await tippe(tester, find.text('Einnahme nachtragen'));
      repo.fehler = const EinnahmeUngueltig('Eine Einnahme kann nicht in der Zukunft liegen.');
      await tippe(tester, find.text('00:01'));
      await tippe(tester, find.widgetWithText(FilledButton, 'Speichern'));
      expect(find.text('Eine Einnahme kann nicht in der Zukunft liegen.'), findsOneWidget);
    });
  });

  group('Editor', () {
    testWidgets('Pflichtangaben, feste Sichtbarkeits-Hinweiskarte, Speichern legt den Plan für die Person an', (tester) async {
      await start(tester, d(Role.parent, const [], kinder: true));
      await tippe(tester, find.widgetWithText(FilledButton, 'Medikament'));
      expect(find.text('Medikament anlegen'), findsOneWidget);
      expect(find.text('Sichtbar nur für dich'), findsOneWidget);
      expect(find.textContaining('Das ist fest und nicht einstellbar'), findsOneWidget);
      await tippe(tester, find.widgetWithText(FilledButton, 'Speichern'));
      expect(find.text('Gib dem Medikament einen Namen.'), findsOneWidget);
      await eingeben(tester, 'Name', 'Blutdrucktablette');
      await eingeben(tester, 'Dosis (z. B. 5 mg · 1 Tablette)', '5 mg');
      await tippe(tester, find.bySemanticsLabel('Für Ben'));
      expect(find.text('Sichtbar für das Kind und alle Eltern'), findsOneWidget);
      await tippe(tester, find.widgetWithText(FilledButton, 'Speichern'));
      expect(repo.angelegt.single.subjekt, _kind);
      final m = repo.angelegt.single.inhalt;
      expect(m.name, 'Blutdrucktablette');
      expect(m.dosis, '5 mg');
      expect(m.zeiten, ['08:00']);
      expect(m.rhythmus.art, RhythmusArt.taeglich);
      expect(m.gueltig, isTrue);
    });

    testWidgets('Rhythmus bei Bedarf: keine Uhrzeiten; Wochentage brauchen mindestens einen Tag', (tester) async {
      await start(tester, d(Role.parent, const []));
      await tippe(tester, find.widgetWithText(FilledButton, 'Medikament'));
      await eingeben(tester, 'Name', 'Nasenspray');
      await tippe(tester, find.text('Wochentage'));
      await tippe(tester, find.widgetWithText(FilledButton, 'Speichern'));
      expect(find.text('Wähle mindestens einen Wochentag.'), findsOneWidget);
      await tippe(tester, find.text('Bei Bedarf'));
      expect(labelFinder('Uhrzeiten'), findsNothing);
      await tippe(tester, find.widgetWithText(FilledButton, 'Speichern'));
      expect(repo.angelegt.single.inhalt.rhythmus.art, RhythmusArt.bedarf);
      expect(repo.angelegt.single.inhalt.zeiten, isEmpty);
    });

    testWidgets('Uhrzeit entfernen: ohne Uhrzeit kein Speichern (feste Zeiten)', (tester) async {
      await start(tester, d(Role.parent, const []));
      await tippe(tester, find.widgetWithText(FilledButton, 'Medikament'));
      await eingeben(tester, 'Name', 'X');
      await tippe(tester, find.byTooltip('Uhrzeit 08:00 entfernen'));
      await tippe(tester, find.widgetWithText(FilledButton, 'Speichern'));
      expect(find.text('Füge mindestens eine Uhrzeit hinzu.'), findsOneWidget);
      expect(repo.angelegt, isEmpty);
    });

    testWidgets('Fehler der Datenschicht (keine Verschlüsselung) erscheint als Meldung', (tester) async {
      await start(tester, d(Role.parent, const []));
      await tippe(tester, find.widgetWithText(FilledButton, 'Medikament'));
      await eingeben(tester, 'Name', 'X');
      repo.fehler = const SchluesselFehlt(['x']);
      await tippe(tester, find.widgetWithText(FilledButton, 'Speichern'));
      expect(find.textContaining('Nachrichten-Schutz noch nicht eingerichtet'), findsOneWidget);
    });

    testWidgets('Rezept läuft ab: Frist nur für Kinder (neutral, nur Eltern), für mich selbst keine Verknüpfung', (tester) async {
      await start(tester, d(Role.parent, const [], kinder: true));
      await tippe(tester, find.widgetWithText(FilledButton, 'Medikament'));
      await eingeben(tester, 'Name', 'Rezeptpflichtig');
      // erst ein Datum: der Date-Picker wird im Test über die Standard-Bestätigung abgeschlossen
      await tippe(tester, find.text('Datum wählen'));
      await tippe(tester, find.text('OK'));
      expect(find.text('Zusätzlich als Frist anlegen'), findsNothing, reason: 'für mich selbst gibt es keine Frist (Fristen sind nicht verschlüsselt)');
      expect(find.textContaining('Eine Frist im Fristen-Tracker gibt es nur für Kinder'), findsOneWidget);
      await tippe(tester, find.bySemanticsLabel('Für Ben'));
      expect(find.text('Zusätzlich als Frist anlegen'), findsOneWidget);
      await tippe(tester, find.text('Zusätzlich als Frist anlegen'));
      await tippe(tester, find.widgetWithText(FilledButton, 'Speichern'));
      expect(repo.angelegt.single.subjekt, _kind);
      expect(repo.angelegt.single.inhalt.rezeptDatum, isNotNull);
      final f = aufgaben.eingaben.single;
      expect(f.titel, 'Rezept erneuern');
      expect(f.frist, isTrue);
      expect(f.sicht.wire, 'parents');
      expect(f.beschreibung, isEmpty);
      expect('${f.titel}${f.beschreibung}'.contains(RegExp('Rezeptpflichtig|Ben', caseSensitive: false)), isFalse);
    });

    for (final skala in [1.0, 1.5, 2.0]) {
      testWidgets('Editor bei 360 px, Textskala $skala: keine Layoutfehler', (tester) async {
        await start(tester, d(Role.parent, const [], kinder: true), skala: skala, groesse: const Size(360, 900));
        await tippe(tester, find.widgetWithText(FilledButton, 'Medikament'));
        pruefeLayout(tester, 'Editor $skala');
        await tippe(tester, find.text('Wochentage'));
        pruefeLayout(tester, 'Editor Wochentage $skala');
        await tippe(tester, find.text('Alle N Tage'));
        pruefeLayout(tester, 'Editor Intervall $skala');
      });
    }
  });

  group('Einbindung', () {
    testWidgets('Mehr-Blatt: Eintrag "Medikamente" nach Fristen mit der Zahl fälliger Einnahmen (nur Sichtbares)', (tester) async {
      final (_, _) = await start(tester, d(Role.parent, [_e(_med1, _ich, _blut()), _e(_med2, _kind, _vitamin())], kinder: true), zumBereichGehen: false);
      await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Mehr')));
      await warte(tester);
      expect(find.byKey(const ValueKey('mehr:medikamente')), findsOneWidget);
      // fällig: Blutdruck 00:01 (heute, vorbei) und Vitamin D 00:02 (Kind); 23:59 ist noch nicht fällig
      expect(find.bySemanticsLabel('Medikamente, 2 Hinweise'), findsOneWidget);
      final fristen = tester.getTopLeft(find.byKey(const ValueKey('mehr:fristen')));
      final med = tester.getTopLeft(find.byKey(const ValueKey('mehr:medikamente')));
      final muell = find.byKey(const ValueKey('mehr:muell'));
      expect(med.dx > fristen.dx || med.dy > fristen.dy, isTrue);
      expect(muell, findsNothing);
      await tester.tap(find.byKey(const ValueKey('mehr:medikamente')));
      await warte(tester);
      expect(find.text('0 von 3 erledigt'), findsOneWidget);
    });

    testWidgets('Mehr-Blatt ohne Pläne: Eintrag da, ohne Zahl', (tester) async {
      await start(tester, d(Role.parent, const []), zumBereichGehen: false);
      await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Mehr')));
      await warte(tester);
      expect(find.bySemanticsLabel('Medikamente'), findsOneWidget);
    });

    testWidgets('Desktop: Eintrag in der Seitenleiste mit Zahl, Bereich im Inhaltsbereich, Seitenleiste bleibt', (tester) async {
      await start(tester, eigene(), groesse: const Size(1440, 900), zumBereichGehen: false);
      expect(find.text('Medikamente').first, findsOneWidget);
      await tester.tap(find.text('Medikamente').first);
      await warte(tester);
      expect(find.text('lx-familyhub'), findsOneWidget);
      expect(find.text('Nachts · 00:01'), findsOneWidget);
      expect(find.byType(MedikamenteScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Startseite: Kachel zeigt Uhrzeit und Person, nie den Medikamentennamen', (tester) async {
      await start(tester, d(Role.parent, [_e(_med1, _ich, _blut(zeit: '23:58')), _e(_med2, _kind, _vitamin())], kinder: true), zumBereichGehen: false);
      expect(labelFinder('Medikamente'), findsOneWidget);
      expect(find.textContaining('nächste Einnahme'), findsOneWidget);
      expect(find.textContaining('Blutdruck'), findsNothing);
      expect(find.textContaining('Vitamin'), findsNothing);
      expect(find.textContaining('5 mg'), findsNothing);
      Scrollable.ensureVisible(tester.element(find.textContaining('nächste Einnahme')), alignment: 0.3);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.textContaining('nächste Einnahme'));
      await warte(tester);
      expect(find.byType(MedikamenteScreen), findsOneWidget);
    });

    testWidgets('Startseite ohne offene Einnahmen: keine Kachel', (tester) async {
      await start(tester, d(Role.parent, [_e(_med2, _ich, _spray())]), zumBereichGehen: false);
      expect(labelFinder('Medikamente'), findsNothing);
    });
  });

  group('Layout bei 360 px und Textskala 1.0 / 1.5 / 2.0', () {
    for (final skala in [1.0, 1.5, 2.0]) {
      testWidgets('Heute und Detail, Textskala $skala', (tester) async {
        await start(
          tester,
          d(Role.parent, [_e(_med1, _ich, _blut()), _e(_med3, _kind, _vitamin()), _e(_med2, _ich, _spray())], kinder: true),
          skala: skala,
          groesse: const Size(360, 900),
        );
        pruefeLayout(tester, 'Heute $skala');
        await tippe(tester, find.text('Vitamin D · 1 Tropfen').first);
        pruefeLayout(tester, 'Detail $skala');
      });
    }
  });

  testWidgets('Semantics: Abhaken-Knopf, Zeile und Filter sind benannt', (tester) async {
    final handle = tester.ensureSemantics();
    await start(tester, d(Role.parent, [_e(_med1, _ich, _blut()), _e(_med2, _kind, _vitamin())], kinder: true));
    expect(find.bySemanticsLabel(RegExp('Als genommen abhaken: Blutdrucktablette · 5 mg')), findsWidgets);
    expect(find.bySemanticsLabel(RegExp('^Vitamin D · 1 Tropfen, Ben, 00:02 Uhr')), findsOneWidget);
    expect(find.bySemanticsLabel('Meine Medikamente'), findsOneWidget);
    expect(find.bySemanticsLabel('Medikamente von Ben'), findsOneWidget);
    handle.dispose();
  });
}
