// Benchmark der Argon2id-Ableitung (Profil kdf1 und Vergleichsprofile) auf dem Gerät, im Emulator oder im Browser. Keine Produktionsdatei.
//
// Aufruf (in app/, Windows lokal mit gesetztem NIX_SKIP_SODIUM_BUILD_HOOKS=1, der Android-Build nimmt den NDK-Hook trotzdem):
//   Android (Gerät/Emulator, Release):  flutter run --release -d <geraet> -t tool/kdf_benchmark.dart
//                                       Ausgabe: adb logcat -s flutter | grep KDF-BENCH   (oder auf dem Bildschirm)
//   Web:   flutter build web --release --no-web-resources-cdn -t tool/kdf_benchmark.dart ; build/web ausliefern, in Chrome öffnen,
//          Ergebnis auf der Seite und in der Konsole (Zeilen "KDF-BENCH ...")
// Gemessen wird nur crypto.pwhash (Argon2id, 32 Byte Ausgabe) über den SodiumCryptoProvider, wie später im Ablauf. Je Profil ein Aufwärmlauf
// (nicht gezählt), dann [kLaeufe] gemessene Läufe mit wechselndem Salt; ausgegeben werden Minimum, Median und Maximum in Millisekunden.
// Zusätzlich: Takt eines Zeitgebers (alle 10 ms) während der Rechnung zeigt, ob die Oberfläche blockiert (Android: Isolate -> Takt läuft,
// Web: Hauptthread -> Takt steht).
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:lx_fampad/data/crypto/nfkc.dart';
import 'package:lx_fampad/data/crypto/pw_sicherung.dart';
import 'package:lx_fampad/data/crypto/sodium_crypto_provider.dart';

const int kLaeufe = 3;

/// (Name, Speicher in KiB, Durchläufe)
const List<(String, int, int)> kProfile = [
  ('kdf1 (Profil)', kKdf1MemKiB, kKdf1Ops),
  ('32 MiB / ops 3', 32768, 3),
  ('64 MiB / ops 2', 65536, 2),
  ('64 MiB / ops 4', 65536, 4),
  ('128 MiB / ops 3', 131072, 3),
];

void _log(String z, List<String> zeilen, void Function() aktualisieren) {
  debugPrint('KDF-BENCH $z');
  zeilen.add(z);
  aktualisieren();
}

Future<void> _messen(List<String> zeilen, void Function() aktualisieren) async {
  final crypto = await SodiumCryptoProvider.laden();
  _log('Plattform: ${kIsWeb ? 'Web' : defaultTargetPlatform.name}${kReleaseMode ? ' (release)' : kProfileMode ? ' (profile)' : ' (debug)'}', zeilen, aktualisieren);
  final pw = passwortBytes('correct horse battery staple');
  // Known-Answer: dieselbe Eingabe wie in test/crypto/pw_sicherung_test.dart muss auf jeder Plattform denselben Master ergeben
  final kat = await crypto.pwhash(passwort: pw, salt: Uint8List.fromList(List.generate(16, (i) => i)), memKiB: kKdf1MemKiB, ops: kKdf1Ops);
  final katHex = kat.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  _log('Known-Answer kdf1: ${katHex == '0d1a3c6523c8f06e4e0af9c515aa5b5448cfebd6838f2d52c3d8b6ef8ddc3c2e' ? 'OK' : 'ABWEICHUNG $katHex'}', zeilen, aktualisieren);

  for (final (name, mem, ops) in kProfile) {
    try {
      Uint8List salt(int i) => Uint8List.fromList(List.generate(16, (j) => (i * 31 + j) & 255));
      await crypto.pwhash(passwort: pw, salt: salt(99), memKiB: mem, ops: ops); // Aufwärmen
      final zeiten = <int>[];
      var takte = 0;
      final sw = Stopwatch();
      final takt = Timer.periodic(const Duration(milliseconds: 10), (_) => takte++);
      for (var i = 0; i < kLaeufe; i++) {
        sw
          ..reset()
          ..start();
        await crypto.pwhash(passwort: pw, salt: salt(i), memKiB: mem, ops: ops);
        zeiten.add(sw.elapsedMilliseconds);
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      takt.cancel();
      zeiten.sort();
      final summe = zeiten.reduce((a, b) => a + b);
      // erwartete Takte bei freier Oberfläche: Summe/10 ms; ein deutlich kleinerer Wert heißt: Hauptthread war blockiert
      _log('$name: min ${zeiten.first} ms, Median ${zeiten[zeiten.length ~/ 2]} ms, max ${zeiten.last} ms; Zeitgeber-Takte $takte von ca. ${summe ~/ 10} möglich', zeilen, aktualisieren);
    } on Object catch (e) {
      _log('$name: FEHLER $e', zeilen, aktualisieren);
    }
  }
  _log('FERTIG', zeilen, aktualisieren);
}

void main() {
  runApp(const _App());
}

class _App extends StatefulWidget {
  const _App();
  @override
  State<_App> createState() => _AppState();
}

class _AppState extends State<_App> {
  final List<String> _zeilen = ['Messung läuft ...'];

  @override
  void initState() {
    super.initState();
    // erst einen Frame zeichnen, damit der Text sichtbar ist, bevor die Rechnung im Web den Hauptthread belegt
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_messen(_zeilen, () => setState(() {}))));
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: SafeArea(
        child: Padding(padding: const EdgeInsets.all(12), child: SingleChildScrollView(child: Text(_zeilen.join('\n'), key: const Key('ergebnis')))),
      ),
    ),
  );
}
