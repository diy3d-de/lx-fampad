// Sync-Dienst der App: entscheidet WANN abgeglichen wird und hält den Zustand für den Sync-Indikator.
//
// Auslöser: Start, Rückkehr in die App, nach lokalen Änderungen (entprellt, 2 s), Hinweis "neue Revision" über den WebSocket,
// alle paar Minuten, Antippen des Indikators und Herunterziehen. Es läuft immer höchstens ein Abgleich; kommt währenddessen ein
// weiterer Auslöser, folgt genau ein weiterer Lauf. Fehler (offline, Server, Überlast) lösen einen Backoff mit Zufallsanteil aus;
// 401 beendet die Schleife (der Auth-Zustand führt zur Anmeldung), 426 zeigt die Update-Seite.
// WAS abgeglichen wird, steht in data/sync/ (Store, Engine, Socket). Die Oberfläche wartet nie auf den Server.
import 'dart:async';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/update/update_service.dart';
import 'auth/auth_state.dart';
import 'database_provider.dart';
import 'dateien/transfer_dienst.dart' show dateiCacheDienstProvider, transferDienstProvider;
import 'erinnerungen/erinnerung_dienst.dart';
import 'heute_widget/heute_widget_dienst.dart';
import 'standort/standort_hinweis.dart';
import 'startseite/startseite_state.dart';
import 'countdown/countdown_state.dart';
import 'chat/chat_krypto_state.dart';
import 'sync/sync_engine.dart';
import 'sync/sync_socket.dart';
import 'sync/sync_store.dart';

enum SyncStatus {
  /// Nicht angemeldet bzw. Dienst nicht gestartet.
  getrennt,
  laeuft,
  synchron,

  /// Kein Netz oder Server nicht erreichbar: Änderungen bleiben lokal und gehen später raus.
  offline,
  fehler,

  /// Die App ist für den Server zu alt (Pflicht-Update).
  updateNoetig,

  /// Wartungsmodus des Betreibers: der Server nimmt vorübergehend nichts an; Änderungen bleiben lokal und gehen danach raus.
  wartung,
}

/// Hinweis für die Person (z. B. Eintrag anderswo gelöscht); bleibt stehen, bis sie ihn schließt.
class SyncMeldung {
  final int id;
  final String text;
  const SyncMeldung(this.id, this.text);
}

class SyncState {
  final SyncStatus status;
  final int offeneAenderungen;
  final DateTime? letzterAbgleich;
  final String? meldung;
  final List<SyncMeldung> hinweise;

  /// WebSocket verbunden: Änderungen anderer Geräte erscheinen binnen Sekunden.
  final bool live;

  const SyncState({
    this.status = SyncStatus.getrennt,
    this.offeneAenderungen = 0,
    this.letzterAbgleich,
    this.meldung,
    this.hinweise = const [],
    this.live = false,
  });

  /// Während eines Abgleichs oder mit offenen Änderungen darf kein App-Update installiert werden.
  bool get beschaeftigt => status == SyncStatus.laeuft || (offeneAenderungen > 0 && status != SyncStatus.fehler);

  SyncState copyWith({
    SyncStatus? status,
    int? offeneAenderungen,
    DateTime? letzterAbgleich,
    String? meldung,
    bool meldungLoeschen = false,
    List<SyncMeldung>? hinweise,
    bool? live,
  }) => SyncState(
    status: status ?? this.status,
    offeneAenderungen: offeneAenderungen ?? this.offeneAenderungen,
    letzterAbgleich: letzterAbgleich ?? this.letzterAbgleich,
    meldung: meldungLoeschen ? null : (meldung ?? this.meldung),
    hinweise: hinweise ?? this.hinweise,
    live: live ?? this.live,
  );
}

/// Zeiten des Sync (in Tests kürzer).
class SyncZeiten {
  final Duration entprellen;
  final Duration periodisch;
  final Duration backoffStart;
  final Duration backoffMax;
  const SyncZeiten({
    this.entprellen = const Duration(seconds: 2),
    this.periodisch = const Duration(minutes: 3),
    this.backoffStart = const Duration(seconds: 2),
    this.backoffMax = const Duration(minutes: 5),
  });
}

