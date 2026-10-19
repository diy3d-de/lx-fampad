// Android: Terminerinnerungen über flutter_local_notifications (zonedSchedule). Wird nur über den bedingten Import in
// erinnerung_port_io.dart eingebunden, nie im Web. Fehler (fehlendes Plugin in Tests, abgelehnte Systemanfrage) werden abgefangen und als
// "nicht gelungen" gemeldet: Erinnerungen sind Zusatz, ein Fehler hier darf die App nie stören, der Dienst versucht es später erneut.
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;

import '../system_channel.dart';
import 'erinnerung_planung.dart';
import 'erinnerung_port.dart';

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
  final SystemChannel _system;
  var _bereit = false;

  AndroidErinnerungPort({SystemChannel? system}) : _system = system ?? SystemChannel();
  void Function(String payload)? _beiTipp;

  AndroidFlutterLocalNotificationsPlugin? get _android => _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();

  @override
  bool get verfuegbar => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Art des letzten gescheiterten Aufrufs (nur Typ bzw. Fehlercode, nie Inhalte) für die Diagnose-Zeile.
  String? letzterFehler;

  Future<T?> _sicher<T>(Future<T?> Function() f) async {
    try {
      return await f();
    } on MissingPluginException {
      letzterFehler = 'MissingPlugin';
      return null;
    } on PlatformException catch (e) {
      letzterFehler = 'Platform:${e.code}';
      return null;
    } catch (e) {
      letzterFehler = e.runtimeType.toString();
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

  /// Stellt das Plugin bereit, falls der erste Versuch scheiterte (Berechtigung und Einstellungen dürfen nicht an einem früheren Fehler hängen).
  Future<bool> _sicherBereit() async => _bereit || await initialisieren(beiTipp: _beiTipp ?? (_) {});

  @override
  Future<BenachrichtigungsStatus> benachrichtigungsStatus() async {
    // Eigener Kanal zuerst: er liest Berechtigung, Systemschalter und Kanal direkt und kennt "dauerhaft verweigert"
    final s = await _sicher<({bool enabled, bool canAsk, int kanal})>(() => _system.benachrichtigungsStatus());
    if (s != null) {
      if (s.enabled) return BenachrichtigungsStatus.erlaubt;
      return s.canAsk ? BenachrichtigungsStatus.fragbar : BenachrichtigungsStatus.gesperrt;
    }
    letzterFehler = 'systemkanal';
    // Rückfall: Plugin (kennt den Dialog-Zustand nicht, Anfragen ist dann der einzige Weg)
    await _sicherBereit();
    final an = await _sicher<bool>(() async => await _android?.areNotificationsEnabled());
    // null = der Aufruf selbst ist gescheitert (Plugin fehlt/nicht bereit): "unbekannt", nie als "nicht erlaubt" verbucht
    if (an == null) return BenachrichtigungsStatus.unbekannt;
    return an ? BenachrichtigungsStatus.erlaubt : BenachrichtigungsStatus.fragbar;
  }

  @override
  Future<bool> benachrichtigungenErlaubt() async => await benachrichtigungsStatus() == BenachrichtigungsStatus.erlaubt;

  @override
  Future<bool> benachrichtigungenAnfragen() async {
    if (await benachrichtigungsStatus() == BenachrichtigungsStatus.erlaubt) return true;
    await _sicherBereit();
    await _sicher<bool>(() async {
      await _system.benachrichtigungAngefragt();
      return true;
    });
    await _sicher<bool>(() async => await _android?.requestNotificationsPermission());
    return benachrichtigungenErlaubt();
  }

  @override
  Future<bool> exakteAlarmeMoeglich() async =>
      await _sicherBereit() && await _sicher<bool>(() async => await _android?.canScheduleExactNotifications()) == true;

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
  Future<bool> alarmEinstellungenOeffnen() async {
    if (await _sicher<bool>(() => _system.alarmEinstellungenOeffnen()) == true) return true;
    return systemEinstellungenOeffnen();
  }

  @override
  Future<ErinnerungDiagnose> diagnose() async {
    final bereit = await _sicherBereit();
    final s = await _sicher<({bool enabled, bool canAsk, int kanal})>(() => _system.benachrichtigungsStatus());
    final erlaubt = s?.enabled ?? await benachrichtigungenErlaubt();
    final offen = bereit ? await _sicher<List<PendingNotificationRequest>>(() => _plugin.pendingNotificationRequests()) : null;
    return ErinnerungDiagnose(
      bereit: bereit,
      erlaubt: erlaubt,
      kanal: s?.kanal ?? -1,
      exakt: await exakteAlarmeMoeglich(),
      geplant: offen?.where((p) => p.id != kTestBenachrichtigungId).length ?? -1,
      fehler: letzterFehler,
    );
  }

  @override
  Future<bool> systemEinstellungenOeffnen() async {
    // Eigener Aufruf ohne resolveActivity (das Plugin liefert ab Android 11 wegen der Paketsichtbarkeit sonst still false), Rückfall Plugin
    if (await _sicher<bool>(() => _system.benachrichtigungsEinstellungenOeffnen()) == true) return true;
    await _sicherBereit();
    return await _sicher<bool>(() async => await _android?.openAppNotificationSettings()) == true;
  }
}
