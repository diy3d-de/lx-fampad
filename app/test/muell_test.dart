// Abfuhrtermine ("Müll"): Modell und Logik (nächste Abholung, morgen), Erinnerungsplanung (nur Eltern/Admins, Sonderabfall aus, Sperrmüll an,
// Uhrzeit 18:00), Startseiten-Kachel (normal / morgen / Kind / ausgeschaltet / Desktop), Seite mit Filter (einspaltig), Einstellungen (Rechte, Standardwerte,
// lokal gespeichert), "Jetzt nach neuer Datei suchen" (Rechte, Ablauf, zu oft), Hinweis auf ein neues Jahr (einmalig, nur Eltern/Admins), Erinnerungsdienst
// und die optionale Kalenderanzeige (Schalter aus/an, verdrängt keine Termine); Layout bei 360 px Breite und Textskala 1.0 und 1.5.
import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/constants.dart' show kMaxContentWidth;
import 'package:lx_fampad/data/api/models.dart' show Role;
import 'package:lx_fampad/data/app_database.dart' show AufgabenCompanion;
import 'package:lx_fampad/data/auth/auth_state.dart';
import 'package:lx_fampad/data/calendar/expansion.dart' show tagText;
import 'package:lx_fampad/data/erinnerungen/erinnerung_dienst.dart';
import 'package:lx_fampad/data/erinnerungen/erinnerung_einstellungen.dart';
import 'package:lx_fampad/data/erinnerungen/erinnerung_planung.dart';
import 'package:lx_fampad/data/muell/muell_logik.dart';
import 'package:lx_fampad/data/muell/muell_modelle.dart';
import 'package:lx_fampad/data/muell/muell_state.dart';
import 'package:lx_fampad/data/calendar/termin_repository.dart' show KalenderDaten;
import 'package:lx_fampad/data/calendar/zeitzonen.dart' show familienOrt, wandUhr;
import 'package:lx_fampad/data/push/chat_benachrichtiger.dart' show ChatAnzeigePort;
import 'package:lx_fampad/data/push/chat_benachrichtiger_provider.dart';
import 'package:lx_fampad/features/calendar/calendar_state.dart';
import 'package:lx_fampad/features/calendar/erinnerung_steuerung.dart';
import 'package:lx_fampad/features/calendar/muell_kalender.dart';
import 'package:lx_fampad/features/muell/muell_abfuhrkalender_screen.dart';
import 'package:lx_fampad/features/muell/muell_einstellungen_screen.dart';
import 'package:lx_fampad/features/muell/muell_screen.dart';
import 'package:lx_fampad/features/shell/shell_tab.dart';
import 'package:lx_fampad/ui/widgets.dart' show LxCard;
import 'package:timezone/data/latest_all.dart' as tzdata;

import 'support/fake_erinnerung_port.dart';
import 'support/fake_server.dart';
import 'support/harness.dart';
import 'support/test_app.dart';

/// Donnerstag 22.10.2026, 12:00 Uhr Berlin (Sommerzeit endet erst am 25.10.).
final _jetzt = DateTime.utc(2026, 10, 22, 10);

Map<String, dynamic> _tag(String datum, List<String> arten) => {'date': datum, 'kinds': arten};

List<Map<String, dynamic>> _termine() => [
  _tag('2026-10-28', ['bio', 'gelb']),
  _tag('2026-11-04', ['rest']),
  _tag('2026-11-18', ['papier']),
  _tag('2026-11-26', ['sonder']),
  _tag('2026-12-14', ['sperr']),
  _tag('2026-12-30', ['baum']),
];

Map<String, dynamic> _antwort({
  List<Map<String, dynamic>>? termine,
  List<Map<String, dynamic>>? jahre,
  bool pending = false,
  String? letzte,
  String? naechsteAnforderung,
  String ort = 'Salz',
}) => {
  'place': ort,
  'years': jahre ?? [
    {'year': 2026, 'status': 'loaded', 'eventCount': 6, 'checkedAt': '2026-10-22T05:00:00.000Z', 'errorCode': null},
  ],
  'events': termine ?? _termine(),
  'check': {'pending': pending, 'lastCheckAt': letzte, 'nextCheckAt': '2026-11-30T23:00:00.000Z', 'nextRequestAt': naechsteAnforderung},
};

/// Uhrzeit in der Familienzone (Europe/Berlin), wie die App sie zeigt (nicht in der Zone des Testgeräts).
String _hhmm(String iso) {
  final t = wandUhr(DateTime.parse(iso), familienOrt);
  return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}

/// Anzeige-Port, der Benachrichtigungen aufzeichnet.
class _Anzeige implements ChatAnzeigePort {
  final gezeigt = <({int id, String titel, String text, String nutzlast})>[];

  /// false: die Anzeige scheitert (keine Erlaubnis o. ä.).
  bool ok = true;

  @override
  Future<bool> initialisieren() async => true;

  @override
  Future<bool> zeigen({required int id, required String titel, required String text, required bool sperrbildschirmTitel, int? anzahl}) async => true;

  @override
  Future<bool> zeigenSicherheit({required int id, required String titel, required String text, String nutzlast = 'sicherheit'}) async {
    versuche++;
    if (!ok) return false;
    gezeigt.add((id: id, titel: titel, text: text, nutzlast: nutzlast));
    return true;
  }

  int versuche = 0;

  @override
  Future<void> entfernen(int id) async {}
}