final syncZeitenProvider = Provider<SyncZeiten>((ref) => const SyncZeiten());

/// Zufall für den Backoff (in Tests festlegbar).
final syncZufallProvider = Provider<Random>((ref) => Random());

/// Öffnet den WebSocket (null: echter Socket; in Tests ein Fake).
final syncSocketOeffnerProvider = Provider<SocketOeffner?>((ref) => null);

final syncStoreProvider = Provider<SyncStore>((ref) => SyncStore(ref.watch(appDatabaseProvider)));

/// Abgelehnte, nicht gesendete Änderungen im Ausgang (live; nur für die Warnung vor dem Abmelden).
final abgelehnteAenderungenProvider = StreamProvider.autoDispose<int>((ref) => ref.watch(syncStoreProvider).abgelehnteAenderungen());

/// Bereitet Ops vor dem Senden vor (Chat: verschlüsselt). Der Hintergrund-Abgleich eines Push-Weckers setzt hier null: dort gibt es keine Chat-Verschlüsselung
/// (kein Schlüsselbund, keine Controller); Chat-Klartext im Ausgang bleibt dann liegen und geht erst beim nächsten Start der App hinaus.
final opVorbereiterProvider = Provider<OpVorbereiter?>(
  (ref) => ChatOpVorbereiter(db: ref.watch(appDatabaseProvider), krypto: () => ref.read(chatKryptoProvider.notifier).krypto()),
);

final syncEngineProvider = Provider<SyncEngine>((ref) {
  return SyncEngine(
    store: ref.watch(syncStoreProvider),
    api: ref.watch(apiProvider),
    // Chat: Klartext im Ausgang wird erst beim Senden verschlüsselt (mit der dann aktuellen Epoche)
    vorbereiter: ref.watch(opVorbereiterProvider),
    geraeteId: () async {
      final aus = ref.read(authProvider).me?.sessionDeviceId;
      if (aus != null && aus.isNotEmpty) return aus;
      return ref.read(tokenStoreProvider).readDeviceId();
    },
  );
});

/// Zählt die Hinweise des Servers "Mitglieder geändert" (WebSocket `members_changed`); [mitgliederAktualisierungProvider] lädt dann die Liste neu.
class MitgliederHinweis extends Notifier<int> {
  @override
  int build() => 0;
  void hinweis() => state++;
}

final mitgliederHinweisProvider = NotifierProvider<MitgliederHinweis, int>(MitgliederHinweis.new);

class SyncController extends Notifier<SyncState> {
  Timer? _entprellen;
  Timer? _periodisch;
  Timer? _backoffTimer;
  StreamSubscription<int>? _offenSub;
  SyncSocket? _socket;
  Future<SyncErgebnis>? _laeuft;
  bool _nochmal = false;
  bool _aktiv = false;
  bool _vordergrund = true;
  int _fehlversuche = 0;

  /// Aufeinanderfolgende Mengenlimit-Wartezeiten (429) ohne Fortschritt.
  int _limitFolge = 0;
  int _hinweisId = 0;
  int _bekannteRev = 0;

  /// Höchste per WebSocket gemeldete Revision, die während eines Laufs eintraf (der Lauf kennt sie womöglich noch nicht).
  int _gemeldeteRev = 0;

  /// Zählt Wechsel zwischen Vorder- und Hintergrund: ein Wechsel, der auf den Abgleich vor dem Hintergrund wartet, wird durch einen neueren überholt.
  int _wechsel = 0;
  int _geraetVersuche = 0;

  /// Zählt Starts und Stopps: eine Antwort, die erst nach dem Stopp eintrifft, wird nicht mehr in die Datenbank geschrieben.
  int _generation = 0;

  SyncZeiten get _zeiten => ref.read(syncZeitenProvider);

  @override
  SyncState build() {
    ref.onDispose(() {
      _aktiv = false; // Rückrufe des Sockets dürfen beim Abbau keinen Zustand mehr ändern
      _aufraeumen();
    });
    return const SyncState();
  }

  bool get aktiv => _aktiv;

