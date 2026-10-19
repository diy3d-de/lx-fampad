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
  bool get beschaeftigt => status == SyncStatus.laeuft || offeneAenderungen > 0;

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

final syncEngineProvider = Provider<SyncEngine>((ref) {
  return SyncEngine(
    store: ref.watch(syncStoreProvider),
    api: ref.watch(apiProvider),
    geraeteId: () async {
      final aus = ref.read(authProvider).me?.sessionDeviceId;
      if (aus != null && aus.isNotEmpty) return aus;
      return ref.read(tokenStoreProvider).readDeviceId();
    },
  );
});

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
  int _hinweisId = 0;
  int _bekannteRev = 0;
  int _geraetVersuche = 0;

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
    _fehlversuche = 0;
    _geraetVersuche = 0;
    _offenSub = ref.read(syncStoreProvider).offeneAenderungen().listen((n) {
      if (_aktiv) state = state.copyWith(offeneAenderungen: n);
    });
    state = state.copyWith(status: SyncStatus.synchron, live: false, meldungLoeschen: true);
    _vordergrundStarten();
    unawaited(synchronisieren());
  }

  /// Beendet den Dienst (Abmelden, Sitzungsverlust). Die lokalen Daten und der Ausgang bleiben unberührt.
  /// [zustandAendern] false: nur Zeitgeber und Socket anhalten (beim Abbau des Widget-Baums darf kein Zustand geändert werden).
  void stoppen({bool zustandAendern = true}) {
    if (!_aktiv) return;
    _aktiv = false;
    _aufraeumen();
    if (zustandAendern) state = state.copyWith(status: SyncStatus.getrennt, live: false, meldungLoeschen: true);
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
  void vordergrund(bool vorn) {
    if (_vordergrund == vorn) return;
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
        if (rev > _bekannteRev) unawaited(synchronisieren());
      },
      beiStatus: (live) {
        if (_aktiv && state.live != live) state = state.copyWith(live: live);
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
    final lauf = ref.read(syncEngineProvider).abgleichen();
    _laeuft = lauf;
    final SyncErgebnis e;
    try {
      e = await lauf;
    } finally {
      _laeuft = null;
    }
    if (!_aktiv) return;
    _ergebnis(e);
    if (_nochmal) {
      _nochmal = false;
      if (e.ok && _aktiv) await synchronisieren();
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
        _geraetVersuche = 0;
        _backoffTimer?.cancel();
        _backoffTimer = null;
        if (e.rev > _bekannteRev) _bekannteRev = e.rev;
        state = state.copyWith(status: SyncStatus.synchron, letzterAbgleich: DateTime.now(), meldungLoeschen: true, hinweise: hinweise);
      case SyncAusgang.sitzungVerloren:
        // kein Wiederholen: der Auth-Zustand führt zur Anmeldung; nach erneuter Anmeldung startet HomeShell den Dienst neu
        state = state.copyWith(status: SyncStatus.getrennt, meldungLoeschen: true, hinweise: hinweise);
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
      case SyncAusgang.offline:
        state = state.copyWith(status: SyncStatus.offline, meldung: e.meldung, hinweise: hinweise);
        _backoffPlanen(e);
      case SyncAusgang.ueberlastet || SyncAusgang.fehler:
        state = state.copyWith(status: SyncStatus.fehler, meldung: e.meldung, hinweise: hinweise);
        _backoffPlanen(e);
    }
  }

  /// Nächster Versuch nach 2 s, 4 s, 8 s ... höchstens 5 min (mit ±50 % Zufall); bei 429/503 mindestens die Wartezeit des Servers.
  void _backoffPlanen(SyncErgebnis e, {bool kurz = false}) {
    if (!_aktiv) return;
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

/// Fehlermeldung für die Anzeige (nie Interna).
String syncMeldungFuer(SyncState s) {
  switch (s.status) {
    case SyncStatus.offline:
      return 'Offline – Änderungen werden später abgeglichen.';
    case SyncStatus.fehler:
      return s.meldung ?? 'Der Abgleich ist fehlgeschlagen.';
    case SyncStatus.updateNoetig:
      return 'Bitte aktualisiere die App.';
    default:
      return '';
  }
}
