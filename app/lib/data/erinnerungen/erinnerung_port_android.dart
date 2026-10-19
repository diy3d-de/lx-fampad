// Android: Terminerinnerungen über flutter_local_notifications (zonedSchedule). Wird nur über den bedingten Import in
// erinnerung_port_io.dart eingebunden, nie im Web. Fehler (fehlendes Plugin in Tests, abgelehnte Systemanfrage) werden abgefangen und als
// "nicht gelungen" gemeldet: Erinnerungen sind Zusatz, ein Fehler hier darf die App nie stören, der Dienst versucht es später erneut.
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;

import 'erinnerung_planung.dart';
import 'erinnerung_port.dart';

/// Hat dieser Prozess das Plugin schon eingerichtet (mit dem Rückruf beim Tippen auf eine Erinnerung)? Dann richtet es der Chat nicht noch einmal ein.
bool erinnerungPluginInitialisiert = false;

const _kKanalId = 'terminerinnerungen';
const _kKanalName = 'Terminerinnerungen';
const _kKanalBeschreibung = 'Erinnerungen an Termine aus dem Familienkalender. Sie werden auf diesem Gerät berechnet und nicht über einen Server verschickt.';

/// Einfarbiges Symbol der Statusleiste (android/app/src/main/res/drawable/ic_stat_notify.xml); das App-Symbol wäre ein farbiges Quadrat.
const _kSymbol = 'ic_stat_notify';

/// Fehlercode des Plugins, wenn genaue Alarme nicht erlaubt sind (z. B. Erlaubnis nachträglich entzogen).
const _kKeineGenauenAlarme = 'exact_alarms_not_permitted';

NotificationDetails _details({required bool sperrbildschirmTitel}) => NotificationDetails(
  android: AndroidNotificationDetails(
    _kKanalId,
    _kKanalName,
    channelDescription: _kKanalBeschreibung,
    icon: _kSymbol,
    importance: Importance.high,
    priority: Priority.high,
    category: AndroidNotificationCategory.reminder,
    // Standard: privat. Auf dem Sperrbildschirm erscheint dann nur ein neutraler Hinweis, Titel und Ort bleiben verborgen, bis das Gerät entsperrt ist.
    visibility: sperrbildschirmTitel ? NotificationVisibility.public : NotificationVisibility.private,
    styleInformation: const BigTextStyleInformation(''),
  ),
);

class AndroidErinnerungPort implements ErinnerungPort {
  final _plugin = FlutterLocalNotificationsPlugin();
  var _bereit = false;
  void Function(String payload)? _beiTipp;

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
  Future<bool> initialisieren({required void Function(String payload) beiTipp}) async {
    _beiTipp = beiTipp;
    if (!verfuegbar) return false;
    if (_bereit) return true;
    final ok = await _sicher<bool>(
      () async =>
          await _plugin.initialize(
            settings: const InitializationSettings(android: AndroidInitializationSettings(_kSymbol)),
            onDidReceiveNotificationResponse: (r) {
              final p = r.payload;
              if (p != null) _beiTipp?.call(p);
            },
          ) ??
          false,
    );
    if (ok != true) return false;
    erinnerungPluginInitialisiert = true;
    final kanal = await _sicher<bool>(() async {
      await _android?.createNotificationChannel(
        const AndroidNotificationChannel(_kKanalId, _kKanalName, description: _kKanalBeschreibung, importance: Importance.high),
      );
      return true;
    });
    _bereit = kanal == true;
    return _bereit;
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

  /// Setzt eine Benachrichtigung. Liefert (gesetzt, genauBlieb): ohne Erlaubnis für genaue Alarme (Fehlercode des Plugins) wird sofort
  /// ungenau gesetzt und genauBlieb ist false.
  Future<(bool, bool)> _setzen({
    required int id,
    required String titel,
    required String text,
    required DateTime zeit,
    required String? payload,
    required bool exakt,
    required bool sperrbildschirmTitel,
  }) async {
    Future<void> los(bool genau) => _plugin.zonedSchedule(
      id: id,
      title: titel,
      body: text,
      scheduledDate: tz.TZDateTime.from(zeit, tz.UTC),
      notificationDetails: _details(sperrbildschirmTitel: sperrbildschirmTitel),
      androidScheduleMode: genau ? AndroidScheduleMode.exactAllowWhileIdle : AndroidScheduleMode.inexactAllowWhileIdle,
      payload: payload,
    );
    try {
      await los(exakt);
      return (true, exakt);
    } on PlatformException catch (e) {
      if (exakt && e.code == _kKeineGenauenAlarme) {
        try {
          await los(false);
          return (true, false);
        } catch (_) {
          return (false, false);
        }
      }
      return (false, exakt);
    } catch (_) {
      return (false, exakt);
    }
  }

  @override
  Future<bool> planen(List<GeplanteErinnerung> liste, {required bool exakt, required bool sperrbildschirmTitel}) async {
    if (!_bereit) return false;
    final neu = {for (final e in liste) e.id};
    final offen = await _sicher<List<PendingNotificationRequest>>(() => _plugin.pendingNotificationRequests());
    if (offen == null) return false;
    var ok = true;
    for (final p in offen) {
      if (p.id == kTestBenachrichtigungId || neu.contains(p.id)) continue;
      if (!await _abbrechen(p.id)) ok = false;
    }
    // Wurde "genau" nicht erlaubt, gilt das für den Rest der Planung ebenso
    var genau = exakt;
    for (final e in liste) {
      final (gesetzt, genauBlieb) = await _setzen(
        id: e.id,
        titel: e.titel,
        text: e.text,
        zeit: e.zeit,
        payload: e.payload,
        exakt: genau,
        sperrbildschirmTitel: sperrbildschirmTitel,
      );
      genau = genauBlieb;
      if (!gesetzt) ok = false;
    }
    return ok;
  }

  Future<bool> _abbrechen(int id) async =>
      await _sicher<bool>(() async {
        await _plugin.cancel(id: id);
        return true;
      }) ==
      true;

  @override
  Future<bool> alleLoeschen() async {
    if (!_bereit) return false;
    final offen = await _sicher<List<PendingNotificationRequest>>(() => _plugin.pendingNotificationRequests());
    if (offen == null) return false;
    var ok = true;
    for (final p in offen) {
      if (p.id == kTestBenachrichtigungId) continue;
      if (!await _abbrechen(p.id)) ok = false;
    }
    return ok;
  }

  @override
  Future<bool> testPlanen(Duration wartezeit, {required bool exakt, required bool sperrbildschirmTitel}) async {
    if (!_bereit) return false;
    final (gesetzt, _) = await _setzen(
      id: kTestBenachrichtigungId,
      titel: 'Testbenachrichtigung',
      text: 'So erscheinen Terminerinnerungen auf diesem Gerät.',
      zeit: DateTime.now().toUtc().add(wartezeit),
      payload: null,
      exakt: exakt,
      sperrbildschirmTitel: sperrbildschirmTitel,
    );
    return gesetzt;
  }

  @override
  Future<void> systemEinstellungenOeffnen() async {
    if (!_bereit) return;
    await _sicher<bool>(() async => await _android?.openAppNotificationSettings());
  }
}
