// Modelle und Texte der Passkey-Sicherung und der Eltern-Wiederherstellung: tolerant bei Zusatzfeldern, streng bei Pflichtfeldern, ältere Server ohne die neuen Felder, Texte der
// Sicherheitsereignisse (feste deutsche Sätze, nie Inhalte).
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/api/api_error.dart';
import 'package:lx_fampad/data/api/eltern_modelle.dart';
import 'package:lx_fampad/data/api/models.dart';
import 'package:lx_fampad/data/auth/sicherheit_text.dart';

Map<String, dynamic> _anfrage({String state = 'pending', Map<String, dynamic> extra = const {}}) => {
  'id': 'a1',
  'state': state,
  'keyVersion': 2,
  'readyAt': '2026-10-23T10:00:00.000Z',
  'expiresAt': '2026-10-26T10:00:00.000Z',
  'createdAt': '2026-10-22T10:00:00.000Z',
  'guardianId': null,
  'guardianName': null,
  'challenge': null,
  'releaseBlob': null,
  'releaseSig': null,
  ...extra,
};

Object? _j(Object o) => jsonDecode(jsonEncode(o));

void main() {
  test('Zustände der Anfrage: bekannte werden gelesen, unbekannte sind ein Fehler; offen sind nur die laufenden', () {
    expect(AnfrageZustand.parse('pending'), AnfrageZustand.wartet);
    expect(AnfrageZustand.parse('released'), AnfrageZustand.freigegeben);
    expect(() => AnfrageZustand.parse('neu'), throwsA(isA<ApiException>()));
    expect([for (final z in AnfrageZustand.values) if (z.offen) z.name], ['wartet', 'uebernommen', 'offengelegt', 'freigegeben']);
  });

  test('AnfrageDto: Pflichtfelder streng, Zusatzfelder tolerant, Wartefrist', () {
    final a = AnfrageDto.fromJson(_anfrage(extra: {'unbekannt': 1}));
    expect(a.zustand, AnfrageZustand.wartet);
    expect(a.bereit(DateTime.utc(2026, 10, 23, 9)), isFalse);
    expect(a.bereit(DateTime.utc(2026, 10, 23, 10)), isTrue);
    expect(() => AnfrageDto.fromJson({..._anfrage(), 'id': null}), throwsA(isA<ApiException>()));
    expect(() => AnfrageDto.fromJson({..._anfrage(), 'readyAt': 'kein datum'}), throwsA(isA<ApiException>()));
    expect(() => AnfrageDto.fromJson('text'), throwsA(isA<ApiException>()));
  });

  test('HinterlegungStand: fehlende Angaben ergeben "nicht aktiv", nie einen Fehler; unklare Einträge gelten als veraltet', () {
    expect(HinterlegungStand.fromJson(_j({})).aktiv, isFalse);
    expect(HinterlegungStand.fromJson(_j({})).berechtigt, isFalse);
    final s = HinterlegungStand.fromJson(_j({
      'eligible': true,
      'enabled': true,
      'since': '2026-10-01T10:00:00.000Z',
      'keyVersion': 1,
      'guardians': [
        {'id': 'm', 'displayName': 'Mama', 'guardianKeyVersion': 1, 'stale': false},
        {'id': 'p', 'displayName': 'Papa', 'guardianKeyVersion': 2}, // stale fehlt: nie "gültig" annehmen
        {'id': 3},
        'kaputt',
      ],
    }));
    expect(s.eltern.map((e) => (e.name, e.veraltet)), [('Mama', false), ('Papa', true)]);
    expect(s.seit, isNotNull);
  });

  test('HilfeUebersicht: Kinder und Anfragen; der Eintrag steht nur beim übernehmenden Elternteil', () {
    final u = HilfeUebersicht.fromJson(_j({
      'children': [
        {'id': 'k', 'displayName': 'Ben', 'stale': false},
        {'id': 'x'},
      ],
      'requests': [
        {..._anfrage(state: 'revealed'), 'childId': 'k', 'childName': 'Ben', 'commit': 'c', 'revealPub': 'p', 'revealNonce': 'n', 'escrow': {'blob': 'b', 'sig': 's', 'keyVersion': 2, 'guardianKeyVersion': 1}},
        {..._anfrage(), 'childId': 'k', 'childName': 'Ben', 'commit': 'c', 'escrow': null},
      ],
    }));
    expect(u.kinder.map((k) => k.name), ['Ben']);
    expect(u.anfragen[0].hinterlegungBlob, 'b');
    expect(u.anfragen[0].hinterlegungElternVersion, 1);
    expect(u.anfragen[1].hinterlegungBlob, isNull);
    expect(HilfeUebersicht.fromJson(_j({})).anfragen, isEmpty);
  });

  test('Ältere Server: Schlüsselangaben ohne die Passkey-Felder und Fähigkeiten ohne die neuen Schalter', () {
    final k = EigeneSchluesselDto.fromJson({'keys': null, 'hasBackup': false});
    expect(k.prfSicherungBestaetigtAm, isNull);
    expect(k.prfCredentialIds, isEmpty);
    expect(k.prfSicherungVeraltet, isFalse);
    final k2 = EigeneSchluesselDto.fromJson({'keys': null, 'hasBackup': false, 'prfBackupVerifiedAt': '2026-10-01T00:00:00Z', 'prfBackupCredentialIds': ['a', 5, ''], 'prfBackupStale': true});
    expect(k2.prfCredentialIds, ['a']);
    expect(k2.prfSicherungVeraltet, isTrue);
    expect(ServerFaehigkeiten.fromJson({'pwBackup': true}).prfBackup, isFalse);
    expect(ServerFaehigkeiten.fromJson({'pwBackup': true}).elternWiederherstellung, isFalse);
    expect(ServerFaehigkeiten.fromJson({'prfBackup': true, 'parentRecovery': true}).elternWiederherstellung, isTrue);
  });

  test('Sicherheitsereignisse: neue Arten haben feste Sätze; unbekannte bleiben neutral', () {
    SicherheitsEreignisDto e(String kind, {String? akteur, String? betroffener}) => SicherheitsEreignisDto(
      id: '1',
      art: SicherheitsArt.parse(kind),
      weg: SicherheitsWeg.passkey,
      akteur: akteur,
      durchAdmin: false,
      zeit: DateTime.utc(2026, 10, 22),
      betroffener: betroffener,
    );
    for (final k in [
      'key_backup_prf_read',
      'guardian_escrow_set',
      'guardian_escrow_removed',
      'guardian_recovery_requested',
      'guardian_recovery_asked',
      'guardian_recovery_challenged',
      'guardian_recovery_released',
      'guardian_recovery_ended',
    ]) {
      expect(SicherheitsArt.parse(k), isNot(SicherheitsArt.andere), reason: k);
      expect(sicherheitsEreignisText(e(k)), isNot(contains('null')), reason: k);
    }
    expect(SicherheitsArt.parse('irgendwas_neues'), SicherheitsArt.andere);
    expect(sicherheitsEreignisText(e('guardian_recovery_asked', betroffener: 'Ben')), startsWith('Ben bittet um die Wiederherstellung'));
    expect(sicherheitsEreignisText(e('guardian_recovery_challenged', akteur: 'Mama')), startsWith('Mama hat deine Anfrage übernommen'));
    expect(sicherheitsEreignisText(e('guardian_recovery_ended', betroffener: 'Ben')), contains('Ben'));
    expect(sicherheitsEreignisText(e('guardian_recovery_ended')), contains('Deine Anfrage'));
  });
}
