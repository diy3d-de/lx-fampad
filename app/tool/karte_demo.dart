// Entwicklungswerkzeug (nicht Teil der App): zeigt nur die Standort-Karte mit zwei Beispielpersonen, ohne Anmeldung, gegen den echten Kartenserver.
// Zum Prüfen von Release-Problemen der Karte auf Emulator/Gerät:  flutter build apk --release -t tool/karte_demo.dart  (mit lokaler Debug-Signatur,
// die APK nie verteilen). Für Kacheln braucht das Gerät Netz; die Adresse lässt sich mit --dart-define=KARTE_BASE=... ändern.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lx_fampad/data/api/models.dart';
import 'package:lx_fampad/data/auth/auth_state.dart';
import 'package:lx_fampad/data/standort/standort_dienst.dart';
import 'package:lx_fampad/data/standort/standort_modelle.dart';
import 'package:lx_fampad/features/standort/standort_karte_ansicht.dart';
import 'package:lx_fampad/ui/theme.dart';

class _Auth extends AuthController {
  @override
  AuthState build() => AuthState(status: AuthStatus.angemeldet, user: _ich);
}

class _Standort extends StandortController {
  @override
  StandortState build() => const StandortState();
}

const _ich = UserDto(id: 'a', email: null, displayName: 'Tester Eins', colorIndex: 0, role: Role.parent, status: MemberStatus.active);
const _ben = UserDto(id: 'b', email: null, displayName: 'Ben', colorIndex: 2, role: Role.child, status: MemberStatus.active, avatar: AvatarDto.vorlage('V01', 1));

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final jetzt = DateTime.now();
  runApp(
    ProviderScope(
      overrides: [
        authProvider.overrideWith(_Auth.new),
        standortProvider.overrideWith(_Standort.new),
      ],
      child: MaterialApp(
        theme: buildTheme(),
        home: Scaffold(
          body: SafeArea(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                StandortKarte(
                  positionen: [
                    GeteiltePosition(userId: 'b', shareId: 's', endetAt: jetzt.add(const Duration(hours: 1)), breite: 50.5612, laenge: 7.9741, genauigkeit: 25, messzeit: jetzt.subtract(const Duration(seconds: 30))),
                    GeteiltePosition(userId: 'c', shareId: 's2', endetAt: jetzt.add(const Duration(hours: 1)), breite: 50.45, laenge: 8.05, genauigkeit: 60, messzeit: jetzt.subtract(const Duration(minutes: 2))),
                  ],
                  mitglieder: {'a': _ich, 'b': _ben, 'c': const UserDto(id: 'c', email: null, displayName: 'Cora Test', colorIndex: 4, role: Role.parent, status: MemberStatus.active)},
                ),
                const SizedBox(height: 600),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
