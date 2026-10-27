// Ohne Browser (Android, Tests): keine Benachrichtigungen dieser Art.
import 'browser_benachrichtigung.dart';

BrowserBenachrichtigung browserBenachrichtigungPlattform() => const _Keine();

class _Keine implements BrowserBenachrichtigung {
  const _Keine();
  @override
  BrowserErlaubnis erlaubnis() => BrowserErlaubnis.fehlt;
  @override
  Future<BrowserErlaubnis> anfragen() async => BrowserErlaubnis.fehlt;
  @override
  void zeigen({required String titel, required String text, required String tag, required void Function() beiKlick}) {}
}
