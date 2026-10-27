// Erinnerungen in der Web-App, reine Logik und Port: neutrale Texte, fällig/doppelt/verpasst/Toleranz, Schnappschuss und Merkliste, Ablage, Port ohne Titel.
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/calendar/feiertage.dart' show MemoryFeiertageSpeicher;
import 'package:lx_fampad/data/erinnerungen/browser_benachrichtigung.dart';
import 'package:lx_fampad/data/erinnerungen/erinnerung_planung.dart';
import 'package:lx_fampad/data/erinnerungen/erinnerung_port.dart';
import 'package:lx_fampad/data/erinnerungen/web_erinnerung_logik.dart';
import 'package:lx_fampad/data/erinnerungen/web_erinnerung_port.dart';

const _u = '3f2b8c1e-9d4a-4b6f-8a1c-2e7d5f0a9b13';
final _nun = DateTime.utc(2026, 10, 19, 12);

WebEintrag _e(int id, Duration vor, [String? payload]) => WebEintrag(id, _nun.subtract(vor).millisecondsSinceEpoch, payload ?? 'termin|$_u|2026-10-19');

GeplanteErinnerung _g(int id, DateTime zeit, String payload) => GeplanteErinnerung(id: id, zeit: zeit, titel: 'Geheimer Titel', text: 'Geheimer Ort', payload: payload);

