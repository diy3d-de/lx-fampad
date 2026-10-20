// Standort teilen, Oberfläche: Einstieg auf der Startseite, Start mit Dauer und Empfängern, laufendes Teilen, Liste der Teilenden (Genauigkeit, Alter,
// "zuletzt gesehen"), Detail, Platz für die Karte. Layout bei 360 px und Textskala 1.5. Die Steuerung ist hier ein Testdouble (die echte prüft standort_dienst_test).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/standort/standort_dienst.dart';
import 'package:lx_fampad/data/standort/standort_modelle.dart';
import 'package:lx_fampad/data/standort/standort_port.dart';
import 'package:lx_fampad/features/karte/karte_verfuegbar.dart';
import 'package:lx_fampad/features/standort/standort_karte.dart';

import 'support/fake_server.dart';
import 'support/harness.dart';

const _cora = '33333333-4444-4555-8666-777777777777';
const _dora = '44444444-5555-4666-8777-888888888888';

/// Steuerung ohne Netz und Gerät: festes Anfangs-Zustand, Aufrufe werden gemerkt.
class _TestSteuerung extends StandortController {
  final StandortState anfang;
  Duration? gestartetMit;
  StandortTakt? gestartetTakt;
  Set<String>? gestartetFuer;
  var beendet = 0;
  Duration? verlaengert;
  _TestSteuerung(this.anfang);

  @override
  StandortState build() => anfang;

  @override
  void starten() {}

  @override
  void vordergrund(bool vorn) {}

  @override
  Future<bool> teilen({required Duration dauer, required Set<String> empfaenger, StandortTakt takt = kStandortTaktStandard}) async {
    gestartetTakt = takt;
    gestartetMit = dauer;
    gestartetFuer = empfaenger;
    state = StandortState(phase: StandortPhase.teilt, endetAt: DateTime.now().add(dauer), empfaenger: empfaenger, verbunden: true);
    return true;
  }

  @override
  Future<void> beenden({String? grund, bool dienstStoppen = true, bool serverInformieren = true}) async {
    beendet++;
    state = const StandortState();
  }

  @override
  Future<void> verlaengern(Duration um) async => verlaengert = um;

  void setze(StandortState neu) => state = neu;
}

