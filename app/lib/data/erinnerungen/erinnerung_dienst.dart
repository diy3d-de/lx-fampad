// ignore_for_file: prefer_initializing_formals
// Dienst für Termin- und Aufgabenerinnerungen: hält die Planung des Geräts im Gleichklang mit den lokalen Kalender- und Aufgabendaten
// (ein gemeinsames Fenster, siehe erinnerung_planung.dart).
//  - Auslöser (verdrahtet in features/calendar/erinnerung_steuerung.dart, am App-Wurzel-Widget, das nie pausiert): Start der App, jede
//    Änderung der lokalen Termine (auch durch den Sync, entprellt), Rückkehr in die App, Änderung der Einstellungen, Anmeldung/Abmeldung.
//    Nach Neustart des Geräts und App-Update setzt das Plugin seine gespeicherten Alarme selbst neu (ScheduledNotificationBootReceiver);
//    das Fenster wird beim nächsten App-Start aufgefrischt.
//  - Ein Lauf berechnet das Fenster (erinnerung_planung.dart) und gleicht das Gerät daran an. Läuft schon einer, wird danach genau einmal
//    wiederholt. Ändert sich weder Fenster noch Genauigkeit noch Sperrbildschirm-Einstellung, bleibt das Betriebssystem unberührt.
//  - Scheitert das Plugin (Aufruf liefert false oder wirft), gilt der Zustand NICHT als gesetzt: ein einmaliger Wiederholversuch folgt
//    nach einer Pause, ansonsten der nächste Auslöser.
//  - Konto: Ohne Anmeldung (abgemeldet, ohne Sitzungsverlust) und bei einem anderen Konto als beim letzten Mal werden alle Erinnerungen
//    gelöscht; bei Sitzungsverlust bleiben sie (die lokalen Daten bleiben ebenfalls). Beim Leeren der lokalen Daten ruft der Wiper
//    [alleEntfernen] auf; ein laufender Planungslauf wird dabei abgewartet und kann danach nichts mehr setzen.
//  - Erinnerungen entstehen nur lokal: kein Server, kein Push, nichts verlässt das Gerät.
import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_state.dart';
import '../calendar/termin_repository.dart';
import '../auth/reset_hinweis.dart' show kSicherheitPayload;
import '../medikamente/medikament_erinnerung.dart' show istMedikamentPayload, planeMedikamentErinnerungen;
import '../medikamente/medikament_state.dart' show medDatenProvider;
import '../vorsorge/vorsorge_erinnerung.dart' show istVorsorgePayload, planeVorsorgeErinnerungen;
import '../vorsorge/vorsorge_state.dart' show vorsorgeDatenProvider;
import '../zaehler/zaehler_erinnerung.dart' show istZaehlerPayload, planeZaehlerErinnerungen;
import '../zaehler/zaehler_state.dart' show darfRolleZaehler, zaehlerDatenProvider;
import '../muell/muell_logik.dart' show istMuellPayload;
import '../tagesbriefing/briefing_einstellungen.dart' show briefingEinstellungenProvider;
import '../tagesbriefing/briefing_erinnerung.dart' show istBriefingPayload, planeBriefingErinnerungen;
import '../muell/muell_state.dart' show muellErinnerungen, muellProvider;
import '../api/models.dart' show Role;
import '../betrieb/betrieb_hinweis.dart' show kBetriebPayload;
import '../wetter/wetter_hinweise.dart' show istWetterPayload;
import '../standort/standort_hinweis.dart' show kStandortPayload;
import '../tasks/aufgabe_repository.dart' show aufgabenProvider;
import 'erinnerung_einstellungen.dart';
import 'erinnerung_planung.dart';
import 'erinnerung_port.dart';
import 'erinnerung_port_stub.dart' if (dart.library.io) 'erinnerung_port_io.dart';
import 'web_erinnerung_state.dart' show webErinnerungPortProvider;

/// Port des Geräts: im Web der Browser-Port (nur solange die Web-App offen ist, siehe web_erinnerung_port.dart), sonst das Android-Plugin bzw. ohne Wirkung.
final erinnerungPortProvider = Provider<ErinnerungPort>((ref) => kIsWeb ? ref.watch(webErinnerungPortProvider) : erinnerungPortErzeugen());

