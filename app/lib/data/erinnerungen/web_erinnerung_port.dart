// ignore_for_file: prefer_initializing_formals
// Web-Umsetzung des Erinnerungs-Ports: kein Betriebssystem-Alarm, sondern ein lokaler Schnappschuss der Planung (Kennung, Zeit, Nutzlast in `sync_meta`),
// den der Minutentakt (web_erinnerung_state.dart) prüft, solange die Web-App offen ist. Der Dienst (erinnerung_dienst.dart) plant wie auf Android
// mit `planeErinnerungen`; Titel und Texte der Planung werden hier NIE aufbewahrt oder gezeigt (nur neutrale Texte, siehe web_erinnerung_logik.dart).
import 'dart:async';

import '../../constants.dart' show kAppName;
import '../calendar/feiertage.dart' show FeiertageSpeicher;
import 'browser_benachrichtigung.dart';
import 'erinnerung_planung.dart';
import 'erinnerung_port.dart';
import 'web_erinnerung_logik.dart';

const kWebPlanSchluessel = 'web_erinnerung_plan';
const kWebMerklisteSchluessel = 'web_erinnerung_gezeigt';
const kWebAnSchluessel = 'web_erinnerung_an';

class WebErinnerungPort implements ErinnerungPort {
  final FeiertageSpeicher _speicher;
  final BrowserBenachrichtigung browser;
  final Future<bool> Function() _aktiv;
  final DateTime Function() _jetzt;

  List<WebEintrag>? _plan;
  Set<String>? _gezeigt;
  Future<void>? _laden;
  Timer? _test;

  /// Ein Prüfdurchgang läuft (der Steuer-Code lässt nie zwei zugleich laufen).
  bool beschaeftigt = false;

  /// Wird nach jedem Planen aufgerufen (der Takt prüft dann sofort, ohne die nächste Minute abzuwarten).
  void Function()? beiGeplant;

  WebErinnerungPort({required FeiertageSpeicher speicher, required this.browser, required Future<bool> Function() aktiv, required DateTime Function() jetzt})
    : _speicher = speicher,
      _aktiv = aktiv,
      _jetzt = jetzt;

  Future<void> _bereit() => _laden ??= () async {
    try {
      _plan = webPlanLesen(await _speicher.lesen(schluessel: kWebPlanSchluessel));
      _gezeigt = webMerklisteLesen(await _speicher.lesen(schluessel: kWebMerklisteSchluessel));
    } catch (_) {
      _plan = const [];
      _gezeigt = const {};
    }
  }();

  Future<void> _sichern() async {
    try {
      await _speicher.schreiben(webPlanKodieren(_plan ?? const []), schluessel: kWebPlanSchluessel);
      await _speicher.schreiben(webMerklisteKodieren(_gezeigt ?? const {}), schluessel: kWebMerklisteSchluessel);
    } catch (_) {
      // gilt dann nur, solange die App offen ist
    }
  }

  /// Geplante Einträge (für Tests und die Diagnose).
  List<WebEintrag> get plan => _plan ?? const [];

  /// Fällige und verpasste Erinnerungen jetzt (ohne etwas zu verändern).
  Future<WebPruefung> pruefen(DateTime jetzt) async {
    await _bereit();
    return webPruefen(plan: _plan ?? const [], gezeigt: _gezeigt ?? const {}, jetzt: jetzt);
  }

  /// Merkt Einträge als gezeigt (nie doppelt) und bereinigt die Merkliste.
  Future<void> alsGezeigtMerken(Iterable<WebEintrag> eintraege, DateTime jetzt) async {
    await _bereit();
    _gezeigt = webMerklisteBereinigen({...?_gezeigt, for (final e in eintraege) e.schluessel}, jetzt);
    await _sichern();
  }

  @override
  bool get verfuegbar => true;

  @override
  Future<bool> initialisieren({required void Function(String payload) beiTipp}) async => true;

  @override
  Future<String?> startPayload() async => null;

  @override
  Future<bool> benachrichtigungenErlaubt() async => browser.erlaubnis() == BrowserErlaubnis.erlaubt;

  @override
  Future<BenachrichtigungsStatus> benachrichtigungsStatus() async => switch (browser.erlaubnis()) {
    BrowserErlaubnis.erlaubt => BenachrichtigungsStatus.erlaubt,
    BrowserErlaubnis.offen => BenachrichtigungsStatus.fragbar,
    BrowserErlaubnis.blockiert || BrowserErlaubnis.fehlt => BenachrichtigungsStatus.gesperrt,
  };

  @override
  Future<bool> benachrichtigungenAnfragen() async => (await browser.anfragen()) == BrowserErlaubnis.erlaubt;

  @override
  Future<bool> exakteAlarmeMoeglich() async => true;

  /// Hält nur den Schnappschuss; ohne den Schalter "Erinnerungen im Browser" bleibt nichts liegen. Titel und Texte der Planung werden verworfen,
  /// ebenso [sperrbildschirmTitel] (das Web zeigt nie einen Titel).
  @override
  Future<bool> planen(List<GeplanteErinnerung> liste, {required bool exakt, required bool sperrbildschirmTitel}) async {
    if (!await _aktiv()) return alleLoeschen();
    await _bereit();
    _plan = webSchnappschuss(liste, _plan ?? const [], _jetzt());
    await _sichern();
    beiGeplant?.call();
    return true;
  }

  @override
  Future<bool> alleLoeschen() async {
    _test?.cancel();
    _plan = const [];
    _gezeigt = const {};
    _laden = Future<void>.value();
    try {
      await _speicher.loeschen(kWebPlanSchluessel);
      await _speicher.loeschen(kWebMerklisteSchluessel);
    } catch (_) {}
    return true;
  }

  /// Testbenachrichtigung: nach [wartezeit] eine neutrale Browser-Benachrichtigung (nur wenn erlaubt).
  @override
  Future<bool> testPlanen(Duration wartezeit, {required bool exakt, required bool sperrbildschirmTitel}) async {
    if (browser.erlaubnis() != BrowserErlaubnis.erlaubt) return false;
    _test?.cancel();
    _test = Timer(wartezeit, () => browser.zeigen(titel: kAppName, text: 'Erinnerung: Das ist ein Test', tag: 'fampad-test', beiKlick: () {}));
    return true;
  }

  @override
  Future<bool> systemEinstellungenOeffnen() async => false;

  @override
  Future<bool> alarmEinstellungenOeffnen() async => false;

  @override
  Future<ErinnerungDiagnose> diagnose() async =>
      ErinnerungDiagnose(bereit: true, erlaubt: browser.erlaubnis() == BrowserErlaubnis.erlaubt, kanal: -1, exakt: true, geplant: plan.length);
}
