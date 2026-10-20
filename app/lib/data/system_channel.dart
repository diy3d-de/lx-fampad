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

  /// Kopiert einen Geheimtext als "vertraulich" in die Zwischenablage (Android 13+: keine Vorschau). false = nicht möglich (Web, Tests).
  Future<bool> geheimKopieren(String text) async => (await _aufrufen<bool>('copySensitive', {'text': text})) == true;

  /// Benachrichtigungen dieser App: [enabled] = darf anzeigen (Berechtigung, Systemschalter, Kanal), [canAsk] = Android zeigt den
  /// Berechtigungsdialog noch. null = Kanal nicht verfügbar (Web, Tests).
  /// [kanal]: Wichtigkeit des Erinnerungs-Kanals (0 = aus, -1 = nicht angelegt).
  Future<({bool enabled, bool canAsk, int kanal})?> benachrichtigungsStatus() async {
    final r = await _aufrufen<Map<Object?, Object?>>('notificationStatus');
    if (r == null) return null;
    final k = r['channelImportance'];
    return (enabled: r['enabled'] == true, canAsk: r['canAsk'] == true, kanal: k is int ? k : -1);
  }

  /// Wichtigkeit des Kanals der Chat-Benachrichtigungen (0 = aus, -1 = nicht angelegt oder nicht lesbar).
  Future<int> chatKanalWichtigkeit() async => (await _aufrufen<int>('chatChannelImportance')) ?? -1;

  /// Öffnet "Alarme & Erinnerungen" der App (Rückfall App-Info). false = nicht möglich.
  Future<bool> alarmEinstellungenOeffnen() async => (await _aufrufen<bool>('openExactAlarmSettings')) == true;

  /// Merkt, dass der Berechtigungsdialog angefordert wurde (nötig, um "nie gefragt" von "dauerhaft verweigert" zu unterscheiden).
  Future<void> benachrichtigungAngefragt() => _aufrufen<void>('notificationAsked');

  /// Öffnet die Benachrichtigungseinstellungen der App (Rückfall: App-Info). false = nicht möglich.
  Future<bool> benachrichtigungsEinstellungenOeffnen() async => (await _aufrufen<bool>('openNotificationSettings')) == true;

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