  /// Startet den Dienst (nach der Anmeldung): Zähler der offenen Änderungen, Zeitgeber, WebSocket und ein erster Abgleich.
  void starten() {
    if (_aktiv) return;
    _aktiv = true;
    _generation++;
    _fehlversuche = 0;
    _limitFolge = 0;
    _geraetVersuche = 0;
    _bekannteRev = 0;
    _gemeldeteRev = 0;
    _nochmal = false;
    _offenSub = ref.read(syncStoreProvider).offeneAenderungen().listen((n) {
      if (_aktiv) state = state.copyWith(offeneAenderungen: n);
    });
    state = const SyncState(status: SyncStatus.synchron);
    _vordergrundStarten();
    unawaited(synchronisieren());
  }

  /// Beendet den Dienst (Abmelden, Sitzungsverlust). Die lokalen Daten und der Ausgang bleiben unberührt.
  /// [zustandAendern] false: nur Zeitgeber und Socket anhalten (beim Abbau des Widget-Baums darf kein Zustand geändert werden).
  void stoppen({bool zustandAendern = true}) {
    if (!_aktiv) return;
    _aktiv = false;
    _generation++;
    _aufraeumen();
    _bekannteRev = 0;
    _gemeldeteRev = 0;
    _nochmal = false;
    // nichts vom bisherigen Zustand (Hinweise, offene Änderungen, letzter Abgleich) überlebt das Abmelden oder einen Personenwechsel
    if (zustandAendern) state = const SyncState();
  }

  void _aufraeumen() {
    _entprellen?.cancel();
    _periodisch?.cancel();
    _backoffTimer?.cancel();
    _entprellen = _periodisch = _backoffTimer = null;
    _offenSub?.cancel();
    _offenSub = null;
    _socket?.stop();
    _socket = null;
  }

  /// App im Vordergrund (true) bzw. im Hintergrund (false): der WebSocket und die Zeitgeber laufen nur im Vordergrund.
  /// Vor dem Wechsel in den Hintergrund wird einmal abgeglichen, wenn Änderungen im Ausgang warten (im Hintergrund laufen keine Zeitgeber:
  /// sonst blieben sie bis zur Rückkehr liegen). Kehrt die App währenddessen zurück, gilt nur der neuere Wechsel.
  Future<void> vordergrund(bool vorn) async {
    final wechsel = ++_wechsel;
    if (_vordergrund == vorn) return;
    if (!vorn && _aktiv && (state.offeneAenderungen > 0 || await ref.read(syncStoreProvider).offeneAnzahl() > 0)) {
      _entprellen?.cancel();
      _entprellen = null;
      try {
        await synchronisieren();
      } catch (_) {
        // der Abgleich meldet Fehler selbst über den Zustand; hier zählt nur, dass der Wechsel weitergeht
      }
      if (wechsel != _wechsel) return;
    }
    _vordergrund = vorn;
    if (!_aktiv) return;
    if (vorn) {
      _vordergrundStarten();
      unawaited(synchronisieren());
    } else {
      _periodisch?.cancel();
      _periodisch = null;
      _entprellen?.cancel();
      _entprellen = null;
      _socket?.stop();
      _socket = null;
      state = state.copyWith(live: false);
    }
  }

  void _vordergrundStarten() {
    if (!_vordergrund || !_aktiv) return;
    _periodisch?.cancel();
    _periodisch = Timer.periodic(_zeiten.periodisch, (_) => unawaited(synchronisieren()));
    _socket?.stop();
    _socket = SyncSocket(
      ticket: () => ref.read(apiProvider).wsTicket(),
      beiRev: (rev) {
        if (rev <= _bekannteRev) return;
        // während eines Laufs: nur merken (der Hinweis auf die eigene Änderung käme sonst als Zusatzlauf; eine fremde Änderung
        // erkennt synchronisieren() danach daran, dass der Lauf die Revision nicht erreicht hat)
        if (_laeuft != null) {
          if (rev > _gemeldeteRev) _gemeldeteRev = rev;
          return;
        }
        unawaited(synchronisieren());
      },
      beiStatus: (live) {
        if (_aktiv && state.live != live) state = state.copyWith(live: live);
      },
      beiMitglieder: () {
        if (_aktiv) ref.read(mitgliederHinweisProvider.notifier).hinweis();
      },
      oeffner: ref.read(syncSocketOeffnerProvider),
      zufall: ref.read(syncZufallProvider),
      backoffStart: _zeiten.backoffStart ~/ 2,
    )..start();
  }

