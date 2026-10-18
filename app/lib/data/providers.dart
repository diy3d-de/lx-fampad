import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

final httpClientProvider = Provider<http.Client>((ref) {
  final client = http.Client();
  ref.onDispose(client.close);
  return client;
});

/// Platzhalter-Anmeldung (Phase 0): nur ein Schalter, keine echte Prüfung.
/// Phase 1 ersetzt das durch Passkey/Passwort+2FA und Sitzungsverwaltung.
class AuthController extends Notifier<bool> {
  @override
  bool build() => false;

  void signInPreview() => state = true;
  void signOut() => state = false;
}

final authProvider = NotifierProvider<AuthController, bool>(AuthController.new);
