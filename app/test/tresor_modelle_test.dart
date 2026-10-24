// Tresor (Abschnitt 6m): Klartext-Format (Rundlauf, Toleranz, Grenzen) und Vorlagen. Reine Logik, ohne Datenbank und Schlüssel.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/chat/chat_krypto.dart' show kMaxTresorKlartextBytes;
import 'package:lx_fampad/data/tresor/tresor_modelle.dart';
import 'package:lx_fampad/data/tresor/tresor_vorlagen.dart';

TresorInhalt _wlan() => const TresorInhalt(
  kategorie: TresorKategorie.haushalt,
  titel: 'WLAN Zuhause',
  felder: [
    TresorFeld(bezeichnung: 'Netzname', wert: 'FamilieNetz'),
    TresorFeld(bezeichnung: 'Passwort', wert: 'Sonne-Mond-4711!', geheim: true),
  ],
  notiz: 'Gästenetz: gast',
  vorlage: TresorVorlage.wlan,
  geaendert: 1792800000000,
);

void main() {
  test('Rundlauf: Kodieren und Lesen ergeben denselben Inhalt (Felder in Reihenfolge, geheim-Marke, Notiz, Vorlage, Zeitpunkt)', () {
    final klar = tresorKodieren(_wlan());
    expect(klar, startsWith('t1:'));
    final z = tresorLesen(klar)!;
    expect(z, _wlan());
    expect([for (final f in z.felder) f.bezeichnung], ['Netzname', 'Passwort']);
    expect(z.felder.map((f) => f.geheim), [false, true]);
    expect(z.vorlage, TresorVorlage.wlan);
    expect(z.geaendert, 1792800000000);
  });

  test('eigene Kategorie braucht einen Namen, andere Kategorien keinen', () {
    const e = TresorInhalt(kategorie: TresorKategorie.eigene, kategorieName: 'Auto', titel: 'Kfz-Schein');
    expect(tresorLesen(tresorKodieren(e))!.kategorieAnzeige, 'Auto');
    expect(const TresorInhalt(kategorie: TresorKategorie.eigene, titel: 'x').gueltig, isFalse);
    expect(const TresorInhalt(kategorie: TresorKategorie.zugang, kategorieName: 'Auto', titel: 'x').gueltig, isFalse);
    expect(const TresorInhalt(kategorie: TresorKategorie.notfall, titel: 'x').kategorieAnzeige, 'Notfall');
    // Kategorie wechseln verliert den Namen
    expect(e.kopie(kategorie: TresorKategorie.haushalt).kategorieName, '');
    expect(() => tresorKodieren(const TresorInhalt(kategorie: TresorKategorie.eigene, titel: 'x')), throwsArgumentError);
  });

  test('ungültige Inhalte werden nie geschrieben: Titel, Felder, Bezeichnung, Länge, Zahl der Felder', () {
    const k = TresorKategorie.zugang;
    expect(() => tresorKodieren(const TresorInhalt(kategorie: k, titel: '  ')), throwsArgumentError);
    expect(() => tresorKodieren(TresorInhalt(kategorie: k, titel: 'x' * (kMaxTresorTitel + 1))), throwsArgumentError);
    expect(() => tresorKodieren(const TresorInhalt(kategorie: k, titel: 'x', felder: [TresorFeld(bezeichnung: '')])), throwsArgumentError);
    expect(() => tresorKodieren(TresorInhalt(kategorie: k, titel: 'x', felder: [TresorFeld(bezeichnung: 'b', wert: 'w' * (kMaxTresorWert + 1))])), throwsArgumentError);
    expect(() => tresorKodieren(TresorInhalt(kategorie: k, titel: 'x', notiz: 'n' * (kMaxTresorNotiz + 1))), throwsArgumentError);
    expect(() => tresorKodieren(TresorInhalt(kategorie: k, titel: 'x', felder: [for (var i = 0; i < kMaxTresorFelder + 1; i++) TresorFeld(bezeichnung: 'F$i')])), throwsArgumentError);
    // genau die Grenze geht
    expect(tresorKodieren(TresorInhalt(kategorie: k, titel: 'x', felder: [for (var i = 0; i < kMaxTresorFelder; i++) TresorFeld(bezeichnung: 'F$i')])), isNotEmpty);
  });

  test('Größe: höchstens 16000 Byte Klartext (Mehrbyte-Zeichen zählen mit ihren Bytes), die Grenze deckt sich mit der Verschlüsselung', () {
    expect(kMaxKlartextBytesTresor, kMaxTresorKlartextBytes);
    // Notiz 4000 + 16 Felder à 1000 Zeichen passen noch nicht in 16000 Byte, wenn sie aus 3-Byte-Zeichen bestehen
    final gross = TresorInhalt(
      kategorie: TresorKategorie.zugang,
      titel: 'x',
      notiz: '€' * kMaxTresorNotiz,
      felder: [for (var i = 0; i < 6; i++) TresorFeld(bezeichnung: 'F$i', wert: '€' * kMaxTresorWert)],
    );
    expect(gross.gueltig, isTrue); // einzeln innerhalb der Zeichengrenzen
    expect(() => tresorKodieren(gross), throwsArgumentError);
    // mit ASCII passt derselbe Umfang
    final ok = TresorInhalt(kategorie: TresorKategorie.zugang, titel: 'x', notiz: 'n' * kMaxTresorNotiz, felder: [for (var i = 0; i < 6; i++) TresorFeld(bezeichnung: 'F$i', wert: 'w' * kMaxTresorWert)]);
    expect(utf8.encode(tresorKodieren(ok)).length, lessThanOrEqualTo(kMaxKlartextBytesTresor));
  });

  test('Toleranz beim Lesen: kaputt, fremder Typ, neuere Version, ungültige Werte ergeben null; unbekannte Zusatzfelder und eine unbekannte Vorlage stören nicht', () {
    expect(tresorLesen(''), isNull);
    expect(tresorLesen('t1:kein json'), isNull);
    expect(tresorLesen('z1:{}'), isNull);
    expect(tresorLesen('a1:{}'), isNull);
    expect(tresorLesen('t1:[]'), isNull);
    final basis = jsonDecode(tresorKodieren(_wlan()).substring(3)) as Map<String, Object?>;
    String mit(void Function(Map<String, Object?>) f) {
      final m = {...basis};
      f(m);
      return 't1:${jsonEncode(m)}';
    }

    expect(tresorLesen(mit((m) => m['v'] = kTresorFormat + 1)), isNull, reason: 'neuere Version');
    expect(tresorLesen(mit((m) => m['v'] = 0)), isNull);
    expect(tresorLesen(mit((m) => m['kat'] = 'unbekannt')), isNull);
    expect(tresorLesen(mit((m) => m['t'] = '')), isNull);
    expect(tresorLesen(mit((m) => m['t'] = 5)), isNull);
    expect(tresorLesen(mit((m) => m['f'] = 'nein')), isNull);
    expect(tresorLesen(mit((m) => m['f'] = [{'b': 'x', 'w': 3}])), isNull);
    expect(tresorLesen(mit((m) => m['f'] = [{'b': 'x', 'g': 'ja'}])), isNull);
    expect(tresorLesen(mit((m) => m['g'] = -1)), isNull);
    expect(tresorLesen(mit((m) => m.remove('g'))), isNull);
    // Zusatzfelder (spätere Versionen mit Anhängen o. Ä.) und eine unbekannte Vorlage: lesbar
    final z = tresorLesen(mit((m) {
      m['anhang'] = ['x'];
      m['vl'] = 'zukunft';
    }));
    expect(z, isNotNull);
    expect(z!.vorlage, isNull);
  });

  test('Vorlagen: fünf, alle gültig mit Titel, deutsche Bezeichnungen, geheime Felder markiert, Kategorien wie vorgesehen', () {
    expect(kTresorVorlagen.map((v) => v.kennung), TresorVorlage.values);
    for (final v in kTresorVorlagen) {
      expect(v.name, isNotEmpty);
      expect(v.felder.length, lessThanOrEqualTo(kMaxTresorFelder));
      final e = v.neu(titel: 'Test');
      expect(e.gueltig, isTrue, reason: v.name);
      expect(e.vorlage, v.kennung);
      expect(tresorLesen(tresorKodieren(e)), e);
      expect(tresorVorlage(v.kennung), same(v));
    }
    expect(tresorVorlage(TresorVorlage.wlan).kategorie, TresorKategorie.haushalt);
    expect(tresorVorlage(TresorVorlage.arzt).kategorie, TresorKategorie.notfall);
    expect(tresorVorlage(TresorVorlage.wlan).felder.where((f) => f.geheim).map((f) => f.bezeichnung), contains('Passwort'));
    expect(tresorVorlage(TresorVorlage.ausweis).felder.firstWhere((f) => f.bezeichnung == 'Nummer').geheim, isTrue);
    expect(tresorVorlage(TresorVorlage.eigener).felder, isEmpty);
    // ohne Titel ist ein Eintrag aus der Vorlage noch nicht speicherbar
    expect(tresorVorlage(TresorVorlage.wlan).neu().gueltig, isFalse);
    // die Vorlage ist eine Kopie: Änderungen am Eintrag ändern die Vorlage nie
    final a = tresorVorlage(TresorVorlage.wlan).neu(titel: 'a');
    expect(identical(a.felder, tresorVorlage(TresorVorlage.wlan).felder), isFalse);
  });

  test('Kategorien und Vorlagen haben feste Kennungen (Teil des Formats)', () {
    expect(TresorKategorie.values.map((k) => k.wire), ['notfall', 'dokumente', 'zugang', 'haushalt', 'eigene']);
    expect(TresorVorlage.values.map((k) => k.wire), ['wlan', 'versicherung', 'ausweis', 'arzt', 'eigener']);
  });
}
