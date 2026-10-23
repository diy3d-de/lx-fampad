// Untere Leiste mit "Mehr": reine Logik (Auswahl, Reihenfolge, Standard, ungültige Werte, Badge-Summe, "Mehr aktiv").
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/constants.dart';
import 'package:lx_fampad/data/shell/leiste_logik.dart';

void main() {
  group('Standard und Auswahl', () {
    test('Standard: Start, Kalender, Chat, Aufgaben; Listen liegen hinter Mehr, Dateien sind ausgeblendet', () {
      expect(kLeisteStandard.map((t) => kTabs[t].label), ['Start', 'Kalender', 'Chat', 'Aufgaben']);
      expect(hinterMehr(kLeisteStandard).map((t) => kTabs[t].label), ['Listen']);
      expect(kDateienSichtbar, isFalse);
      expect(leisteWaehlbar.map((t) => kTabs[t].label), ['Start', 'Kalender', 'Chat', 'Listen', 'Aufgaben']);
      expect(mobilerTabGueltig(3), isFalse, reason: 'Dateien nicht anzeigen');
      expect(mobilerTabGueltig(6), isFalse, reason: 'Standort ist mobil kein Tab');
      expect(leisteGueltig(kLeisteStandard), isTrue);
    });

    test('Text: Hin und Zurück; Reihenfolge bleibt', () {
      const eigene = [0, 4, 2, 1];
      expect(leisteAlsText(eigene), 'start,listen,chat,kalender');
      expect(leisteAusText(leisteAlsText(eigene)), eigene);
      expect(leisteAusText('chat,start,aufgaben,listen'), [2, 0, 5, 4]);
    });

    test('ungültige oder fehlende Werte ergeben den Standard (nie eine halbe Auswahl)', () {
      for (final text in [
        null,
        '',
        '   ',
        'start,kalender,chat', // zu wenige
        'start,kalender,chat,aufgaben,listen', // zu viele
        'start,start,chat,aufgaben', // doppelt
        'kalender,chat,listen,aufgaben', // ohne Start
        'start,kalender,chat,dateien', // Dateien nicht wählbar
        'start,kalender,chat,gibt-es-nicht',
        '["start"]',
        '{kaputt',
      ]) {
        expect(leisteAusText(text), kLeisteStandard, reason: '$text');
      }
    });
  });

  group('Ändern', () {
    test('Schieben: Pfeile; außerhalb bleibt alles', () {
      expect(leisteSchieben([0, 1, 2, 5], 1, -1), [1, 0, 2, 5]);
      expect(leisteSchieben([0, 1, 2, 5], 1, 1), [0, 2, 1, 5]);
      expect(leisteSchieben([0, 1, 2, 5], 0, -1), [0, 1, 2, 5]);
      expect(leisteSchieben([0, 1, 2, 5], 3, 1), [0, 1, 2, 5]);
    });

    test('Ersetzen: nur durch einen Bereich hinter Mehr; Start bleibt immer in der Leiste', () {
      expect(leisteErsetzen([0, 1, 2, 5], 3, 4), [0, 1, 2, 4]);
      expect(leisteErsetzen([0, 1, 2, 5], 0, 4), [0, 1, 2, 5], reason: 'Start nicht entfernbar');
      expect(leisteErsetzen([0, 1, 2, 5], 3, 1), [0, 1, 2, 5], reason: 'schon in der Leiste');
      expect(leisteErsetzen([0, 1, 2, 5], 3, 3), [0, 1, 2, 5], reason: 'Dateien nicht wählbar');
      expect(leisteErsetzen([0, 1, 2, 5], 9, 4), [0, 1, 2, 5]);
      expect(leisteGueltig(leisteErsetzen([0, 1, 2, 5], 2, 4)), isTrue);
    });
  });

  group('Mehr aktiv und Auswahl in der Leiste', () {
    test('Bereich in der Leiste: dessen Platz; sonst das Feld Mehr (Platz 4)', () {
      expect(leisteAuswahl(0, kLeisteStandard), 0);
      expect(leisteAuswahl(5, kLeisteStandard), 3);
      expect(leisteAuswahl(4, kLeisteStandard), kLeistePlaetze, reason: 'Listen liegen hinter Mehr');
      expect(mehrAktiv(4, kLeisteStandard), isTrue);
      expect(mehrAktiv(1, kLeisteStandard), isFalse);
      // eigene Leiste mit Listen statt Aufgaben: umgekehrt
      expect(mehrAktiv(4, [0, 1, 2, 4]), isFalse);
      expect(mehrAktiv(5, [0, 1, 2, 4]), isTrue);
    });
  });

  group('Badge-Summe', () {
    const h = MehrHinweise(aufgaben: 3, aufgabenUeberfaellig: 1, fristen: 2, fristenUeberfaellig: 0);

    test('Aufgaben zählen nur, wenn der Aufgaben-Bereich hinter Mehr liegt; Fristen immer', () {
      expect(h.summe(kLeisteStandard), 2, reason: 'Aufgaben stehen in der Leiste');
      expect(h.summe([0, 1, 2, 4]), 5, reason: 'Aufgaben hinter Mehr: 3 + 2 Fristen');
    });

    test('Medikamente (fällige und verpasste Einnahmen) zählen immer mit, denn der Eintrag liegt immer hinter Mehr', () {
      const m = MehrHinweise(medikamente: 2, fristen: 1);
      expect(m.summe(kLeisteStandard), 3);
      expect(m.summe([0, 1, 2, 4]), 3);
    });

    test('fällige Zähler-Ablesungen zählen immer mit (der Eintrag liegt immer hinter Mehr), sind nie rot und für Kinder 0', () {
      const z = MehrHinweise(zaehler: 2, medikamente: 1);
      expect(z.summe(kLeisteStandard), 3);
      expect(z.summe([0, 1, 2, 4]), 3);
      expect(z.ueberfaellig(kLeisteStandard), isFalse);
      expect(const MehrHinweise().zaehler, 0);
    });

    test('rot nur bei Überfälligem, das wirklich hinter Mehr liegt', () {
      expect(h.ueberfaellig(kLeisteStandard), isFalse, reason: 'überfällige Aufgabe ist in der Leiste sichtbar');
      expect(h.ueberfaellig([0, 1, 2, 4]), isTrue);
      expect(const MehrHinweise(fristen: 1, fristenUeberfaellig: 1).ueberfaellig(kLeisteStandard), isTrue);
      expect(const MehrHinweise().summe([0, 1, 2, 4]), 0);
    });

    test('Zahl über 9 als "9+"', () {
      expect([for (final n in [1, 9, 10, 99]) hinweisText(n)], ['1', '9', '9+', '9+']);
    });
  });
}
