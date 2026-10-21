// Standort teilen: Steuerung (Riverpod). Flüchtig und Ende-zu-Ende verschlüsselt (Verfahren: standort_krypto.dart, Server: docs/API.md, "Standort").
//
//  - Nichts wird gespeichert: weder die eigene Position noch die der anderen (nur im Arbeitsspeicher; kein Eintrag in Datenbank, Ausgang oder Sync).
//  - Start nur durch die Person selbst (Tipp mit Dauer und Empfängern). Solange geteilt wird, läuft der Android-Vordergrunddienst mit ständiger
//    Benachrichtigung; die Dauer ist begrenzt, Beenden jederzeit ohne Rückfrage.
//  - Eine eigene WebSocket-Verbindung (wie der Sync-Socket, aber auch im Hintergrund, solange geteilt wird): bei Verbindungsverlust wird nichts
//    nachgeschickt, nach dem Wiederverbinden gilt die neueste Position.
import 'dart:async';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/models.dart';
import '../auth/auth_state.dart';
import '../../constants.dart' show kAppName;
import '../chat/chat_krypto_state.dart';
import '../crypto/crypto_fehler.dart';
import '../crypto/crypto_provider.dart';
import '../crypto/schluessel.dart';
import '../lists/members.dart';
import '../sync/sync_socket.dart';
import '../sync/sync_store.dart' show neueUuid;
import '../sync_state.dart' show syncSocketOeffnerProvider, syncZufallProvider;
import 'standort_hinweis.dart';
import 'standort_krypto.dart';
import 'standort_modelle.dart';
import 'standort_port.dart';

/// Alles, was die Standort-Verschlüsselung von diesem Gerät braucht.
class StandortSchluessel {
  final CryptoProvider crypto;
  final String ichId;
  final Personenschluessel schluessel;
  final int keyVersion;

  /// Schlüssel, an die dieses Gerät verteilen darf (gemerkt und gleich dem Schlüssel des Servers); null: nicht vertrauenswürdig.
  final Future<OeffentlicheSchluessel?> Function(String userId) vertrauenswuerdig;

  /// Gemerkter (TOFU) Schlüssel einer Person: Grundlage für die Prüfung einer Freigabe (nie ein Schlüssel vom Server).
  final Future<OeffentlicheSchluessel?> Function(String userId) gemerkt;
  const StandortSchluessel({required this.crypto, required this.ichId, required this.schluessel, required this.keyVersion, required this.vertrauenswuerdig, required this.gemerkt});
}

/// Liefert die Schlüssel des Geräts (null: Verschlüsselung nicht eingerichtet oder nicht bereit). Standard: dieselben wie im Chat.
final standortSchluesselProvider = Provider<Future<StandortSchluessel?> Function()>((ref) {
  return () async {
    final k = await ref.read(chatKryptoProvider.notifier).krypto();
    if (k == null) return null;
    return StandortSchluessel(
      crypto: k.crypto,
      ichId: k.ichId,
      schluessel: k.meinSchluessel,
      keyVersion: k.meineKeyVersion,
      vertrauenswuerdig: k.vertrauenswuerdig,
      gemerkt: (u) => k.gemerkt(u),
    );
  };
});

final standortPortProvider = Provider<StandortPort>((ref) => standortPortErzeugen());

/// Akkuoptimierung der App (true = nicht eingeschränkt, false = Android darf das Teilen im Hintergrund bremsen, null = unbekannt). Die Seite lädt neu, wenn die App zurückkehrt.
final akkuUneingeschraenktProvider = FutureProvider.autoDispose<bool?>((ref) => ref.read(standortPortProvider).akkuUneingeschraenkt());

final standortUhrProvider = Provider<DateTime Function()>((ref) => DateTime.now);

/// Abstand der Zeitgeber (Lebenszeichen an den Dienst, Prüfung auf Ablauf, erneutes Senden der Position); in Tests verkürzt.
class StandortZeiten {
  final Duration herzschlag;
  final Duration takt;

  /// Wartezeit auf die Bestätigung des Servers nach dem Start.
  final Duration startFrist;

  /// Wie lange das Starten auf eine Verbindung zum Server wartet.
  final Duration verbindungsFrist;

  const StandortZeiten({
    this.herzschlag = const Duration(seconds: 30),
    this.takt = const Duration(seconds: 10),
    this.startFrist = const Duration(seconds: 8),
    this.verbindungsFrist = const Duration(seconds: 5),
  });
}

final standortZeitenProvider = Provider<StandortZeiten>((ref) => const StandortZeiten());

