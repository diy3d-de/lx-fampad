// Web: Browser-Benachrichtigung über die Notification API (package:web, schon eine Abhängigkeit). Nur die Anzeige, solange die Web-App offen ist;
// kein Service Worker, kein Web-Push, keine Anfrage an einen Fremddienst.
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

import 'browser_benachrichtigung.dart';

BrowserBenachrichtigung browserBenachrichtigungPlattform() => _WebBenachrichtigung();

class _WebBenachrichtigung implements BrowserBenachrichtigung {
  bool get _gibt => globalContext.has('Notification');

  static BrowserErlaubnis _abbilden(String s) => switch (s) {
    'granted' => BrowserErlaubnis.erlaubt,
    'denied' => BrowserErlaubnis.blockiert,
    _ => BrowserErlaubnis.offen,
  };

  @override
  BrowserErlaubnis erlaubnis() {
    try {
      return _gibt ? _abbilden(web.Notification.permission) : BrowserErlaubnis.fehlt;
    } catch (_) {
      return BrowserErlaubnis.fehlt;
    }
  }

  @override
  Future<BrowserErlaubnis> anfragen() async {
    if (!_gibt) return BrowserErlaubnis.fehlt;
    try {
      return _abbilden((await web.Notification.requestPermission().toDart).toDart);
    } catch (_) {
      return erlaubnis();
    }
  }

  @override
  void zeigen({required String titel, required String text, required String tag, required void Function() beiKlick}) {
    try {
      if (erlaubnis() != BrowserErlaubnis.erlaubt) return;
      final n = web.Notification(titel, web.NotificationOptions(body: text, tag: tag));
      n.onclick = ((web.Event _) {
        try {
          web.window.focus();
        } catch (_) {}
        n.close();
        beiKlick();
      }).toJS;
    } catch (_) {
      // manche Browser (Android-Chrome) erlauben das Erzeugen nur über einen Service Worker: dann bleibt es beim Hinweis in der App
    }
  }
}
