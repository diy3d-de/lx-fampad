// Tresor (Abschnitt 6m): wer den Tresor sehen darf und wer in die Tresor-Konversation gehört (dieselbe Regel wie auf dem Server). Kinder haben nie Zugriff.
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/api/models.dart';
import 'package:lx_fampad/data/tresor/tresor_teilnehmer.dart';

UserDto _u(String id, Role r, {MemberStatus status = MemberStatus.active}) => UserDto(id: id, email: null, displayName: id, colorIndex: 0, role: r, status: status);

void main() {
  final mitglieder = [_u('a1', Role.admin), _u('p1', Role.parent), _u('k1', Role.child), _u('k2', Role.child)];

  test('nur aktive Eltern und Admins dürfen den Tresor sehen, Kinder nie', () {
    expect(darfTresorSehen(ich: 'a1', mitglieder: mitglieder), isTrue);
    expect(darfTresorSehen(ich: 'p1', mitglieder: mitglieder), isTrue);
    expect(darfTresorSehen(ich: 'P1', mitglieder: mitglieder), isTrue);
    expect(darfTresorSehen(ich: 'k1', mitglieder: mitglieder), isFalse);
    expect(darfTresorSehen(ich: 'unbekannt', mitglieder: mitglieder), isFalse);
    expect(darfTresorSehen(ich: 'a1', mitglieder: const []), isFalse);
    // ein noch nicht aktives Mitglied nicht
    expect(darfTresorSehen(ich: 'p1', mitglieder: [_u('p1', Role.parent, status: MemberStatus.pending)]), isFalse);
  });

  test('zulässige Listen: nur aktive Erwachsene, mindestens eine Person, keine Doppelten', () {
    bool g(List<String> t) => tresorTeilnehmerGueltig(teilnehmer: t, mitglieder: mitglieder);
    expect(g(['a1']), isTrue);
    expect(g(['p1']), isTrue);
    expect(g(['a1', 'p1']), isTrue);
    expect(g(['a1', 'k1']), isFalse);
    expect(g(['k1']), isFalse);
    expect(g([]), isFalse);
    expect(g(['a1', 'x']), isFalse);
    expect(g(['a1', 'A1']), isFalse);
  });

  test('wer hineingehört: alle Eltern und Admins, nie ein Kind; mit nurMit nur Personen mit Schlüssel', () {
    expect(sollTresorTeilnehmer(mitglieder: mitglieder), {'a1', 'p1'});
    expect(sollTresorTeilnehmer(mitglieder: mitglieder, nurMit: {'a1', 'k1'}), {'a1'});
    expect(sollTresorTeilnehmer(mitglieder: [_u('k1', Role.child)]), isEmpty);
  });

  test('Abgleich: Neue kommen dazu (nur mit Schlüssel), wer nicht mehr hineingehört, geht; ohne Schlüssel wird niemand entfernt', () {
    var a = tresorAbgleichen(aktuell: {'a1'}, mitglieder: mitglieder);
    expect([a.hinzu, a.weg], [{'p1'}, <String>{}]);
    // p1 hat noch keinen Schlüssel: kommt noch nicht dazu
    a = tresorAbgleichen(aktuell: {'a1'}, mitglieder: mitglieder, nurMit: {'a1'});
    expect(a.leer, isTrue);
    // ein Elternteil wurde Kind: es geht
    final danach = [_u('a1', Role.admin), _u('p1', Role.child), _u('k1', Role.child)];
    a = tresorAbgleichen(aktuell: {'a1', 'p1'}, mitglieder: danach);
    expect([a.hinzu, a.weg], [<String>{}, {'p1'}]);
    // ein Kind wurde Elternteil: es kommt dazu, aber nur mit Schlüssel
    final auf = [_u('a1', Role.admin), _u('k1', Role.parent)];
    expect(tresorAbgleichen(aktuell: {'a1'}, mitglieder: auf).hinzu, {'k1'});
    expect(tresorAbgleichen(aktuell: {'a1'}, mitglieder: auf, nurMit: {'a1'}).hinzu, isEmpty);
    // ein entferntes Mitglied geht
    expect(tresorAbgleichen(aktuell: {'a1', 'x'}, mitglieder: mitglieder).weg, {'x'});
    // ein Kind in der Liste (darf nie vorkommen) wird entfernt
    expect(tresorAbgleichen(aktuell: {'a1', 'k1'}, mitglieder: mitglieder).weg, {'k1'});
  });
}
