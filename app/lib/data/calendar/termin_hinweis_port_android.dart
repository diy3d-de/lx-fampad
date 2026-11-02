// Android: lokale Benachrichtigung über neue und geänderte Termine (eigener Kanal "Terminänderungen", flutter_local_notifications). Wird nur über den
// bedingten Import in termin_hinweis_dienst.dart eingebunden, nie im Web. Fehler werden abgefangen: Benachrichtigungen sind Zusatz und stören den Abgleich nie.
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../erinnerungen/erinnerung_port_android.dart' show erinnerungPluginInitialisiert;
import 'termin_hinweis_dienst.dart';
import 'termin_hinweis_logik.dart';

const _kKanalId = 'termin_hinweise';
const _kKanalName = 'Terminänderungen';
const _kKanalBeschreibung = 'Hinweise auf neue und geänderte Termine anderer Personen. Der Titel steht nur da, wenn du ihn auf dem Sperrbildschirm zeigen lässt.';
const _kSymbol = 'ic_stat_notify';

class AndroidTerminHinweisAnzeige implements TerminHinweisAnzeige {
  final _plugin = FlutterLocalNotificationsPlugin();
  var _bereit = false;

  Future<bool> _vorbereiten() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return false;
    if (_bereit) return true;
    try {
      // Hat schon die Terminerinnerung das Plugin eingerichtet (mit ihrem Rückruf beim Tippen), wird nicht noch einmal initialisiert
      if (!erinnerungPluginInitialisiert) {
        final ok = await _plugin.initialize(settings: const InitializationSettings(android: AndroidInitializationSettings(_kSymbol)));
        if (ok != true) return false;
      }
      final android = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      await android?.createNotificationChannel(const AndroidNotificationChannel(_kKanalId, _kKanalName, description: _kKanalBeschreibung, importance: Importance.defaultImportance));
      // ohne Erlaubnis (Android 13+) gibt es keine Anzeige; gefragt wird nur in Profil > Benachrichtigungen
      if (await android?.areNotificationsEnabled() != true) return false;
      _bereit = true;
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> zeigen(List<TerminTreffer> treffer, {required bool mitTitel, required bool sperrbildschirmTitel}) async {
    if (!await _vorbereiten()) return false;
    try {
      final t = terminHinweisText(treffer, mitTitel: mitTitel);
      await _plugin.show(
        id: kTerminHinweisId,
        title: t.titel,
        body: t.text,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            _kKanalId,
            _kKanalName,
            channelDescription: _kKanalBeschreibung,
            icon: _kSymbol,
            importance: Importance.defaultImportance,
            priority: Priority.defaultPriority,
            category: AndroidNotificationCategory.event,
            visibility: sperrbildschirmTitel ? NotificationVisibility.public : NotificationVisibility.private,
          ),
        ),
        payload: kTerminHinweisPayload,
      );
      return true;
    } catch (_) {
      return false;
    }
  }
}

TerminHinweisAnzeige terminHinweisAnzeigeErzeugen() => AndroidTerminHinweisAnzeige();