/// Uhr (für Tests überschreibbar).
final erinnerungUhrProvider = Provider<DateTime Function()>((ref) => DateTime.now);

/// Wartezeit, bis Änderungen der Termine zu einem Abgleich führen (ein ICS-Import oder Sync ändert viele Zeilen nacheinander).
/// Duration.zero = sofort (Tests).
final erinnerungEntprellenProvider = Provider<Duration>((ref) => const Duration(milliseconds: 500));

/// Pause vor dem einmaligen Wiederholversuch nach einem Fehler.
final erinnerungWiederholenProvider = Provider<Duration>((ref) => const Duration(seconds: 30));

/// Wird beim Tippen auf eine Benachrichtigung aufgerufen (Tag und Termin aus dem Inhalt); die Oberfläche hängt hier die Navigation ein.
typedef ErinnerungGeoeffnet = void Function(({String terminId, DateTime tag}) ziel);

class ErinnerungDienst {
  final Ref _ref;
  final ErinnerungPort port;
  final DateTime Function() _jetzt;
  final Duration _entprellen;
  final Duration _wiederholAbstand;
  bool _laeuft = false;
  bool _nochmal = false;
  bool _bereit = false;
  bool _startGelesen = false;
  bool _beendet = false;
  bool _gesperrt = false;
  bool _wiederholt = false;
  Future<void>? _aktuell;
  Timer? _entprellTimer;
  Timer? _wiederholTimer;

  /// Das Betriebssystem hat sicher keine Erinnerungen von uns mehr (nach Löschen oder leerer Planung).
  bool _leer = false;

  /// Navigation beim Tippen auf eine Benachrichtigung (setzt features/calendar/erinnerung_steuerung.dart).
  ErinnerungGeoeffnet? beiGeoeffnet;

  /// Navigation beim Tippen auf die Erinnerung einer Aufgabe (Aufgaben-ID).
  void Function(String aufgabeId)? beiAufgabeGeoeffnet;

  /// Tipp auf die Benachrichtigung "Standort geteilt": die Standort-Seite öffnen.
  void Function()? beiStandortGeoeffnet;

  /// Tipp auf den Sicherheitshinweis (Nutzlast `sicherheit`): Profil › Sicherheit › Sicherheitsereignisse öffnen.
  void Function()? beiSicherheitGeoeffnet;

  /// Tipp auf den Betreiber-Hinweis (Betrieb: Hinweis – öffne Betrieb).
  void Function()? beiBetriebGeoeffnet;

  /// Tipp auf eine Medikamenten-Erinnerung (Nutzlast `medikament|<ID>`, nie ein Inhalt): die Medikamenten-Ansicht öffnen.
  void Function()? beiMedikamentGeoeffnet;

  /// Tipp auf eine Zähler-Erinnerung (Nutzlast `zaehler`, nie ein Inhalt): die Zähler-Übersicht öffnen (die Shell prüft die Rolle).
  void Function()? beiZaehlerGeoeffnet;

  /// Tipp auf eine Vorsorge-Erinnerung (Nutzlast `vorsorge`, nie ein Inhalt): den Bereich Vorsorge öffnen.
  void Function()? beiVorsorgeGeoeffnet;

  /// Tipp auf die Müll-Erinnerung bzw. den Hinweis auf ein neues Jahr (Nutzlast `muell|<Tag>` oder `muell`): die Müll-Seite öffnen.
  void Function()? beiMuellGeoeffnet;
  void Function()? beiWetterGeoeffnet;

  /// Tipp auf die Benachrichtigung des Tagesbriefings (Nutzlast `briefing`, nur Zahlen): die Startseite öffnen.
  void Function()? beiBriefingGeoeffnet;

  /// Zuletzt erfolgreich an das Betriebssystem übergebene Planung samt Einstellungen (null: nichts bekannt).
  List<GeplanteErinnerung>? _letzte;
  bool? _letzteExakt;
  bool? _letzteErlaubt;
  bool? _letzteSperre;