  /// Nach jeder lokalen Änderung aufrufen: gleicht nach kurzer Pause ab (mehrere Änderungen hintereinander ergeben einen Lauf).
  void lokaleAenderung() {
    if (!_aktiv) return;
    _entprellen?.cancel();
    _entprellen = Timer(_zeiten.entprellen, () => unawaited(synchronisieren()));
  }

  void hinweisSchliessen(int id) => state = state.copyWith(hinweise: [for (final h in state.hinweise) if (h.id != id) h]);

  /// Gleicht jetzt ab. [manuell]: auch während eines Backoffs (Antippen, Herunterziehen). Kehrt zurück, wenn der Lauf fertig ist.
  Future<void> synchronisieren({bool manuell = false}) async {
    if (!_aktiv) return;
    if (!manuell && _backoffTimer != null) return; // der Backoff löst den nächsten Versuch selbst aus
    final laufend = _laeuft;
    if (laufend != null) {
      _nochmal = true;
      await laufend;
      return;
    }
    if (manuell) {
      _backoffTimer?.cancel();
      _backoffTimer = null;
    }
    state = state.copyWith(status: SyncStatus.laeuft);
    final generation = _generation;
    final lauf = ref.read(syncEngineProvider).abgleichen(abgebrochen: () => !_aktiv || generation != _generation);
    _laeuft = lauf;
    final SyncErgebnis e;
    try {
      e = await lauf;
    } finally {
      if (identical(_laeuft, lauf)) _laeuft = null; // ein neuer Lauf nach Stopp und Neustart bleibt stehen
    }
    // gestoppt (oder gestoppt und neu gestartet): das Ergebnis gehört zu einer früheren Sitzung
    if (!_aktiv || generation != _generation) return;
    _ergebnis(e);
    final fremdeRev = e.ok && _gemeldeteRev > _bekannteRev; // ein Hinweis traf ein, den dieser Lauf nicht mehr erfasst hat
    if ((_nochmal || fremdeRev) && (e.ok || e.ausgang == SyncAusgang.abgebrochen)) {
      _nochmal = false;
      if (_aktiv) await synchronisieren();
    }
  }

