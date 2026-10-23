// "Neu in x.y.z": Logik (Erststart, Update, gleiche Version, fehlender Eintrag) und Dialog (360 px, Textskala 1.5).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/calendar/feiertage.dart';
import 'package:lx_fampad/data/neuigkeiten/neuigkeiten.dart';
import 'package:lx_fampad/features/neuigkeiten/neuigkeiten_dialog.dart';

const _json = '{"0.9.2": ["Profil neu geordnet", "  ", 7], "0.9.3": []}';

ProviderContainer _umgebung(MemoryFeiertageSpeicher speicher, {String text = _json}) {
  final c = ProviderContainer(overrides: [
    feiertageSpeicherProvider.overrideWithValue(speicher),
    neuigkeitenQuelleProvider.overrideWithValue(() async => text),
  ]);
  addTearDown(c.dispose);
  return c;
}

void main() {
  test('neuigkeitFuer: nur Texte, leere Liste und kaputtes JSON ergeben null', () {
    expect(neuigkeitFuer(_json, '0.9.2')!.punkte, ['Profil neu geordnet']);
    expect(neuigkeitFuer(_json, '0.9.3'), isNull);
    expect(neuigkeitFuer(_json, '1.0.0'), isNull);
    expect(neuigkeitFuer('kaputt', '0.9.2'), isNull);
    expect(neuigkeitFuer('[]', '0.9.2'), isNull);
  });

  test('neuigkeitenFaellig', () {
    expect(neuigkeitenFaellig(installiert: '0.9.2', gemerkt: null), isFalse);
    expect(neuigkeitenFaellig(installiert: '0.9.2', gemerkt: '0.9.2'), isFalse);
    expect(neuigkeitenFaellig(installiert: '0.9.2', gemerkt: '0.9.1'), isTrue);
    expect(neuigkeitenFaellig(installiert: null, gemerkt: '0.9.1'), isFalse);
    expect(neuigkeitenFaellig(installiert: 'dev', gemerkt: '0.9.1'), isFalse);
  });

  test('Erststart: nichts zeigen, nur merken', () async {
    final s = MemoryFeiertageSpeicher();
    final d = _umgebung(s).read(neuigkeitenDienstProvider);
    expect(await d.pruefen('0.9.2'), isNull);
    expect(s.werte[kNeuigkeitenSchluessel], '0.9.2');
  });

  test('Update: zeigt einmal, gemerkt wird erst beim Schließen', () async {
    final s = MemoryFeiertageSpeicher(null, {kNeuigkeitenSchluessel: '0.9.1'});
    final d = _umgebung(s).read(neuigkeitenDienstProvider);
    final n = await d.pruefen('0.9.2');
    expect(n!.version, '0.9.2');
    expect(s.werte[kNeuigkeitenSchluessel], '0.9.1');
    await d.gesehen('0.9.2');
    expect(await d.pruefen('0.9.2'), isNull);
  });

  test('Update ohne Eintrag: nichts zeigen, Version wird gemerkt', () async {
    final s = MemoryFeiertageSpeicher(null, {kNeuigkeitenSchluessel: '0.9.1'});
    final d = _umgebung(s).read(neuigkeitenDienstProvider);
    expect(await d.pruefen('0.9.3'), isNull);
    expect(s.werte[kNeuigkeitenSchluessel], '0.9.3');
  });

  for (final skala in [1.0, 1.5, 2.0]) {
    testWidgets('Dialog bei 360 px, Textskala $skala: Stichpunkte, Schließen ruft onGesehen', (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      var gesehen = 0;
      final n = Neuigkeit('0.9.2', [for (var i = 0; i < 4; i++) 'Ein längerer Stichpunkt Nummer $i, der in der schmalen Breite umbrechen muss']);
      await tester.pumpWidget(
        MaterialApp(
          builder: (c, w) => MediaQuery(data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(skala)), child: w!),
          home: Builder(builder: (ctx) => Scaffold(body: TextButton(onPressed: () => neuigkeitenDialogZeigen(ctx, n, onGesehen: () => gesehen++), child: const Text('auf')))),
        ),
      );
      await tester.tap(find.text('auf'));
      await tester.pumpAndSettle();
      expect(find.text('Neu in 0.9.2'), findsOneWidget);
      expect(find.textContaining('Nummer 3'), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(tester.getSize(find.byType(TextButton).last).height, greaterThanOrEqualTo(44));
      await tester.tap(find.text('Verstanden'));
      await tester.pumpAndSettle();
      expect(gesehen, 1);
      expect(find.text('Neu in 0.9.2'), findsNothing);
    });
  }
}
