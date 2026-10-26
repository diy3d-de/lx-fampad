// Home-Assistant-Anbindung: Entscheidungslogik (rein). Zuordnung Kanal -> Zähler, "schon vorhanden" (nie überschreiben), Prüffälle (Stand kleiner, Sprung nach der Regel
// 10-faches des Medians und mehr als 20 Einheiten, weniger als 3 Tage Verlauf), Fälligkeit bei automatischer Quelle, Zeitzonen-Tag.
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/calendar/zeitzonen.dart';
import 'package:lx_fampad/data/ingest/ingest_logik.dart';
import 'package:lx_fampad/data/zaehler/zaehler_logik.dart';
import 'package:lx_fampad/data/zaehler/zaehler_modelle.dart';
import 'package:lx_fampad/data/zaehler/zaehler_uebersicht.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

DateTime _t(int tag) => DateTime.utc(2026, 10, tag);

/// Stände Tag 1 bis [bis] mit [proTag] Einheiten je Tag, ab [start] Einheiten (in Tausendsteln gerechnet).
List<Stand> _reihe({int bis = 10, int proTag = 10, int start = 1000}) => [for (var i = 1; i <= bis; i++) Stand(_t(i), (start + proTag * (i - 1)) * 1000)];

ZaehlerInhalt _z(String kanal, {bool archiviert = false, bool pruefen = true, ZaehlerModus modus = ZaehlerModus.stand}) => ZaehlerInhalt(
  art: ZaehlerArt.strom,
  name: 'Strom $kanal',
  quelle: modus == ZaehlerModus.monat ? null : ZaehlerQuelle(kanal: kanal, pruefen: pruefen),
  archiviertAb: archiviert ? '2026-01-01' : null,
  modus: modus,
);

