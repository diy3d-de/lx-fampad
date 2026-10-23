// Medikamenten-Plan: wessen Medikamente jemand sehen darf und wer in die Medikamenten-Konversation einer Person gehört (reine Logik, gleiche Regel wie auf dem Server).
// Erwachsene sehen NIE die eines anderen Erwachsenen (auch Admins nicht), Eltern und Admins zusätzlich die ihrer Kinder, Kinder nur die eigenen (auch nicht die der Geschwister).
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/api/models.dart';
import 'package:lx_fampad/data/medikamente/medikament_subjekte.dart';

UserDto u(String id, Role rolle, {String? name, MemberStatus status = MemberStatus.active}) =>
    UserDto(id: id, email: null, displayName: name ?? id, colorIndex: 0, role: rolle, status: status);

void erw(TeilnehmerAbgleich a, Set<String> hinzu, Set<String> weg) {
  expect(a.hinzu, hinzu);
  expect(a.weg, weg);
}

void main() {
  final admin = u('admin', Role.admin, name: 'Anton');
  final mama = u('mama', Role.parent, name: 'Mama');
  final papa = u('papa', Role.parent, name: 'Papa');
  final emil = u('emil', Role.child, name: 'Emil');
  final anna = u('anna', Role.child, name: 'Anna');
  final alle = [admin, mama, papa, emil, anna];

  List<String> ids(Iterable<UserDto> l) => [for (final x in l) x.id];

  group('erlaubte Subjekte: "Ich + meine Kinder"', () {
    test('Eltern und Admins: sie selbst zuerst, dann alle Kinder nach Namen; nie ein anderer Erwachsener', () {
      expect(ids(erlaubteSubjekte(ich: 'mama', mitglieder: alle)), ['mama', 'anna', 'emil']);
      expect(ids(erlaubteSubjekte(ich: 'admin', mitglieder: alle)), ['admin', 'anna', 'emil']);
      expect(ids(erlaubteSubjekte(ich: 'papa', mitglieder: alle)), ['papa', 'anna', 'emil']);
    });

    test('Kinder: nur sie selbst (weder Erwachsene noch Geschwister)', () {
      expect(ids(erlaubteSubjekte(ich: 'emil', mitglieder: alle)), ['emil']);
      expect(ids(erlaubteSubjekte(ich: 'anna', mitglieder: alle)), ['anna']);
    });

    test('unbekannte oder nicht aktive Person: nichts; nicht aktive Kinder fehlen', () {
      expect(erlaubteSubjekte(ich: 'fremd', mitglieder: alle), isEmpty);
      expect(erlaubteSubjekte(ich: 'mama', mitglieder: const []), isEmpty);
      expect(erlaubteSubjekte(ich: 'emil', mitglieder: [u('emil', Role.child, status: MemberStatus.pending)]), isEmpty);
      expect(ids(erlaubteSubjekte(ich: 'mama', mitglieder: [mama, u('anna', Role.child, status: MemberStatus.pending), emil])), ['mama', 'emil']);
    });

    test('die Familienrolle (reine Anzeige) ändert nichts', () {
      final grosseltern = UserDto(id: 'oma', email: null, displayName: 'Oma', colorIndex: 0, role: Role.child, status: MemberStatus.active, familyRole: FamilyRole.grosseltern);
      expect(ids(erlaubteSubjekte(ich: 'mama', mitglieder: [mama, grosseltern])), ['mama', 'oma']); // Rolle Kind: Eltern sehen sie
      final elternAlsKind = UserDto(id: 'x', email: null, displayName: 'X', colorIndex: 0, role: Role.child, status: MemberStatus.active, familyRole: FamilyRole.elternteil);
      expect(ids(erlaubteSubjekte(ich: 'x', mitglieder: [mama, elternAlsKind])), ['x']);
    });

    test('Regeltabelle: wer wessen Medikamente sehen darf', () {
      const erwartet = {
        'admin': {'admin', 'emil', 'anna'},
        'mama': {'mama', 'emil', 'anna'},
        'papa': {'papa', 'emil', 'anna'},
        'emil': {'emil'},
        'anna': {'anna'},
      };
      for (final ich in erwartet.keys) {
        for (final subjekt in ['admin', 'mama', 'papa', 'emil', 'anna']) {
          expect(darfSubjektSehen(ich: ich, subjekt: subjekt, mitglieder: alle), erwartet[ich]!.contains(subjekt), reason: '$ich -> $subjekt');
        }
      }
    });
  });

  group('Teilnehmer der Medikamenten-Konversation', () {
    test('Kind: es selbst und alle Eltern/Admins; Erwachsener: nur er selbst', () {
      expect(sollTeilnehmer(subjekt: 'emil', mitglieder: alle), {'emil', 'admin', 'mama', 'papa'});
      expect(sollTeilnehmer(subjekt: 'mama', mitglieder: alle), {'mama'});
      expect(sollTeilnehmer(subjekt: 'admin', mitglieder: alle), {'admin'});
      expect(sollTeilnehmer(subjekt: 'fremd', mitglieder: alle), isEmpty);
    });

    test('nur mit eingerichteter Verschlüsselung: das Subjekt bleibt immer, andere nur mit Schlüssel', () {
      expect(sollTeilnehmer(subjekt: 'emil', mitglieder: alle, nurMit: {'mama', 'emil'}), {'emil', 'mama'});
      expect(sollTeilnehmer(subjekt: 'emil', mitglieder: alle, nurMit: {'mama'}), {'mama', 'emil'});
      expect(sollTeilnehmer(subjekt: 'emil', mitglieder: alle, nurMit: <String>{}), {'emil'});
    });

    test('gültige und ungültige Listen (Regel des Servers)', () {
      bool g(String subjekt, List<String> l) => teilnehmerGueltig(subjekt: subjekt, teilnehmer: l, mitglieder: alle);
      expect(g('emil', ['emil']), isTrue);
      expect(g('emil', ['emil', 'mama', 'admin']), isTrue);
      expect(g('emil', ['emil', 'anna']), isFalse); // Geschwister
      expect(g('emil', ['mama', 'admin']), isFalse); // Subjekt fehlt
      expect(g('mama', ['mama']), isTrue);
      expect(g('mama', ['mama', 'papa']), isFalse); // anderer Erwachsener
      expect(g('mama', ['mama', 'admin']), isFalse); // auch ein Admin nicht
      expect(g('mama', ['mama', 'emil']), isFalse); // auch kein Kind
      expect(g('fremd', ['fremd']), isFalse);
      expect(g('emil', ['emil', 'unbekannt']), isFalse);
    });

    test('Abgleich: wer fehlt, kommt hinzu, wer nicht mehr hineingehört, geht (Rollenwechsel, entfernte Eltern)', () {
      // Elternteil fehlt noch
      var a = teilnehmerAbgleichen(subjekt: 'emil', aktuell: ['emil', 'mama'], mitglieder: alle);
      erw(a, {'admin', 'papa'}, <String>{});
      // nur Personen mit Schlüssel kommen hinzu, niemand geht wegen eines fehlenden Schlüssels
      a = teilnehmerAbgleichen(subjekt: 'emil', aktuell: ['emil', 'mama'], mitglieder: alle, nurMit: {'papa'});
      erw(a, {'papa'}, <String>{});
      a = teilnehmerAbgleichen(subjekt: 'emil', aktuell: ['emil', 'mama', 'papa', 'admin'], mitglieder: alle, nurMit: {'emil'});
      expect(a.leer, isTrue);
      // Papa wird Kind: er fliegt aus der Liste von Emil
      final papaKind = [admin, mama, u('papa', Role.child), emil, anna];
      a = teilnehmerAbgleichen(subjekt: 'emil', aktuell: ['emil', 'mama', 'papa', 'admin'], mitglieder: papaKind);
      erw(a, <String>{}, {'papa'});
      // Emil wird erwachsen: nur er selbst bleibt
      final emilErwachsen = [admin, mama, papa, u('emil', Role.parent), anna];
      a = teilnehmerAbgleichen(subjekt: 'emil', aktuell: ['emil', 'mama', 'papa', 'admin'], mitglieder: emilErwachsen);
      erw(a, <String>{}, {'mama', 'papa', 'admin'});
      // Mama wurde entfernt (nicht mehr in der Mitgliederliste)
      a = teilnehmerAbgleichen(subjekt: 'emil', aktuell: ['emil', 'mama', 'papa', 'admin'], mitglieder: [admin, papa, emil, anna]);
      erw(a, <String>{}, {'mama'});
      // das Subjekt selbst geht nie (auch nicht, wenn es nicht in der Liste steht: es kommt dazu)
      a = teilnehmerAbgleichen(subjekt: 'emil', aktuell: ['mama'], mitglieder: alle);
      expect(a.hinzu, containsAll(['emil']));
      expect(a.weg, isEmpty);
    });
  });
}
