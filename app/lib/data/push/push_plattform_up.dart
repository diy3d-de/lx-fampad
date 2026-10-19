// UnifiedPush (Paket unifiedpush, Android). Nur über push_plattform_fabrik.dart eingebunden (bedingter Import): im Web wird dieses Paket
// nie geladen. Nicht Android (Windows/Linux-Entwicklung, Tests): leere Umsetzung. Der eingebettete FCM-Verteiler (Google) ist NICHT
// eingebunden; ohne installierte ntfy-App (oder anderen Verteiler) gibt es keinen Push.
import 'dart:io' show Platform;

import 'package:unifiedpush/unifiedpush.dart';

import 'push_plattform.dart';
import 'push_plattform_stub.dart' as stub;

/// Eine Instanz genügt (die Registrierung der App beim Verteiler).
const _instanz = 'lx-fampad';

PushPlattform neuePushPlattform() => Platform.isAndroid ? _UnifiedPush() : stub.neuePushPlattform();

class _UnifiedPush implements PushPlattform {
  @override
  bool get unterstuetzt => true;

  @override
  Future<void> initialisieren(PushRueckrufe r) async {
    await UnifiedPush.initialize(
      onNewEndpoint: (PushEndpoint e, String instanz) {
        if (instanz == _instanz) r.beiEndpunkt(e.url);
      },
      onRegistrationFailed: (FailedReason grund, String instanz) {
        if (instanz == _instanz) r.beiFehler(grund.name);
      },
      onUnregistered: (String instanz) {
        if (instanz == _instanz) r.beiAbgemeldet();
      },
      // der Inhalt (message) wird nie gelesen: ein Wecker heißt nur "gleiche ab"
      onMessage: (PushMessage message, String instanz) {
        if (instanz == _instanz) r.beiWecker();
      },
    );
  }

  @override
  Future<String?> aktuellerVerteiler() => UnifiedPush.getDistributor();

  @override
  Future<bool> standardVerteilerNutzen() => UnifiedPush.tryUseCurrentOrDefaultDistributor();

  @override
  Future<List<String>> verteiler() => UnifiedPush.getDistributors();

  @override
  Future<void> verteilerSpeichern(String name) => UnifiedPush.saveDistributor(name);

  @override
  Future<void> registrieren() => UnifiedPush.register(instance: _instanz, messageForDistributor: 'lx-fampad');

  @override
  Future<void> abmelden() => UnifiedPush.unregister(_instanz);
}
