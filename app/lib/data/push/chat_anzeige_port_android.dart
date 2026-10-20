// Android: Chat-Benachrichtigungen über flutter_local_notifications (eigener Kanal "Chat-Nachrichten"). Wird nur über den bedingten Import in
// chat_anzeige_port_io.dart eingebunden, nie im Web. Fehler werden abgefangen und als "nicht gelungen" gemeldet: Benachrichtigungen sind Zusatz, ein Fehler hier darf
// den Abgleich nie stören.
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../erinnerungen/erinnerung_port_android.dart' show erinnerungPluginInitialisiert;
import 'chat_benachrichtiger.dart';

const _kKanalId = 'chat_nachrichten';
const _kKanalName = 'Chat-Nachrichten';
const _kKanalBeschreibung = 'Hinweise auf neue Nachrichten. Sie enthalten nie den Inhalt: nur dass es etwas Neues gibt und in welchem Chat.';
const _kSymbol = 'ic_stat_notify';

class AndroidChatAnzeige implements ChatAnzeigePort {
  final _plugin = FlutterLocalNotificationsPlugin();
  var _bereit = false;

  bool get _verfuegbar => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  Future<bool> initialisieren() async {
    if (!_verfuegbar) return false;
    if (_bereit) return true;
    try {
      // Hat schon die Terminerinnerung das Plugin eingerichtet (und ihren Rückruf beim Tippen gesetzt), wird nicht noch einmal initialisiert
      if (!erinnerungPluginInitialisiert) {
        final ok = await _plugin.initialize(settings: const InitializationSettings(android: AndroidInitializationSettings(_kSymbol)));
        if (ok != true) return false;
      }
      final android = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      await android?.createNotificationChannel(const AndroidNotificationChannel(_kKanalId, _kKanalName, description: _kKanalBeschreibung, importance: Importance.high));
      // ohne Erlaubnis (Android 13+, nicht gefragt oder abgelehnt) gibt es keine Anzeige; gefragt wird nur in Profil, Erinnerungen und Benachrichtigungen
      if (await android?.areNotificationsEnabled() != true) return false;
      _bereit = true;
      return true;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> zeigen({required int id, required String titel, required String text, required bool sperrbildschirmTitel}) async {
    if (!_bereit) return false;
    try {
      await _plugin.show(
        id: id,
        title: titel,
        body: text,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            _kKanalId,
            _kKanalName,
            channelDescription: _kKanalBeschreibung,
            icon: _kSymbol,
            importance: Importance.high,
            priority: Priority.high,
            category: AndroidNotificationCategory.message,
            // Standard: privat. Auf dem Sperrbildschirm steht dann nur ein neutraler Hinweis, Titel und Chat-Name bleiben bis zum Entsperren verborgen.
            visibility: sperrbildschirmTitel ? NotificationVisibility.public : NotificationVisibility.private,
          ),
        ),
        payload: 'chat',
      );
      return true;
    } catch (_) {
      return false;
    }
  }
}
