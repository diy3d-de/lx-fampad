// Erinnerungen in der Web-App: Negativtests. Die Browser-Benachrichtigung und der Hinweis in der App kennen nur Kennung, Zeit und Nutzlast der Planung (nie Titel oder
// Text), keinen Chat, Standort, Schlüssel, Tresor, Dateien-Namen, Push oder Betrieb und keinen Fremddienst (kein Service Worker, kein Web-Push).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _dateien = [
  'lib/data/erinnerungen/browser_benachrichtigung.dart',
  'lib/data/erinnerungen/browser_benachrichtigung_stub.dart',
  'lib/data/erinnerungen/browser_benachrichtigung_web.dart',
  'lib/data/erinnerungen/web_erinnerung_logik.dart',
  'lib/data/erinnerungen/web_erinnerung_port.dart',
  'lib/data/erinnerungen/web_erinnerung_state.dart',
  'lib/features/calendar/web_erinnerung_steuerung.dart',
  'lib/features/home/web_erinnerung_karte.dart',
  'lib/features/profile/web_erinnerungen_seite.dart',
];

String _code(String pfad) => File(pfad).readAsLinesSync().where((z) => !z.trimLeft().startsWith('//')).join('\n');

void main() {
  test('kein Import von Chat, Standort, Schlüsseln, Tresor, Dateien, Push, Betrieb, Suche, Teilen (erlaubt: nur die Nutzlast-Prüfer der Erinnerungen)', () {
    final kopplung = RegExp(
      r"import\s+'[^']*(chat|standort|crypto|e2ee|schluessel|tresor|dateien|files|ingest|push|betrieb|suche|teilen|heute_widget)[^']*'"
      r'|chatRepositoryProvider|ChatRepository|standortProvider|E2eeController|tresorDatenProvider|medDatenProvider|zaehlerDatenProvider|dateienVerfuegbarProvider',
    );
    for (final d in _dateien) {
      expect(File(d).existsSync(), isTrue, reason: d);
      expect(kopplung.hasMatch(_code(d)), isFalse, reason: d);
    }
  });

  test('die Web-Teile lesen nie Titel oder Text der Planung und nehmen sie nie in die Ablage', () {
    final titel = RegExp(r'\.titel\b|\.text\b|\.ort\b');
    for (final d in _dateien.where((d) => !d.contains('browser_benachrichtigung'))) {
      expect(titel.hasMatch(_code(d)), isFalse, reason: d);
    }
  });

  test('kein Service Worker, kein Web-Push, kein Fremddienst', () {
    final fremd = RegExp(r'serviceWorker|ServiceWorker|PushManager|pushManager|registration|https?://|HttpRequest|fetch\(|XMLHttp');
    for (final d in _dateien) {
      expect(fremd.hasMatch(_code(d)), isFalse, reason: d);
    }
  });

  test('die Benachrichtigung trägt immer den Namen der App und einen neutralen Text', () {
    final state = _code('lib/data/erinnerungen/web_erinnerung_state.dart');
    expect(RegExp(r'browser\.zeigen\(titel: kAppName, text: (text|\x27Erinnerung: )').allMatches(state), hasLength(2));
  });
}
