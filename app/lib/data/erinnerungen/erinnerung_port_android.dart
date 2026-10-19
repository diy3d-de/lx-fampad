// Android: Terminerinnerungen über flutter_local_notifications (zonedSchedule). Wird nur über den bedingten Import in
// erinnerung_port_io.dart eingebunden, nie im Web. Jeder Aufruf fängt Fehler ab (fehlendes Plugin in Tests, Systemdialog abgelehnt):
// Erinnerungen sind Zusatz, ein Fehler hier darf die App nie stören.
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;

import 'erinnerung_planung.dart';
import 'erinnerung_port.dart';

const _kKanalId = 'terminerinnerungen';
const _kKanalName = 'Terminerinnerungen';
const _kKanalBeschreibung = 'Erinnerungen an Termine aus dem Familienkalender. Sie werden auf diesem Gerät berechnet und nicht über einen Server verschickt.';

const _kDetails = NotificationDetails(
  android: AndroidNotificationDetails(
    _kKanalId,
    _kKanalName,
    channelDescription: _kKanalBeschreibung,
    importance: Importance.high,
    priority: Priority.high,
    category: AndroidNotificationCategory.reminder,
    // Mehrzeiliger Text (Zeit und Ort) wird auf dem Gerät ausgeklappt angezeigt
    styleInformation: BigTextStyleInformation(''),
  ),
);

class AndroidErinnerungPort implements ErinnerungPort {
  final _plugin = FlutterLocalNotificationsPlugin();
  var _bereit = false;

  AndroidFlutterLocalNotificationsPlugin? get _android => _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();

  @override
  bool get verfuegbar => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<T?> _sicher<T>(Future<T?> Function() f) async {
    try {
      return await f();
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> initialisieren({required void Function(String payload) beiTipp}) async {
    if (!verfuegbar || _bereit) return;
    final ok = await _sicher<bool>(
      () async =>
          await _plugin.initialize(
            settings: const InitializationSettings(android: AndroidInitializationSettings('@mipmap/ic_launcher')),
            onDidReceiveNotificationResponse: (r) {
              final p = r.payload;
              if (p != null) beiTipp(p);
            },
          ) ??
          false,
    );
    if (ok != true) return;
    await _sicher<void>(
      () async => _android?.createNotificationChannel(
        const AndroidNotificationChannel(_kKanalId, _kKanalName, description: _kKanalBeschreibung, importance: Importance.high),
      ),
    );
    _bereit = true;
  }

  @override
  Future<String?> startPayload() async {
    if (!_bereit) return null;
    final d = await _sicher<NotificationAppLaunchDetails>(() => _plugin.getNotificationAppLaunchDetails());
    if (d == null || !d.didNotificationLaunchApp) return null;
    return d.notificationResponse?.payload;
  }

  @override
  Future<bool> benachrichtigungenErlaubt() async => _bereit && await _sicher<bool>(() async => await _android?.areNotificationsEnabled()) == true;

  @override
  Future<bool> benachrichtigungenAnfragen() async {
    if (!_bereit) return false;
    await _sicher<bool>(() async => await _android?.requestNotificationsPermission());
    return benachrichtigungenErlaubt();
  }

  @override
  Future<bool> exakteAlarmeMoeglich() async => _bereit && await _sicher<bool>(() async => await _android?.canScheduleExactNotifications()) == true;

  AndroidScheduleMode _modus(bool exakt) => exakt ? AndroidScheduleMode.exactAllowWhileIdle : AndroidScheduleMode.inexactAllowWhileIdle;

  @override
  Future<void> planen(List<GeplanteErinnerung> liste, {required bool exakt}) async {
    if (!_bereit) return;
    final neu = {for (final e in liste) e.id};
    final offen = await _sicher<List<PendingNotificationRequest>>(() => _plugin.pendingNotificationRequests()) ?? const [];
    for (final p in offen) {
      if (p.id == kTestBenachrichtigungId || neu.contains(p.id)) continue;
      await _sicher<void>(() => _plugin.cancel(id: p.id));
    }
    for (final e in liste) {
      await _sicher<void>(
        () => _plugin.zonedSchedule(
          id: e.id,
          title: e.titel,
          body: e.text,
          scheduledDate: tz.TZDateTime.from(e.zeit, tz.UTC),
          notificationDetails: _kDetails,
          androidScheduleMode: _modus(exakt),
          payload: e.payload,
        ),
      );
    }
  }

  @override
  Future<void> alleLoeschen() async {
    if (!_bereit) return;
    final offen = await _sicher<List<PendingNotificationRequest>>(() => _plugin.pendingNotificationRequests()) ?? const [];
    for (final p in offen) {
      if (p.id == kTestBenachrichtigungId) continue;
      await _sicher<void>(() => _plugin.cancel(id: p.id));
    }
  }

  @override
  Future<void> testPlanen(Duration wartezeit, {required bool exakt}) async {
    if (!_bereit) return;
    await _sicher<void>(
      () => _plugin.zonedSchedule(
        id: kTestBenachrichtigungId,
        title: 'Testbenachrichtigung',
        body: 'So erscheinen Terminerinnerungen auf diesem Gerät.',
        scheduledDate: tz.TZDateTime.now(tz.UTC).add(wartezeit),
        notificationDetails: _kDetails,
        androidScheduleMode: _modus(exakt),
      ),
    );
  }

  @override
  Future<void> systemEinstellungenOeffnen() async {
    if (!_bereit) return;
    await _sicher<bool>(() async => await _android?.openAppNotificationSettings());
  }
}