void main() {
  tzdata.initializeTimeZones();

  group('Zuordnung Kanal -> Zähler', () {
    test('nur Zähler mit Quelle, nicht archivierte', () {
      final z = {'a': _z('strom_bezug'), 'b': _z('strom_einspeisung', archiviert: true), 'c': ZaehlerInhalt(art: ZaehlerArt.strom, name: 'Hand')};
      final m = kanalZuordnung(z);
      expect(m.keys, ['strom_bezug']);
      expect(m['strom_bezug']!.zaehlerId, 'a');
    });

    test('ein Zähler nach dem Wechsel: der neue (nicht archivierte) bekommt die Werte', () {
      final z = {'alt': _z('strom_bezug', archiviert: true), 'neu': _z('strom_bezug')};
      expect(kanalZuordnung(z)['strom_bezug']!.zaehlerId, 'neu');
    });

    test('derselbe Kanal an zwei Zählern: stabil der mit der kleineren ID, und die Doppelung wird gemeldet', () {
      final z = {'b': _z('x1'), 'a': _z('x1')};
      expect(kanalZuordnung(z)['x1']!.zaehlerId, 'a');
      expect(doppelteKanaele(z), {'x1'});
      expect(doppelteKanaele({'a': _z('x1'), 'b': _z('x2'), 'c': _z('x1', archiviert: true)}), isEmpty);
    });
  });

  group('Entscheidung je Wert', () {
    test('erster Wert überhaupt: eintragen', () {
      expect(entscheide(bestehende: const [], tag: _t(5), milli: 5000, pruefen: true).aktion, IngestAktion.eintragen);
    });

    test('normaler Folgewert: eintragen', () {
      expect(entscheide(bestehende: _reihe(), tag: _t(11), milli: 1100000, pruefen: true).aktion, IngestAktion.eintragen);
    });

    test('gleicher Wert wie gestern (kein Verbrauch): eintragen', () {
      expect(entscheide(bestehende: _reihe(), tag: _t(11), milli: 1090000, pruefen: true).aktion, IngestAktion.eintragen);
    });

    test('für den Tag gibt es schon einen Stand (von Hand oder automatisch): vorhanden, nichts überschreiben, auch bei anderem Wert', () {
      for (final milli in [1050000, 5, 99999999]) {
        final e = entscheide(bestehende: _reihe(bis: 10), tag: _t(10), milli: milli, pruefen: true);
        expect(e.aktion, IngestAktion.vorhanden, reason: '$milli');
      }
      expect(entscheide(bestehende: _reihe(bis: 10), tag: _t(10), milli: 1, pruefen: false).aktion, IngestAktion.vorhanden);
    });

    test('Stand kleiner als der davor: IMMER zur Prüfung (auch mit ausgeschaltetem Schalter)', () {
      for (final p in [true, false]) {
        final e = entscheide(bestehende: _reihe(), tag: _t(11), milli: 12400, pruefen: p);
        expect(e.aktion, IngestAktion.pruefen);
        expect(e.grund, PruefGrund.kleiner);
        expect(e.davorMilli, 1090000);
      }
    });

    test('schon wenig Stände: Stand kleiner wird trotzdem geprüft', () {
      final e = entscheide(bestehende: [Stand(_t(1), 5000000)], tag: _t(2), milli: 4999999, pruefen: true);
      expect(e.grund, PruefGrund.kleiner);
    });

    test('Wert höher als ein späterer, schon eingetragener Stand: zur Prüfung', () {
      final e = entscheide(bestehende: _reihe(bis: 10), tag: _t(5) /* gibt es */, milli: 1, pruefen: true);
      expect(e.aktion, IngestAktion.vorhanden);
      final luecke = [..._reihe(bis: 4), Stand(_t(8), 1070000)];
      final h = entscheide(bestehende: luecke, tag: _t(6), milli: 1080000, pruefen: true);
      expect(h.aktion, IngestAktion.pruefen);
      expect(h.grund, PruefGrund.hoeherAlsSpaeter);
      expect(entscheide(bestehende: luecke, tag: _t(6), milli: 1045000, pruefen: true).aktion, IngestAktion.eintragen);
    });

    test('Nachholen eines verpassten Tages in der Lücke: eintragen, wenn dazwischen', () {
      final bestehende = [..._reihe(bis: 4), ..._reihe(bis: 10).skip(5)];
      expect(entscheide(bestehende: bestehende, tag: _t(5), milli: 1040000, pruefen: true).aktion, IngestAktion.eintragen);
    });

    group('Sprung (Tagesverbrauch > 10-faches des Medians und > 20 Einheiten)', () {
      // üblich: 10 Einheiten je Tag, Stand am 10. = 1090 Einheiten
      test('120 Einheiten an einem Tag bei üblich 10: Sprung', () {
        final e = entscheide(bestehende: _reihe(), tag: _t(11), milli: 1090000 + 120000, pruefen: true);
        expect(e.aktion, IngestAktion.pruefen);
        expect(e.grund, PruefGrund.sprung);
        expect(e.tagesVerbrauchMilli, 120000);
        expect(e.ueblichMilli, 10000);
      });

      test('genau das Zehnfache ist noch kein Sprung (mehr als, nicht gleich), und unter 20 Einheiten nie', () {
        expect(entscheide(bestehende: _reihe(proTag: 10), tag: _t(11), milli: 1090000 + 100000, pruefen: true).aktion, IngestAktion.eintragen); // = 10 * 10, nicht mehr
        expect(entscheide(bestehende: _reihe(proTag: 10), tag: _t(11), milli: 1090000 + 100001, pruefen: true).grund, PruefGrund.sprung);
        // üblich 1 Einheit: das Zehnfache sind 10, aber unter der Mindestgrenze von 20
        expect(entscheide(bestehende: _reihe(proTag: 1), tag: _t(11), milli: 1009000 + 19000, pruefen: true).aktion, IngestAktion.eintragen);
        expect(entscheide(bestehende: _reihe(proTag: 1), tag: _t(11), milli: 1009000 + 20000, pruefen: true).aktion, IngestAktion.eintragen); // genau 20: nicht mehr als 20
        expect(entscheide(bestehende: _reihe(proTag: 1), tag: _t(11), milli: 1009000 + 20001, pruefen: true).grund, PruefGrund.sprung);
      });

      test('ausgeschalteter Schalter: kein Sprung-Hinweis (nur "kleiner" bleibt)', () {
        expect(entscheide(bestehende: _reihe(), tag: _t(11), milli: 1090000 + 120000, pruefen: false).aktion, IngestAktion.eintragen);
      });

      test('weniger als 3 Tage Verlauf: nur die Prüfung "kleiner"', () {
        final zwei = [Stand(_t(1), 1000000), Stand(_t(2), 1010000)];
        expect(entscheide(bestehende: zwei, tag: _t(3), milli: 5000000, pruefen: true).aktion, IngestAktion.eintragen);
        final drei = [...zwei, Stand(_t(3), 1020000)];
        expect(entscheide(bestehende: drei, tag: _t(4), milli: 5000000, pruefen: true).grund, PruefGrund.sprung);
      });

      test('mehrere Tage in einer Lücke: der Zuwachs wird auf die Tage verteilt', () {
        // 5 Tage ohne Wert, dann +50 Einheiten = 10 je Tag: nichts Besonderes
        expect(entscheide(bestehende: _reihe(bis: 5), tag: _t(10), milli: 1040000 + 50000, pruefen: true).aktion, IngestAktion.eintragen);
        // 5 Tage ohne Wert, dann +600 = 120 je Tag: Sprung
        expect(entscheide(bestehende: _reihe(bis: 5), tag: _t(10), milli: 1040000 + 600000, pruefen: true).grund, PruefGrund.sprung);
      });

      test('nur die letzten 30 Tage zählen für den Median', () {
        // vor 60 Tagen war der Verbrauch hoch (100 je Tag), seitdem 10 je Tag
        final alt = [for (var i = 0; i < 5; i++) Stand(DateTime.utc(2026, 8, 1 + i), (1000 + 100 * i) * 1000)];
        final neu = [for (var i = 0; i < 6; i++) Stand(DateTime.utc(2026, 10, 1 + i), (2000 + 10 * i) * 1000)];
        final e = entscheide(bestehende: [...alt, ...neu], tag: DateTime.utc(2026, 10, 7), milli: 2050000 + 150000, pruefen: true);
        expect(e.ueblichMilli, 10000);
        expect(e.grund, PruefGrund.sprung);
      });
    });

    test('Zählerwechsel-Marken am selben Tag zählen als ein Tag (der später angelegte Stand gilt)', () {
      final b = [..._reihe(bis: 5), Stand(_t(6), 1050000, marke: StandMarke.ende), Stand(_t(6), 0, marke: StandMarke.start)];
      expect(entscheide(bestehende: b, tag: _t(6), milli: 100, pruefen: true).aktion, IngestAktion.vorhanden);
      expect(entscheide(bestehende: b, tag: _t(7), milli: 10000, pruefen: true).aktion, IngestAktion.eintragen);
    });
  });

  test('Median: ungerade, gerade (gerundeter Mittelwert), leer', () {
    expect(medianMilli([5, 1, 3]), 3);
    expect(medianMilli([1, 2, 3, 10]), 3); // (2+3)/2 = 2,5 -> 3
    expect(medianMilli([4, 4]), 4);
    expect(medianMilli(const []), 0);
  });

  group('Ablesen fällig bei automatischer Quelle', () {
    test('erst, wenn länger als 3 Tage kein Wert kam', () {
      final heute = _t(20);
      expect(automatischFaellig(_t(20), heute), isFalse);
      expect(automatischFaellig(_t(17), heute), isFalse); // genau 3 Tage
      expect(automatischFaellig(_t(16), heute), isTrue); // 4 Tage
      expect(automatischFaellig(null, heute), isFalse); // wartet noch auf den ersten Wert
    });

    test('Fälligkeit der Reihe: ohne Ablese-Rhythmus, nur nach dem Ausbleiben', () {
      final inhalt = _z('strom_bezug');
      ZaehlerReihe reihe(List<Stand> st) => baueReihen({'z': inhalt}, {'z': st}).single;
      expect(reiheFaelligkeit(reihe(_reihe(bis: 10)), _t(12)).faellig, isFalse);
      expect(reiheFaelligkeit(reihe(_reihe(bis: 10)), _t(13)).faellig, isFalse);
      final f = reiheFaelligkeit(reihe(_reihe(bis: 10)), _t(14));
      expect(f.faellig, isTrue);
      expect(f.letzterTermin, _t(14)); // der Tag, ab dem es fehlt: letzter Stand + 4
      expect(reiheFaelligkeit(reihe(const []), _t(15)).faellig, isFalse);
    });
  });

  test('Der Kalendertag eines Päckchens ist der Tag der Familienzone, nicht der UTC-Tag', () {
    // 2026-10-25 23:30 UTC ist in Berlin (Sommerzeit endet in der Nacht) schon der 26. um 00:30 (MESZ bis 03:00 -> 01:30 Uhr MEZ); der Kalendertag ist der 26.
    final berlin = wandUhr(DateTime.utc(2026, 10, 25, 23, 30), familienOrt);
    expect(DateTime.utc(berlin.year, berlin.month, berlin.day), DateTime.utc(2026, 10, 26));
    // und dagegen der Tag im Winter: 23:30 UTC ist 00:30 des Folgetags
    final winter = wandUhr(DateTime.utc(2026, 12, 31, 23, 30), familienOrt);
    expect(DateTime.utc(winter.year, winter.month, winter.day), DateTime.utc(2027, 1, 1));
    // Kalendertage rechnen über Tagesnummern: kein Fehler am Tag der Zeitumstellung
    expect(tagNummer(DateTime.utc(2026, 10, 26)) - tagNummer(DateTime.utc(2026, 10, 25)), 1);
  });

  group('Doppelte Stände und Kanäle', () {
    test('standeZusammenfuehren: je Tag zählt der zuletzt geschriebene Stand, bei Gleichstand die größte ID, unabhängig von der Reihenfolge', () {
      final a = StandQuelle('a', 1000, Stand(_t(4), 1030000));
      final b = StandQuelle('b', 2000, Stand(_t(4), 1031000));
      final c = StandQuelle('c', 2000, Stand(_t(4), 1032000));
      final anderer = StandQuelle('x', 500, Stand(_t(3), 1020000));
      for (final reihenfolge in [
        [a, b, c, anderer],
        [c, b, a, anderer],
        [anderer, b, c, a],
      ]) {
        final m = standeZusammenfuehren(reihenfolge);
        expect(m.map((s) => '${s.tag.day}:${s.milli}'), ['3:1020000', '4:1032000']);
      }
      expect(standeZusammenfuehren([a, b]).last.milli, 1031000);
      expect(standeZusammenfuehren(const []), isEmpty);
    });

    test('zaehlerMitDoppeltenAutoTagen zählt nur Wiederholungen desselben Tags', () {
      expect(zaehlerMitDoppeltenAutoTagen({'a': [_t(1), _t(2)], 'b': [_t(1), _t(1)], 'c': const []}), {'b'});
    });

    test('doppelteKanaele erkennt auch einen Kanal, den zwei Geräte für denselben Zähler beliefern', () {
      final z = {'a': _z('strom_bezug'), 'b': _z('solar_erzeugung')};
      expect(doppelteKanaele(z), isEmpty);
      expect(doppelteKanaele(z, mitDoppeltenTagen: {'a'}), {'strom_bezug'});
      expect(doppelteKanaele({'a': _z('strom_bezug', archiviert: true)}, mitDoppeltenTagen: {'a'}), isEmpty);
    });
  });

  group('Hinweis Wird bald gelöscht', () {
    final jetzt = DateTime.utc(2026, 10, 26, 10);
    test('erst ab 25 Tagen, danach die Restzeit bis 30 Tage; ohne Datum nie', () {
      expect(paketLoeschInTagen(null, jetzt), isNull);
      expect(paketLoeschInTagen(jetzt.subtract(const Duration(days: 24, hours: 23)), jetzt), isNull);
      expect(paketLoeschInTagen(jetzt.subtract(const Duration(days: 25)), jetzt), 5);
      expect(paketLoeschInTagen(jetzt.subtract(const Duration(days: 29, hours: 5)), jetzt), 1);
      expect(paketLoeschInTagen(jetzt.subtract(const Duration(days: 31)), jetzt), 0);
    });
    test('Texte', () {
      expect(paketLoeschText(3), 'Wird in 3 Tagen vom Server gelöscht');
      expect(paketLoeschText(1), 'Wird in 1 Tag vom Server gelöscht');
      expect(paketLoeschText(0), 'Wird heute oder morgen vom Server gelöscht');
    });
  });
}

