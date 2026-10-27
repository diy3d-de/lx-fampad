// Schnittstelle zur Benachrichtigungs-Funktion des Browsers (Notification API, nur die Anzeige: kein Web-Push, kein Service Worker, kein Fremddienst).
// Im Web gilt browser_benachrichtigung_web.dart (bedingter Import), sonst eine Variante ohne Wirkung; Tests nehmen [FakeBrowserBenachrichtigung].
import 'browser_benachrichtigung_stub.dart' if (dart.library.js_interop) 'browser_benachrichtigung_web.dart';

/// Zustand der Browser-Erlaubnis: [erlaubt] (granted), [offen] (default: noch nie gefragt), [blockiert] (denied), [fehlt] (der Browser kennt die Funktion nicht).
enum BrowserErlaubnis { erlaubt, offen, blockiert, fehlt }

abstract class BrowserBenachrichtigung {
  BrowserErlaubnis erlaubnis();

  /// Fragt die Erlaubnis an (öffnet den Browser-Dialog): NUR aus einem Klick der Person aufrufen, nie beim Start.
  Future<BrowserErlaubnis> anfragen();

  /// Zeigt eine Benachrichtigung ([titel], [text] sind schon neutral). [beiKlick] läuft, wenn die Person sie antippt. Nie eine Ausnahme nach außen.
  void zeigen({required String titel, required String text, required String tag, required void Function() beiKlick});
}

BrowserBenachrichtigung browserBenachrichtigungErzeugen() => browserBenachrichtigungPlattform();

/// Für Tests: Zustand und Anzeigen im Speicher.
class FakeBrowserBenachrichtigung implements BrowserBenachrichtigung {
  BrowserErlaubnis stand;
  BrowserErlaubnis nachAnfrage;
  int anfragenAnzahl = 0;
  final List<({String titel, String text, String tag, void Function() beiKlick})> gezeigt = [];
  FakeBrowserBenachrichtigung({this.stand = BrowserErlaubnis.offen, this.nachAnfrage = BrowserErlaubnis.erlaubt});

  @override
  BrowserErlaubnis erlaubnis() => stand;

  @override
  Future<BrowserErlaubnis> anfragen() async {
    anfragenAnzahl++;
    if (stand == BrowserErlaubnis.offen) stand = nachAnfrage;
    return stand;
  }

  @override
  void zeigen({required String titel, required String text, required String tag, required void Function() beiKlick}) {
    if (stand != BrowserErlaubnis.erlaubt) return; // wie der Browser: ohne Erlaubnis keine Anzeige
    gezeigt.add((titel: titel, text: text, tag: tag, beiKlick: beiKlick));
  }
}