void main() {
  group('neutrale Texte', () {
    test('nie ein Titel, nie ein Name; unbekannte Nutzlasten und der Auslauf-Hinweis haben keinen Web-Text', () {
      expect(webNeutralerText('termin|$_u|2026-10-19'), 'Erinnerung: Ein Termin steht an');
      expect(webNeutralerText('aufgabe|$_u'), 'Erinnerung: Eine Aufgabe steht an');
      expect(webNeutralerText('muell|2026-10-20'), 'Erinnerung: Eine Abholung steht an');
      expect(webNeutralerText('medikament|$_u'), 'Erinnerung: Etwas steht an');
      expect(webNeutralerText('zaehler'), 'Erinnerung: Etwas steht an');
      expect(webNeutralerText('briefing'), contains('Tagesüberblick'));
      for (final p in ['', 'sicherheit', 'betrieb', 'standort', 'wetter|x', 'termin|kaputt|2026-10-19', 'aufgabe|x']) {
        expect(webNeutralerText(p), isNull, reason: p);
      }
    });
  });

  group('prüfen', () {
    test('fällig innerhalb der Toleranz, verpasst danach bis 24 Stunden, Zukunft und Älteres nie', () {
      final plan = [
        _e(1, const Duration(minutes: 1)),
        _e(2, const Duration(minutes: 5)),
        _e(3, const Duration(minutes: 6)),
        _e(4, const Duration(hours: 23)),
        _e(5, const Duration(hours: 24)),
        _e(6, const Duration(hours: 30)),
        _e(7, const Duration(minutes: -1)),
      ];
      final p = webPruefen(plan: plan, gezeigt: {}, jetzt: _nun);
      expect(p.faellig.map((e) => e.id), [1, 2]);
      expect(p.verpasst.map((e) => e.id), [3, 4], reason: 'neueste zuerst; 24 Stunden und älter nicht mehr');
    });

    test('nie doppelt: gezeigte Erinnerungen fallen heraus, eine verschobene Zeit zählt neu', () {
      final a = _e(1, const Duration(minutes: 1));
      expect(webPruefen(plan: [a], gezeigt: {a.schluessel}, jetzt: _nun).faellig, isEmpty);
      final verschoben = _e(1, const Duration(minutes: 2));
      expect(webPruefen(plan: [verschoben], gezeigt: {a.schluessel}, jetzt: _nun).faellig, hasLength(1));
    });

    test('verpasst: höchstens 10', () {
      final plan = [for (var i = 0; i < 15; i++) _e(100 + i, Duration(minutes: 10 + i))];
      final p = webPruefen(plan: plan, gezeigt: {}, jetzt: _nun);
      expect(p.verpasst, hasLength(kWebVerpasstMax));
      expect(p.verpasst.first.id, 100);
    });

    test('Merkliste wird nach 48 Stunden bereinigt', () {
      final alt = _e(1, const Duration(hours: 49)).schluessel;
      final neu = _e(2, const Duration(hours: 1)).schluessel;
      expect(webMerklisteBereinigen({alt, neu}, _nun), {neu});
    });
  });

  group('Schnappschuss', () {
    test('behält Vergangenes im Verpasst-Fenster, verwirft Älteres und Hinweise ohne Web-Text, nimmt nie Titel auf', () {
      final alt = [_e(1, const Duration(hours: 2)), _e(2, const Duration(hours: 30)), _e(3, const Duration(hours: 1), 'sicherheit')];
      final neu = [
        _g(10, _nun.add(const Duration(hours: 1)), 'aufgabe|$_u'),
        _g(kAuslaufHinweisPlanId, _nun.add(const Duration(hours: 2)), ''),
      ];
      final s = webSchnappschuss(neu, alt, _nun);
      expect(s.map((e) => e.id), [1, 10]);
      expect(webPlanKodieren(s), isNot(contains('Geheim')));
    });
  });

  group('Ablage', () {
    test('Hin und zurück; Unlesbares ergibt leere Listen, nie eine Ausnahme', () {
      final plan = [_e(1, const Duration(hours: 1)), _e(2, const Duration(minutes: 1), 'briefing')];
      expect(webPlanLesen(webPlanKodieren(plan)), plan);
      expect(webPlanLesen('kaputt{'), isEmpty);
      expect(webPlanLesen('[[1,2,"sicherheit"]]'), isEmpty);
      expect(webPlanLesen(null), isEmpty);
      expect(webMerklisteLesen(webMerklisteKodieren({'1@2'})), {'1@2'});
      expect(webMerklisteLesen('{"a":1}'), isEmpty);
      expect(webMerklisteLesen('["x"]'), isEmpty);
    });
  });

  group('Port', () {
    late MemoryFeiertageSpeicher speicher;
    late FakeBrowserBenachrichtigung browser;
    late bool aktiv;
    late DateTime jetzt;
    WebErinnerungPort neu() => WebErinnerungPort(speicher: speicher, browser: browser, aktiv: () async => aktiv, jetzt: () => jetzt);

    setUp(() {
      speicher = MemoryFeiertageSpeicher();
      browser = FakeBrowserBenachrichtigung();
      aktiv = true;
      jetzt = _nun;
    });

    test('planen hält nur den Schnappschuss (kein Titel in der Ablage); nach einem Neustart steht er wieder da', () async {
      final p = neu();
      expect(await p.planen([_g(1, _nun.add(const Duration(minutes: 10)), 'termin|$_u|2026-10-19')], exakt: true, sperrbildschirmTitel: true), isTrue);
      expect(speicher.werte.values.join(), isNot(contains('Geheim')));
      expect((await neu().pruefen(_nun.add(const Duration(minutes: 11)))).faellig, hasLength(1));
    });

    test('nach einer Pause bleibt Vergangenes als verpasst erhalten, auch wenn die neue Planung es nicht mehr kennt', () async {
      final p = neu();
      await p.planen([_g(1, _nun.add(const Duration(minutes: 10)), 'aufgabe|$_u')], exakt: true, sperrbildschirmTitel: false);
      jetzt = _nun.add(const Duration(hours: 3));
      final p2 = neu();
      await p2.planen([_g(2, jetzt.add(const Duration(hours: 1)), 'briefing')], exakt: true, sperrbildschirmTitel: false);
      final r = await p2.pruefen(jetzt);
      expect(r.faellig, isEmpty);
      expect(r.verpasst.map((e) => e.id), [1]);
    });

    test('Schalter aus: planen räumt auf und hält nichts; alleLöschen leert Ablage und Speicher', () async {
      final p = neu();
      await p.planen([_g(1, _nun.add(const Duration(minutes: 10)), 'aufgabe|$_u')], exakt: true, sperrbildschirmTitel: false);
      aktiv = false;
      await p.planen([_g(1, _nun.add(const Duration(minutes: 10)), 'aufgabe|$_u')], exakt: true, sperrbildschirmTitel: false);
      expect(p.plan, isEmpty);
      expect(speicher.werte.containsKey(kWebPlanSchluessel), isFalse);
      aktiv = true;
      await p.planen([_g(1, _nun.add(const Duration(minutes: 10)), 'aufgabe|$_u')], exakt: true, sperrbildschirmTitel: false);
      await p.alsGezeigtMerken(p.plan, _nun);
      await p.alleLoeschen();
      expect(speicher.werte.containsKey(kWebPlanSchluessel), isFalse);
      expect(speicher.werte.containsKey(kWebMerklisteSchluessel), isFalse);
      expect((await p.pruefen(_nun)).faellig, isEmpty);
    });

    test('Erlaubnis: Zustände ehrlich abgebildet; Anfrage nur über benachrichtigungenAnfragen', () async {
      final p = neu();
      expect(await p.benachrichtigungsStatus(), BenachrichtigungsStatus.fragbar);
      expect(browser.anfragenAnzahl, 0, reason: 'nie von selbst fragen');
      browser.stand = BrowserErlaubnis.blockiert;
      expect(await p.benachrichtigungsStatus(), BenachrichtigungsStatus.gesperrt);
      browser.stand = BrowserErlaubnis.fehlt;
      expect(await p.benachrichtigungsStatus(), BenachrichtigungsStatus.gesperrt);
      browser.stand = BrowserErlaubnis.offen;
      expect(await p.benachrichtigungenAnfragen(), isTrue);
      expect(browser.anfragenAnzahl, 1);
      expect(await p.benachrichtigungsStatus(), BenachrichtigungsStatus.erlaubt);
    });
  });
}
