// Methodenkanal zu MainActivity.kt für Android-Besonderheiten: Gerätename und App-Version (für die Geräteliste),
// Bildschirmfoto-Schutz (FLAG_SECURE) und Einladungs-Links, mit denen die App geöffnet wird.
// Im Web und in Tests gibt es den Kanal nicht; jeder Aufruf ist dann ein stiller No-op.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../constants.dart';

class SystemChannel {
  static const _channel = MethodChannel(kSystemChannel);
  int _geschuetzt = 0;
  final _links = StreamController<String>.broadcast();
  bool _verbunden = false;

  bool get verfuegbar => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Hört auf Links, die die laufende App erreichen (Android: Intent mit https://familie.lx-labs.dev/#/einladung/…).
  Stream<String> get links {
    if (verfuegbar && !_verbunden) {
      _verbunden = true;
      _channel.setMethodCallHandler((call) async {
        if (call.method == 'link' && call.arguments is String) _links.add(call.arguments as String);
        return null;
      });
    }
    return _links.stream;
  }

  Future<T?> _aufrufen<T>(String methode, [Object? argumente]) async {
    if (!verfuegbar) return null;
    try {
      return await _channel.invokeMethod<T>(methode, argumente);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  Future<String?> geraetename() => _aufrufen<String>('deviceName');
  Future<String?> appVersion() => _aufrufen<String>('appVersion');

  /// Link, mit dem die App gestartet wurde (einmalig; danach null).
  Future<String?> startLink() => _aufrufen<String>('initialLink');

  /// Schaltet den Bildschirmfoto-Schutz (FLAG_SECURE) ein; zählt verschachtelte Aufrufe mit.
  Future<void> schuetzen() async {
    _geschuetzt++;
    if (_geschuetzt == 1) await _aufrufen<void>('setSecure', {'secure': true});
  }

  Future<void> freigeben() async {
    if (_geschuetzt == 0) return;
    _geschuetzt--;
    if (_geschuetzt == 0) await _aufrufen<void>('setSecure', {'secure': false});
  }
}
