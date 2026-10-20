// Android: Benachrichtigung über eine Standortfreigabe mit flutter_local_notifications (eigener Kanal "Standortfreigaben", Wichtigkeit hoch). Wird nur über den bedingten Import
// in standort_anzeige_port_io.dart eingebunden, nie im Web. Fehler werden abgefangen und als "nicht gelungen" gemeldet: die Benachrichtigung ist Zusatz.
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../erinnerungen/erinnerung_port_android.dart' show erinnerungPluginInitialisiert;
import 'standort_hinweis.dart';

const _kKanalId = 'standort_freigaben';
const _kKanalName = 'Standortfreigaben';
const _kKanalBeschreibung = 'Hinweis, wenn jemand aus der Familie seinen Standort mit dir teilt. Er enthält nie einen Standort, nur den Namen.';
const _kSymbol = 'ic_stat_notify';

class AndroidStandortAnzeige implements StandortAnzeigePort {
  final _plugin = FlutterLocalNotificationsPlugin();
  var _bereit = false;

  bool get _verfuegbar => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  AndroidFlutterLocalNotificationsPlugin? get _android => _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();

  Future<bool> _pluginVorbereiten() async {
    if (!_verfuegbar) return false;
    try {
      // Hat schon die Terminerinnerung das Plugin eingerichtet (und ihren Rückruf beim Tippen gesetzt), wird nicht noch einmal initialisiert
      if (!erinnerungPluginInitialisiert) {
        final ok = await _plugin.initialize(settings: const InitializationSettings(android: AndroidInitializationSettings(_kSymbol)));
        if (ok != true) return false;
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> initialisieren() async {
    if (!_verfuegbar) return false;
    if (_bereit) return true;
    try {
      if (!await _pluginVorbereiten()) return false;
      await _android?.createNotificationChannel(const AndroidNotificationChannel(_kKanalId, _kKanalName, description: _kKanalBeschreibung, importance: Importance.high));
      // ohne Erlaubnis (Android 13+, nicht gefragt oder abgelehnt) gibt es keine Anzeige; gefragt wird nur in Profil, Erinnerungen und Benachrichtigungen
      if (await _android?.areNotificationsEnabled() != true) return false;
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
  Future<bool> zeigen({required int id, required String titel, required String text, required bool sperrbildschirmTitel, Duration? verfall}) async {
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
            category: AndroidNotificationCategory.status,
            autoCancel: true,
            // geht von selbst weg, wenn die Freigabe endet
            timeoutAfter: verfall != null && verfall > Duration.zero ? verfall.inMilliseconds : null,
            // Standard: privat. Auf dem Sperrbildschirm steht dann nur ein neutraler Hinweis, Titel und Name bleiben bis zum Entsperren verborgen.
            visibility: sperrbildschirmTitel ? NotificationVisibility.public : NotificationVisibility.private,
          ),
        ),
        payload: kStandortPayload,
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> entfernen(int id) async {
    if (!await _pluginVorbereiten()) return;
    try {
      await _plugin.cancel(id: id);
    } catch (_) {}
  }

  @override
  Future<void> alleEntfernen() async {
    if (!await _pluginVorbereiten()) return;
    try {
      final aktive = await _android?.getActiveNotifications() ?? const <ActiveNotification>[];
      for (final n in aktive) {
        final id = n.id;
        if (id != null && id >= kStandortIdBasis && id < kStandortIdBasis + kStandortIdBereich) await _plugin.cancel(id: id);
      }
    } catch (_) {}
  }
}