  void _ergebnis(SyncErgebnis e) {
    var hinweise = state.hinweise;
    if (e.hinweise.isNotEmpty) {
      hinweise = [...hinweise, for (final h in e.hinweise) SyncMeldung(++_hinweisId, h.text)];
      if (hinweise.length > 5) hinweise = hinweise.sublist(hinweise.length - 5);
    }
    switch (e.ausgang) {
      case SyncAusgang.ok:
        _fehlversuche = 0;
        _limitFolge = 0;
        _geraetVersuche = 0;
        _backoffTimer?.cancel();
        _backoffTimer = null;
        if (e.rev > _bekannteRev) _bekannteRev = e.rev;
        state = state.copyWith(status: SyncStatus.synchron, letzterAbgleich: DateTime.now(), meldungLoeschen: true, hinweise: hinweise);
      case SyncAusgang.abgebrochen:
        // der Dienst wurde gestoppt (oder neu gestartet): nichts mehr zu melden, der nächste Lauf folgt von selbst
        state = state.copyWith(status: SyncStatus.synchron);
      case SyncAusgang.sitzungVerloren:
        // kein Wiederholen: der Auth-Zustand führt zur Anmeldung; der Dienst stoppt ganz (Zeitgeber, Socket, Zustand), damit er nach
        // erneuter Anmeldung (HomeShell startet ihn dann) sauber neu beginnt
        stoppen();
      case SyncAusgang.updateNoetig:
        // Pflicht-Update: Update-Seite statt App; Zeitgeber und Socket enden, bis die App aktualisiert und neu gestartet ist
        ref.read(updateProvider.notifier).pflichtSetzen();
        _aktiv = false;
        _aufraeumen();
        state = state.copyWith(status: SyncStatus.updateNoetig, live: false, meldung: e.meldung, hinweise: hinweise);
      case SyncAusgang.geraetFalsch:
        state = state.copyWith(status: SyncStatus.fehler, meldung: 'Dieses Gerät wird neu zugeordnet …', hinweise: hinweise);
        if (_geraetVersuche++ < 3) {
          unawaited(ref.read(authProvider.notifier).neuLaden().whenComplete(() => _backoffPlanen(e, kurz: true)));
        } else {
          _backoffPlanen(e);
        }
      case SyncAusgang.wartung:
        // kein Fehler: die Änderungen bleiben im Ausgang, der nächste Versuch kommt nach der Wartezeit des Servers (mindestens eine Minute, bis 5 Minuten)
        state = state.copyWith(status: SyncStatus.wartung, meldung: e.meldung, hinweise: hinweise);
        _backoffPlanen(e);
      case SyncAusgang.offline:
        state = state.copyWith(status: SyncStatus.offline, meldung: e.meldung, hinweise: hinweise);
        _backoffPlanen(e);
      case SyncAusgang.ueberlastet when e.mengenlimit:
        // Mengenlimit mit Wartezeit (z. B. großer Import): läuft nach der Wartezeit weiter. Bei langer Wartezeit oder vielen Wiederholungen
        // ohne Fortschritt wird es nicht still als "läuft" gezeigt, sondern als Hinweis (und blockiert dann kein App-Update).
        _limitFolge = e.ops > 0 ? 1 : _limitFolge + 1;
        final sek = _limitWartezeit(e).inSeconds;
        final lang = sek > 60 || _limitFolge > 5;
        // Retry-After von 30 Minuten und mehr ist das Tageslimit des Servers (Retry-After 3600): das heißt "heute nicht mehr"
        final roh = e.warten?.inSeconds ?? 0;
        final meldung = roh >= 1800
            ? 'Tageslimit für Änderungen erreicht: der Server nimmt vorerst nichts mehr an (weiter in etwa ${roh >= 5400 ? '${(roh / 3600).round()} Std.' : '${(roh / 60).round()} Min.'}). Deine Änderungen bleiben gespeichert.'
            : 'Der Server bremst gerade (zu viele Anfragen). Nächster Versuch in $sek s.';
        state = lang
            ? state.copyWith(status: SyncStatus.fehler, meldung: meldung, hinweise: hinweise)
            : state.copyWith(status: SyncStatus.laeuft, meldungLoeschen: true, hinweise: hinweise);
        _backoffPlanen(e);
      case SyncAusgang.ueberlastet || SyncAusgang.fehler:
        state = state.copyWith(status: SyncStatus.fehler, meldung: e.meldung, hinweise: hinweise);
        _backoffPlanen(e);
    }
  }

  /// Wartezeit bei einem Mengenlimit: die Angabe des Servers, mindestens der Backoff-Start (kein Dauerlauf bei Retry-After 0), höchstens 5 min.
  Duration _limitWartezeit(SyncErgebnis e) {
    final minSek = _zeiten.backoffStart.inSeconds < 1 ? 1 : _zeiten.backoffStart.inSeconds;
    return Duration(seconds: (e.warten?.inSeconds ?? 0).clamp(minSek, 300));
  }

