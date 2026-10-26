// SyncIndicator: Tippen gleicht ab; verschwindet das Widget währenddessen (Seitenwechsel, Abmelden), darf nach dem Abgleich nichts mehr
// mit dem entfernten Widget passieren (kein ref und kein ScaffoldMessenger nach dem Abbau).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/sync_state.dart';
import 'package:lx_fampad/widgets/sync_indicator.dart';

import 'support/fake_server.dart';
import 'support/harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(testVorbereiten);

  testWidgets('Widget während des Abgleichs entfernt: kein Fehler nach der Antwort', (tester) async {
    final env = await angemeldeteUmgebung();
    final c = ProviderContainer(overrides: env.overrides);
    addTearDown(c.dispose);
    final tor = Completer<void>();
    var zeigen = true;
    late StateSetter neuBauen;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                neuBauen = setState;
                return zeigen ? const SyncIndicator() : const SizedBox();
              },
            ),
          ),
        ),
      ),
    );
    final sync = c.read(syncProvider.notifier)..starten();
    await tester.pump(const Duration(milliseconds: 100));
    env.server.on('POST /sync', (req) async {
      await tor.future;
      return jsonAntwort(env.sync.verarbeiten(req.json));
    });
    await tester.tap(find.byType(IconButton));
    await tester.pump(const Duration(milliseconds: 100));
    neuBauen(() => zeigen = false); // Seitenwechsel, während der Abgleich noch läuft
    await tester.pump();
    tor.complete();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
    sync.stoppen();
    await tester.pump();
  });

  testWidgets('Widget bleibt stehen: nach dem Abgleich erscheint die Meldung "Abgeglichen"', (tester) async {
    final env = await angemeldeteUmgebung();
    final c = ProviderContainer(overrides: env.overrides);
    addTearDown(c.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(container: c, child: const MaterialApp(home: Scaffold(body: SyncIndicator()))));
    final sync = c.read(syncProvider.notifier)..starten();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byType(IconButton));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Alles aktuell'), findsOneWidget);
    sync.stoppen();
    await tester.pump();
  });
}
