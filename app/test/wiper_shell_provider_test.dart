// Daten leeren (Abmelden mit Datenwipe): "Zuletzt benutzt", eingeklappte Gruppen und der Schalter "Jetzt wichtig" der Vorperson sind weg.
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/auth/auth_state.dart' show localDataWiperProvider;
import 'package:lx_fampad/data/calendar/feiertage.dart' show MemoryFeiertageSpeicher;
import 'package:lx_fampad/data/shell/zuletzt_logik.dart' show kGruppenZuSchluessel, kZuletztSchluessel;
import 'package:lx_fampad/data/shell/zuletzt_state.dart';
import 'package:lx_fampad/data/startseite/jetzt_wichtig_logik.dart' show kJetztWichtigSchluessel;
import 'package:lx_fampad/data/startseite/jetzt_wichtig_state.dart';

import 'support/fake_server.dart';
import 'support/harness.dart';
import 'support/test_app.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(testVorbereiten);

  test('Wiper setzt shellMerkerProvider und jetztWichtigAnProvider zurück (die nächste Person erbt nichts)', () async {
    final speicher = MemoryFeiertageSpeicher('nein', {kJetztWichtigSchluessel: 'nein'});
    final env = TestUmgebung(FakeServer())
      ..speicher = speicher
      ..wiperEcht = true;
    final c = env.container();
    addTearDown(c.dispose);
    c.listen(shellMerkerProvider, (_, _) {});
    c.listen(jetztWichtigAnProvider, (_, _) {});
    await c.read(shellMerkerProvider.notifier).merken('listen');
    await c.read(shellMerkerProvider.notifier).gruppeUmschalten('familie');
    await pumpEventQueue();
    expect(c.read(shellMerkerProvider).zuletzt, ['listen']);
    expect(c.read(shellMerkerProvider).gruppenZu, {'familie'});
    expect(c.read(jetztWichtigAnProvider), isFalse);
    speicher.werte.remove(kZuletztSchluessel);
    speicher.werte.remove(kGruppenZuSchluessel);
    speicher.werte.remove(kJetztWichtigSchluessel); // wie sync_meta nach dem Leeren der Datenbank
    await c.read(localDataWiperProvider)();
    await pumpEventQueue();
    expect(c.read(shellMerkerProvider).zuletzt, isEmpty);
    expect(c.read(shellMerkerProvider).gruppenZu, isEmpty);
    expect(c.read(jetztWichtigAnProvider), isTrue, reason: 'Standard: an');
  });
}