  /// Nächster Versuch nach 2 s, 4 s, 8 s ... höchstens 5 min (mit ±50 % Zufall); bei 429/503 mindestens die Wartezeit des Servers.
  void _backoffPlanen(SyncErgebnis e, {bool kurz = false}) {
    if (!_aktiv) return;
    // Mengenlimit des Servers (429 mit Retry-After, z. B. bei einem großen Import): genau so lange warten wie genannt (plus bis zu 1 s Zufall)
    // und nicht hochschaukeln, sonst dauert ein Import mit vielen Änderungen ein Vielfaches der nötigen Zeit.
    if (e.mengenlimit) {
      final warte = _limitWartezeit(e) + Duration(milliseconds: 250 + (ref.read(syncZufallProvider).nextDouble() * 750).round());
      _backoffTimer?.cancel();
      _backoffTimer = Timer(warte, () {
        _backoffTimer = null;
        unawaited(synchronisieren());
      });
      return;
    }
    // Wartung des Betreibers: fester Takt (Wartezeit des Servers plus bis zu 30 s Zufall, damit nicht alle Geräte gleichzeitig kommen), kein Hochschaukeln des Fehler-Backoffs
    // (nach dem Ende der Wartung soll es zügig weitergehen, nicht erst nach Minuten)
    if (e.ausgang == SyncAusgang.wartung) {
      final basisSek = (e.warten?.inSeconds ?? 60).clamp(5, 300);
      final warte = Duration(seconds: basisSek, milliseconds: (ref.read(syncZufallProvider).nextDouble() * 30000).round());
      _backoffTimer?.cancel();
      _backoffTimer = Timer(warte, () {
        _backoffTimer = null;
        unawaited(synchronisieren());
      });
      return;
    }
    _fehlversuche++;
    final basis = min(_zeiten.backoffMax.inMilliseconds, _zeiten.backoffStart.inMilliseconds * pow(2, min(_fehlversuche - 1, 16)).toInt());
    var warte = Duration(milliseconds: kurz ? _zeiten.backoffStart.inMilliseconds : (basis * (0.5 + ref.read(syncZufallProvider).nextDouble())).round());
    if (e.warten != null && e.warten! > warte) warte = e.warten!;
    _backoffTimer?.cancel();
    _backoffTimer = Timer(warte, () {
      _backoffTimer = null;
      unawaited(synchronisieren());
    });
  }
}

final syncProvider = NotifierProvider<SyncController, SyncState>(SyncController.new);

/// Für localDataWiperProvider (main.dart): hält den Sync an und löscht dann alle lokalen Daten (Listen, Ausgang, Sync-Zustand). Der Stopp
/// kommt zuerst, damit eine noch laufende Antwort des Servers nicht in die geleerte Datenbank geschrieben wird.
Future<void> Function() lokaleDatenWiper(Ref ref) => () async {
  ref.read(syncProvider.notifier).stoppen();
  // Terminerinnerungen des Geräts gehören zu den lokalen Daten: weg damit (fehlerfrei, ein Problem hier darf das Leeren nicht stoppen)
  try {
    await ref.read(erinnerungDienstProvider).alleEntfernen();
  } catch (_) {}
  // die Zusammenfassung für das Startbildschirm-Widget (Titel, Aufgaben, Einkauf) bleibt nicht auf dem Gerät liegen
  try {
    await ref.read(heuteWidgetDienstProvider).loeschen();
  } catch (_) {}
  // schon gezeigte Standort-Benachrichtigungen (Name der teilenden Person) bleiben nicht auf dem Gerät stehen
  try {
    await ref.read(standortBenachrichtigerProvider).alleEntfernen();
  } catch (_) {}
  // laufende Übertragungen der Dateiablage enden, heruntergeladene Dateien (Offline-Kopien, Teil-Dateien) und angefangene Uploads bleiben nicht auf dem Gerät liegen; der Dienst entsteht danach neu
  try {
    await ref.read(transferDienstProvider).beenden();
    await ref.read(dateiCacheDienstProvider).alleLoeschen().timeout(const Duration(seconds: 10));
  } catch (_) {}
  ref.invalidate(transferDienstProvider);
  await ref.read(appDatabaseProvider).alleDatenLoeschen();
  // die gemerkte Reihenfolge der Startseite lag in sync_meta und ist weg: der Zustand im Arbeitsspeicher liest neu (Standard), die nächste Person erbt sie nicht
  ref.invalidate(startseiteMobilProvider);
  ref.invalidate(startseiteDesktopProvider);
  ref.invalidate(countdownTermineProvider);
};

/// Fehlermeldung für die Anzeige (nie Interna).
String syncMeldungFuer(SyncState s) {
  switch (s.status) {
    case SyncStatus.offline:
      return 'Offline – Änderungen werden später übertragen.';
    case SyncStatus.fehler:
      return s.meldung ?? 'Das Übertragen hat nicht geklappt.';
    case SyncStatus.updateNoetig:
      return 'Bitte aktualisiere die App.';
    case SyncStatus.wartung:
      return 'Wartung – Änderungen werden danach übertragen.';
    default:
      return '';
  }
}
