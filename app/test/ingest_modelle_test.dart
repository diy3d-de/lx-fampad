// Home-Assistant-Anbindung: die Erweiterung der Zähler-Formate (`quelle` im z1-Klartext, `q` im a1-Klartext) bleibt für ältere Apps lesbar: gleiche Version `v`, nur zusätzliche Felder,
// die ein älterer Leser ignoriert; ohne Quelle ist der Klartext byte-gleich zu vorher.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/api/models.dart' show ServerFaehigkeiten;
import 'package:lx_fampad/data/zaehler/zaehler_modelle.dart';

ZaehlerInhalt _z({ZaehlerQuelle? quelle, ZaehlerModus modus = ZaehlerModus.stand}) => ZaehlerInhalt(art: ZaehlerArt.strom, name: 'Strom', quelle: quelle, modus: modus);

void main() {
  group('Zähler (z1) mit Quelle', () {
    test('ohne Quelle ist der Klartext unverändert (kein neues Feld, Version 1)', () {
      final klar = zaehlerKodieren(_z());
      expect(klar, isNot(contains('quelle')));
      expect(jsonDecode(klar.substring(3))['v'], 1);
      expect(zaehlerLesen(klar)!.quelle, isNull);
      expect(zaehlerLesen(klar)!.automatisch, isFalse);
    });

    test('mit Quelle: Hin und zurück, die Version bleibt 1', () {
      final z = _z(quelle: const ZaehlerQuelle(kanal: 'strom_bezug', pruefen: false));
      final klar = zaehlerKodieren(z);
      final json = jsonDecode(klar.substring(3)) as Map<String, dynamic>;
      expect(json['v'], 1);
      expect(json['quelle'], {'art': 'ha', 'kanal': 'strom_bezug', 'pruefen': false});
      expect(zaehlerLesen(klar), z);
      expect(zaehlerLesen(klar)!.quelle!.pruefen, isFalse);
    });

    test('Ein älterer Leser (liest nur die ihm bekannten Felder) kommt mit dem Zusatzfeld zurecht: entfernt man quelle, bleibt genau das alte Format', () {
      final mit = jsonDecode(zaehlerKodieren(_z(quelle: const ZaehlerQuelle(kanal: 'strom_bezug'))).substring(3)) as Map<String, dynamic>;
      final ohne = jsonDecode(zaehlerKodieren(_z()).substring(3)) as Map<String, dynamic>;
      expect({...mit}..remove('quelle'), ohne);
    });

    test('Prüfen ist ohne Angabe an', () {
      final klar = 'z1:${jsonEncode({'v': 1, 'art': 's', 'name': 'x', 'einheit': 'kWh', 'kosten': true, 'quelle': {'art': 'ha', 'kanal': 'k1'}})}';
      expect(zaehlerLesen(klar)!.quelle, const ZaehlerQuelle(kanal: 'k1'));
      expect(zaehlerLesen(klar)!.quelle!.pruefen, isTrue);
    });

    test('Eine unbekannte oder kaputte Quelle macht den Zähler nie unlesbar: er gilt als "von Hand"', () {
      for (final q in [
        {'art': 'zukunft', 'kanal': 'k1'},
        {'art': 'ha', 'kanal': 'GROSS'},
        {'art': 'ha', 'kanal': ''},
        {'art': 'ha', 'kanal': 'x' * 41},
        {'art': 'ha', 'kanal': 5},
        {'art': 'ha', 'kanal': 'k1', 'pruefen': 'ja'},
        'text',
        5,
        null,
      ]) {
        final klar = 'z1:${jsonEncode({'v': 1, 'art': 's', 'name': 'x', 'einheit': 'kWh', 'kosten': true, 'quelle': q})}';
        final z = zaehlerLesen(klar);
        expect(z, isNotNull, reason: '$q');
        expect(z!.quelle, isNull, reason: '$q');
      }
    });

    test('Monatswerte und Home Assistant lassen sich nicht kombinieren', () {
      expect(_z(quelle: const ZaehlerQuelle(kanal: 'k1'), modus: ZaehlerModus.monat).gueltig, isFalse);
      expect(() => zaehlerKodieren(_z(quelle: const ZaehlerQuelle(kanal: 'k1'), modus: ZaehlerModus.monat)), throwsArgumentError);
      expect(() => zaehlerKodieren(_z(quelle: const ZaehlerQuelle(kanal: 'Ungültig!'))), throwsArgumentError);
    });

    test('kopie: Quelle setzen und entfernen; die Gleichheit beachtet die Quelle', () {
      final z = _z();
      final mit = z.kopie(quelle: () => const ZaehlerQuelle(kanal: 'k1'));
      expect(mit.automatisch, isTrue);
      expect(mit, isNot(z));
      expect(mit.kopie(name: 'Neu').quelle, const ZaehlerQuelle(kanal: 'k1')); // andere Änderungen lassen die Quelle
      expect(mit.kopie(quelle: () => null).quelle, isNull);
    });
  });

  group('Zählerstand (a1) mit Herkunft', () {
    test('von Hand: Klartext unverändert', () {
      final klar = standKodieren(const StandInhalt(datum: '2026-10-26', milli: 123456));
      expect(klar, 'a1:{"v":1,"d":"2026-10-26","w":123456}');
      expect(standLesen(klar)!.automatisch, isFalse);
    });

    test('automatisch: Feld q, Version bleibt 1, Hin und zurück', () {
      final klar = standKodieren(const StandInhalt(datum: '2026-10-26', milli: 123456, automatisch: true));
      expect(klar, 'a1:{"v":1,"d":"2026-10-26","w":123456,"q":"ha"}');
      final s = standLesen(klar)!;
      expect(s.automatisch, isTrue);
      expect(s.milli, 123456);
    });

    test('Ein älterer Leser ignoriert q: ohne das Feld ist es genau das alte Format', () {
      final mit = jsonDecode(standKodieren(const StandInhalt(datum: '2026-10-26', milli: 5, automatisch: true, marke: StandMarke.start)).substring(3)) as Map<String, dynamic>;
      final ohne = jsonDecode(standKodieren(const StandInhalt(datum: '2026-10-26', milli: 5, marke: StandMarke.start)).substring(3)) as Map<String, dynamic>;
      expect({...mit}..remove('q'), ohne);
    });

    test('Eine unbekannte Herkunft macht den Stand nie unlesbar; er gilt als von Hand', () {
      final s = standLesen('a1:{"v":1,"d":"2026-10-26","w":5,"q":"anders"}')!;
      expect(s.automatisch, isFalse);
      expect(s.milli, 5);
    });

    test('kopie behält die Herkunft; Gleichheit beachtet sie; Monatswerte sind nie automatisch', () {
      const s = StandInhalt(datum: '2026-10-26', milli: 5, automatisch: true);
      expect(s.kopie(milli: 6).automatisch, isTrue);
      expect(s, isNot(const StandInhalt(datum: '2026-10-26', milli: 5)));
      expect(StandInhalt.monatswert(monat: '2026-10', milli: 5, zeit: 1).automatisch, isFalse);
    });
  });

  group('Fähigkeit features.ingest aus GET /version', () {
    test('true und false werden gelesen; fehlt das Feld (älterer Server) oder hat es einen falschen Typ, ist die Angabe null (die App fragt dann mit einem Probe-Aufruf)', () {
      expect(ServerFaehigkeiten.fromJson({'ingest': true}).ingest, isTrue);
      expect(ServerFaehigkeiten.fromJson({'ingest': false}).ingest, isFalse);
      expect(ServerFaehigkeiten.fromJson({'files': true}).ingest, isNull);
      expect(ServerFaehigkeiten.fromJson({'ingest': 'ja'}).ingest, isNull);
      expect(ServerFaehigkeiten.fromJson({'ingest': 1}).ingest, isNull);
      expect(ServerFaehigkeiten.keine.ingest, isNull);
    });
  });
}