/// Öffnet die Verbindung (in Tests austauschbar).
typedef StandortSocketFabrik = SyncSocket Function({required void Function(Map<String, Object?>) beiNachricht, required void Function(bool) beiStatus});

final standortSocketFabrikProvider = Provider<StandortSocketFabrik>((ref) {
  return ({required beiNachricht, required beiStatus}) => SyncSocket(
    ticket: () => ref.read(apiProvider).wsTicket(),
    beiRev: (_) {},
    beiStatus: beiStatus,
    beiNachricht: beiNachricht,
    oeffner: ref.read(syncSocketOeffnerProvider),
    zufall: ref.read(syncZufallProvider),
    // nach einem Verbindungsabbruch (Netzwechsel) schnell wieder da: der Server wartet nur 90 s, bevor er die Freigabe beendet.
    // Höchstens 15 s Grundabstand, mit Zufallsanteil (Jitter +/- 50 %) also bis etwa 22 s zwischen zwei Versuchen.
    backoffMax: const Duration(seconds: 15),
  );
});

enum StandortPhase { aus, startet, teilt }

class StandortState {
  final StandortPhase phase;
  final DateTime? endetAt;

  /// Personen, die meine Freigabe bekommen haben.
  final Set<String> empfaenger;

  /// Gewählte Personen, an die NICHT verteilt wurde (Schlüssel nicht bestätigt).
  final Set<String> ausgelassen;

  /// Fehler oder Hinweis für die Oberfläche (deutsch, ohne Inhalte).
  final String? meldung;

  /// Wer gerade mit mir teilt (Person -> Stand).
  final Map<String, GeteiltePosition> geteilt;
  final bool verbunden;

  /// Die Ortung des Geräts ist ausgeschaltet.
  final bool ortungAus;
  final DateTime? letzterVersand;
  final GeraetePosition? eigene;
  const StandortState({
    this.phase = StandortPhase.aus,
    this.endetAt,
    this.empfaenger = const {},
    this.ausgelassen = const {},
    this.meldung,
    this.geteilt = const {},
    this.verbunden = false,
    this.ortungAus = false,
    this.letzterVersand,
    this.eigene,
  });

  bool get teilt => phase != StandortPhase.aus;

  StandortState kopie({
    StandortPhase? phase,
    DateTime? endetAt,
    bool endeLoeschen = false,
    Set<String>? empfaenger,
    Set<String>? ausgelassen,
    String? meldung,
    bool meldungLoeschen = false,
    Map<String, GeteiltePosition>? geteilt,
    bool? verbunden,
    bool? ortungAus,
    DateTime? letzterVersand,
    GeraetePosition? eigene,
    bool eigeneLoeschen = false,
  }) => StandortState(
    phase: phase ?? this.phase,
    endetAt: endeLoeschen ? null : (endetAt ?? this.endetAt),
    empfaenger: empfaenger ?? this.empfaenger,
    ausgelassen: ausgelassen ?? this.ausgelassen,
    meldung: meldungLoeschen ? null : (meldung ?? this.meldung),
    geteilt: geteilt ?? this.geteilt,
    verbunden: verbunden ?? this.verbunden,
    ortungAus: ortungAus ?? this.ortungAus,
    letzterVersand: eigeneLoeschen ? null : (letzterVersand ?? this.letzterVersand),
    eigene: eigeneLoeschen ? null : (eigene ?? this.eigene),
  );
}

/// Meldungen für die Oberfläche (feste Sätze, nie Servertexte).
const _kMeldungKeinSchluessel = 'Richte zuerst die Verschlüsselung ein (Profil, Verschlüsselung). Ohne sie lässt sich der Standort nicht verschlüsselt teilen.';
const _kMeldungKeineEmpfaenger = 'Keine der gewählten Personen hat einen bestätigten Schlüssel. Bestätige zuerst ihre Schlüssel (Profil, Verschlüsselung).';
const _kMeldungOffline = 'Keine Verbindung zum Server. Zum Teilen brauchst du eine Verbindung.';
const _kMeldungAbgelehnt = 'Der Server hat das Teilen abgelehnt. Versuche es später noch einmal.';

/// Abstand zweier Punkte in Metern (Haversine).
double abstandMeter(double b1, double l1, double b2, double l2) {
  const r = 6371000.0;
  double rad(double g) => g * pi / 180;
  final db = rad(b2 - b1);
  final dl = rad(l2 - l1);
  final a = pow(sin(db / 2), 2) + cos(rad(b1)) * cos(rad(b2)) * pow(sin(dl / 2), 2);
  return 2 * r * asin(sqrt(a.toDouble()));
}

