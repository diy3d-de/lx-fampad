// Rückmeldung und Leerzustände: Lade-Platzhalter (ruhige Flächen mit Vorlesetext), Rückgängig-Hinweis (Handlung ruft die Funktion genau einmal auf).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/ui/theme.dart';
import 'package:lx_fampad/ui/widgets.dart';
import 'package:lx_fampad/widgets/rueckgaengig.dart';

void main() {
  testWidgets('LadePlatzhalter: Vorlesetext "Wird geladen", ohne Überlauf bei 360 px und Textskala 2.0', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: MediaQuery(
          data: const MediaQueryData(size: Size(360, 800), textScaler: TextScaler.linear(2)),
          child: const Scaffold(body: Padding(padding: EdgeInsets.all(16), child: LadePlatzhalter(karten: 2))),
        ),
      ),
    );
    expect(find.bySemanticsLabel('Wird geladen'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Rückgängig-Hinweis: Tipp ruft die Handlung einmal auf und schließt den Hinweis', (tester) async {
    var aufrufe = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => rueckgaengigZeigen(context, text: 'Eintrag gelöscht', rueckgaengig: () async => aufrufe++),
              child: const Text('los'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('los'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 800));
    expect(find.text('Eintrag gelöscht'), findsOneWidget);
    await tester.tap(find.text('Rückgängig'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Eintrag gelöscht'), findsNothing);
    expect(aufrufe, 1);
  });
}
