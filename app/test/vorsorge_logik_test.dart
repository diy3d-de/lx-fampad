// Vorsorge und Impfungen (Abschnitt 6p): feste IDs (Known-Answer wie auf dem Server), Klartext-Formate, Katalog der Vorlagen und die Fälligkeit (rein, auf Kalendertagen).
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/chat/chat_ids.dart';
import 'package:lx_fampad/data/vorsorge/vorsorge_logik.dart';
import 'package:lx_fampad/data/vorsorge/vorsorge_modelle.dart';
import 'package:lx_fampad/data/vorsorge/vorsorge_vorlagen.dart';

DateTime _t(int j, int m, int t) => DateTime.utc(j, m, t);

VorsorgeFaelligkeit _f(String kennung, {required DateTime geburt, List<String> erledigt = const [], required DateTime heute, VorsorgeGeschlecht? geschlecht, String? naechstes}) => vorsorgeFaelligkeit(
  vorlage: vorsorgeVorlage(kennung),
  eintrag: VorsorgeEintragInhalt(vorlage: kennung, art: VorsorgeArt.vorsorge, erledigt: erledigt, naechstes: naechstes),
  geburt: geburt,
  geschlecht: geschlecht,
  heute: heute,
);

void main() {
  group('feste ID des Profils (Known-Answer, muss server/test/sync-vorsorge.test.ts entsprechen)', () {
    test('abgeleitet aus der Konversation', () {
      expect(medsChatId('22222222-2222-4222-8222-222222222222'), '9a34c21c-7257-562d-b9c3-eb7b59ff6244');
      expect(vorsorgeProfilId('9a34c21c-7257-562d-b9c3-eb7b59ff6244'), '02dfdb56-dbdd-583b-ab94-86a5ea105baa');
      expect(vorsorgeProfilId('9A34C21C-7257-562D-B9C3-EB7B59FF6244'), '02dfdb56-dbdd-583b-ab94-86a5ea105baa');
    });
  });

  group('Klartext-Formate', () {
    test('Profil: Roundtrip, ungültig und fremde Version', () {
      const p = VorsorgeProfilInhalt(geburt: '2015-03-12', geschlecht: VorsorgeGeschlecht.weiblich);
      final k = vorsorgeProfilKodieren(p);
      expect(k, startsWith('vp1:'));
      expect(vorsorgeProfilLesen(k), p);
      expect(vorsorgeProfilLesen(vorsorgeProfilKodieren(const VorsorgeProfilInhalt(geburt: '2015-03-12'))), const VorsorgeProfilInhalt(geburt: '2015-03-12'));
      expect(() => vorsorgeProfilKodieren(const VorsorgeProfilInhalt(geburt: '2015-02-30')), throwsArgumentError);
      expect(vorsorgeProfilLesen('vp1:{"v":2,"geburt":"2015-03-12"}'), isNull, reason: 'neuere Version = nicht lesbar');
      expect(vorsorgeProfilLesen('vp1:{"v":1,"geburt":"morgen"}'), isNull);
      expect(vorsorgeProfilLesen('vp1:{"v":1,"geburt":"2015-03-12","geschlecht":"q"}'), isNull);
      expect(vorsorgeProfilLesen('ve1:{"v":1}'), isNull, reason: 'falscher Typ');
      expect(vorsorgeProfilLesen('vp1:{kaputt'), isNull);
    });

    test('Eintrag: Roundtrip, ungültig und fremde Version', () {
      const e = VorsorgeEintragInhalt(vorlage: 'mmr', art: VorsorgeArt.impfung, erledigt: ['2026-01-05', '2026-03-01'], naechstes: '2027-01-01', vorlauf: 30, notiz: 'Praxis Meier');
      final k = vorsorgeEintragKodieren(e);
      expect(k, startsWith('ve1:'));
      expect(vorsorgeEintragLesen(k), e);
      const eigen = VorsorgeEintragInhalt(name: 'Augenarzt', art: VorsorgeArt.sonstiges, intervallMonate: 12);
      expect(vorsorgeEintragLesen(vorsorgeEintragKodieren(eigen)), eigen);
      // ein eigener Eintrag braucht einen Namen, Erledigt-Daten müssen aufsteigend und gültig sein
      expect(() => vorsorgeEintragKodieren(const VorsorgeEintragInhalt(art: VorsorgeArt.sonstiges)), throwsArgumentError);
      expect(() => vorsorgeEintragKodieren(const VorsorgeEintragInhalt(vorlage: 'mmr', art: VorsorgeArt.impfung, erledigt: ['2026-03-01', '2026-01-05'])), throwsArgumentError);
      expect(() => vorsorgeEintragKodieren(const VorsorgeEintragInhalt(vorlage: 'mmr', art: VorsorgeArt.impfung, erledigt: ['2026-02-30'])), throwsArgumentError);
      expect(() => vorsorgeEintragKodieren(const VorsorgeEintragInhalt(vorlage: 'mmr', art: VorsorgeArt.impfung, vorlauf: 4000)), throwsArgumentError);
      expect(vorsorgeEintragLesen('ve1:{"v":9,"art":"i","vorlage":"mmr","erledigt":[]}'), isNull);
      expect(vorsorgeEintragLesen('ve1:{"v":1,"art":"?","vorlage":"mmr","erledigt":[]}'), isNull);
      expect(vorsorgeEintragLesen('ve1:{"v":1,"art":"i","erledigt":[]}'), isNull, reason: 'weder Vorlage noch Name');
      expect(vorsorgeEintragLesen('vp1:{"v":1}'), isNull);
    });
  });

  group('Katalog', () {
    test('Kennungen sind eindeutig, jede Vorlage hat Quelle und Hinweis, Fenster sind stimmig', () {
      final ids = [for (final v in kVorsorgeVorlagen) v.kennung];
      expect(ids.toSet().length, ids.length);
      for (final v in kVorsorgeVorlagen) {
        expect(v.quelle, startsWith('https://'), reason: v.kennung);
        expect(v.hinweis, isNotEmpty, reason: v.kennung);
        if (!v.nurHinweis) expect(v.wiederkehrend || v.dosen.isNotEmpty, isTrue, reason: '${v.kennung} braucht Dosen oder ein Intervall');
        for (final d in v.dosen) {
          if (d.ab != null && d.bis != null) {
            final g = _t(2020, 1, 31);
            expect(alterDatum(g, d.bis!).isAfter(alterDatum(g, d.ab!)), isTrue, reason: '${v.kennung}: Ende nach Beginn');
          }
        }
      }
    });

    test('nicht belegte Richtwerte sind gekennzeichnet (ungeprüft), freiwillige U10, U11 und J2 ebenso', () {
      for (final k in ['u10', 'u11', 'j2']) {
        final v = vorsorgeVorlage(k)!;
        expect(v.freiwillig, isTrue, reason: k);
        expect(v.ungeprueft, isTrue, reason: k);
      }
      for (final k in ['sechsfach', 'mmr', 'rotavirus', 'hpv', 'td_auffrischung']) {
        expect(vorsorgeVorlage(k)!.ungeprueft, isTrue, reason: k);
      }
      for (final k in ['hepatitis_b_risiko', 'fsme_risiko', 'chikungunya_risiko', 'lunge_ldct']) {
        expect(vorsorgeVorlage(k)!.nurHinweis, isTrue, reason: k);
      }
      expect(vorsorgeVorlage('u3')!.ungeprueft, isFalse, reason: 'belegt (BMG)');
      expect(vorsorgeVorlage('gibt-es-nicht'), isNull);
      expect(kVorsorgeHinweis, contains('keine ärztliche Beratung'));
      expect(kVorsorgeHinweis, contains('Oktober 2026'));
    });
  });

  group('Kalenderrechnung', () {
    test('Monate rechnen auf dem Kalender (Monatsende, Schaltjahr)', () {
      expect(monateDazu(_t(2024, 1, 31), 1), _t(2024, 2, 29));
      expect(monateDazu(_t(2023, 1, 31), 1), _t(2023, 2, 28));
      expect(monateDazu(_t(2024, 2, 29), 12), _t(2025, 2, 28));
      expect(monateDazu(_t(2024, 11, 15), 3), _t(2025, 2, 15));
      expect(alterDatum(_t(2020, 2, 29), const Alter.jahre(4)), _t(2024, 2, 29));
      expect(alterDatum(_t(2020, 2, 29), const Alter.jahre(1)), _t(2021, 2, 28));
      expect(alterDatum(_t(2026, 10, 1), const Alter.wochen(6)), _t(2026, 11, 12));
      expect(alterInJahren(_t(2000, 2, 29), _t(2026, 2, 28)), 25);
      expect(alterInJahren(_t(2000, 2, 29), _t(2026, 3, 1)), 26);
    });
  });

  group('Fälligkeit: Untersuchungen im Altersfenster', () {
    final geburt = _t(2026, 1, 15);
    test('U4 (3. bis 4. Monat): später, bald, fällig, überfällig, erledigt', () {
      expect(_f('u4', geburt: geburt, heute: _t(2026, 2, 1)).status, VorsorgeStatus.bald, reason: 'Beginn am 15.03.: in 42 Tagen');
      expect(_f('u4', geburt: _t(2026, 1, 15), heute: _t(2026, 1, 16)).status, VorsorgeStatus.bald);
      expect(_f('u4', geburt: _t(2026, 10, 1), heute: _t(2026, 10, 2)).status, VorsorgeStatus.bald);
      final f = _f('u4', geburt: geburt, heute: _t(2026, 3, 15));
      expect(f.status, VorsorgeStatus.faellig);
      expect(f.ab, _t(2026, 3, 15));
      expect(f.bis, _t(2026, 5, 15));
      expect(_f('u4', geburt: geburt, heute: _t(2026, 5, 14)).status, VorsorgeStatus.faellig, reason: 'letzter Tag im Fenster');
      expect(_f('u4', geburt: geburt, heute: _t(2026, 5, 15)).status, VorsorgeStatus.ueberfaellig);
      expect(_f('u4', geburt: geburt, heute: _t(2026, 4, 1), erledigt: ['2026-03-20']).status, VorsorgeStatus.erledigt);
      expect(_f('u9', geburt: geburt, heute: _t(2026, 4, 1)).status, VorsorgeStatus.spaeter);
    });

    test('Lebenstage und -wochen (U2, U3) rechnen auf Tagen', () {
      final g = _t(2026, 10, 20);
      final u2 = _f('u2', geburt: g, heute: _t(2026, 10, 22));
      expect(u2.status, VorsorgeStatus.faellig);
      expect(u2.ab, _t(2026, 10, 22));
      expect(u2.bis, _t(2026, 10, 30));
      expect(_f('u2', geburt: g, heute: _t(2026, 10, 30)).status, VorsorgeStatus.ueberfaellig);
      expect(_f('u3', geburt: g, heute: _t(2026, 11, 10)).ab, _t(2026, 11, 10));
    });

    test('Geburt am Monatsende: Fenster schneiden am Monatsende ab', () {
      final f = _f('u4', geburt: _t(2025, 12, 31), heute: _t(2026, 2, 27));
      expect(f.ab, _t(2026, 2, 28));
      expect(f.bis, _t(2026, 4, 30));
    });
  });

  group('Fälligkeit: Impfserien und wiederkehrende Termine', () {
    test('MMR: zweite Dosis rückt nach, mindestens ein Monat Abstand, danach erledigt', () {
      final g = _t(2025, 1, 10);
      final eins = _f('mmr', geburt: g, heute: _t(2026, 1, 20));
      expect(eins.dosis, 1);
      expect(eins.dosenGesamt, 2);
      expect(eins.status, VorsorgeStatus.faellig);
      // erste Dosis mit 14 Monaten: zweite frühestens einen Monat später UND ab 15 Monaten (der spätere Zeitpunkt zählt)
      final zwei = _f('mmr', geburt: g, heute: _t(2026, 3, 1), erledigt: ['2026-03-01']);
      expect(zwei.dosis, 2);
      expect(zwei.ab, _t(2026, 4, 10), reason: 'ab 15 Monaten (10.04.), später als ein Monat Abstand (01.04.)');
      expect(zwei.status, VorsorgeStatus.bald);
      expect(_f('mmr', geburt: g, heute: _t(2026, 5, 1), erledigt: ['2026-03-01']).status, VorsorgeStatus.faellig);
      expect(_f('mmr', geburt: g, heute: _t(2026, 5, 1), erledigt: ['2026-03-01', '2026-04-15']).status, VorsorgeStatus.erledigt);
    });

    test('Influenza ab 60: noch nie, dann jährlich ab dem letzten Datum', () {
      final g = _t(1960, 5, 20);
      final nie = _f('influenza', geburt: g, heute: _t(2026, 10, 1));
      expect(nie.status, VorsorgeStatus.faellig);
      expect(nie.ab, _t(2020, 5, 20));
      final letzte = _f('influenza', geburt: g, heute: _t(2026, 10, 1), erledigt: ['2025-10-20']);
      expect(letzte.ab, _t(2026, 10, 20));
      expect(letzte.status, VorsorgeStatus.bald);
      expect(_f('influenza', geburt: g, heute: _t(2026, 10, 21), erledigt: ['2025-10-20']).status, VorsorgeStatus.faellig);
      expect(_f('influenza', geburt: g, heute: _t(2026, 10, 1), erledigt: ['2026-09-01']).status, VorsorgeStatus.spaeter);
    });

    test('Check-up: einmalig von 18 bis 34, danach läuft die zweite Vorlage', () {
      final g = _t(1990, 6, 1);
      expect(_f('checkup_18_34', geburt: g, heute: _t(2026, 1, 1)).status, VorsorgeStatus.ueberfaellig, reason: 'Fenster 2008 bis 2025 vorbei');
      expect(_f('checkup_35', geburt: g, heute: _t(2026, 1, 1)).status, VorsorgeStatus.faellig);
      expect(_f('checkup_35', geburt: g, heute: _t(2026, 1, 1), erledigt: ['2025-12-01']).ab, _t(2028, 12, 1));
    });

    test('Mammographie: nur bis 70, danach "nicht mehr empfohlen"; Geschlecht passt nicht: nicht relevant', () {
      final g = _t(1950, 1, 1);
      final f = _f('mammographie', geburt: g, heute: _t(2026, 1, 1), erledigt: ['2020-01-01'], geschlecht: VorsorgeGeschlecht.weiblich);
      expect(f.status, VorsorgeStatus.erledigt);
      expect(f.grund, 'Nicht mehr empfohlen.');
      final falsch = _f('mammographie', geburt: _t(1970, 1, 1), heute: _t(2026, 1, 1), geschlecht: VorsorgeGeschlecht.maennlich);
      expect(falsch.status, VorsorgeStatus.keinTermin);
      expect(falsch.nichtRelevant, isTrue);
      // ohne Angabe wird gerechnet (nie stillschweigend weggelassen)
      expect(_f('mammographie', geburt: _t(1970, 1, 1), heute: _t(2026, 1, 1)).status, VorsorgeStatus.faellig);
    });

    test('Koloskopie: zweite Untersuchung frühestens nach 10 Jahren', () {
      final g = _t(1970, 1, 1);
      final f = _f('darm_koloskopie', geburt: g, heute: _t(2026, 1, 1), erledigt: ['2021-02-10']);
      expect(f.dosis, 2);
      expect(f.ab, _t(2031, 2, 10));
      expect(f.status, VorsorgeStatus.spaeter);
    });

    test('Masern für Erwachsene: nur ab Jahrgang 1971', () {
      expect(_f('masern_erwachsene', geburt: _t(1965, 1, 1), heute: _t(2026, 1, 1)).nichtRelevant, isTrue);
      expect(_f('masern_erwachsene', geburt: _t(1980, 1, 1), heute: _t(2026, 1, 1)).status, VorsorgeStatus.faellig);
    });
  });

  group('Nie Fälligkeiten erfinden', () {
    test('Risiko-Impfungen bleiben ein Hinweis, auch mit Geburtsdatum', () {
      for (final k in ['hepatitis_b_risiko', 'fsme_risiko', 'rsv_saeugling', 'lunge_ldct']) {
        final f = _f(k, geburt: _t(1980, 1, 1), heute: _t(2026, 10, 27));
        expect(f.status, VorsorgeStatus.keinTermin, reason: k);
        expect(f.ab, isNull, reason: k);
      }
    });

    test('ohne Geburtsdatum keine Rechnung nach Alter, aber von Hand gesetzte Termine gelten', () {
      final ohne = vorsorgeFaelligkeit(vorlage: vorsorgeVorlage('u5'), eintrag: const VorsorgeEintragInhalt(vorlage: 'u5', art: VorsorgeArt.vorsorge), geburt: null, heute: _t(2026, 10, 27));
      expect(ohne.status, VorsorgeStatus.keinTermin);
      expect(ohne.grund, contains('Geburtsdatum'));
      final hand = vorsorgeFaelligkeit(
        vorlage: vorsorgeVorlage('u5'),
        eintrag: const VorsorgeEintragInhalt(vorlage: 'u5', art: VorsorgeArt.vorsorge, naechstes: '2026-10-20'),
        geburt: null,
        heute: _t(2026, 10, 27),
      );
      expect(hand.status, VorsorgeStatus.faellig);
    });

    test('Eigene Einträge: Termin von Hand oder Intervall nach dem letzten Datum, sonst nur ein Hinweis', () {
      VorsorgeFaelligkeit eigen(VorsorgeEintragInhalt i, DateTime heute) => vorsorgeFaelligkeit(vorlage: null, eintrag: i, geburt: null, heute: heute);
      expect(eigen(const VorsorgeEintragInhalt(name: 'Augenarzt', art: VorsorgeArt.sonstiges), _t(2026, 10, 27)).status, VorsorgeStatus.keinTermin);
      expect(eigen(const VorsorgeEintragInhalt(name: 'Augenarzt', art: VorsorgeArt.sonstiges, naechstes: '2026-12-01'), _t(2026, 10, 27)).status, VorsorgeStatus.bald);
      final iv = eigen(const VorsorgeEintragInhalt(name: 'Augenarzt', art: VorsorgeArt.sonstiges, intervallMonate: 12, erledigt: ['2025-11-01']), _t(2026, 10, 27));
      expect(iv.ab, _t(2026, 11, 1));
      // ein erreichtes Handdatum ist nach einem späteren Erledigt-Datum nicht mehr maßgeblich
      final erreicht = eigen(const VorsorgeEintragInhalt(name: 'X', art: VorsorgeArt.sonstiges, naechstes: '2026-10-01', erledigt: ['2026-10-05'], intervallMonate: 6), _t(2026, 10, 27));
      expect(erreicht.ab, _t(2027, 4, 5));
    });
  });

  group('Empfehlung im Auswahlblatt', () {
    test('Kleinkind: U-Untersuchungen und Impfungen des Alters, nie Erwachsenen-Dinge oder Risiko-Hinweise', () {
      final g = _t(2025, 10, 1);
      final heute = _t(2026, 10, 27);
      final e = [for (final v in kVorsorgeVorlagen) if (vorsorgeEmpfohlen(v, geburt: g, heute: heute)) v.kennung];
      expect(e, containsAll(['u7', 'mmr', 'varizellen']));
      expect(e, isNot(contains('u2')), reason: 'Fenster vorbei');
      expect(e, isNot(contains('influenza')));
      expect(e, isNot(contains('rsv_saeugling')), reason: 'nur Hinweis');
      expect(e, isNot(contains('mammographie')));
    });

    test('Erwachsene Frau: Geschlecht entscheidet, ohne Angabe nie geschlechtsabhängige Vorschläge', () {
      final g = _t(1985, 4, 4);
      final heute = _t(2026, 10, 27);
      final frau = [for (final v in kVorsorgeVorlagen) if (vorsorgeEmpfohlen(v, geburt: g, geschlecht: VorsorgeGeschlecht.weiblich, heute: heute)) v.kennung];
      expect(frau, containsAll(['checkup_35', 'hautkrebs', 'gebaermutterhals_35', 'brust_abtasten', 'td_auffrischung', 'zahn_erwachsene']));
      expect(frau, isNot(contains('prostata')));
      final ohne = [for (final v in kVorsorgeVorlagen) if (vorsorgeEmpfohlen(v, geburt: g, heute: heute)) v.kennung];
      expect(ohne, isNot(contains('brust_abtasten')));
      expect(ohne, isNot(contains('prostata')));
      expect(ohne, contains('hautkrebs'));
    });
  });

  group('Karten', () {
    test('Einträge landen in der richtigen Karte, nicht lesbare fehlen', () {
      VorsorgeAnsicht a(String id, VorsorgeEintragInhalt? i) => VorsorgeAnsicht(id: id, konversationId: 'k', subjektId: 's', inhalt: i, erstelltAt: DateTime(2026));
      final karten = vorsorgeKarten(
        [
          a('1', const VorsorgeEintragInhalt(vorlage: 'u4', art: VorsorgeArt.vorsorge)),
          a('2', const VorsorgeEintragInhalt(vorlage: 'u5', art: VorsorgeArt.vorsorge)),
          a('3', const VorsorgeEintragInhalt(vorlage: 'u9', art: VorsorgeArt.vorsorge)),
          a('4', const VorsorgeEintragInhalt(vorlage: 'fsme_risiko', art: VorsorgeArt.impfung)),
          a('5', null),
        ],
        geburt: _t(2026, 1, 15),
        heute: _t(2026, 3, 20),
      );
      expect(karten.faellig.map((p) => p.eintrag.id), ['1']);
      expect(karten.bald.map((p) => p.eintrag.id), ['2']);
      expect(karten.spaeterOderErledigt.map((p) => p.eintrag.id), ['3']);
      expect(karten.hinweise.map((p) => p.eintrag.id), ['4']);
    });
  });
}