class _Port extends KeinStandortPort {
  /// Stand der Akkuoptimierung aus Sicht von Android (null: unbekannt).
  bool? akku;
  var anfragen = 0;
  _Port({this.akku});
  @override
  bool get verfuegbar => true;
  @override
  Future<bool?> akkuUneingeschraenkt() async => akku;
  @override
  Future<bool> akkuAnfragen() async {
    anfragen++;
    akku = true;
    return true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(testVorbereiten);

  final jetzt = DateTime(2026, 10, 20, 12);

  GeteiltePosition person(String id, {Duration alter = const Duration(minutes: 2), double? g = 12, bool ungeprueft = false, bool ohne = false}) => GeteiltePosition(
    userId: id,
    shareId: 's-$id',
    endetAt: jetzt.add(const Duration(minutes: 40)),
    breite: ungeprueft || ohne ? null : 48.13721,
    laenge: ungeprueft || ohne ? null : 11.5755,
    genauigkeit: g,
    messzeit: ungeprueft || ohne ? null : jetzt.subtract(alter),
    ungeprueft: ungeprueft,
  );

  late _TestSteuerung steuerung;

  Future<void> start(
    WidgetTester tester, {
    StandortState zustand = const StandortState(),
    double skala = 1.0,
    String role = 'admin',
    bool verfuegbar = true,
    _Port? port,
    StandortKartenBuilder? karte,
  }) async {
    final env = await angemeldeteUmgebung(role: role);
    env.server.json('GET /members', {
      'members': [
        userJson(role: role),
        userJson(id: fixIdKind, role: 'child', name: 'Ben', email: 'ben@beispiel.de'),
        userJson(id: _cora, role: 'parent', name: 'Cora Berger', email: 'cora@beispiel.de'),
        userJson(id: _dora, role: 'child', name: 'Dora', email: 'dora@beispiel.de'),
      ],
    });
    steuerung = _TestSteuerung(zustand);
    // die echte Karte fragt die Kartendatei auf dem Server ab: hier "gibt es nicht" (404)
    if (karte == standortKartenStandard) env.extraOverrides.add(karteDateiProvider.overrideWith((ref) async => null));
    env.standortKarte = karte;
    env.standortPort = verfuegbar ? (port ?? _Port()) : const KeinStandortPort();
    env.extraOverrides.addAll([
      standortProvider.overrideWith(() => steuerung),
      standortUhrProvider.overrideWith((ref) => () => jetzt),
    ]);
    await starteApp(tester, env, skala: skala, groesse: const Size(360, 1700));
  }

  Future<void> oeffnen(WidgetTester tester) async {
    await tippe(tester, find.text('// STANDORT').first);
    await warte(tester);
  }

  testWidgets('Startseite: Karte "Standort", Tippen öffnet die Seite mit Kopfzeile, Dauer und Empfängern', (tester) async {
    await start(tester);
    expect(find.text('Niemand teilt gerade'), findsOneWidget);
    await oeffnen(tester);
    expect(find.text('Standort'), findsWidgets);
    expect(find.text('Standort teilen'), findsOneWidget);
    for (final t in ['15 Minuten', '1 Stunde', '8 Stunden', 'Bis ich beende']) {
      expect(find.text(t), findsOneWidget);
    }
    expect(find.text('Niemand teilt gerade'), findsWidgets);
    expect(find.textContaining('Ende-zu-Ende verschlüsselt'), findsOneWidget);
  });

  testWidgets('Voreinstellung: Admin teilt mit allen; Start mit 1 Stunde ruft die Steuerung mit den gewählten Personen auf', (tester) async {
    await start(tester);
    await oeffnen(tester);
    await tippe(tester, find.text('Standort teilen'));
    expect(steuerung.gestartetMit, const Duration(hours: 1));
    expect(steuerung.gestartetFuer, {fixIdKind, _cora, _dora});
  });

  testWidgets('Dauer und Personen lassen sich ändern', (tester) async {
    await start(tester);
    await oeffnen(tester);
    await tippe(tester, find.text('8 Stunden'));
    await tippe(tester, find.text('Dora'));
    await tippe(tester, find.text('Standort teilen'));
    expect(steuerung.gestartetMit, const Duration(hours: 8));
    expect(steuerung.gestartetFuer, {fixIdKind, _cora});
  });

  testWidgets('"Bis ich beende" nennt die Höchstdauer und startet mit 12 Stunden', (tester) async {
    await start(tester);
    await oeffnen(tester);
    await tippe(tester, find.text('Bis ich beende'));
    expect(find.text('höchstens 12 Stunden'), findsOneWidget);
    await tippe(tester, find.text('Standort teilen'));
    expect(steuerung.gestartetMit, kStandortHoechstdauer);
  });

  testWidgets('Ein Kind teilt zunächst nur mit Eltern und Admins; ohne Auswahl ist der Knopf gesperrt', (tester) async {
    await start(tester, role: 'child');
    await oeffnen(tester);
    await tippe(tester, find.text('Standort teilen'));
    expect(steuerung.gestartetFuer, {_cora});
  });

  testWidgets('Laufendes Teilen: Empfänger, Restzeit, Beenden ohne Rückfrage, Verlängern', (tester) async {
    await start(
      tester,
      zustand: StandortState(
        phase: StandortPhase.teilt,
        endetAt: jetzt.add(const Duration(minutes: 42)),
        empfaenger: const {fixIdKind, _cora},
        ausgelassen: const {_dora},
        verbunden: true,
        eigene: GeraetePosition(breite: 48.1, laenge: 11.5, genauigkeit: 8, zeit: jetzt.subtract(const Duration(seconds: 20))),
      ),
    );
    await oeffnen(tester);
    expect(find.text('Du teilst deinen Standort'), findsWidgets);
    expect(find.textContaining('mit Ben, Cora Berger'), findsOneWidget);
    expect(find.textContaining('noch 42 Min'), findsOneWidget);
    expect(find.textContaining('± 8 m'), findsOneWidget);
    expect(find.textContaining('Nicht geteilt mit Dora'), findsOneWidget);
    await tippe(tester, find.text('1 Stunde länger'));
    expect(steuerung.verlaengert, const Duration(hours: 1));
    await tippe(tester, find.text('Teilen beenden'));
    expect(steuerung.beendet, 1);
    expect(find.text('Standort teilen'), findsOneWidget);
  });

  testWidgets('Hinweise: Ortung aus, offline', (tester) async {
    await start(tester, zustand: StandortState(phase: StandortPhase.teilt, endetAt: jetzt.add(const Duration(hours: 1)), empfaenger: const {fixIdKind}, ortungAus: true));
    await oeffnen(tester);
    expect(find.textContaining('Ortung deines Geräts ist ausgeschaltet'), findsOneWidget);
    expect(find.textContaining('Keine Verbindung zum Server'), findsOneWidget);
    expect(find.text('Warte auf die erste Position …'), findsOneWidget);
  });

  testWidgets('Liste der Teilenden: Genauigkeit, Alter, "zuletzt gesehen vor …", ungeprüft; Detail mit Koordinaten', (tester) async {
    await start(
      tester,
      zustand: StandortState(
        geteilt: {
          fixIdKind: person(fixIdKind),
          _cora: person(_cora, alter: const Duration(minutes: 12), g: 1400),
          _dora: person(_dora, ungeprueft: true),
        },
      ),
    );
    await oeffnen(tester);
    expect(find.text('Ben'), findsWidgets);
    expect(find.text('± 12 m · vor 2 Min'), findsOneWidget);
    expect(find.text('zuletzt gesehen vor 12 Min · ± 1,4 km'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Schlüssel nicht bestätigt, keine Position'), 200, scrollable: find.byType(Scrollable).first);
    expect(find.text('Schlüssel nicht bestätigt, keine Position'), findsOneWidget);
    await tippe(tester, find.text('± 12 m · vor 2 Min'));
    expect(find.text('48,13721, 11,57550'), findsOneWidget);
    expect(find.text('GENAUIGKEIT'), findsOneWidget);
    expect(find.text('TEILT NOCH'), findsOneWidget);
  });

  testWidgets('Karten-Schnittstelle: ein eingetragener Builder bekommt nur Personen mit Position', (tester) async {
    List<GeteiltePosition>? bekommen;
    await start(
      tester,
      zustand: StandortState(geteilt: {fixIdKind: person(fixIdKind), _dora: person(_dora, ungeprueft: true)}),
      karte: (context, positionen, mitglieder) {
        bekommen = positionen;
        return Center(child: Text('KARTE ${positionen.length} ${mitglieder.length}'));
      },
    );
    await oeffnen(tester);
    expect(find.text('KARTE 1 4'), findsOneWidget);
    expect(bekommen!.single.userId, fixIdKind);
  });

  testWidgets('Echte Karte ohne Kartendatei auf dem Server: Hinweis "Karte noch nicht eingerichtet", die Liste bleibt', (tester) async {
    await start(tester, zustand: StandortState(geteilt: {fixIdKind: person(fixIdKind)}), karte: standortKartenStandard);
    await oeffnen(tester);
    expect(find.text('Karte noch nicht eingerichtet'), findsOneWidget);
    expect(find.text('± 12 m · vor 2 Min'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Aktualisierung: Auswahl Genau (3 s), Normal (5 s, Standard), Sparsam (15 s) geht an die Steuerung', (tester) async {
    await start(tester);
    await oeffnen(tester);
    expect(find.text('Normal (5 s)'), findsOneWidget);
    await tippe(tester, find.text('Standort teilen'));
    expect(steuerung.gestartetTakt, StandortTakt.normal);
    await steuerung.beenden();
    await warte(tester);
    await tippe(tester, find.text('Genau (3 s)'));
    await tippe(tester, find.text('Standort teilen'));
    expect(steuerung.gestartetTakt, StandortTakt.genau);
  });

  testWidgets('Ohne Android (Browser): Hinweis statt Startkarte, die Liste bleibt', (tester) async {
    await start(tester, verfuegbar: false, zustand: StandortState(geteilt: {fixIdKind: person(fixIdKind)}));
    await oeffnen(tester);
    expect(find.textContaining('nur in der Android-App'), findsOneWidget);
    expect(find.text('Standort teilen'), findsNothing);
    expect(find.text('± 12 m · vor 2 Min'), findsOneWidget);
    expect(find.textContaining('Akku'), findsNothing);
  });

  testWidgets('Hinweis zum Akkuschutz (Samsung) steht auf der Seite', (tester) async {
    await start(tester);
    await oeffnen(tester);
    await tester.scrollUntilVisible(find.text('Akku-Einstellungen öffnen'), 200, scrollable: find.byType(Scrollable).first);
    expect(find.textContaining('Samsung'), findsOneWidget);
  });

  testWidgets('Akku eingeschränkt (Samsung "Optimiert"): Warnung auf der Seite, beim ersten Teilen ein Dialog, danach nicht mehr', (tester) async {
    final port = _Port(akku: false);
    await start(tester, port: port);
    await oeffnen(tester);
    await tester.scrollUntilVisible(find.text('Ohne Einschränkung erlauben'), 200, scrollable: find.byType(Scrollable).first);
    expect(find.textContaining('eingeschränkt ("Optimiert")'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Standort teilen'), -200, scrollable: find.byType(Scrollable).first);
    await tippe(tester, find.text('Standort teilen'));
    expect(find.text('Akku: Teilen im Hintergrund'), findsOneWidget);
    expect(steuerung.gestartetMit, isNull, reason: 'erst nach der Antwort');
    await tippe(tester, find.text('Trotzdem teilen'));
    expect(steuerung.gestartetMit, const Duration(hours: 1));
    expect(port.anfragen, 0);
    // zweiter Start: kein Dialog mehr (nur einmal je Gerät)
    await steuerung.beenden();
    await warte(tester);
    await tippe(tester, find.text('Standort teilen'));
    expect(find.text('Akku: Teilen im Hintergrund'), findsNothing);
  });

  testWidgets('Akku-Dialog: "Erlauben" öffnet den Systemdialog und teilt danach', (tester) async {
    final port = _Port(akku: false);
    await start(tester, port: port);
    await oeffnen(tester);
    await tippe(tester, find.text('Standort teilen'));
    await tippe(tester, find.text('Erlauben'));
    expect(port.anfragen, 1);
    expect(steuerung.gestartetMit, isNull, reason: 'erst nach der Rückkehr aus dem Systemdialog');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await warte(tester);
    expect(steuerung.gestartetMit, const Duration(hours: 1));
  });

  testWidgets('Akku nicht eingeschränkt: kein Dialog, grüner Hinweis', (tester) async {
    await start(tester, port: _Port(akku: true));
    await oeffnen(tester);
    await tippe(tester, find.text('Standort teilen'));
    expect(find.text('Akku: Teilen im Hintergrund'), findsNothing);
    expect(steuerung.gestartetMit, const Duration(hours: 1));
  });

  for (final skala in [1.0, 1.5]) {
    testWidgets('Layout bei 360 px, Textskala $skala: kein Überlauf, Touch-Ziele mindestens 44 px', (tester) async {
      await start(
        tester,
        skala: skala,
        zustand: StandortState(
          geteilt: {fixIdKind: person(fixIdKind), _cora: person(_cora, alter: const Duration(minutes: 12), g: 1400), _dora: person(_dora, ungeprueft: true)},
        ),
      );
      await oeffnen(tester);
      expect(tester.takeException(), isNull);
      expect(kleineZiele(tester), isEmpty);
      // laufendes Teilen
      steuerung.setze(
        StandortState(
        phase: StandortPhase.teilt,
        endetAt: jetzt.add(const Duration(hours: 2, minutes: 5)),
        empfaenger: const {fixIdKind, _cora, _dora},
        ausgelassen: const {_dora},
        ortungAus: true,
        eigene: GeraetePosition(breite: 48, laenge: 11, zeit: jetzt),
        geteilt: {fixIdKind: person(fixIdKind)},
        ),
      );
      await warte(tester);
      expect(tester.takeException(), isNull);
      expect(kleineZiele(tester), isEmpty);
    });
  }
}