class StandortController extends Notifier<StandortState> {
  SyncSocket? _socket;
  StreamSubscription<StandortEreignis>? _ereignisSub;
  Timer? _takt;
  Timer? _herzschlag;
  Timer? _startFrist;
  StandortSender? _sender;
  String? _shareId;
  String? _ich;
  bool _vordergrund = true;
  bool _aktiv = false;
  StandortTakt _sendeTakt = kStandortTaktStandard;

  /// Zählt Starts und Stopps der Freigabe: späte Antworten einer früheren Freigabe werden verworfen.
  int _lauf = 0;
  GeraetePosition? _letzteGesendet;
  DateTime? _letzterVersandZeit;
  final Map<String, StandortEmpfaenger> _empfang = {};

  /// Beendete Freigaben anderer (Kennung -> Ende), nur im Arbeitsspeicher und nur bis zu ihrem Ende: ein später eingespieltes `loc_start` mit bekannter
  /// Kennung (Server oder Dritte spielen einen alten Wrap erneut ein) lässt die Freigabe nicht wieder aufleben.
  final Map<String, DateTime> _beendet = {};

  void _merkeBeendet(StandortEmpfaenger e) {
    final deckel = _jetzt().add(kStandortHoechstdauer);
    _beendet[e.shareId] = e.freigabeEnde.isAfter(deckel) ? deckel : e.freigabeEnde;
  }

  DateTime _jetzt() => ref.read(standortUhrProvider)();
  late StandortPort _portRef;
  StandortPort get _port => _portRef;
  StandortZeiten get _zeiten => ref.read(standortZeitenProvider);

  @override
  StandortState build() {
    _portRef = ref.read(standortPortProvider);
    ref.onDispose(_aufraeumen);
    // Abmelden oder Personenwechsel: nichts vom Standort bleibt im Speicher
    ref.listen(authProvider.select((s) => s.status == AuthStatus.angemeldet ? s.user?.id : null), (alt, neu) {
      if (alt != neu) unawaited(_zuruecksetzen());
    });
    return const StandortState();
  }

  /// Startet den Empfang (nach der Anmeldung): Verbindung und Ereignisse des Geräts.
  void starten() {
    if (_aktiv) return;
    final ich = ref.read(authProvider).user?.id;
    if (ich == null) return;
    _aktiv = true;
    _ich = ich;
    _ereignisSub ??= _port.ereignisse.listen(_beiGeraetEreignis, onError: (Object _) {});
    _verbinden();
    _takt = Timer.periodic(_zeiten.takt, (_) => unawaited(_tick()));
  }

  /// Hält Zeitgeber, Verbindung und Gerätedienst an (Abmelden: die Oberfläche wird abgebaut). Ändert den Zustand nicht, das ist beim Abbau des Widget-Baums
  /// nicht erlaubt; der Zustand wird beim nächsten [starten] bzw. beim Personenwechsel zurückgesetzt.
  void anhalten() {
    _aktiv = false;
    _takt?.cancel();
    _takt = null;
    _herzschlag?.cancel();
    _herzschlag = null;
    _startFrist?.cancel();
    _startFrist = null;
    _socket?.stop();
    _socket = null;
    _ereignisSub?.cancel();
    _ereignisSub = null;
    if (_sender != null) {
      unawaited(_port.stoppen());
      _sender?.vergessen();
      _sender = null;
      _shareId = null;
    }
  }

  /// App im Vordergrund (true) bzw. Hintergrund: im Hintergrund bleibt die Verbindung nur, solange geteilt wird.
  void vordergrund(bool vorn) {
    _vordergrund = vorn;
    if (!_aktiv) return;
    if (vorn) {
      _verbinden();
    } else if (!state.teilt) {
      _trennen();
    }
  }

  void _verbinden() {
    if (!_aktiv || _socket != null) return;
    _socket = ref.read(standortSocketFabrikProvider)(beiNachricht: _beiNachricht, beiStatus: _beiStatus)..start();
  }

  void _trennen() {
    _socket?.stop();
    _socket = null;
    if (state.verbunden) state = state.kopie(verbunden: false);
  }

  void _beiStatus(bool live) {
    if (!_aktiv) return;
    if (state.verbunden != live) state = state.kopie(verbunden: live);
    // diese Verbindung gehört dem Standort-Kanal: der Server zählt sie nicht als "Gerät ist live" (sonst blieben Push-Hinweise im Hintergrund aus)
    if (live) _socket?.senden({'type': 'loc_hello'});
    // nach dem Wiederverbinden gilt sofort die neueste Position (nichts wurde in der Zwischenzeit gepuffert)
    if (live && state.phase == StandortPhase.teilt) unawaited(_senden());
  }