  ErinnerungDienst(this._ref, {required this.port, required DateTime Function() jetzt, required Duration entprellen, required Duration wiederholen})
    : _jetzt = jetzt,
      _entprellen = entprellen,
      _wiederholAbstand = wiederholen;

  /// Zuletzt geplante Erinnerungen (für Anzeige und Tests).
  List<GeplanteErinnerung> get geplant => _letzte ?? const [];

  void beenden() {
    _beendet = true;
    _entprellTimer?.cancel();
    _wiederholTimer?.cancel();
  }

  /// Abgleich nach einer Änderung der Termine, mit Wartezeit (viele Änderungen hintereinander ergeben einen Lauf).
  void entprellt() {
    if (_beendet || !port.verfuegbar) return;
    if (_entprellen == Duration.zero) {
      unawaited(abgleichen());
      return;
    }
    _entprellTimer?.cancel();
    _entprellTimer = Timer(_entprellen, () => unawaited(abgleichen()));
  }

  /// Gleicht die Planung an. Mehrfache Aufrufe während eines Laufs ergeben genau einen weiteren Lauf; der Aufrufer kann das Ende abwarten.
  Future<void> abgleichen() {
    if (_beendet || !port.verfuegbar) return Future.value();
    if (_laeuft) {
      _nochmal = true;
      return _aktuell ?? Future.value();
    }
    _laeuft = true;
    return _aktuell = _schleife();
  }

  Future<void> _schleife() async {
    var fehler = false;
    try {
      do {
        _nochmal = false;
        try {
          fehler = !await _lauf();
        } catch (_) {
          // Erinnerungen sind Zusatz: ein Fehler beim Planen darf nichts anderes stören; der Zustand gilt als unbekannt
          _letzte = null;
          fehler = true;
        }
      } while (_nochmal && !_beendet);
    } finally {
      _laeuft = false;
    }
    if (!fehler) {
      _wiederholt = false;
    } else if (!_wiederholt && !_beendet) {
      _wiederholt = true; // genau ein Wiederholversuch
      _wiederholTimer?.cancel();
      _wiederholTimer = Timer(_wiederholAbstand, () => unawaited(abgleichen()));
    }
  }

