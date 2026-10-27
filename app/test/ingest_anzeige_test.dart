// Home-Assistant-Anbindung: kleine reine Anzeige-Hilfen (letzter automatischer Stand, Tage ohne Wert, welche Zählerarten Home Assistant bedient, Kanäle).
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/ingest/ingest_anzeige.dart';
import 'package:lx_fampad/data/zaehler/zaehler_logik.dart' show Stand;
import 'package:lx_fampad/data/zaehler/zaehler_modelle.dart';
import 'package:lx_fampad/data/zaehler/zaehler_state.dart' show ZaehlerEintrag;
import 'package:lx_fampad/data/zaehler/zaehler_uebersicht.dart';

import 'support/zaehler_welt.dart';

ZaehlerReihe _reihe(String id, ZaehlerInhalt inhalt, List<Stand> staende) => baueReihen({id: inhalt}, {id: staende}).single;

void main() {
  final heute = DateTime.utc(2026, 10, 26);
  const ha = ZaehlerQuelle(kanal: 'strom_bezug');

  test('Nur Strom und Solar bekommen Werte von Home Assistant (kWh); Wasser, Gas, Wärme und eigene Zähler nie', () {
    expect([for (final a in ZaehlerArt.values) if (haLiefertFuer(a)) a], [ZaehlerArt.strom, ZaehlerArt.erzeugung]);
    expect(haStandardKanal(ZaehlerArt.strom), 'strom_bezug');
    expect(haStandardKanal(ZaehlerArt.erzeugung), 'solar_erzeugung');
    expect(haStandardKanal(ZaehlerArt.kaltwasser), isNull);
    expect(haStandardKanal(ZaehlerArt.gas), isNull);
  });

  test('Die drei festen Kanäle passen zu den Formaten der Integration', () {
    expect([for (final k in kHaKanaele) k.kanal], ['strom_bezug', 'strom_einspeisung', 'solar_erzeugung']);
    for (final k in kHaKanaele) {
      expect(ZaehlerQuelle.kanalForm.hasMatch(k.kanal), isTrue);
      expect(haLiefertFuer(k.art), isTrue);
    }
  });

  test('Der letzte automatische Stand ist der jüngste Stand eines nicht archivierten Zählers mit Quelle; Zähler von Hand und archivierte zählen nicht', () {
    final auto1 = _reihe(zStrom, ZaehlerInhalt(art: ZaehlerArt.strom, name: 'Strom Haus', quelle: ha), [Stand(DateTime.utc(2026, 10, 20), 1000), Stand(DateTime.utc(2026, 10, 24), 2000)]);
    final auto2 = _reihe(zSolar, ZaehlerInhalt(art: ZaehlerArt.erzeugung, name: 'Solar', quelle: const ZaehlerQuelle(kanal: 'solar_erzeugung')), [Stand(DateTime.utc(2026, 10, 22), 500)]);
    final hand = _reihe(zKalt1, ZaehlerInhalt(art: ZaehlerArt.kaltwasser, name: 'Wasser'), [Stand(DateTime.utc(2026, 10, 25), 50)]);
    final archiv = _reihe(zWarm, ZaehlerInhalt(art: ZaehlerArt.strom, name: 'Alt', quelle: ha, archiviertAb: '2026-10-01'), [Stand(DateTime.utc(2026, 10, 25), 9)]);
    final r = letzterAutomatischerStand([auto1, auto2, hand, archiv])!;
    expect(r.name, 'Strom Haus');
    expect(r.tag, DateTime.utc(2026, 10, 24));
    expect(letzterAutomatischerStand([hand, archiv]), isNull);
    expect(letzterAutomatischerStand(const []), isNull);
    expect(letzterAutomatischerStand([_reihe(zStrom, ZaehlerInhalt(art: ZaehlerArt.strom, name: 'Neu', quelle: ha), const [])]), isNull);
  });

  test('Tage ohne Wert und ihr Text', () {
    final r = _reihe(zStrom, ZaehlerInhalt(art: ZaehlerArt.strom, name: 'Strom', quelle: ha), [Stand(DateTime.utc(2026, 10, 22), 1000)]);
    expect(tageOhneWert(r, heute), 4);
    expect(tageOhneWert(_reihe(zStrom, ZaehlerInhalt(art: ZaehlerArt.strom, name: 'Strom', quelle: ha), const []), heute), isNull);
    expect(seitTagenText(4), 'seit 4 Tagen');
    expect(seitTagenText(1), 'seit gestern');
    expect(seitTagenText(0), 'seit gestern');
  });

  group('Doppelt belieferte Zähler und zusammengeführte Stände', () {
    StandAnsicht stand(String id, String zaehler, String datum, int milli, int ms, {bool auto = true}) => StandAnsicht(
      id: id,
      zaehlerId: zaehler,
      inhalt: StandInhalt(datum: datum, milli: milli, automatisch: auto),
      erstelltAt: DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true),
    );
    ZaehlerEintrag eintrag(String id, ZaehlerInhalt inhalt, List<StandAnsicht> staende) => ZaehlerEintrag(
      ZaehlerAnsicht(id: id, konversationId: 'k', inhalt: inhalt, erstelltAt: DateTime.utc(2026)),
      staende,
    );
    final strom = ZaehlerInhalt(art: ZaehlerArt.strom, name: 'Strom Haus', quelle: ha);

    test('Zwei automatische Stände am selben Tag mit verschiedenen Werten (zwei Verbindungen): der Zähler und sein Kanal gelten als doppelt belegt', () {
      final e = eintrag(zStrom, strom, [stand('a', zStrom, '2026-10-24', 1000, 1), stand('b', zStrom, '2026-10-24', 1005, 2), stand('c', zStrom, '2026-10-25', 1010, 3)]);
      final d = doppeltBelieferte([e]);
      expect(d.zaehler, ['Strom Haus']);
      expect(d.kanaele, {'strom_bezug'});
      expect(haKanalLabel('strom_bezug'), 'Strom Bezug');
      expect(haKanalLabel('xyz'), 'xyz');
    });

    test('Derselbe Wert zweimal am selben Tag (zwei Abholgeräte desselben Elternteils holen gleichzeitig ab) ist unkritisch und löst keine Warnung aus', () {
      final e = eintrag(zStrom, strom, [stand('a', zStrom, '2026-10-24', 1000, 1), stand('b', zStrom, '2026-10-24', 1000, 2), stand('c', zStrom, '2026-10-25', 1010, 3)]);
      final d = doppeltBelieferte([e]);
      expect(d.zaehler, isEmpty);
      expect(d.kanaele, isEmpty);
    });

    test('Ein von Hand und ein automatisch geschriebener Stand am selben Tag, archivierte Zähler und Zähler ohne Quelle zählen nicht', () {
      final gemischt = eintrag(zStrom, strom, [stand('a', zStrom, '2026-10-24', 1000, 1, auto: false), stand('b', zStrom, '2026-10-25', 1010, 2)]);
      expect(doppeltBelieferte([gemischt]).zaehler, isEmpty);
      final doppelt = [stand('a', zStrom, '2026-10-24', 1000, 1), stand('b', zStrom, '2026-10-24', 1005, 2)];
      final archiv = ZaehlerInhalt(art: ZaehlerArt.strom, name: 'Alt', quelle: ha, archiviertAb: '2026-01-01');
      expect(doppeltBelieferte([eintrag(zStrom, archiv, doppelt)]).zaehler, isEmpty);
      expect(doppeltBelieferte([eintrag(zStrom, ZaehlerInhalt(art: ZaehlerArt.strom, name: 'Hand'), doppelt)]).zaehler, isEmpty);
    });

    test('Die Rechen-Stände eines Zählers führen doppelte Tage zusammen: der zuletzt geschriebene gilt, in jeder Reihenfolge', () {
      final a = stand('a', zStrom, '2026-10-24', 1000, 1);
      final b = stand('b', zStrom, '2026-10-24', 2000, 5);
      for (final liste in [[a, b], [b, a]]) {
        final r = eintrag(zStrom, strom, liste).rechenStaende;
        expect(r, hasLength(1));
        expect(r.single.milli, 2000);
      }
    });
  });
}
