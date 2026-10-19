import 'package:web/web.dart' as web;

/// Öffnet den Download-Link in einem neuen Tab (nur auf Tipp aufrufen). Es geht nur die feste Download-Adresse
/// ohne Token hinaus.
bool downloadOeffnen(String url) {
  web.window.open(url, '_blank', 'noopener');
  return true;
}