  /// Ein Lauf. true = erledigt (oder nichts zu tun), false = das Plugin hat versagt.
  Future<bool> _lauf() async {
    await _ref.read(erinnerungEinstellungenProvider.notifier).bereit;
    if (_beendet) return true;
    if (!_bereit) {
      _bereit = await port.initialisieren(beiTipp: _getippt);
      if (!_bereit) return false;
      if (!_startGelesen) {
        _startGelesen = true;
        _getippt(await port.startPayload());
      }
    }
    final auth = _ref.read(authProvider);
    // Ohne Konto (nie angemeldet oder ausdrücklich abgemeldet): nichts darf stehen bleiben. Sitzungsverlust (Hinweis) und die Prüfung
    // beim Start lassen alles unberührt.
    if (auth.status == AuthStatus.abgemeldet && auth.hinweis == null) return _loeschen();
    if (!auth.angemeldet) return true;
    final ich = auth.user?.id;
    if (ich == null) return true;
    final einst = _ref.read(erinnerungEinstellungenProvider);
    if (!await _kontoPruefen(ich)) return false;
    // Abfuhrtermine haben einen eigenen Schalter: der globale Schalter "Erinnerungen auf diesem Gerät" aus löscht nur Termine und Aufgaben, nicht die Müll-Alarme
    final nurMuell = !einst.an;
    if (!_muellBereit(auth.user?.role)) return true;
    final muellPlan = muellErinnerungen(_ref.read(muellProvider), auth.user?.role, _jetzt());
    // Einnahme-Erinnerungen (eigener Schalter): erst, wenn Pläne und Mitglieder gelesen sind (sonst würde ein leeres Fenster ihre Alarme löschen); neutral, nur lokal
    final md = einst.medikamenteAn ? _ref.read(medDatenProvider) : null;
    if (md != null && !md.geladen) return true;
    final medPlan = md == null ? const <GeplanteErinnerung>[] : planeMedikamentErinnerungen(medDaten: md, jetzt: _jetzt());
    // Vorsorge-Erinnerungen (eigener Schalter, neutral, nur lokal): erst, wenn Profile, Einträge und Mitglieder gelesen sind
    final vd = einst.vorsorgeAn ? _ref.read(vorsorgeDatenProvider) : null;
    if (vd != null && !vd.geladen) return true;
    final vorsorgePlan = vd == null ? const <GeplanteErinnerung>[] : planeVorsorgeErinnerungen(daten: vd, jetzt: _jetzt());
    // Ablese-Erinnerungen der Zähler (eigener Schalter, nur Eltern und Admins, neutral, nur lokal): erst, wenn die Daten gelesen sind
    final zd = einst.zaehlerAn && darfRolleZaehler(auth.user?.role) ? _ref.read(zaehlerDatenProvider) : null;
    if (zd != null && !zd.geladen) return true;
    final zaehlerPlan = zd == null ? const <GeplanteErinnerung>[] : planeZaehlerErinnerungen(daten: zd, jetzt: _jetzt());
    // Tagesbriefing am Morgen (eigener Schalter, Standard aus, neutral, nur Zahlen, nur lokal): erst, wenn Termine und Aufgaben gelesen sind
    await _ref.read(briefingEinstellungenProvider.notifier).bereit;
    final be = _ref.read(briefingEinstellungenProvider);
    var briefingPlan = const <GeplanteErinnerung>[];
    if (be.morgensAn) {
      if (!_datenDa(true)) return true;
      briefingPlan = planeBriefingErinnerungen(
        daten: _ref.read(kalenderDatenProvider),
        aufgaben: _ref.read(aufgabenProvider).value ?? const [],
        ich: ich,
        elternRolle: auth.user?.role == Role.admin || auth.user?.role == Role.parent,
        minuten: be.minuten,
        jetzt: _jetzt(),
      );
    }
    final zusatzPlan = [...muellPlan, ...medPlan, ...vorsorgePlan, ...zaehlerPlan, ...briefingPlan];
    if (nurMuell && zusatzPlan.isEmpty) return _loeschen();
    // Erst planen, wenn die Datenbank die Termine geliefert hat (sonst würde ein leeres Fenster alle Alarme löschen)
    if (!nurMuell && !_datenDa(einst.aufgabenAn)) return true;
    final exakt = await port.exakteAlarmeMoeglich();
    // Wurde die Erlaubnis nachträglich erteilt (oder entzogen), alles neu setzen: kein App-Neustart nötig
    final bs = await port.benachrichtigungsStatus();
    final erlaubt = bs == BenachrichtigungsStatus.erlaubt;
    // "unbekannt" (Systemaufruf kurz gescheitert) ändert nichts: keine Neuplanung durch ein kurzes Scheitern
    if (bs != BenachrichtigungsStatus.unbekannt && _letzteErlaubt != null && _letzteErlaubt != erlaubt) {
      _letzte = null;
      _leer = false;
    }
    final plan = planeErinnerungen(
      daten: nurMuell ? const KalenderDaten() : _ref.read(kalenderDatenProvider),
      ich: ich,
      jetzt: _jetzt(),
      aufgaben: !nurMuell && einst.aufgabenAn ? (_ref.read(aufgabenProvider).value ?? const []) : const [],
      // Abfuhrtermine: Abend vor der Abholung, nur Eltern/Admins (leer für alle anderen)
      zusatz: zusatzPlan,
      elternRolle: auth.user?.role == Role.admin || auth.user?.role == Role.parent,
    );
    final alt = _letzte;
    final gleich =
        alt != null &&
        _letzteExakt == exakt &&
        _letzteSperre == einst.sperrbildschirmTitel &&
        alt.length == plan.length &&
        [for (var i = 0; i < plan.length; i++) alt[i].gleich(plan[i])].every((b) => b);
    if (gleich) return true;
    if (_gesperrt || _beendet) return true; // ein Abmelden/Leeren ist im Gange: nichts mehr setzen
    final ok = await port.planen(plan, exakt: exakt, sperrbildschirmTitel: einst.sperrbildschirmTitel);
    if (!ok) {
      _letzte = null;
      return false;
    }
    _letzte = plan;
    _letzteExakt = exakt;
    if (bs != BenachrichtigungsStatus.unbekannt) _letzteErlaubt = erlaubt;
    _letzteSperre = einst.sperrbildschirmTitel;
    _leer = plan.isEmpty;
    return true;
  }

