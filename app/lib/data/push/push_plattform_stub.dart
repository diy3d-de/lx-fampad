// Web und alle Plattformen ohne dart:io: kein Push. Diese Datei importiert bewusst weder unifiedpush noch dart:io.
import 'push_plattform.dart';

PushPlattform neuePushPlattform() => const _KeinPush();

class _KeinPush implements PushPlattform {
  const _KeinPush();

  @override
  bool get unterstuetzt => false;
  @override
  Future<void> initialisieren(PushRueckrufe rueckrufe) async {}
  @override
  Future<String?> aktuellerVerteiler() async => null;
  @override
  Future<bool> standardVerteilerNutzen() async => false;
  @override
  Future<List<String>> verteiler() async => const [];
  @override
  Future<void> verteilerSpeichern(String name) async {}
  @override
  Future<void> registrieren() async {}
  @override
  Future<void> abmelden() async {}
}
