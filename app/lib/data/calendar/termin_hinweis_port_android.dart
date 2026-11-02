// Android: lokale Benachrichtigung über neue und geänderte Termine (eigener Kanal "Terminänderungen", flutter_local_notifications). Wird nur über den
// bedingten Import in termin_hinweis_dienst.dart eingebunden, nie im Web. Fehler werden abgefangen: Benachrichtigungen sind Zusatz und stören den Abgleich nie.
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../erinnerungen/erinnerung_port_android.dart' show erinnerungPluginInitialisiert;
import 'termin_hinweis_dienst.dart';
import 'termin_hinweis_logik.dart';

const _kKanalId = 'termin_hinweise';
const _kKanalName = 'Terminänderungen';
const _kKanalBeschreibung =
    'Hinweise auf neue und geänderte Termine anderer Personen. Hast du in den Erinnerungen „Titel auf Sperrbildschirm zeigen“ eingeschaltet, steht der Titel in der Meldung und ist dann auch für Smartwatches und Apps sichtbar, die Benachrichtigungen mitlesen.';
const _kSymbol = 'ic_stat_notify';

class AndroidTerminHinweisAnzeige implements TerminHinweisAnzeige {
  final _plugin = FlutterLocalNotificationsPlugin();
  var _bereit = false;
  var _pluginBereit = false;

  /// Ein Tipp auf die Meldung (oder eine andere Meldung der App, falls dieses Plugin zuerst eingerichtet wurde) läuft hierüber.
  final void Function(String payload)? beiTipp;
  AndroidTerminHinweisAnzeige({this.beiTipp});

  /// Plugin einrichten (ohne Kanal und Erlaubnis; zum Zurücknehmen genügt das).
  Future<bool> _pluginVorbereiten() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return false;
    if (_pluginBereit) return true;
    try {
      // Hat schon die Terminerinnerung das Plugin eingerichtet (mit ihrem Rückruf beim Tippen), wird nicht noch einmal initialisiert; sonst bekommt
      // es hier denselben Rückruf, damit ein Tipp den Kalender öffnet
      if (!erinnerungPluginInitialisiert) {
        final ok = await _plugin.initialize(
          settings: const InitializationSettings(android: AndroidInitializationSettings(_kSymbol)),
          onDidReceiveNotificationResponse: (r) {
            final p = r.payload;
            if (p != null) beiTipp?.call(p);
          },
        );
        if (ok != true) return false;
      }
      _pluginBereit = true;
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> entfernen() async {
    if (!await _pluginVorbereiten()) return;
    try {
      await _plugin.cancel(id: kTerminHinweisId);
    } catch (_) {
      // Zusatz: ein Fehler hier darf nichts stören
    }
  }

  Future<bool> _vorbereiten() async {
    if (_bereit) return true;
    try {
      if (!await _pluginVorbereiten()) return false;
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
            // Ohne "Titel zeigen" steht in der Meldung ohnehin nur der neutrale Text (terminHinweisText); ein privater Eintrag würde ihn durch das
            // systemeigene "Inhalt ausgeblendet" ersetzen (das Plugin kennt keine publicVersion). Mit der Einstellung steht der Titel bewusst auch dort.
            visibility: NotificationVisibility.public,
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

TerminHinweisAnzeige terminHinweisAnzeigeErzeugen({void Function(String payload)? beiTipp}) => AndroidTerminHinweisAnzeige(beiTipp: beiTipp);