  // ------------------------------------------------------------------ Teilen

  /// Startet das Teilen für [dauer] mit [empfaenger]. Liefert true, wenn es läuft; sonst steht der Grund in [StandortState.meldung].
  Future<bool> teilen({required Duration dauer, required Set<String> empfaenger, StandortTakt takt = kStandortTaktStandard}) async {
    if (!_aktiv || state.teilt) return false;
    _sendeTakt = takt;
    final lauf = ++_lauf;
    state = state.kopie(phase: StandortPhase.startet, meldungLoeschen: true, empfaenger: const {}, ausgelassen: const {});
    Future<bool> scheitern(String meldung, {bool dienstStoppen = false}) async {
      if (lauf != _lauf) return false;
      // auch in der Startphase: ein schon gesendetes loc_start soll am Server nicht stehen bleiben
      final sid = _shareId;
      if (sid != null) _socket?.senden({'type': 'loc_stop', 'shareId': sid});
      if (dienstStoppen) await _port.stoppen();
      _sender?.vergessen();
      _sender = null;
      _shareId = null;
      state = state.kopie(phase: StandortPhase.aus, meldung: meldung, endeLoeschen: true);
      return false;
    }

    try {
      if (!_port.verfuegbar) return await scheitern('Standort teilen gibt es nur in der Android-App.');
      var st = await _port.status();
      if (!st.erlaubt || !st.benachrichtigungen) st = await _port.berechtigungAnfragen();
      if (lauf != _lauf) return false;
      if (!st.erlaubt) return await scheitern('Ohne die Erlaubnis für den Standort kann ich ihn nicht teilen. Du kannst sie in den Android-Einstellungen erteilen.');
      if (!st.benachrichtigungen) {
        return await scheitern('Benachrichtigungen sind ausgeschaltet. Beim Teilen zeigt $kAppName eine ständige Benachrichtigung, mit der du es beenden kannst. Erlaube sie in den Android-Einstellungen.');
      }
      final keys = await ref.read(standortSchluesselProvider)();
      if (lauf != _lauf) return false;
      if (keys == null) return await scheitern(_kMeldungKeinSchluessel);

      final empf = <String, OeffentlicheSchluessel>{};
      final aus = <String>{};
      for (final id in empfaenger) {
        if (id == keys.ichId) continue;
        final k = await keys.vertrauenswuerdig(id);
        if (k == null) {
          aus.add(id);
        } else {
          empf[id] = k;
        }
      }
      if (lauf != _lauf) return false;
      if (empf.isEmpty) return await scheitern(_kMeldungKeineEmpfaenger);
      if (!(await _verbundenWarten())) return await scheitern(_kMeldungOffline);
      if (lauf != _lauf) return false;

      final jetzt = _jetzt();
      final begrenzt = dauer > kStandortHoechstdauer ? kStandortHoechstdauer : dauer;
      final ende = jetzt.add(begrenzt);
      final shareId = neueUuid();
      final sender = StandortSender.neu(keys.crypto, shareId: shareId, ichId: keys.ichId, meineKeyVersion: keys.keyVersion, signGeheim: keys.schluessel.signGeheim, endsAtMs: ende.millisecondsSinceEpoch);
      final wraps = [
        for (final e in empf.entries) {'userId': e.key, 'wrap': sender.wrapFuer(e.key, e.value).kodieren()},
      ];
      _sender = sender;
      _shareId = shareId;
      _ich = keys.ichId;
      _letzteGesendet = null;
      _letzterVersandZeit = null;

      final fehler = await _port.starten(ende, intervall: _sendeTakt.intervall);
      if (lauf != _lauf) {
        // zwischendurch beendet: ein inzwischen gestarteter Dienst darf nicht weiterlaufen
        if (fehler == null) await _port.stoppen();
        return false;
      }
      if (fehler != null) {
        return await scheitern(switch (fehler) {
          StartFehler.keineBerechtigung => 'Ohne die Erlaubnis für den Standort kann ich ihn nicht teilen.',
          StartFehler.benachrichtigungenAus => 'Benachrichtigungen sind ausgeschaltet: ohne die ständige Benachrichtigung startet das Teilen nicht.',
          StartFehler.ende => 'Die gewählte Dauer ist schon vorbei.',
          StartFehler.dienstStart => 'Das Teilen konnte nicht gestartet werden. Öffne die App im Vordergrund und versuche es noch einmal.',
        }, dienstStoppen: true);
      }
      state = state.kopie(endetAt: ende, empfaenger: empf.keys.toSet(), ausgelassen: aus);
      _startFrist?.cancel();
      _startFrist = Timer(_zeiten.startFrist, () {
        if (lauf == _lauf && state.phase == StandortPhase.startet) unawaited(scheitern(_kMeldungAbgelehnt, dienstStoppen: true));
      });
      final gesendet = _socket?.senden({'type': 'loc_start', 'shareId': shareId, 'endsAt': ende.millisecondsSinceEpoch, 'recipients': wraps}) ?? false;
      if (!gesendet) return await scheitern(_kMeldungOffline, dienstStoppen: true);
      return true;
    } catch (_) {
      return await scheitern('Das Teilen konnte nicht gestartet werden.', dienstStoppen: true);
    }
  }

