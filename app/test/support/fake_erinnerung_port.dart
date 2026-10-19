// Fake für die Plugin-Schnittstelle der Terminerinnerungen: zeichnet alle Aufrufe auf, keine Plattform nötig. Fehler lassen sich einstellen
// (Plugin nicht bereit, Planen scheitert oder wirft), und `planenBremse` hält einen Planungslauf an (Rennen mit dem Löschen).
import 'dart:async';

import 'package:lx_fampad/data/erinnerungen/erinnerung_planung.dart';
import 'package:lx_fampad/data/erinnerungen/erinnerung_port.dart';

class FakeErinnerungPort implements ErinnerungPort {
  @override
  bool verfuegbar = true;
  bool erlaubt = true;
  bool exakt = true;
  bool anfrageErteilt = true;
  bool initOk = true;
  bool planenOk = true;
  bool planenWirft = false;
  bool loeschenOk = true;
  bool testOk = true;
  String? start;
  int initialisiert = 0;
  int geloescht = 0;
  int anfragen = 0;
  int systemEinstellungen = 0;
  final planungen = <List<GeplanteErinnerung>>[];
  final exaktFlags = <bool>[];
  final sperrFlags = <bool>[];
  final tests = <Duration>[];
  final ereignisse = <String>[];

  /// Wenn gesetzt, wartet `planen` darauf (Test hält den Lauf mitten im Setzen an).
  Completer<void>? planenBremse;
  void Function(String payload)? beiTipp;

  List<GeplanteErinnerung>? get letzte => planungen.isEmpty ? null : planungen.last;

  /// Simuliert das Tippen auf eine Benachrichtigung bei laufender App.
  void tippe(String payload) => beiTipp?.call(payload);

  @override
  Future<bool> initialisieren({required void Function(String payload) beiTipp}) async {
    initialisiert++;
    this.beiTipp = beiTipp;
    return initOk;
  }

  @override
  Future<String?> startPayload() async {
    final s = start;
    start = null;
    return s;
  }

  @override
  Future<bool> benachrichtigungenErlaubt() async => erlaubt;

  /// Android zeigt keinen Dialog mehr (dauerhaft verweigert): Anfragen ändern nichts.
  bool dauerhaft = false;

  /// Der Systemaufruf scheitert (Status nicht lesbar).
  bool statusUnbekannt = false;

  /// Ob sich die Systemeinstellungen öffnen lassen.
  bool systemOk = true;

  @override
  Future<BenachrichtigungsStatus> benachrichtigungsStatus() async => statusUnbekannt
      ? BenachrichtigungsStatus.unbekannt
      : erlaubt ? BenachrichtigungsStatus.erlaubt : (dauerhaft ? BenachrichtigungsStatus.gesperrt : BenachrichtigungsStatus.fragbar);

  @override
  Future<bool> benachrichtigungenAnfragen() async {
    anfragen++;
    if (anfrageErteilt && !dauerhaft) erlaubt = true;
    return erlaubt;
  }

  @override
  Future<bool> exakteAlarmeMoeglich() async => exakt;

  @override
  Future<bool> planen(List<GeplanteErinnerung> liste, {required bool exakt, required bool sperrbildschirmTitel}) async {
    ereignisse.add('planen-start');
    final b = planenBremse;
    if (b != null) await b.future;
    if (planenWirft) {
      ereignisse.add('planen-fehler');
      throw StateError('Plugin kaputt');
    }
    planungen.add(List.of(liste)); // auch ein misslungener Versuch zählt als Aufruf
    exaktFlags.add(exakt);
    sperrFlags.add(sperrbildschirmTitel);
    ereignisse.add(planenOk ? 'planen-ende' : 'planen-misslungen');
    return planenOk;
  }

  @override
  Future<bool> alleLoeschen() async {
    ereignisse.add('loeschen');
    geloescht++;
    return loeschenOk;
  }

  @override
  Future<bool> testPlanen(Duration wartezeit, {required bool exakt, required bool sperrbildschirmTitel}) async {
    if (testOk) tests.add(wartezeit);
    return testOk;
  }

  @override
  Future<bool> alarmEinstellungenOeffnen() async {
    alarmEinstellungen++;
    return systemOk;
  }

  int alarmEinstellungen = 0;

  @override
  Future<ErinnerungDiagnose> diagnose() async =>
      ErinnerungDiagnose(bereit: initOk, erlaubt: erlaubt, kanal: erlaubt ? 4 : 0, exakt: exakt, geplant: letzte?.length ?? 0);

  @override
  Future<bool> systemEinstellungenOeffnen() async {
    systemEinstellungen++;
    return systemOk;
  }
}