/// Die Filter-Chips (Alle, Rest, Bio, Gelb, Papier, Sonder, Sperr, Bäume) sind je so breit wie ihr Inhalt (nicht die ganze Zeile) und stehen in wenigen Zeilen.
void _chipsNebeneinander(WidgetTester tester) {
  final breiten = <double>[];
  final zeilen = <int>{};
  for (final label in ['Alle', 'Rest', 'Bio', 'Gelb', 'Papier', 'Sonder', 'Sperr', 'Bäume']) {
    final chip = find.ancestor(of: find.text(label), matching: find.byType(InkWell)).first;
    breiten.add(tester.getSize(chip).width);
    zeilen.add(tester.getTopLeft(chip).dy.round());
  }
  expect(breiten.every((b) => b < 170), isTrue, reason: 'Breiten $breiten: kein Chip füllt die Zeile');
  expect(zeilen.length, lessThanOrEqualTo(4), reason: 'Zeilen $zeilen: die Chips stapeln sich nicht (8 Chips, höchstens 4 Zeilen auch bei Textskala 1.5)');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tzdata.initializeTimeZones();
  setUpAll(testVorbereiten);

  // ---------------------------------------------------------------------------------------------- Modell und Logik

  group('Modell und Logik', () {
    test('MuellDto liest die Antwort; unbekannte Arten werden "Sonstiges", kaputte Zeilen fallen weg', () {
      final dto = MuellDto.fromJson({
        ..._antwort(
          termine: [
            _tag('2026-10-28', ['gelb', 'bio', 'neu-vom-server']),
            {'date': 'kaputt', 'kinds': ['bio']},
            {'date': '2026-11-01'},
            _tag('2026-11-02', []),
          ],
        ),
        'years': [
          {'year': 2026, 'status': 'loaded', 'eventCount': 118, 'checkedAt': '2026-10-22T05:00:00Z'},
          {'year': 2027, 'status': 'unavailable', 'errorCode': 'empty'},
          {'year': 2028, 'status': 'error'},
          {'year': 'x'},
        ],
      });
      expect(dto.verfuegbar, isTrue);
      expect(dto.ort, 'Salz');
      expect(dto.tage, hasLength(1));
      expect(dto.tage.single.tag, DateTime.utc(2026, 10, 28));
      expect(dto.tage.single.arten, [MuellArt.bio, MuellArt.gelb, MuellArt.sonst], reason: 'sortiert nach der festen Reihenfolge, unbekannt = Sonstiges');
      expect(dto.jahre.map((j) => j.status), [MuellJahrStatus.geladen, MuellJahrStatus.nichtVerfuegbar, MuellJahrStatus.fehler]);
      expect(dto.geladeneJahre, {2026});
      expect(dto.jahr(2026)!.anzahlTermine, 118);
      expect(() => MuellDto.fromJson('kein json'), throwsA(anything));
      expect(MuellDto.nichtVerfuegbar.verfuegbar, isFalse);
    });

    test('nächste Abholung, kommende Termine', () {
      final tage = MuellDto.fromJson(_antwort()).tage;
      final heute = muellHeute(_jetzt);
      expect(heute, DateTime.utc(2026, 10, 22));
      final n = naechsteAbholung(tage, heute)!;
      expect(n.tag, DateTime.utc(2026, 10, 28));
      expect(tageBis(n.tag, heute), 6);
      expect(tageBisText(0), 'heute');
      expect(tageBisText(1), 'morgen');
      expect(tageBisText(6), 'in 6 Tagen');
      expect(naechsteAbholung(tage, DateTime.utc(2026, 10, 28))!.tag, DateTime.utc(2026, 10, 28), reason: 'am Tag selbst gilt er noch');
      expect(naechsteAbholung(tage, DateTime.utc(2026, 10, 29))!.tag, DateTime.utc(2026, 11, 4));
      expect(naechsteAbholung(tage, DateTime.utc(2027, 1, 1)), isNull);
      expect(naechsteAbholung(tage, heute, art: MuellArt.gelb)!.arten, [MuellArt.gelb], reason: 'bei Filter nur die Art');
      expect(kommendeAbholungen(tage, heute, art: MuellArt.papier).map((t) => t.tag), [DateTime.utc(2026, 11, 18)]);
      expect(kommendeAbholungen(tage, heute, max: 2), hasLength(2));
      expect(vorkommendeArten(tage), hasLength(7), reason: 'Grünabfall und Sonstiges kommen nicht vor');
      expect(muellKurzDatum(n.tag), 'Mi 28.10.');
      expect(muellLangDatum(n.tag), 'Mittwoch, 28.10.');
      expect(artenText(n.arten), 'Bioabfall, Gelber Sack');
      expect(muellTagKopf(n.tag), (zahl: '28', unten: 'Mi · Okt'));
    });

    test('Texte der Prüfung: gefunden, noch nicht verfügbar, Quelle nicht erreichbar, noch nicht geprüft', () {
      final dto = MuellDto.fromJson({
        ..._antwort(),
        'years': [
          {'year': 2026, 'status': 'loaded', 'eventCount': 118, 'checkedAt': '2026-10-22T05:00:00.000Z'},
          {'year': 2027, 'status': 'unavailable', 'checkedAt': '2026-12-01T06:05:00.000Z'},
          {'year': 2028, 'status': 'error', 'checkedAt': '2026-12-01T06:05:00.000Z'},
        ],
      });
      expect(muellJahrErgebnis(dto, 2026), '2026: gefunden, 118 Termine');
      expect(muellJahrErgebnis(dto, 2027), '2027: noch nicht verfügbar (geprüft um ${_hhmm('2026-12-01T06:05:00.000Z')})');
      expect(muellJahrErgebnis(dto, 2028), '2028: Quelle nicht erreichbar (geprüft um ${_hhmm('2026-12-01T06:05:00.000Z')})');
      expect(muellJahrErgebnis(dto, 2029), '2029: noch nicht geprüft');
    });

    test('Standardwerte der Erinnerung: Tonnen, Sperrmüll und Bäume an; Sonderabfall und Sonstiges aus; Zeit 18:00', () {
      expect(kMuellStandardErinnerung, containsAll([MuellArt.rest, MuellArt.bio, MuellArt.gelb, MuellArt.papier, MuellArt.gruen, MuellArt.baum, MuellArt.sperr]));
      expect(kMuellStandardErinnerung, isNot(contains(MuellArt.sonder)));
      expect(kMuellStandardErinnerung, isNot(contains(MuellArt.sonst)));
      const e = MuellEinstellungen();
      expect(e.erinnerungAn, isTrue);
      expect(e.minuten, 18 * 60);
      expect(e.imKalender, isFalse, reason: 'im Kalender standardmäßig aus');
      expect(uhrzeitAusMinuten(18 * 60), '18:00');
      expect(uhrzeitAusMinuten(19 * 60 + 5), '19:05');
    });
  });

  // ---------------------------------------------------------------------------------------------- Erinnerungsplanung

  group('Erinnerungsplanung', () {
    final tage = MuellDto.fromJson(_antwort()).tage;

    test('Abend vor der Abholung um 18:00 (Berlin): ein Eintrag je Abholung mit den eingeschalteten Arten', () {
      final e = planeMuellErinnerungen(tage: tage, aktiv: kMuellStandardErinnerung, minuten: kMuellStandardZeit, jetzt: _jetzt);
      // 27.10. 18:00 MEZ (Winterzeit seit 25.10.) = 17:00 UTC
      expect(e.first.zeit, DateTime.utc(2026, 10, 27, 17));
      expect(e.first.titel, 'Morgen ist Abholung');
      expect(e.first.text, 'Bioabfall, Gelber Sack');
      expect(e.first.payload, 'muell|2026-10-28');
      expect(istMuellPayload(e.first.payload), isTrue);
      expect(istMuellPayload('muell'), isTrue);
      expect(istMuellPayload('termin|x'), isFalse);
      expect(istMuellPayload(null), isFalse);
      expect(e.map((x) => x.zeit), [
        DateTime.utc(2026, 10, 27, 17),
        DateTime.utc(2026, 11, 3, 17),
        DateTime.utc(2026, 11, 17, 17),
        DateTime.utc(2026, 12, 13, 17), // Sperrmüll: standardmäßig an
        DateTime.utc(2026, 12, 29, 17),
      ]);
      expect(e.map((x) => x.id).toSet(), hasLength(5), reason: 'stabile, verschiedene IDs');
    });

    test('Sonderabfall ist standardmäßig aus (26.11. ohne Erinnerung), Sperrmüll an; eingeschaltet erscheint er', () {
      final e = planeMuellErinnerungen(tage: tage, aktiv: kMuellStandardErinnerung, minuten: kMuellStandardZeit, jetzt: _jetzt);
      expect(e.any((x) => x.payload == 'muell|2026-11-26'), isFalse);
      expect(e.any((x) => x.payload == 'muell|2026-12-14'), isTrue);
      final mit = planeMuellErinnerungen(tage: tage, aktiv: {...kMuellStandardErinnerung, MuellArt.sonder}, minuten: kMuellStandardZeit, jetzt: _jetzt);
      expect(mit.any((x) => x.payload == 'muell|2026-11-26'), isTrue);
      expect(mit.firstWhere((x) => x.payload == 'muell|2026-11-26').text, 'Sonderabfall');
    });

    test('nur eingeschaltete Arten im Text; eine Abholung ohne eingeschaltete Art entfällt; Uhrzeit einstellbar', () {
      final e = planeMuellErinnerungen(tage: tage, aktiv: {MuellArt.gelb}, minuten: 19 * 60 + 30, jetzt: _jetzt);
      expect(e, hasLength(1));
      expect(e.single.text, 'Gelber Sack');
      expect(e.single.zeit, DateTime.utc(2026, 10, 27, 18, 30), reason: '19:30 MEZ');
      expect(planeMuellErinnerungen(tage: tage, aktiv: const {}, minuten: 1080, jetzt: _jetzt), isEmpty);
    });

    test('Vergangenes entfällt (27.10. 18:00 ist schon vorbei), Sommerzeit rechnet richtig (vor dem 25.10. 16:00 UTC)', () {
      final spaet = planeMuellErinnerungen(tage: tage, aktiv: kMuellStandardErinnerung, minuten: 1080, jetzt: DateTime.utc(2026, 10, 27, 17, 30));
      expect(spaet.first.payload, 'muell|2026-11-04');
      final sommer = planeMuellErinnerungen(tage: [MuellTag(DateTime.utc(2026, 10, 20), const [MuellArt.rest])], aktiv: kMuellStandardErinnerung, minuten: 1080, jetzt: DateTime.utc(2026, 10, 1));
      expect(sommer.single.zeit, DateTime.utc(2026, 10, 19, 16), reason: '18:00 MESZ');
    });

    test('Horizont etwa 90 Tage: spätere Abholungen belegen das 300er-Fenster nicht (die App plant bei Start, Rückkehr und Abgleich neu)', () {
      expect(kMuellHorizontTage, 90);
      final viele = [for (var i = 0; i < 150; i++) MuellTag(DateTime.utc(2026, 10, 24 + i * 2), const [MuellArt.rest])]; // jeden 2. Tag
      final e = planeMuellErinnerungen(tage: viele, aktiv: kMuellStandardErinnerung, minuten: 1080, jetzt: _jetzt);
      expect(e, isNotEmpty);
      expect(e.last.zeit.isBefore(_jetzt.add(const Duration(days: 91))), isTrue);
      expect(e.length, lessThan(50), reason: 'etwa 45 statt 150: das Fenster bleibt für Termine und Aufgaben frei');
      final eins = planeMuellErinnerungen(tage: [MuellTag(DateTime.utc(2027, 3, 1), const [MuellArt.rest])], aktiv: kMuellStandardErinnerung, minuten: 1080, jetzt: _jetzt);
      expect(eins, isEmpty, reason: 'Anfang März liegt außerhalb der 90 Tage');
    });

    test('nur Eltern und Admins (Rolle), nur mit eingeschaltetem Schalter und Terminen', () {
      final z = MuellZustand(dto: MuellDto.fromJson(_antwort()), ablageGelesen: true);
      expect(muellErinnerungen(z, Role.parent, _jetzt), isNotEmpty);
      expect(muellErinnerungen(z, Role.admin, _jetzt), isNotEmpty);
      expect(muellErinnerungen(z, Role.child, _jetzt), isEmpty, reason: 'Kinder bekommen nichts');
      expect(muellErinnerungen(z, null, _jetzt), isEmpty);
      expect(muellErinnerungen(z.mit(einst: const MuellEinstellungen(erinnerungAn: false)), Role.parent, _jetzt), isEmpty);
      expect(muellErinnerungen(const MuellZustand(), Role.parent, _jetzt), isEmpty);
      expect(muellErinnerungen(MuellZustand(dto: MuellDto.nichtVerfuegbar), Role.parent, _jetzt), isEmpty);
    });

    test('teilt sich das Fenster mit den übrigen Erinnerungen (zusatz), ohne doppelte IDs', () {
      final z = planeMuellErinnerungen(tage: tage, aktiv: kMuellStandardErinnerung, minuten: 1080, jetzt: _jetzt);
      final e = planeErinnerungen(daten: const KalenderDaten(), ich: 'ich', jetzt: _jetzt, zusatz: [...z, z.first]);
      expect(e, hasLength(z.length));
      expect(e.map((x) => x.zeit).toList(), [...e.map((x) => x.zeit)]..sort());
      final begrenzt = planeErinnerungen(daten: const KalenderDaten(), ich: 'ich', jetzt: _jetzt, zusatz: z, maxAnzahl: 2);
      expect(begrenzt.length, 3, reason: 'zwei Erinnerungen plus der Hinweis "Erinnerungen laufen aus"');
    });
  });

  // ---------------------------------------------------------------------------------------------- Oberfläche

  Future<(TestUmgebung, ProviderContainer)> start(
    WidgetTester tester, {
    String role = 'parent',
    Object? Function()? antwort,
    DateTime? jetzt,
    double skala = 1.0,
    Size groesse = const Size(360, 800),
    void Function(TestUmgebung env)? vorher,
    bool erinnerungen = true,
    bool erlaubt = true,
  }) async {
    final env = await angemeldeteUmgebung(role: role);
    env.extraOverrides.addAll([
      muellUhrProvider.overrideWithValue(() => jetzt ?? _jetzt),
      muellPruefAbfrageProvider.overrideWithValue(const Duration(milliseconds: 250)),
      // kein Gerätedienst für Erinnerungen (sonst bleibt nach einer Änderung ein Entprell-Timer stehen); Tests der Erinnerungen setzen ihren eigenen
      erinnerungPortProvider.overrideWithValue(FakeErinnerungPort()
        ..verfuegbar = erinnerungen
        ..erlaubt = erlaubt),
      erinnerungEntprellenProvider.overrideWithValue(Duration.zero),
      erinnerungUhrProvider.overrideWithValue(() => jetzt ?? _jetzt),
    ]);
    env.server.on('GET /waste', (_) {
      final a = antwort == null ? _antwort() : antwort();
      return a == null ? fehler(404, 'not_found') : jsonAntwort(a);
    });
    vorher?.call(env);
    final container = await starteApp(tester, env, skala: skala, groesse: groesse);
    return (env, container);
  }

  Finder kachelCard() => find.ancestor(of: find.text('Mi 28.10.'), matching: find.byType(LxCard));

  group('Startseite: Kachel', () {
    testWidgets('normal: Datum der nächsten Abholung, Symbole der Arten und Abstand; nicht hervorgehoben', (tester) async {
      await start(tester);
      expect(labelFinder('Müll'), findsOneWidget);
      expect(find.text('Mi 28.10.'), findsOneWidget);
      expect(find.text('in 6 Tagen · Bioabfall, Gelber Sack'), findsOneWidget);
      expect(find.byIcon(Icons.eco_outlined), findsOneWidget);
      expect(find.byIcon(Icons.shopping_bag_outlined), findsOneWidget);
      expect(find.text('morgen'), findsNothing);
      expect(tester.widget<LxCard>(kachelCard()).gewaehlt, isFalse);
      pruefeLayout(tester, 'Kachel normal');
    });

    testWidgets('am Tag vor der Abholung: hervorgehoben, "morgen" als Hinweis', (tester) async {
      await start(tester, jetzt: DateTime.utc(2026, 10, 27, 10));
      expect(labelFinder('Müll · morgen'), findsOneWidget);
      expect(find.text('morgen'), findsOneWidget);
      expect(find.text('Mi 28.10.'), findsOneWidget);
      expect(tester.widget<LxCard>(kachelCard()).gewaehlt, isTrue);
      pruefeLayout(tester, 'Kachel morgen');
    });

    testWidgets('am Tag der Abholung: "heute" hervorgehoben', (tester) async {
      await start(tester, jetzt: DateTime.utc(2026, 10, 28, 6));
      expect(labelFinder('Müll · heute'), findsOneWidget);
      expect(find.text('heute'), findsOneWidget);
    });

    testWidgets('Kinder sehen die Kachel ebenfalls', (tester) async {
      await start(tester, role: 'child');
      expect(find.text('Mi 28.10.'), findsOneWidget);
    });

    testWidgets('auf dem Server ausgeschaltet (404): keine Kachel', (tester) async {
      await start(tester, antwort: () => null);
      expect(labelFinder('Müll'), findsNothing);
      expect(find.text('Mi 28.10.'), findsNothing);
    });

    testWidgets('ohne Termine: keine Kachel', (tester) async {
      await start(tester, antwort: () => _antwort(termine: const []));
      expect(labelFinder('Müll'), findsNothing);
    });

    for (final skala in [1.0, 1.5]) {
      testWidgets('Seite öffnet per Tipp: nächste Abholung groß, Filter, kommende Termine, keine Legende (360 px, Textskala $skala)', (tester) async {
        await start(tester, skala: skala);
        await tippe(tester, find.text('Mi 28.10.'));
        expect(find.byType(MuellScreen), findsOneWidget);
        expect(find.text('Müll'), findsWidgets);
        expect(find.text('Mittwoch, 28.10.'), findsOneWidget);
        expect(find.text('Bioabfall, Gelber Sack · in 6 Tagen'), findsOneWidget);
        expect(labelFinder('Kommende Termine'), findsOneWidget);
        expect(labelFinder('Legende'), findsNothing);
        expect(labelFinder('Nächste je art'), findsNothing);
        expect(find.text('Alle'), findsOneWidget);
        // Die Chips zeigen nur Arten mit Terminen im Zeitraum (Grünabfall und Sonstiges kommen nicht vor)
        expect(find.text('Rest'), findsOneWidget);
        expect(find.text('Grün'), findsNothing);
        // Tage der Liste: 28, 04, 18, 26, 14, 30
        for (final z in ['28', '04', '18', '26', '14', '30']) {
          expect(find.text(z), findsOneWidget, reason: 'Tag $z');
        }
        pruefeLayout(tester, 'Müll-Seite');
        _chipsNebeneinander(tester);
        // Filter nach Art: nur Altpapier
        await tippe(tester, find.text('Papier'));
        expect(find.text('18'), findsOneWidget);
        expect(find.text('04'), findsNothing);
        expect(find.text('28'), findsNothing);
        await tippe(tester, find.text('Alle'));
        expect(find.text('04'), findsOneWidget);
        pruefeLayout(tester, 'Müll-Seite mit Filter');
      });
    }

    for (final breite in [320.0, 360.0]) {
      // (320 px bei Textskala 1.5 läuft die vorhandene Schnellzugriff-Reihe der Startseite über: das ist nicht Sache der Müll-Seite)
      for (final skala in breite < 360 ? [1.0] : [1.0, 1.5]) {
        testWidgets('Filter-Chips haben ihre eigene Breite und stehen nebeneinander, nicht untereinander (${breite.round()} px, Textskala $skala)', (tester) async {
          await start(tester, groesse: Size(breite, 900), skala: skala);
          await tippe(tester, find.text('Mi 28.10.'));
          _chipsNebeneinander(tester);
          pruefeLayout(tester, 'Chips ${breite.round()} px, Skala $skala');
        });
      }
    }

    testWidgets('Desktop: Karte im Raster, "Müll" in der Seitenleiste, Bereich der Shell', (tester) async {
      final (_, container) = await start(tester, groesse: const Size(1280, 900));
      expect(find.text('Mi 28.10.'), findsOneWidget, reason: 'Karte im Karten-Raster');
      expect(find.text('Müll'), findsWidgets);
      container.read(shellTabProvider.notifier).waehlen(kMuellTab);
      await warte(tester);
      expect(find.byType(MuellScreen), findsOneWidget);
      expect(find.text('Mittwoch, 28.10.'), findsOneWidget);
      expect(labelFinder('Legende'), findsNothing);
      expect(labelFinder('Nächste je art'), findsNothing);
      // einspaltig und auf die Inhaltsbreite begrenzt wie die anderen Bereiche
      final breite = tester.getSize(find.ancestor(of: labelFinder('Nächste Abholung'), matching: find.byType(LxCard)).first).width;
      expect(breite, lessThanOrEqualTo(kMaxContentWidth), reason: 'nicht über die ganze Breite gezogen');
      expect(breite, greaterThan(600), reason: 'eine volle Spalte, keine halbleere zweite Spalte');
      expect(find.text('Papier'), findsOneWidget, reason: 'Filter-Chips auch auf dem Desktop');
      expect(tester.takeException(), isNull);
    });

    testWidgets('Desktop: ohne eingeschalteten Server kein Eintrag in der Seitenleiste', (tester) async {
      await start(tester, groesse: const Size(1280, 900), antwort: () => null);
      expect(find.text('Mi 28.10.'), findsNothing);
      expect(find.text('Müll'), findsNothing);
    });
  });

  // ---------------------------------------------------------------------------------------------- Einstellungen und Prüfung

  group('Einstellungen', () {
    Future<(TestUmgebung, ProviderContainer)> zuEinstellungen(WidgetTester tester, {String role = 'parent', double skala = 1.0, bool erinnerungen = true, void Function(TestUmgebung)? vorher}) async {
      final r = await start(tester, role: role, skala: skala, erinnerungen: erinnerungen, vorher: vorher);
      await tippe(tester, find.text('Mi 28.10.'));
      await tippe(tester, find.byTooltip('Einstellungen'));
      expect(find.byType(MuellEinstellungenScreen), findsOneWidget);
      return r;
    }

    for (final skala in [1.0, 1.5]) {
      testWidgets('Eltern: Erinnerung, Uhrzeit 18:00, Arten (Sonderabfall aus, Sperrmüll an), Suche nach neuer Datei (360 px, Textskala $skala)', (tester) async {
        final (env, _) = await zuEinstellungen(tester, skala: skala);
        expect(find.text('Im Kalender anzeigen'), findsOneWidget);
        expect(find.text('Abend vorher erinnern'), findsOneWidget);
        expect(find.text('18:00'), findsOneWidget);
        SwitchListTile art(String code) => tester.widget<SwitchListTile>(find.byKey(ValueKey('muell-art-$code')));
        // Arten stehen in der Liste, sobald es Termine gibt; Grünabfall und Sonderabfall immer (feste Liste)
        expect(art('sperr').value, isTrue);
        expect(art('rest').value, isTrue);
        expect(art('sonder').value, isFalse, reason: 'Sonderabfall: Standard aus');
        expect(find.text('Jetzt nach neuer Datei suchen'), findsOneWidget);
        expect(find.text('Abfuhrkalender'), findsNothing, reason: 'nur Admins');
        pruefeLayout(tester, 'Einstellungen Eltern');
        // Sonderabfall einschalten: lokal gespeichert
        await tippe(tester, find.byKey(const ValueKey('muell-art-sonder')));
        expect(art('sonder').value, isTrue);
        expect(await env.db.metaLesen(kMuellErinnerungArtenSchluessel), contains('sonder'));
      });
    }

    testWidgets('Kinder: nur "Im Kalender anzeigen", weder Erinnerung noch Suche noch Abfuhrkalender', (tester) async {
      await zuEinstellungen(tester, role: 'child');
      expect(find.text('Im Kalender anzeigen'), findsOneWidget);
      expect(find.text('Abend vorher erinnern'), findsNothing);
      expect(find.text('Jetzt nach neuer Datei suchen'), findsNothing);
      expect(find.text('Abfuhrkalender'), findsNothing);
      pruefeLayout(tester, 'Einstellungen Kind');
    });

    testWidgets('Admin: dazu die Seite "Abfuhrkalender" mit Status je Jahr, Prüfzeiten und derselben Suche; kein Eingabefeld für den Link', (tester) async {
      await zuEinstellungen(tester, role: 'admin', vorher: (e) {
        e.server.on('GET /waste', (_) => jsonAntwort(_antwort(jahre: [
          {'year': 2026, 'status': 'loaded', 'eventCount': 122, 'checkedAt': '2026-10-22T05:00:00.000Z', 'errorCode': null},
          {'year': 2027, 'status': 'unavailable', 'checkedAt': '2026-10-22T05:00:00.000Z', 'errorCode': 'empty'},
        ], letzte: '2026-10-22T05:00:00.000Z')));
      });
      await tippe(tester, find.text('Abfuhrkalender'));
      expect(find.byType(MuellAbfuhrkalenderScreen), findsOneWidget);
      expect(find.textContaining('122 Termine', findRichText: true), findsOneWidget);
      expect(find.text('geladen'), findsOneWidget);
      expect(find.text('noch nicht verfügbar'), findsOneWidget);
      expect(find.text('ab 1. Dezember, wöchentlich'), findsOneWidget);
      expect(find.text('Jetzt nach neuer Datei suchen'), findsOneWidget);
      expect(find.byType(TextField), findsNothing, reason: 'kein Eingabefeld für die Quelle');
      expect(find.textContaining('https://'), findsNothing);
      expect(find.textContaining('key='), findsNothing);
      pruefeLayout(tester, 'Abfuhrkalender');
    });

    testWidgets('Uhrzeit und Schalter sind lokal (sync_meta) gespeichert und überstehen einen Neustart', (tester) async {
      final (env, container) = await zuEinstellungen(tester);
      await container.read(muellProvider.notifier).zeitSetzen(19 * 60 + 30);
      await container.read(muellProvider.notifier).erinnerungAnSetzen(false);
      await container.read(muellProvider.notifier).kalenderSetzen(true);
      await warte(tester);
      expect(find.text('19:30'), findsOneWidget);
      expect(await env.db.metaLesen(kMuellErinnerungZeitSchluessel), '19:30');
      expect(await env.db.metaLesen(kMuellErinnerungAnSchluessel), 'nein');
      expect(await env.db.metaLesen(kMuellKalenderSchluessel), 'ja');
      // neuer Container auf derselben Datenbank liest die Werte wieder
      final c2 = env.container();
      addTearDown(c2.dispose);
      await c2.read(authProvider.notifier).start();
      c2.listen(muellProvider, (_, _) {});
      for (var i = 0; i < 50 && !c2.read(muellProvider).ablageGelesen; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      }
      final e = c2.read(muellProvider).einst;
      expect(e.minuten, 19 * 60 + 30);
      expect(e.erinnerungAn, isFalse);
      expect(e.imKalender, isTrue);
    });

    testWidgets('Im Browser (keine Erinnerungen): Hinweis statt der Erinnerungs-Schalter', (tester) async {
      await zuEinstellungen(tester, erinnerungen: false);
      expect(find.textContaining('Erinnerungen gibt es nur in der Android-App'), findsOneWidget);
      expect(find.text('Abend vorher erinnern'), findsNothing);
      expect(find.text('Jetzt nach neuer Datei suchen'), findsOneWidget, reason: 'die Suche geht auch im Browser');
    });
  });

  group('Jetzt nach neuer Datei suchen', () {
    Future<(TestUmgebung, ProviderContainer)> zuSuche(WidgetTester tester, {String role = 'parent', double skala = 1.0, required Handler check, required Object? Function() antwort}) =>
        start(tester, role: role, skala: skala, antwort: antwort, vorher: (e) => e.server.on('POST /waste/check', check)).then((r) async {
          await tippe(tester, find.text('Mi 28.10.'));
          await tippe(tester, find.byTooltip('Einstellungen'));
          return r;
        });

    testWidgets('Ablauf: "Prüfung angefordert", dann "2027: noch nicht verfügbar (geprüft um …)"', (tester) async {
      var abfragen = 0;
      var angefordert = false;
      final jahre27 = [
        {'year': 2026, 'status': 'loaded', 'eventCount': 6, 'checkedAt': '2026-10-22T05:00:00.000Z', 'errorCode': null},
        {'year': 2027, 'status': 'unavailable', 'eventCount': 0, 'checkedAt': '2026-10-22T10:01:00.000Z', 'errorCode': 'empty'},
      ];
      final (env, _) = await zuSuche(
        tester,
        check: (_) {
          angefordert = true;
          return jsonAntwort({'ok': true}, status: 202);
        },
        antwort: () {
          if (!angefordert) return _antwort();
          abfragen++;
          // zuerst noch offen, dann vom Dienst abgearbeitet
          return abfragen < 3 ? _antwort(pending: true) : _antwort(jahre: jahre27, letzte: '2026-10-22T10:01:00.000Z');
        },
      );
      await tippe(tester, find.text('Jetzt nach neuer Datei suchen'));
      expect(env.server.anfragen('POST /waste/check'), hasLength(1));
      expect(find.textContaining('Prüfung angefordert'), findsOneWidget);
      for (var i = 0; i < 40 && find.textContaining('2027:').evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 260));
      }
      expect(find.text('2027: noch nicht verfügbar (geprüft um ${_hhmm('2026-10-22T10:01:00.000Z')})'), findsOneWidget);
      expect(find.textContaining('Prüfung angefordert'), findsNothing);
      pruefeLayout(tester, 'Suche fertig');
    });

    testWidgets('Ergebnis "gefunden" und "Quelle nicht erreichbar" mit festen Texten (nie ein Servertext)', (tester) async {
      for (final (status, erwartet) in [
        ('loaded', '2027: gefunden, 118 Termine'),
        ('error', '2027: Quelle nicht erreichbar (geprüft um ${_hhmm('2026-10-22T10:01:00.000Z')})'),
      ]) {
        var angefordert = false;
        await zuSuche(
          tester,
          check: (_) {
            angefordert = true;
            return jsonAntwort({'ok': true}, status: 202);
          },
          antwort: () => !angefordert
              ? _antwort()
              : _antwort(jahre: [
                  {'year': 2026, 'status': 'loaded', 'eventCount': 6, 'checkedAt': '2026-10-22T05:00:00.000Z', 'errorCode': null},
                  {'year': 2027, 'status': status, 'eventCount': status == 'loaded' ? 118 : 0, 'checkedAt': '2026-10-22T10:01:00.000Z', 'errorCode': status == 'loaded' ? null : 'http_403 https://geheim.example/?key=GEHEIM'},
                ], letzte: '2026-10-22T10:01:00.000Z'),
        );
        await tippe(tester, find.text('Jetzt nach neuer Datei suchen'));
        for (var i = 0; i < 40 && find.textContaining('2027:').evaluate().isEmpty; i++) {
          await tester.pump(const Duration(milliseconds: 260));
        }
        expect(find.text(erwartet), findsOneWidget);
        expect(find.textContaining('geheim'), findsNothing);
        expect(find.textContaining('http_403'), findsNothing);
        await tester.pumpWidget(const SizedBox());
      }
    });

    testWidgets('zu oft gedrückt: freundlicher Hinweis "Bitte etwas später erneut versuchen."', (tester) async {
      final (env, _) = await zuSuche(tester, check: (_) => fehler(429, 'rate_limited', retryAfter: 600), antwort: _antwort);
      await tippe(tester, find.text('Jetzt nach neuer Datei suchen'));
      expect(find.text('Bitte etwas später erneut versuchen.'), findsOneWidget);
      expect(find.textContaining('Zu viele Versuche'), findsNothing);
      expect(env.server.anfragen('POST /waste/check'), hasLength(1));
      // der Knopf bleibt benutzbar (der Server entscheidet)
      expect(tester.widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'Jetzt nach neuer Datei suchen')).onPressed, isNotNull);
    });

    testWidgets('Fehler beim Anfordern: ruhiger Hinweis ohne Servertext', (tester) async {
      await zuSuche(tester, check: (_) => fehler(500, 'internal_error', message: 'SQL-Fehler irgendwo'), antwort: _antwort);
      await tippe(tester, find.text('Jetzt nach neuer Datei suchen'));
      expect(find.textContaining('konnte nicht angefordert werden'), findsOneWidget);
      expect(find.textContaining('SQL'), findsNothing);
    });

    testWidgets('schon angefordert (Server meldet pending): die Seite wartet von sich aus auf das Ergebnis', (tester) async {
      var n = 0;
      await zuSuche(
        tester,
        check: (_) => jsonAntwort({'ok': true}, status: 202),
        antwort: () => ++n < 8 ? _antwort(pending: true, letzte: '2026-10-21T05:00:00.000Z') : _antwort(letzte: '2026-10-22T10:01:00.000Z', jahre: [
          {'year': 2026, 'status': 'loaded', 'eventCount': 6, 'checkedAt': '2026-10-22T05:00:00.000Z', 'errorCode': null},
          {'year': 2027, 'status': 'loaded', 'eventCount': 118, 'checkedAt': '2026-10-22T10:01:00.000Z', 'errorCode': null},
        ]),
      );
      expect(find.textContaining('Prüfung angefordert'), findsOneWidget);
      for (var i = 0; i < 40 && find.textContaining('2027:').evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 260));
      }
      expect(find.text('2027: gefunden, 118 Termine'), findsOneWidget);
    });
  });

  // ---------------------------------------------------------------------------------------------- Hinweis auf ein neues Jahr

  group('Neues Jahr', () {
    Future<void> bis(WidgetTester tester, bool Function() b) async {
      for (var i = 0; i < 60 && !b(); i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 20));
      }
    }

    Future<ProviderContainer> ablauf(WidgetTester tester, String role, _Anzeige anzeige) async {
      var mit2027 = false;
      final (_, container) = await start(
        tester,
        role: role,
        antwort: () => mit2027
            ? _antwort(jahre: [
                {'year': 2026, 'status': 'loaded', 'eventCount': 6, 'checkedAt': '2026-12-01T05:00:00.000Z', 'errorCode': null},
                {'year': 2027, 'status': 'loaded', 'eventCount': 118, 'checkedAt': '2026-12-08T05:00:00.000Z', 'errorCode': null},
              ])
            : _antwort(),
        vorher: (e) => e.extraOverrides.add(chatAnzeigePortProvider.overrideWithValue(anzeige)),
      );
      final n = container.read(muellProvider.notifier);
      await bis(tester, () => container.read(muellProvider).hatTermine);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 150))); // der erste Abruf ist ganz fertig (auch die Prüfung auf neue Jahre)
      expect(anzeige.gezeigt, isEmpty, reason: 'der erste Abruf setzt nur die Grundlinie');
      mit2027 = true;
      await tester.runAsync(n.aktualisieren);
      await warte(tester);
      return container;
    }

    testWidgets('Eltern/Admins: einmal "Abfuhrtermine 2027 sind da" (lokal, ohne Inhalt), beim erneuten Abruf nicht noch einmal', (tester) async {
      final anzeige = _Anzeige();
      final container = await ablauf(tester, 'parent', anzeige);
      expect(anzeige.gezeigt, hasLength(1));
      expect(anzeige.gezeigt.single.titel, 'Abfuhrtermine 2027 sind da');
      expect(anzeige.gezeigt.single.nutzlast, 'muell');
      expect(anzeige.gezeigt.single.text, isNot(contains('Bioabfall')));
      expect(anzeige.gezeigt.single.id, kMuellJahrBenachrichtigungsId);
      await tester.runAsync(container.read(muellProvider.notifier).aktualisieren);
      await warte(tester);
      expect(anzeige.gezeigt, hasLength(1), reason: 'einmalig');
    });

    testWidgets('Scheitert die Anzeige (keine Erlaubnis), gilt das Jahr nicht als gesehen: der Hinweis kommt beim nächsten Abruf', (tester) async {
      final anzeige = _Anzeige()..ok = false;
      final container = await ablauf(tester, 'parent', anzeige);
      expect(anzeige.gezeigt, isEmpty);
      expect(anzeige.versuche, greaterThanOrEqualTo(1));
      anzeige.ok = true;
      await tester.runAsync(container.read(muellProvider.notifier).aktualisieren);
      await warte(tester);
      expect(anzeige.gezeigt, hasLength(1));
      expect(anzeige.gezeigt.single.titel, 'Abfuhrtermine 2027 sind da');
      await tester.runAsync(container.read(muellProvider.notifier).aktualisieren);
      await warte(tester);
      expect(anzeige.gezeigt, hasLength(1), reason: 'danach einmalig');
    });

    testWidgets('Admin bekommt ihn ebenfalls, Kinder nie', (tester) async {
      final admin = _Anzeige();
      await ablauf(tester, 'admin', admin);
      expect(admin.gezeigt, hasLength(1));
      await tester.pumpWidget(const SizedBox());
      final kind = _Anzeige();
      await ablauf(tester, 'child', kind);
      expect(kind.gezeigt, isEmpty);
    });
  });

  // ---------------------------------------------------------------------------------------------- Erinnerungsdienst

  group('Erinnerungsdienst', () {
    late TestUmgebung env;
    late FakeErinnerungPort port;
    late ProviderContainer c;

    Future<void> bis(bool Function() bedingung, {String grund = 'Bedingung'}) async {
      for (var i = 0; i < 150; i++) {
        if (bedingung()) return;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      fail('Zeitüberschreitung: $grund');
    }

    Future<void> los(String role) async {
      env = await angemeldeteUmgebung(role: role);
      port = FakeErinnerungPort();
      env.server.on('GET /waste', (_) => jsonAntwort(_antwort()));
      env.extraOverrides.addAll([
        erinnerungPortProvider.overrideWithValue(port),
        erinnerungSpeicherProvider.overrideWithValue(MemoryErinnerungSpeicher()),
        erinnerungUhrProvider.overrideWithValue(() => _jetzt),
        muellUhrProvider.overrideWithValue(() => _jetzt),
        erinnerungEntprellenProvider.overrideWithValue(Duration.zero),
        erinnerungWiederholenProvider.overrideWithValue(const Duration(milliseconds: 150)),
      ]);
      c = env.container();
      addTearDown(c.dispose);
      await c.read(authProvider.notifier).start();
      c.listen(erinnerungSteuerungProvider, (_, _) {});
    }

    test('Eltern: die Erinnerungen am Abend vor der Abholung werden geplant (Payload muell|…, 18:00), Sonderabfall nicht', () async {
      await los('parent');
      await bis(() => port.letzte?.any((e) => e.payload.startsWith('muell|')) ?? false, grund: 'Müll-Erinnerungen');
      final m = port.letzte!.where((e) => e.payload.startsWith('muell|')).toList();
      expect(m.map((e) => e.payload), ['muell|2026-10-28', 'muell|2026-11-04', 'muell|2026-11-18', 'muell|2026-12-14', 'muell|2026-12-30']);
      expect(m.first.zeit, DateTime.utc(2026, 10, 27, 17));
      expect(m.first.titel, 'Morgen ist Abholung');
      expect(m.first.text, 'Bioabfall, Gelber Sack');
    });

    test('Admin ebenfalls', () async {
      await los('admin');
      await bis(() => port.letzte?.any((e) => e.payload.startsWith('muell|')) ?? false, grund: 'Müll-Erinnerungen Admin');
    });

    test('der globale Schalter "Erinnerungen auf diesem Gerät" aus löscht nur Termine und Aufgaben, nicht die Müll-Alarme (eigener Schalter)', () async {
      await los('parent');
      await env.db.into(env.db.aufgaben).insert(
        AufgabenCompanion.insert(id: '3f2b8c1e-9d4a-4b6f-8a1c-2e7d5f0a9b13', titel: 'Aufgabe', faelligDate: const Value('2026-10-30'), erinnerungMin: const Value(15), ownerId: const Value(fixIdAdmin), createdAt: DateTime.utc(2026, 10, 1)),
      );
      await bis(() => (port.letzte?.any((e) => e.payload.startsWith('aufgabe|')) ?? false) && (port.letzte?.any((e) => e.payload.startsWith('muell|')) ?? false), grund: 'Aufgabe und Müll');
      await c.read(erinnerungEinstellungenProvider.notifier).anSetzen(false);
      await bis(() => !(port.letzte?.any((e) => e.payload.startsWith('aufgabe|')) ?? true), grund: 'Aufgabe weg');
      expect(port.letzte!.where((e) => e.payload.startsWith('muell|')), isNotEmpty, reason: 'Müll bleibt, er hat einen eigenen Schalter');
      // Müll-Schalter ebenfalls aus: jetzt ist alles weg
      await c.read(muellProvider.notifier).erinnerungAnSetzen(false);
      await bis(() => port.geloescht > 0, grund: 'alles aus: das Gerät wird geleert');
    });

    test('Kinder bekommen keine Müll-Erinnerung (die Planung bleibt ohne sie)', () async {
      await los('child');
      await c.read(muellProvider.notifier).aktualisieren();
      await bis(() => c.read(muellProvider).hatTermine, grund: 'Daten geladen');
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect((port.letzte ?? const []).where((e) => e.payload.startsWith('muell|')), isEmpty);
    });

    test('Schalter aus löscht die Müll-Erinnerungen, Sonderabfall ein plant ihn, andere Uhrzeit verschiebt sie; Tipp öffnet die Müll-Seite', () async {
      await los('parent');
      await bis(() => port.letzte?.any((e) => e.payload.startsWith('muell|')) ?? false);
      final n = c.read(muellProvider.notifier);
      await n.artSetzen(MuellArt.sonder, true);
      await bis(() => port.letzte?.any((e) => e.payload == 'muell|2026-11-26') ?? false, grund: 'Sonderabfall');
      await n.zeitSetzen(20 * 60);
      await bis(() => port.letzte?.firstWhere((e) => e.payload.startsWith('muell|')).zeit.isAtSameMomentAs(DateTime.utc(2026, 10, 27, 19)) ?? false, grund: 'Uhrzeit 20:00');
      var geoeffnet = 0;
      c.read(erinnerungDienstProvider).beiMuellGeoeffnet = () => geoeffnet++;
      port.tippe('muell|2026-10-28');
      port.tippe('muell');
      expect(geoeffnet, 2);
      await n.erinnerungAnSetzen(false);
      await bis(() => !(port.letzte?.any((e) => e.payload.startsWith('muell|')) ?? true), grund: 'Müll-Erinnerungen aus');
    });
  });

  // ---------------------------------------------------------------------------------------------- Kalenderanzeige

  group('Kalenderanzeige (optional)', () {
    final marz = DateTime.utc(2027, 3, 10);
    String id(int n) => 'aaaaaaaa-0000-4000-8000-${n.toString().padLeft(12, '0')}';
    Map<String, dynamic> zeit(String titel, DateTime tag, int stunde) => {
      'titel': titel,
      'ganztaegig': false,
      'startUtc': DateTime.utc(tag.year, tag.month, tag.day, stunde - 1).toIso8601String(),
      'endUtc': DateTime.utc(tag.year, tag.month, tag.day, stunde).toIso8601String(),
      'tzid': 'Europe/Berlin',
      'ownerId': fixIdAdmin,
      'audience': 'family',
    };
    Object? marzAntwort() => _antwort(
      jahre: [
        {'year': 2027, 'status': 'loaded', 'eventCount': 3, 'checkedAt': '2026-12-08T05:00:00.000Z', 'errorCode': null},
      ],
      termine: [
        _tag('2027-03-10', ['bio']),
        _tag('2027-03-11', ['rest', 'gelb']),
      ],
    );
    Finder tagZelle(DateTime t) => find.byKey(ValueKey('kalender-tag-${tagText(t)}'));
    Finder streifen(DateTime t) => find.byKey(ValueKey('muell-streifen-${tagText(t)}'));
    final filterKnopf = find.byTooltip(RegExp('^Filter und Anzeige'));

    Future<(TestUmgebung, ProviderContainer)> kalender(WidgetTester tester, {String role = 'admin', double skala = 1.0, void Function(TestUmgebung)? vorher, Size groesse = const Size(360, 800), bool monat = true}) async {
      final (env, container) = await start(tester, role: role, skala: skala, antwort: marzAntwort, groesse: groesse, vorher: vorher);
      await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Kalender')));
      await warte(tester);
      if (monat) container.read(kalenderAuswahlProvider.notifier).ansicht(KalenderAnsicht.monat);
      container.read(kalenderAuswahlProvider.notifier).tag(marz);
      await warte(tester);
      return (env, container);
    }

    testWidgets('Schalter aus (Standard): keine Müll-Marken im Kalender; im Filterblatt steht der Schalter "Müll"', (tester) async {
      await kalender(tester);
      expect(streifen(marz), findsNothing);
      expect(streifen(DateTime.utc(2027, 3, 11)), findsNothing);
      expect(find.byType(MuellStreifen), findsNothing);
      await tippe(tester, filterKnopf);
      expect(find.text('Müll'), findsOneWidget);
      expect(tester.widget<SwitchListTile>(find.widgetWithText(SwitchListTile, 'Müll')).value, isFalse);
      pruefeLayout(tester, 'Filterblatt mit Müll');
    });

    for (final rolle in ['admin', 'child']) {
      testWidgets('Schalter an ($rolle darf ihn setzen): Marken an den Tagen mit Abholung, Beschreibung nennt die Arten, Tagesblatt zeigt Kapseln', (tester) async {
        final (env, _) = await kalender(tester, role: rolle);
        final handle = tester.ensureSemantics();
        await tippe(tester, filterKnopf);
        await tippe(tester, find.text('Müll'));
        await tippeText(tester, 'Fertig');
        expect(streifen(marz), findsOneWidget);
        expect(streifen(DateTime.utc(2027, 3, 11)), findsOneWidget);
        expect(streifen(DateTime.utc(2027, 3, 12)), findsNothing);
        expect(await env.db.metaLesen(kMuellKalenderSchluessel), 'ja');
        expect(tester.getSemantics(tagZelle(DateTime.utc(2027, 3, 11))).label, contains('Müll: Restabfall, Gelber Sack'));
        // Tagesblatt: Kapseln mit Symbol und Name
        await tippe(tester, tagZelle(DateTime.utc(2027, 3, 11)));
        expect(find.byType(MuellTagesZeile), findsOneWidget);
        expect(find.text('Restabfall'), findsOneWidget);
        expect(find.text('Gelber Sack'), findsOneWidget);
        handle.dispose();
        pruefeLayout(tester, 'Tagesblatt mit Müll');
      });
    }

    for (final skala in [1.0, 1.5]) {
      testWidgets('verdrängt keine Termine: gleich viele Balken und "+n" mit und ohne Anzeige (360 px, Textskala $skala)', (tester) async {
        final (_, container) = await kalender(tester, skala: skala, vorher: (e) {
          for (var i = 1; i <= 8; i++) {
            e.sync.andereAendert('termin', id(i), zeit('Ev$i', marz, 8 + i));
          }
        });
        List<int> sichtbar() => [for (var i = 1; i <= 8; i++) if (find.text('Ev$i').evaluate().isNotEmpty) i];
        final ohne = sichtbar();
        expect(ohne, isNotEmpty);
        expect(find.text('+${8 - ohne.length}'), findsOneWidget);
        await container.read(muellProvider.notifier).kalenderSetzen(true);
        await warte(tester);
        expect(streifen(marz), findsOneWidget);
        expect(sichtbar(), ohne, reason: 'dieselben Termine bleiben sichtbar');
        expect(find.text('+${8 - ohne.length}'), findsOneWidget);
        pruefeLayout(tester, 'Monat mit Müll');
      });
    }

    testWidgets('Woche: Punkte unter der Tageszahl der Abholtage', (tester) async {
      final (_, container) = await kalender(tester, vorher: (e) => e.sync.andereAendert('termin', id(1), zeit('Zahnarzt', marz, 10)));
      await container.read(muellProvider.notifier).kalenderSetzen(true);
      container.read(kalenderAuswahlProvider.notifier).ansicht(KalenderAnsicht.woche);
      await warte(tester);
      expect(find.byType(MuellPunkte), findsNWidgets(2), reason: 'Mittwoch 10. und Donnerstag 11.');
      expect(find.text('Zahnarzt'), findsWidgets);
      pruefeLayout(tester, 'Woche mit Müll');
      await container.read(muellProvider.notifier).kalenderSetzen(false);
      await warte(tester);
      expect(find.byType(MuellPunkte), findsNothing);
    });

    testWidgets('Agenda: Kapseln mit den Arten an kommenden Tagen (ohne Termin gespeichert zu werden)', (tester) async {
      // "heute" der Agenda (Familienzone, dieselbe Quelle wie der Kalender), nicht die Zone des Testgeräts
      final morgen = heuteTag().add(const Duration(days: 2));
      final tag = tagText(morgen);
      final (env, container) = await start(
        tester,
        role: 'admin',
        antwort: () => _antwort(termine: [
          _tag(tag, ['papier']),
        ], jahre: [
          {'year': morgen.year, 'status': 'loaded', 'eventCount': 1, 'checkedAt': '2026-12-08T05:00:00.000Z', 'errorCode': null},
        ]),
      );
      await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Kalender')));
      await warte(tester);
      container.read(kalenderAuswahlProvider.notifier).ansicht(KalenderAnsicht.agenda);
      await warte(tester);
      expect(find.text('Altpapier'), findsNothing, reason: 'Standard: aus');
      await container.read(muellProvider.notifier).kalenderSetzen(true);
      await warte(tester);
      expect(find.byType(MuellTagesZeile), findsOneWidget);
      expect(find.text('Altpapier'), findsOneWidget);
      // nie als Termin gespeichert oder synchronisiert
      expect(await env.db.select(env.db.termine).get(), isEmpty);
    });
  });

}