  /// Gelten die geplanten Erinnerungen einer anderen Person (anderes Konto auf diesem Gerät)? Dann alles löschen. Merkt sich das Konto.
  Future<bool> _kontoPruefen(String ich) async {
    final speicher = _ref.read(erinnerungSpeicherProvider);
    String? bisher;
    try {
      bisher = (await speicher.lesen())[kErinnerungKontoSchluessel];
    } catch (_) {
      return true; // Speicher nicht lesbar: nichts ableiten
    }
    if (bisher == ich) return true;
    if (bisher != null && bisher.isNotEmpty) {
      _letzte = null;
      _leer = false;
      if (!await _loeschen()) return false;
    }
    try {
      await speicher.schreiben(kErinnerungKontoSchluessel, ich);
    } catch (_) {}
    return true;
  }

  /// Eltern/Admins planen erst, wenn die lokale Ablage der Abfuhrtermine gelesen ist (sonst würde ein Fenster ohne sie die Müll-Alarme kurz löschen).
  bool _muellBereit(Role? rolle) => (rolle != Role.admin && rolle != Role.parent) || _ref.read(muellProvider).ablageGelesen;

  bool _datenDa(bool mitAufgaben) =>
      _ref.read(termineProvider).hasValue && _ref.read(terminAusnahmenProvider).hasValue && _ref.read(terminTeilnehmerProvider).hasValue &&
      (!mitAufgaben || _ref.read(aufgabenProvider).hasValue);

  Future<bool> _loeschen() async {
    if (_leer) return true;
    final ok = await port.alleLoeschen();
    if (ok) {
      _leer = true;
      _letzte = const [];
    }
    return ok;
  }

  /// Alle Erinnerungen dieses Geräts entfernen (Abmelden, Leeren der lokalen Daten). Wartet einen laufenden Planungslauf ab; solange das
  /// Entfernen läuft, setzt kein Lauf etwas Neues. Die nächste Anmeldung plant neu.
  Future<void> alleEntfernen() async {
    if (_beendet || !port.verfuegbar) return;
    _gesperrt = true;
    try {
      try {
        await _aktuell;
      } catch (_) {}
      if (!_bereit) _bereit = await port.initialisieren(beiTipp: _getippt);
      if (!_bereit) return;
      final ok = await port.alleLoeschen();
      _letzte = null;
      _letzteExakt = null;
      _letzteErlaubt = null;
      _letzteSperre = null;
      if (ok) _leer = true;
    } catch (_) {
      _letzte = null;
    } finally {
      _gesperrt = false;
    }
  }

  /// Öffnet das Ziel einer Nutzlast wie ein Tipp auf die Benachrichtigung (Web: Tipp auf einen Hinweis in der App).
  void oeffnen(String? payload) => _getippt(payload);

  void _getippt(String? payload) {
    if (_beendet) return;
    if (payload == kSicherheitPayload) {
      beiSicherheitGeoeffnet?.call();
      return;
    }
    if (payload == kBetriebPayload) {
      beiBetriebGeoeffnet?.call();
      return;
    }
    if (payload == kStandortPayload) {
      beiStandortGeoeffnet?.call();
      return;
    }
    if (istMedikamentPayload(payload)) {
      beiMedikamentGeoeffnet?.call();
      return;
    }
    if (istVorsorgePayload(payload)) {
      beiVorsorgeGeoeffnet?.call();
      return;
    }
    if (istZaehlerPayload(payload)) {
      beiZaehlerGeoeffnet?.call();
      return;
    }
    if (istMuellPayload(payload)) {
      beiMuellGeoeffnet?.call();
      return;
    }
    if (istBriefingPayload(payload)) {
      beiBriefingGeoeffnet?.call();
      return;
    }
    if (istWetterPayload(payload)) {
      beiWetterGeoeffnet?.call();
      return;
    }
    final aufgabe = aufgabeErinnerungPayloadLesen(payload);
    if (aufgabe != null) {
      beiAufgabeGeoeffnet?.call(aufgabe);
      return;
    }
    final ziel = erinnerungPayloadLesen(payload);
    if (ziel == null) return;
    beiGeoeffnet?.call(ziel);
  }