  Future<bool> _verbundenWarten() async {
    final bis = DateTime.now().add(_zeiten.verbindungsFrist);
    while (DateTime.now().isBefore(bis)) {
      if (_socket?.live == true) return true;
      if (_socket == null && _aktiv) _verbinden();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    return _socket?.live == true;
  }

  /// Bestätigung des Servers: ab jetzt läuft das Teilen (Lebenszeichen und Positionen).
  void _gestartet(int? endsAt) {
    if (state.phase == StandortPhase.aus) return;
    _startFrist?.cancel();
    _startFrist = null;
    final war = state.phase;
    state = state.kopie(phase: StandortPhase.teilt, endetAt: endsAt == null ? null : DateTime.fromMillisecondsSinceEpoch(endsAt));
    if (war == StandortPhase.startet) {
      _herzschlag?.cancel();
      _herzschlag = Timer.periodic(_zeiten.herzschlag, (_) => unawaited(_lebenszeichen()));
    }
  }

  Future<void> _lebenszeichen() async {
    if (state.phase != StandortPhase.teilt) return;
    final lauf = _lauf;
    final h = await _port.herzschlag();
    if (!ref.mounted) return; // Antwort kommt nach dem Abbau des Providers
    if (lauf != _lauf || state.phase != StandortPhase.teilt) return;
    if (h.stopAngefordert) {
      await beenden(grund: 'Du hast das Teilen beendet.');
    } else if (!h.laeuft) {
      await beenden(grund: 'Das Teilen wurde vom Gerät beendet.', dienstStoppen: false);
    }
  }

  Future<void> _tick() async {
    final jetzt = _jetzt();
    final lauf = _lauf;
    // Ablauf der eigenen Freigabe (der Server beendet sie ebenfalls)
    if (state.phase == StandortPhase.teilt && state.endetAt != null && !state.endetAt!.isAfter(jetzt)) {
      await beenden(grund: 'Das Teilen ist abgelaufen.');
      return;
    }
    // Ruhe: die letzte Position wiederholen, damit die anderen sehen, dass es noch aktuell ist
    if (lauf == _lauf && state.phase == StandortPhase.teilt && _letzterVersandZeit != null && jetzt.difference(_letzterVersandZeit!) >= _sendeTakt.ruhe) {
      await _senden();
    }
    // abgelaufene Freigaben anderer verschwinden (keine Historie)
    final alt = state.geteilt;
    final neu = {
      for (final e in alt.entries)
        if (!e.value.abgelaufen(jetzt)) e.key: e.value,
    };
    if (neu.length != alt.length) {
      for (final id in alt.keys.where((id) => !neu.containsKey(id))) {
        final e = _empfang.remove(id);
        if (e != null) _merkeBeendet(e);
        e?.vergessen();
      }
      state = state.kopie(geteilt: neu);
    }
  }

  /// Verlängert die laufende Freigabe um [um] (höchstens bis zur Höchstdauer ab jetzt).
  Future<void> verlaengern(Duration um) async {
    final sender = _sender;
    if (sender == null || state.phase != StandortPhase.teilt) return;
    final jetzt = _jetzt();
    final basis = state.endetAt != null && state.endetAt!.isAfter(jetzt) ? state.endetAt! : jetzt;
    var ende = basis.add(um);
    final deckel = jetzt.add(kStandortHoechstdauer);
    if (ende.isAfter(deckel)) ende = deckel;
    if (!ende.isAfter(state.endetAt ?? jetzt)) return;
    sender.verlaengern(ende.millisecondsSinceEpoch);
    state = state.kopie(endetAt: ende);
    await _port.verlaengern(ende);
    _socket?.senden({'type': 'loc_extend', 'shareId': _shareId, 'endsAt': ende.millisecondsSinceEpoch});
  }

  /// Beendet das Teilen (Tipp, Benachrichtigung, Ablauf, Server). Ohne Rückfrage; die Empfänger erfahren es.
  Future<void> beenden({String? grund, bool dienstStoppen = true, bool serverInformieren = true}) async {
    if (state.phase == StandortPhase.aus && _sender == null) return;
    _lauf++;
    final shareId = _shareId;
    _startFrist?.cancel();
    _startFrist = null;
    _herzschlag?.cancel();
    _herzschlag = null;
    if (serverInformieren && shareId != null) _socket?.senden({'type': 'loc_stop', 'shareId': shareId});
    _sender?.vergessen();
    _sender = null;
    _shareId = null;
    _letzteGesendet = null;
    _letzterVersandZeit = null;
    state = state.kopie(phase: StandortPhase.aus, endeLoeschen: true, empfaenger: const {}, ausgelassen: const {}, eigeneLoeschen: true, meldung: grund, meldungLoeschen: grund == null);
    if (dienstStoppen) await _port.stoppen();
    if (!_vordergrund) _trennen();
  }

  // ------------------------------------------------------------------ Positionen des Geräts

  void _beiGeraetEreignis(StandortEreignis e) {
    switch (e) {
      case PositionEreignis(:final position):
        unawaited(_eigenePosition(position));
      case StopEreignis():
        if (state.teilt) unawaited(beenden(grund: 'Du hast das Teilen beendet.', dienstStoppen: false));
      case DienstEreignis(:final an):
        state = state.kopie(ortungAus: !an);
      case FehlerEreignis():
        if (state.teilt) unawaited(beenden(grund: 'Das Teilen konnte nicht laufen. Prüfe die Erlaubnis für den Standort und versuche es noch einmal.', dienstStoppen: false));
    }
  }

  Future<void> _eigenePosition(GeraetePosition p) async {
    if (state.phase == StandortPhase.aus) return;
    state = state.kopie(eigene: p, ortungAus: false);
    if (state.phase != StandortPhase.teilt) return;
    final jetzt = _jetzt();
    final letzte = _letzteGesendet;
    final zeit = _letzterVersandZeit;
    if (letzte != null && zeit != null) {
      final seit = jetzt.difference(zeit);
      // Android liefert Messungen oft knapp vor Ablauf des Intervalls: ohne Toleranz würde jede zweite verworfen (halbe Rate)
      if (seit < _sendeTakt.intervall - kStandortTaktToleranz) return;
      final bewegt = abstandMeter(letzte.breite, letzte.laenge, p.breite, p.laenge) >= bewegungsSchwelle(p.genauigkeit);
      if (!bewegt && seit < _sendeTakt.ruhe) return;
    }
    await _senden();
  }

  /// Wie viel früher als das Intervall eine Messung noch gesendet wird.
  static const kStandortTaktToleranz = Duration(milliseconds: 500);

  Future<void> _senden() async {
    final sender = _sender;
    final p = state.eigene;
    final shareId = _shareId;
    if (sender == null || p == null || shareId == null || state.phase != StandortPhase.teilt) return;
    final jetzt = _jetzt();
    final String paket;
    try {
      paket = sender.paket(breite: p.breite, laenge: p.laenge, genauigkeit: p.genauigkeit, jetzt: jetzt, messzeit: p.zeit);
    } on CryptoFehler {
      return;
    }
    if (_socket?.senden({'type': 'loc_pos', 'shareId': shareId, 'packet': paket}) != true) return; // offline: nichts puffern
    _letzteGesendet = p;
    _letzterVersandZeit = jetzt;
    state = state.kopie(letzterVersand: jetzt);
  }

  // ------------------------------------------------------------------ Nachrichten des Servers

  void _beiNachricht(Map<String, Object?> m) {
    if (!_aktiv) return;
    switch (m['type']) {
      case 'loc_started':
      case 'loc_active':
        if (m['shareId'] == _shareId) {
          final x = m['endsAt'];
          if (state.phase == StandortPhase.startet) {
            _gestartet(x is int ? x : null);
          } else if (x is int && state.phase == StandortPhase.teilt) {
            state = state.kopie(endetAt: DateTime.fromMillisecondsSinceEpoch(x));
          }
        }
      case 'loc_error':
        if (m['shareId'] == _shareId && _shareId != null) {
          final code = m['code'];
          if (code == 'rate_limited') return; // nur eine übersprungene Position
          if (code == 'unknown_share') {
            unawaited(beenden(grund: 'Das Teilen ist beendet.', serverInformieren: false));
          } else if (state.phase == StandortPhase.startet) {
            unawaited(beenden(grund: _kMeldungAbgelehnt, serverInformieren: false));
          }
        }
      case 'loc_start':
        _inKette(m, () => _empfangStart(m));
      case 'loc_pos':
        _inKette(m, () => _empfangPosition(m));
      case 'loc_extend':
        _inKette(m, () => _empfangVerlaengert(m));
      case 'loc_stop':
        _inKette(m, () => _empfangStop(m));
    }
  }

  /// Nachrichten eines Absenders der Reihe nach: das Öffnen des Wraps ist asynchron, ein danach eintreffendes loc_pos oder loc_stop darf es nicht überholen
  /// (sonst ginge die erste Position verloren oder es bliebe ein Eintrag nach dem Stopp stehen).
  final Map<String, Future<void>> _kette = {};

  void _inKette(Map<String, Object?> m, FutureOr<void> Function() f) {
    final von = m['from'];
    if (von is! String) return;
    final vorher = _kette[von] ?? Future<void>.value();
    late Future<void> neu;
    neu = vorher.then((_) => f()).catchError((Object _) {}).whenComplete(() {
      if (identical(_kette[von], neu)) _kette.remove(von);
    });
    _kette[von] = neu;
  }

  void _empfangVerlaengert(Map<String, Object?> m) {
    final von = m['from'];
    final shareId = m['shareId'];
    final x = m['endsAt'];
    final e = von is String ? _empfang[von] : null;
    final eintrag = von is String ? state.geteilt[von] : null;
    if (von is! String || shareId is! String || x is! int || e == null || eintrag == null || e.shareId != shareId) return;
    // nur vorwärts und nie über die Höchstdauer; maßgeblich bleibt das signierte Ende in den Paketen
    final jetzt = _jetzt();
    var ende = DateTime.fromMillisecondsSinceEpoch(x);
    final deckel = jetzt.add(kStandortHoechstdauer);
    if (ende.isAfter(deckel)) ende = deckel;
    if (!ende.isAfter(eintrag.endetAt)) return;
    e.freigabeEnde = ende;
    state = state.kopie(geteilt: {...state.geteilt, von: eintrag.mitEnde(ende)});
  }

  Future<void> _empfangStart(Map<String, Object?> m) async {
    final von = m['from'];
    final shareId = m['shareId'];
    final wrap = m['wrap'];
    final endsAt = m['endsAt'];
    final ich = _ich;
    if (von is! String || shareId is! String || wrap is! String || endsAt is! int || ich == null || von == ich) return;
    final jetztZeit = _jetzt();
    _beendet.removeWhere((_, ende) => !ende.isAfter(jetztZeit));
    if (_beendet.containsKey(shareId)) return; // schon beendet
    final vorhanden = _empfang[von];
    if (vorhanden != null && vorhanden.shareId == shareId) return; // Nachreichung nach dem Wiederverbinden
    final jetzt = _jetzt();
    var ende = DateTime.fromMillisecondsSinceEpoch(endsAt);
    final deckel = jetzt.add(kStandortHoechstdauer);
    if (ende.isAfter(deckel)) ende = deckel;
    void ungeprueft() {
      _empfang.remove(von)?.vergessen();
      state = state.kopie(geteilt: {...state.geteilt, von: GeteiltePosition(userId: von, shareId: shareId, endetAt: ende, ungeprueft: true)});
      unawaited(_hinweis(von, shareId, ende));
    }

    try {
      final keys = await ref.read(standortSchluesselProvider)();
      if (keys == null || !_aktiv || _ich != ich) return;
      final sender = await keys.gemerkt(von);
      if (sender == null) return ungeprueft();
      final e = StandortEmpfaenger.annehmen(
        keys.crypto,
        wrapText: wrap,
        erwarteteShareId: shareId,
        erwarteterSenderId: von,
        ichId: keys.ichId,
        meinSchluessel: keys.schluessel,
        meineKeyVersion: keys.keyVersion,
        sender: sender,
        jetzt: jetzt,
      );
      final alt = _empfang.remove(von);
      if (alt != null) _merkeBeendet(alt);
      alt?.vergessen();
      _empfang[von] = e;
      state = state.kopie(geteilt: {...state.geteilt, von: GeteiltePosition(userId: von, shareId: shareId, endetAt: e.freigabeEnde)});
      unawaited(_hinweis(von, shareId, e.freigabeEnde));
    } on CryptoFehler {
      ungeprueft();
    } catch (_) {
      ungeprueft();
    }
  }

  /// Neue Freigabe einer anderen Person: Hinweis (im Hintergrund als System-Benachrichtigung, im Vordergrund dezent in der App). Je Freigabe nur einmal.
  Future<void> _hinweis(String von, String shareId, DateTime ende) async {
    try {
      final erg = await ref.read(standortBenachrichtigerProvider).freigabe(von: von, shareId: shareId, endsAt: ende);
      if (erg == HinweisErgebnis.vordergrund && ref.mounted) ref.read(standortHinweisProvider.notifier).melden(von);
    } catch (_) {
      // Zusatz: ein Fehler hier darf den Empfang nicht stören
    }
  }

  void _empfangPosition(Map<String, Object?> m) {
    final von = m['from'];
    final shareId = m['shareId'];
    final paket = m['packet'];
    if (von is! String || shareId is! String || paket is! String) return;
    final e = _empfang[von];
    if (e == null || e.shareId != shareId) return;
    final jetzt = _jetzt();
    try {
      final inhalt = e.oeffnen(paket, jetzt: jetzt);
      state = state.kopie(
        geteilt: {
          ...state.geteilt,
          von: (state.geteilt[von] ?? GeteiltePosition(userId: von, shareId: shareId, endetAt: inhalt.freigabeEnde)).mitPosition(
            breite: inhalt.breite,
            laenge: inhalt.laenge,
            genauigkeit: inhalt.genauigkeit,
            messzeit: inhalt.zeit,
            endetAt: inhalt.freigabeEnde,
          ),
        },
      );
    } on StandortPaketAbgelehnt {
      // wiederholt oder veraltet: still verwerfen
    } on CryptoFehler {
      // beschädigt oder nicht von dieser Person: verwerfen
    }
  }

  void _empfangStop(Map<String, Object?> m) {
    final von = m['from'];
    final shareId = m['shareId'];
    if (von is! String || shareId is! String) return;
    if (shareId == _shareId && von == _ich) {
      // der Server hat meine Freigabe beendet (Ablauf, Ersetzen, Entfernen)
      unawaited(beenden(grund: 'Das Teilen ist beendet.', serverInformieren: false));
      return;
    }
    final e = _empfang[von];
    final eintrag = state.geteilt[von];
    if (eintrag == null || eintrag.shareId != shareId) return;
    try {
      unawaited(ref.read(standortBenachrichtigerProvider).beendet(von));
    } catch (_) {
      // Zusatz (Benachrichtigung entfernen): nie den Empfang stören
    }
    if (e != null && e.shareId == shareId) {
      _merkeBeendet(e);
      _empfang.remove(von)?.vergessen();
    }
    state = state.kopie(geteilt: {
      for (final x in state.geteilt.entries)
        if (x.key != von) x.key: x.value,
    });
  }

  // ------------------------------------------------------------------ Aufräumen

  Future<void> _zuruecksetzen() async {
    final war = state.teilt;
    if (war) await beenden(dienstStoppen: true);
    for (final e in _empfang.values) {
      e.vergessen();
    }
    _empfang.clear();
    _beendet.clear();
    _ich = ref.read(authProvider).user?.id;
    state = const StandortState();
    if (_ich == null) {
      _aktiv = false;
      _takt?.cancel();
      _takt = null;
      _socket?.stop();
      _socket = null;
      await _ereignisSub?.cancel();
      _ereignisSub = null;
    }
  }

  void _aufraeumen() {
    _aktiv = false;
    _takt?.cancel();
    _herzschlag?.cancel();
    _startFrist?.cancel();
    _ereignisSub?.cancel();
    _socket?.stop();
    _socket = null;
    // der Vordergrunddienst darf nicht ohne die Oberfläche weiterlaufen (hier kein Zugriff auf den Zustand: das ist beim Abbau nicht erlaubt)
    if (_sender != null) unawaited(_port.stoppen());
    _sender?.vergessen();
    _sender = null;
    for (final e in _empfang.values) {
      e.vergessen();
    }
    _empfang.clear();
  }
}

final standortProvider = NotifierProvider<StandortController, StandortState>(StandortController.new);

/// Namen und Farben der Mitglieder für die Anzeige (aus dem Zwischenspeicher der Mitgliederliste).
final standortMitgliederProvider = Provider<Map<String, UserDto>>((ref) => {for (final u in ref.watch(mitgliederProvider).value ?? const <UserDto>[]) u.id: u});
