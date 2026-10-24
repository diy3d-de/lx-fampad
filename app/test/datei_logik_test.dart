// Dateiablage: reine Logik (Namensprüfung wie der Server, Pfad und Brotkrumen, Tiefe und Zyklus, Sortierung, Größenformat, Kontingent, Vorschau-Entscheidung, Medientyp aus den ersten Bytes, Rechte).
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/api/models.dart';
import 'package:lx_fampad/data/app_database.dart';
import 'package:lx_fampad/data/dateien/datei_logik.dart';
import 'package:lx_fampad/data/dateien/datei_modelle.dart';

OrdnerZeile ordner(String id, String? parent, {String name = 'x', String audience = 'family', String? owner}) =>
    OrdnerZeile(id: id, parentId: parent, name: name, audience: audience, ownerId: owner, createdAt: DateTime.utc(2026, 10, 1), rev: 1);

void main() {
  group('Namen (wie der Server)', () {
    test('zulässige Namen bleiben, Ränder und unsichtbare Zeichen entfallen', () {
      expect(bereinigeName('  Urlaub 2026 '), 'Urlaub 2026');
      expect(bereinigeName('Rechnung.pdf'), 'Rechnung.pdf');
      expect(bereinigeName('a${String.fromCharCode(0x200b)}b${String.fromCharCode(0x202e)}c'), 'abc'); // Zero-Width und Bidi-Override
      expect(bereinigeName('Ärger mit Ümlauten ß'), 'Ärger mit Ümlauten ß');
    });

    test('unzulässige Namen werden abgelehnt', () {
      for (final n in ['', '   ', '.', '..', 'a/b', r'a\b', 'ende.', 'nul', 'NUL.txt', 'com1', 'LPT9.log', 'a\u0000b', '${String.fromCharCode(0x200b)}${String.fromCharCode(0x200b)}']) {
        expect(bereinigeName(n), isNull, reason: 'Name "$n"');
      }
      expect(bereinigeName('x' * 201), isNull);
      expect(bereinigeName('x' * 200), isNotNull);
      // 255-Byte-Grenze: 86 Zeichen zu je 3 Byte sind 258 Byte
      expect(bereinigeName('€' * 86), isNull);
      expect(bereinigeName('€' * 85), isNotNull);
    });

    test('freier Name: Zähler vor der Endung, ohne Beachtung der Großschreibung', () {
      expect(freierName('Foto.jpg', ['a.txt']), 'Foto.jpg');
      expect(freierName('Foto.jpg', ['foto.JPG']), 'Foto (2).jpg');
      expect(freierName('Foto.jpg', ['Foto.jpg', 'Foto (2).jpg']), 'Foto (3).jpg');
      expect(freierName('Notizen', ['Notizen']), 'Notizen (2)');
    });

    test('Endung', () {
      expect(dateiEndung('a.PDF'), 'pdf');
      expect(dateiEndung('archiv.tar.gz'), 'gz');
      expect(dateiEndung('.versteckt'), '');
      expect(dateiEndung('ohne'), '');
      expect(dateiEndung('ende.'), '');
    });
  });

  group('Pfad, Tiefe, Zyklus', () {
    final baum = [ordner('a', null, name: 'A'), ordner('b', 'a', name: 'B'), ordner('c', 'b', name: 'C'), ordner('d', null, name: 'D')];

    test('Brotkrumen von oben nach unten', () {
      expect(ordnerPfad(baum, 'c').map((o) => o.id), ['a', 'b', 'c']);
      expect(ordnerPfadText(baum, 'c'), 'A / B / C');
      expect(ordnerPfad(baum, null), isEmpty);
      expect(ordnerPfadText(baum, null), '');
    });

    test('Tiefe', () {
      expect(ordnerTiefe(baum, null), 0);
      expect(ordnerTiefe(baum, 'a'), 1);
      expect(ordnerTiefe(baum, 'c'), 3);
      expect(ordnerTiefe(baum, 'fehlt'), -1);
    });

    test('ein Zyklus oder eine zu lange Kette endet ohne Endlosschleife', () {
      final zyklus = [ordner('x', 'y'), ordner('y', 'x')];
      expect(ordnerPfad(zyklus, 'x'), isEmpty);
      expect(ordnerTiefe(zyklus, 'y'), -1);
      final lang = [for (var i = 0; i < 8; i++) ordner('o$i', i == 0 ? null : 'o${i - 1}')];
      expect(ordnerPfad(lang, 'o7'), isEmpty); // tiefer als 6
      expect(ordnerPfad(lang, 'o5'), hasLength(6));
    });

    test('Unterordner von unten (Kinder vor ihrem Elternteil) und Höhe', () {
      expect(unterordnerVonUnten(baum, 'a').map((o) => o.id), ['c', 'b']);
      expect(unterordnerVonUnten(baum, 'd'), isEmpty);
      expect(hoeheUnter(baum, 'a'), 2);
      expect(hoeheUnter(baum, 'c'), 0);
      expect(unterordnerVonUnten([ordner('x', 'y'), ordner('y', 'x')], 'x').map((o) => o.id), ['y']); // endet trotz Zyklus
    });

    test('liegt unter oder in: Grundlage der Zyklus-Prüfung', () {
      expect(liegtUnterOderIn(baum, 'c', 'a'), isTrue);
      expect(liegtUnterOderIn(baum, 'a', 'a'), isTrue);
      expect(liegtUnterOderIn(baum, 'a', 'c'), isFalse);
      expect(liegtUnterOderIn(baum, null, 'a'), isFalse);
      expect(liegtUnterOderIn(baum, 'd', 'a'), isFalse);
    });
  });

  group('Sortierung', () {
    test('Namen: Groß-/Kleinschreibung egal, Zahlen nach ihrem Wert', () {
      final l = ['Foto 10', 'foto 2', 'Foto 1', 'Bild', 'bild 02'];
      l.sort(namensVergleich);
      expect(l, ['Bild', 'bild 02', 'Foto 1', 'foto 2', 'Foto 10']);
    });

    test('Dateien nach Name, Änderung (neueste zuerst) oder Größe (größte zuerst); Gleichstand nach Name', () {
      final d = [('b', DateTime.utc(2026, 1, 1), 5), ('a', DateTime.utc(2026, 3, 1), 5), ('c', DateTime.utc(2026, 2, 1), 9)];
      List<String> s(DateiSortierung w) => dateienSortiert<(String, DateTime, int)>(d, w, name: (x) => x.$1, geaendert: (x) => x.$2, groesse: (x) => x.$3).map((x) => x.$1).toList();
      expect(s(DateiSortierung.name), ['a', 'b', 'c']);
      expect(s(DateiSortierung.geaendert), ['a', 'c', 'b']);
      expect(s(DateiSortierung.groesse), ['c', 'a', 'b']);
    });
  });

  group('Größe und Kontingent', () {
    test('Größenformat mit Komma', () {
      expect(groesseText(0), '0 B');
      expect(groesseText(512), '512 B');
      expect(groesseText(1024), '1 KB');
      expect(groesseText(1536), '1,5 KB');
      expect(groesseText(12 * 1024 * 1024), '12 MB');
      expect(groesseText(2469606195), '2,3 GB');
      expect(groesseText(104857600), '100 MB');
    });

    test('Kontingent-Anzeige: Anteil, Text, Warnstufen', () {
      KontingentAnzeige k(int belegt, [int reserviert = 0]) => KontingentAnzeige(belegt: belegt, reserviert: reserviert, kontingent: 10737418240);
      expect(k(0).stufe, KontingentStufe.ok);
      expect(k(5368709120).anteil, closeTo(0.5, 1e-9));
      expect(k(5368709120).text, '5 GB von 10 GB belegt');
      expect(k(9663676416).stufe, KontingentStufe.knapp); // 90 Prozent
      expect(k(9000000000, 1737418240).stufe, KontingentStufe.voll); // reservierte Uploads zählen mit
      expect(k(20000000000).frei, 0);
      expect(k(20000000000).anteil, 1.0);
    });

    test('Größenprüfung vorab: leer, zu groß, Speicher voll; verschlüsselt mit der Grenze der übertragenen Bytes', () {
      const n = DateiNutzung(belegtBytes: 10737418240 - 1000000, kontingentBytes: 10737418240);
      expect(groessePruefen(0, DateiNutzung.standard), DateiFehler.leer);
      expect(groessePruefen(104857601, DateiNutzung.standard), DateiFehler.zuGross);
      expect(groessePruefen(104857600, DateiNutzung.standard), isNull);
      expect(groessePruefen(2000000, n), DateiFehler.speicherVoll);
      expect(groessePruefen(500000, n), isNull);
      expect(groessePruefen(105000000, DateiNutzung.standard, e2ee: true), isNull); // über 100 MB, aber unter 100 MB + 1 MiB
      expect(groessePruefen(105906177, DateiNutzung.standard, e2ee: true), DateiFehler.zuGross);
    });

    test('Zahlen des Servers: fehlende oder falsche Werte bleiben beim Standard', () {
      final n = DateiNutzung.fromJson({'usedBytes': 5, 'reservedBytes': 'x', 'quotaBytes': 0, 'maxFileBytes': 10});
      expect(n.belegtBytes, 5);
      expect(n.reserviertBytes, 0);
      expect(n.kontingentBytes, kStandardKontingentBytes);
      expect(n.maxDateiBytes, 10);
      expect(n.maxE2eeBytes, kStandardMaxE2eeBytes);
      expect(n.abschnittBytes, kTusAbschnittBytes);
      expect(kTusAbschnittBytes, 4 * 1024 * 1024);
    });
  });

  group('Vorschau und Medientyp', () {
    test('Art der Datei nach Typ, sonst nach Endung', () {
      expect(vorschauArt('image/png', 'x'), VorschauArt.bild);
      expect(vorschauArt(null, 'urlaub.JPG'), VorschauArt.bild);
      expect(vorschauArt('application/pdf', 'x'), VorschauArt.pdf);
      expect(vorschauArt(null, 'a.mp4'), VorschauArt.video);
      expect(vorschauArt('text/plain', 'a'), VorschauArt.text);
      expect(vorschauArt(null, 'a.zip'), VorschauArt.archiv);
      expect(vorschauArt('application/octet-stream', 'a.xyz'), VorschauArt.sonstige);
    });

    test('Vorschaubild nur für Bilder, die der Decoder sicher kann', () {
      expect(kannVorschaubild('image/jpeg'), isTrue);
      expect(kannVorschaubild('image/png'), isTrue);
      expect(kannVorschaubild('image/webp'), isTrue);
      expect(kannVorschaubild('image/gif'), isFalse);
      expect(kannVorschaubild('image/heic'), isFalse);
      expect(kannVorschaubild('image/svg+xml'), isFalse);
      expect(kannVorschaubild(null), isFalse);
      expect(zeigtVollbild('image/png', 'a.png'), isTrue);
      expect(zeigtVollbild('application/pdf', 'a.pdf'), isFalse);
    });

    test('Medientyp aus den ersten Bytes wie beim Server', () {
      Uint8List b(List<int> x) => Uint8List.fromList([...x, ...List.filled(16, 0)]);
      expect(mimeAusKopf(b([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])), 'image/png');
      expect(mimeAusKopf(b([0xff, 0xd8, 0xff, 0xe0])), 'image/jpeg');
      expect(mimeAusKopf(b([0x47, 0x49, 0x46, 0x38, 0x39, 0x61])), 'image/gif');
      expect(mimeAusKopf(b([0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x45, 0x42, 0x50])), 'image/webp');
      expect(mimeAusKopf(b([0x25, 0x50, 0x44, 0x46, 0x2d])), 'application/pdf');
      expect(mimeAusKopf(b([1, 2, 3])), isNull);
      expect(mimeAusKopf(Uint8List(0)), isNull);
    });

    test('Typ für den Upload: nur was die Bytes belegen (Bilder, PDF), sonst nach Endung, sonst keiner', () {
      final png = Uint8List.fromList([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 0]);
      expect(mimeFuerUpload('urlaub.jpg', png), 'image/png'); // falsche Endung: die Bytes entscheiden
      expect(mimeFuerUpload('urlaub.jpg', Uint8List.fromList([1, 2, 3])), isNull); // Bild ohne passende Bytes: kein Etikett (der Server entscheidet)
      expect(mimeFuerUpload('scan.pdf', Uint8List.fromList([1, 2, 3])), isNull);
      expect(mimeFuerUpload('notizen.txt', Uint8List.fromList([65, 66])), 'text/plain');
      expect(mimeFuerUpload('daten.csv', Uint8List.fromList([65])), 'text/csv');
    });
  });

  group('Rechte der Oberfläche', () {
    const eltern = DateiRechte(rolle: Role.parent, ich: 'p');
    const admin = DateiRechte(rolle: Role.admin, ich: 'a');
    const kind = DateiRechte(rolle: Role.child, ich: 'k');

    test('Eltern und Admins dürfen alles', () {
      for (final r in [eltern, admin]) {
        expect(r.darfSehen('parents'), isTrue);
        expect(r.darfAnlegen('parents'), isTrue);
        expect(r.darfAendern('jemand'), isTrue);
        expect(r.darfLoeschen('jemand'), isTrue);
        expect(r.darfStufeAendern, isTrue);
        expect(r.darfFassungHochladen('jemand'), isTrue);
        expect(r.stufenZumAnlegen, [kStufeFamilie, kStufeEltern]);
      }
    });

    test('Kinder sehen und legen nur `family` an, ändern und löschen nur Eigenes, die Stufe nie', () {
      expect(kind.darfSehen('family'), isTrue);
      expect(kind.darfSehen('parents'), isFalse);
      expect(kind.darfAnlegen('family'), isTrue);
      expect(kind.darfAnlegen('parents'), isFalse);
      expect(kind.darfAendern('k'), isTrue);
      expect(kind.darfAendern('p'), isFalse);
      expect(kind.darfAendern(null), isFalse);
      expect(kind.darfLoeschen('k'), isTrue);
      expect(kind.darfLoeschen('p'), isFalse);
      expect(kind.darfFassungHochladen('k'), isTrue);
      expect(kind.darfFassungHochladen('p'), isFalse);
      expect(kind.darfStufeAendern, isFalse);
      expect(kind.stufenZumAnlegen, [kStufeFamilie]);
    });

    test('Zielordner: sichtbar, bei Stufe `family` selbst `family`, oben immer', () {
      final fam = ordner('f', null);
      final eltOrdner = ordner('e', null, audience: 'parents');
      expect(eltern.darfZielOrdner(null, 'family'), isTrue);
      expect(eltern.darfZielOrdner(fam, 'family'), isTrue);
      expect(eltern.darfZielOrdner(eltOrdner, 'family'), isFalse); // Invariante
      expect(eltern.darfZielOrdner(eltOrdner, 'parents'), isTrue);
      expect(kind.darfZielOrdner(eltOrdner, 'family'), isFalse);
      expect(kind.darfZielOrdner(fam, 'family'), isTrue);
    });
  });
}