  /// Berechtigung für Benachrichtigungen anfragen (nur auf Wunsch der Person); plant danach neu.
  Future<bool> berechtigungAnfragen() async {
    _bereit = _bereit || await port.initialisieren(beiTipp: _getippt);
    final ok = await port.benachrichtigungenAnfragen();
    _letzte = null;
    unawaited(abgleichen());
    return ok;
  }

  Future<ErinnerungStatus> status() async {
    if (!port.verfuegbar) return const ErinnerungStatus(verfuegbar: false);
    _bereit = _bereit || await port.initialisieren(beiTipp: _getippt);
    final s = await port.benachrichtigungsStatus();
    return ErinnerungStatus(
      verfuegbar: true,
      erlaubt: s == BenachrichtigungsStatus.erlaubt,
      fragbar: s != BenachrichtigungsStatus.gesperrt,
      unbekannt: s == BenachrichtigungsStatus.unbekannt,
      bereit: _bereit,
      exakt: await port.exakteAlarmeMoeglich(),
    );
  }

  /// Zustände für die Diagnose-Zeile (keine Inhalte). [bereit] ist der Zustand des Plugins im Port.
  Future<ErinnerungDiagnose> diagnose() async {
    if (!port.verfuegbar) return const ErinnerungDiagnose();
    return port.diagnose();
  }

  /// Testbenachrichtigung in [wartezeit] (Standard 10 Sekunden). true = geplant.
  Future<bool> testSenden({Duration wartezeit = const Duration(seconds: 10)}) async {
    _bereit = _bereit || await port.initialisieren(beiTipp: _getippt);
    if (!_bereit) return false;
    final exakt = await port.exakteAlarmeMoeglich();
    return port.testPlanen(wartezeit, exakt: exakt, sperrbildschirmTitel: _ref.read(erinnerungEinstellungenProvider).sperrbildschirmTitel);
  }
}

final erinnerungDienstProvider = Provider<ErinnerungDienst>((ref) {
  final d = ErinnerungDienst(
    ref,
    port: ref.watch(erinnerungPortProvider),
    jetzt: ref.watch(erinnerungUhrProvider),
    entprellen: ref.watch(erinnerungEntprellenProvider),
    wiederholen: ref.watch(erinnerungWiederholenProvider),
  );
  ref.onDispose(d.beenden);
  return d;
});

/// Zustand für die Einstellungen: gibt es Erinnerungen auf diesem Gerät, ist die Berechtigung da, sind genaue Alarme möglich?
class ErinnerungStatus {
  final bool verfuegbar;
  final bool erlaubt;
  final bool exakt;

  /// Nicht erlaubt, aber Android zeigt den Dialog noch (sonst führt nur der Weg in die Einstellungen weiter).
  final bool fragbar;

  /// Der Status ließ sich nicht lesen (Systemaufruf gescheitert): nicht als "verweigert" anzeigen.
  final bool unbekannt;

  /// Das Plugin ist bereit (sonst sind Angaben zu genauen Alarmen nicht belastbar).
  final bool bereit;
  const ErinnerungStatus({required this.verfuegbar, this.erlaubt = false, this.exakt = false, this.fragbar = true, this.unbekannt = false, this.bereit = true});
}

final erinnerungDiagnoseProvider = FutureProvider.autoDispose<ErinnerungDiagnose>((ref) => ref.read(erinnerungDienstProvider).diagnose());

final erinnerungStatusProvider = FutureProvider.autoDispose<ErinnerungStatus>((ref) => ref.read(erinnerungDienstProvider).status());
