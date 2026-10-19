// Familienrolle (reine Anzeige): Modell, Pille neben der Rolle (Admin-Liste, Profil, Seitenleiste), Auswahl im Profil und durch den Admin.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/api/models.dart';
import 'package:lx_fampad/features/admin/admin_screen.dart';

import 'support/fake_server.dart';
import 'support/harness.dart';

Map<String, dynamic> _mitRolle(Map<String, dynamic> user, String? rolle) => {...user, 'familyRole': ?rolle};

FakeServer _server({String role = 'admin', String? eigene, String? ben}) {
  final s = standardServer(role: role);
  final me = meJson(role: role, passkeys: 1, password: true, totp: true);
  me['user'] = _mitRolle(me['user'] as Map<String, dynamic>, eigene);
  s.json('GET /me', me);
  s.json('GET /members', {
    'members': [
      _mitRolle(userJson(role: role), eigene),
      _mitRolle(userJson(id: fixIdKind, role: 'child', name: 'Ben', email: 'ben@beispiel.de'), ben),
    ],
  });
  s.json('PUT /me/family-role', {'ok': true});
  s.json('PUT /members/$fixIdKind/family-role', {'ok': true});
  return s;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(testVorbereiten);

  test('Modell: familyRole fehlt (alter Server), ist gesetzt oder unbekannt (neuere Version) -> nie ein Fehler', () {
    expect(UserDto.fromJson(userJson()).familyRole, isNull);
    expect(UserDto.fromJson({...userJson(), 'familyRole': 'grosseltern'}).familyRole, FamilyRole.grosseltern);
    expect(UserDto.fromJson({...userJson(), 'familyRole': 'onkel'}).familyRole, isNull);
    expect(UserDto.fromJson({...userJson(), 'familyRole': null}).familyRole, isNull);
    expect(FamilyRole.grosseltern.label, 'Großeltern');
    expect(UserDto.fromJson({...userJson(), 'familyRole': 'vater'}).toJson()['familyRole'], 'vater');
  });

  for (final skala in [1.0, 1.5]) {
    testWidgets('Admin zeigt "Admin" und "Elternteil" nebeneinander (Profil und Mitgliederliste, 360 px, Skala $skala)', (tester) async {
      final env = await angemeldeteUmgebung(server: _server(eigene: 'elternteil', ben: 'sonstige'));
      await starteApp(tester, env, skala: skala);
      await tippe(tester, find.byTooltip('Profil und Sicherheit'));
      expect(find.text('Admin'), findsOneWidget);
      expect(find.text('Elternteil'), findsNWidgets(2)); // Pille in der Kopfkarte und Status der Zeile "Familienrolle"
      pruefeLayout(tester, 'Profil mit Familienrolle');
      await tippe(tester, find.text('Mitglieder und Einladungen'));
      expect(find.byType(AdminScreen), findsOneWidget);
      expect(find.text('Admin'), findsOneWidget);
      expect(find.text('Elternteil'), findsOneWidget);
      expect(find.text('Kind'), findsOneWidget);
      expect(find.text('Sonstige'), findsOneWidget);
      pruefeLayout(tester, 'Mitgliederliste mit Familienrolle');
    });
  }

  testWidgets('Rolle Elternteil mit Familienrolle Elternteil: keine doppelte Pille', (tester) async {
    final env = await angemeldeteUmgebung(role: 'parent', server: _server(role: 'parent', eigene: 'elternteil'));
    await starteApp(tester, env);
    await tippe(tester, find.byTooltip('Profil und Sicherheit'));
    // eine Pille in der Kopfkarte (nur Rolle) und der Status der Zeile "Familienrolle"
    expect(find.text('Elternteil'), findsNWidgets(2));
  });

  testWidgets('Profil: Familienrolle wählen sendet PUT /me/family-role und zeigt die neue Pille', (tester) async {
    final server = _server();
    final env = await angemeldeteUmgebung(server: server);
    await starteApp(tester, env);
    await tippe(tester, find.byTooltip('Profil und Sicherheit'));
    expect(find.text('Mutter'), findsNothing);
    server.on('PUT /me/family-role', (req) {
      final me = meJson(passkeys: 1, password: true, totp: true);
      me['user'] = _mitRolle(me['user'] as Map<String, dynamic>, req.json['familyRole'] as String?);
      server.json('GET /me', me);
      return jsonAntwort({'ok': true});
    });
    await tippe(tester, find.text('Familienrolle'));
    expect(find.text('Nur eine Anzeige, ändert keine Rechte.'), findsOneWidget);
    expect(kleineZiele(tester), isEmpty);
    await tippe(tester, find.text('Mutter'));
    final puts = server.anfragen('PUT /me/family-role');
    expect(puts, hasLength(1));
    expect(puts.single.json, {'familyRole': 'mutter'});
    expect(find.text('Mutter'), findsNWidgets(2)); // Pille in der Kopfkarte und Status der Zeile
    expect(find.text('Admin'), findsOneWidget); // Rolle bleibt
  });

  testWidgets('Profil: "Keine Angabe" löscht die Familienrolle (null)', (tester) async {
    final server = _server(eigene: 'vater');
    final env = await angemeldeteUmgebung(server: server);
    await starteApp(tester, env);
    await tippe(tester, find.byTooltip('Profil und Sicherheit'));
    await tippe(tester, find.text('Familienrolle'));
    await tippe(tester, find.text('Keine Angabe'));
    expect(server.anfragen('PUT /me/family-role').single.json, {'familyRole': null});
  });

  testWidgets('Admin setzt die Familienrolle eines anderen Mitglieds (Menü "Familienrolle ändern")', (tester) async {
    final server = _server();
    final env = await angemeldeteUmgebung(server: server);
    await starteApp(tester, env);
    await tippe(tester, find.byTooltip('Profil und Sicherheit'));
    await tippe(tester, find.text('Mitglieder und Einladungen'));
    await tippe(tester, find.byTooltip('Aktionen für Ben'));
    await tippe(tester, find.text('Familienrolle ändern'));
    expect(find.text('Familienrolle für Ben'), findsOneWidget);
    await tippe(tester, find.text('Großeltern'));
    final puts = server.anfragen('PUT /members/$fixIdKind/family-role');
    expect(puts, hasLength(1));
    expect(puts.single.json, {'familyRole': 'grosseltern'});
    pruefeLayout(tester, 'Admin nach Familienrolle');
  });

  testWidgets('Desktop-Seitenleiste: Profilkachel zeigt Rolle und Familienrolle', (tester) async {
    final env = await angemeldeteUmgebung(server: _server(eigene: 'elternteil'));
    await starteApp(tester, env, groesse: const Size(1280, 800));
    expect(find.text('Admin'), findsOneWidget);
    expect(find.text('Elternteil'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
