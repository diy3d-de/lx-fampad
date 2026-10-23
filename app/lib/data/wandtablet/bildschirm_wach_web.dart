// Web: Screen Wake Lock API (navigator.wakeLock). Der Browser gibt die Sperre frei, wenn der Tab unsichtbar wird; beim Zurückkehren wird sie
// neu angefordert. Fehlt die API oder lehnt der Browser ab, bleibt alles wie es ist (kein Fehler).
import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import '../system_channel.dart';
import 'bildschirm_wach.dart';

BildschirmWach erzeugeBildschirmWach(SystemChannel kanal) => WebBildschirmWach();

class WebBildschirmWach implements BildschirmWach {
  web.WakeLockSentinel? _sperre;
  bool _gewuenscht = false;
  JSFunction? _sichtbar;

  Future<void> _anfordern() async {
    if (!_gewuenscht || _sperre != null) return;
    try {
      _sperre = await web.window.navigator.wakeLock.request('screen').toDart;
      _sperre?.addEventListener('release', ((web.Event _) => _sperre = null).toJS);
    } catch (_) {
      _sperre = null; // API fehlt oder abgelehnt: ohne Sperre weiter
    }
  }

  @override
  Future<void> halten() async {
    _gewuenscht = true;
    _sichtbar ??= ((web.Event _) {
      if (web.document.visibilityState == 'visible') unawaited(_anfordern());
    }).toJS;
    try {
      web.document.addEventListener('visibilitychange', _sichtbar);
    } catch (_) {}
    await _anfordern();
  }

  @override
  Future<void> freigeben() async {
    _gewuenscht = false;
    try {
      if (_sichtbar != null) web.document.removeEventListener('visibilitychange', _sichtbar);
      final s = _sperre;
      _sperre = null;
      await s?.release().toDart;
    } catch (_) {}
  }
}
