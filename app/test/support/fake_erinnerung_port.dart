// Fake für die Plugin-Schnittstelle der Terminerinnerungen: zeichnet alle Aufrufe auf, keine Plattform nötig.
import 'package:lx_fampad/data/erinnerungen/erinnerung_planung.dart';
import 'package:lx_fampad/data/erinnerungen/erinnerung_port.dart';

class FakeErinnerungPort implements ErinnerungPort {
  @override
  bool verfuegbar = true;
  bool erlaubt = true;
  bool exakt = true;
  bool anfrageErteilt = true;
  String? start;
  int initialisiert = 0;
  int geloescht = 0;
  int anfragen = 0;
  int systemEinstellungen = 0;
  final planungen = <List<GeplanteErinnerung>>[];
  final exaktFlags = <bool>[];
  final tests = <Duration>[];
  void Function(String payload)? beiTipp;

  List<GeplanteErinnerung>? get letzte => planungen.isEmpty ? null : planungen.last;

  /// Simuliert das Tippen auf eine Benachrichtigung bei laufender App.
  void tippe(String payload) => beiTipp?.call(payload);

  @override
  Future<void> initialisieren({required void Function(String payload) beiTipp}) async {
    initialisiert++;
    this.beiTipp = beiTipp;
  }

  @override
  Future<String?> startPayload() async {
    final s = start;
    start = null;
    return s;
  }

  @override
  Future<bool> benachrichtigungenErlaubt() async => erlaubt;

  @override
  Future<bool> benachrichtigungenAnfragen() async {
    anfragen++;
    if (anfrageErteilt) erlaubt = true;
    return erlaubt;
  }

  @override
  Future<bool> exakteAlarmeMoeglich() async => exakt;

  @override
  Future<void> planen(List<GeplanteErinnerung> liste, {required bool exakt}) async {
    planungen.add(List.of(liste));
    exaktFlags.add(exakt);
  }

  @override
  Future<void> alleLoeschen() async => geloescht++;

  @override
  Future<void> testPlanen(Duration wartezeit, {required bool exakt}) async => tests.add(wartezeit);

  @override
  Future<void> systemEinstellungenOeffnen() async => systemEinstellungen++;
}
