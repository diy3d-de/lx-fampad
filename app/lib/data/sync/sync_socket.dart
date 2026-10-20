// WebSocket-Client: hält im Vordergrund eine Verbindung zu /ws und meldet dem Sync "neue Revision N" (ohne Inhalt).
//
// Ablauf: Ticket holen (POST /ws-ticket, Einmal-Ticket), Verbindung öffnen, als erste Nachricht {type:auth, ticket} senden, auf
// {type:ready} warten. Ping/Pong alle 25 s; bleibt das Pong aus, wird neu verbunden. Bricht die Verbindung ab, folgt ein Neuaufbau mit
// wachsendem Abstand und Zufallsanteil (Backoff + Jitter). Schließcode 4401 heißt "nicht (mehr) angemeldet": dann wird zuerst über das
// Ticket geprüft, ob die Sitzung noch gilt (ein 401 dort beendet die Sitzung über den ApiClient, der Socket gibt dann auf).
// Der Socket ist nur eine Beschleunigung: ohne ihn gleicht der Sync trotzdem regelmäßig ab.
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../../constants.dart';
import '../api/api_error.dart';

/// Öffnet eine Verbindung (in Tests austauschbar).
typedef SocketOeffner = WebSocketChannel Function(Uri uri);

WebSocketChannel _echterSocket(Uri uri) => WebSocketChannel.connect(uri);

/// Adresse des WebSockets: im Web die eigene Domain, auf Android aus API_BASE; immer ws:// bzw. wss:// passend zum Schema.
Uri webSocketAdresse({String api = kApiBase, Uri? seite}) {
  final basis = api.isEmpty ? (seite ?? Uri.base) : Uri.parse(api);
  final secure = basis.scheme == 'https' || basis.scheme == 'wss';
  return Uri(scheme: secure ? 'wss' : 'ws', host: basis.host, port: basis.hasPort ? basis.port : null, path: '/ws');
}

class SyncSocket {
  final Future<String> Function() ticket;
  final void Function(int rev) beiRev;
  final void Function(bool live) beiStatus;

  /// Weitere Nachrichten des Servers, die der Sync nicht selbst auswertet (Standort teilen: `loc_*`); sonst null.
  final void Function(Map<String, Object?> nachricht)? beiNachricht;
  final SocketOeffner _oeffner;
  final Random _zufall;
  final Duration pingAbstand;
  final Duration pongFrist;
  final Duration backoffStart;
  final Duration backoffMax;
  final Uri Function() _adresse;

  SyncSocket({
    required this.ticket,
    required this.beiRev,
    required this.beiStatus,
    this.beiNachricht,
    SocketOeffner? oeffner,
    Random? zufall,
    Uri Function()? adresse,
    this.pingAbstand = const Duration(seconds: 25),
    this.pongFrist = const Duration(seconds: 10),
    this.backoffStart = const Duration(seconds: 1),
    this.backoffMax = const Duration(seconds: 60),
  }) : _oeffner = oeffner ?? _echterSocket,
       _zufall = zufall ?? Random(),
       _adresse = adresse ?? webSocketAdresse;

  bool _aktiv = false;
  bool _live = false;
  int _versuche = 0;
  int _unangemeldet = 0; // aufeinanderfolgende Schließcodes 4401
  int _lauf = 0; // erhöht bei jedem Start/Stopp: späte Ereignisse alter Verbindungen werden verworfen
  WebSocketChannel? _kanal;
  Timer? _neuTimer;
  Timer? _pingTimer;
  Timer? _pongTimer;

  bool get live => _live;
  bool get aktiv => _aktiv;

  /// Anzahl der Verbindungsversuche seit dem letzten erfolgreichen Aufbau (Tests).
  int get versuche => _versuche;

  void start() {
    if (_aktiv) return;
    _aktiv = true;
    _versuche = 0;
    unawaited(_verbinden(++_lauf));
  }

  void stop() {
    _aktiv = false;
    _lauf++;
    _neuTimer?.cancel();
    _neuTimer = null;
    _abbauen();
    _setLive(false);
  }

  void _setLive(bool v) {
    if (_live == v) return;
    _live = v;
    beiStatus(v);
  }

  void _abbauen() {
    _pingTimer?.cancel();
    _pongTimer?.cancel();
    _pingTimer = _pongTimer = null;
    final k = _kanal;
    _kanal = null;
    if (k != null) {
      try {
        unawaited(k.sink.close().catchError((Object _) {}));
      } catch (_) {
        // schon geschlossen
      }
    }
  }

  /// Abstand bis zum nächsten Versuch: Start * 2^n, höchstens [backoffMax], mit ±50 % Zufall (Jitter).
  Duration abstand(int versuch) {
    final basis = min(backoffMax.inMilliseconds, backoffStart.inMilliseconds * pow(2, min(versuch, 16)).toInt());
    return Duration(milliseconds: (basis * (0.5 + _zufall.nextDouble())).round());
  }

  void _spaeter(int lauf, {Duration? nach}) {
    if (!_aktiv || lauf != _lauf) return;
    _neuTimer?.cancel();
    final warte = nach ?? abstand(_versuche);
    _versuche++;
    _neuTimer = Timer(warte, () => unawaited(_verbinden(lauf)));
  }

  Future<void> _verbinden(int lauf) async {
    if (!_aktiv || lauf != _lauf) return;
    final String t;
    try {
      t = await ticket();
    } on ApiException catch (e) {
      if (!_aktiv || lauf != _lauf) return;
      if (e.kind == ApiErrorKind.nichtAngemeldet) {
        // Sitzung beendet: der ApiClient hat das gemeldet, der Auth-Zustand schließt die App-Oberfläche. Kein Neuaufbau.
        stop();
        return;
      }
      _spaeter(lauf, nach: e.retryAfter != null && e.retryAfter! > abstand(_versuche) ? e.retryAfter : null);
      return;
    } catch (_) {
      _spaeter(lauf);
      return;
    }
    if (!_aktiv || lauf != _lauf) return;

    final WebSocketChannel kanal;
    try {
      kanal = _oeffner(_adresse());
      await kanal.ready;
    } catch (_) {
      if (_aktiv && lauf == _lauf) _spaeter(lauf);
      return;
    }
    if (!_aktiv || lauf != _lauf) {
      unawaited(kanal.sink.close().catchError((Object _) {}));
      return;
    }
    _kanal = kanal;
    // Anmelden mit dem Einmal-Ticket (nie in der Adresse)
    kanal.sink.add(jsonEncode({'type': 'auth', 'ticket': t}));
    kanal.stream.listen(
      (daten) => _nachricht(lauf, kanal, daten),
      onError: (Object _) => _getrennt(lauf, kanal, null),
      onDone: () => _getrennt(lauf, kanal, kanal.closeCode),
      cancelOnError: true,
    );
  }

  void _nachricht(int lauf, WebSocketChannel kanal, Object? daten) {
    if (lauf != _lauf || !identical(kanal, _kanal)) return;
    Object? msg;
    try {
      msg = daten is String ? jsonDecode(daten) : null;
    } catch (_) {
      return;
    }
    if (msg is! Map) return;
    switch (msg['type']) {
      case 'ready':
        _versuche = 0;
        _unangemeldet = 0;
        _setLive(true);
        _pingTimer?.cancel();
        _pingTimer = Timer.periodic(pingAbstand, (_) => _ping(lauf, kanal));
      case 'rev':
        final r = msg['rev'];
        if (r is int) beiRev(r);
      case 'pong':
        _pongTimer?.cancel();
        _pongTimer = null;
      case final String art when art.startsWith('loc_'):
        final h = beiNachricht;
        if (h != null) h(msg.cast<String, Object?>());
    }
  }

  /// Sendet eine Nachricht, wenn die Verbindung angemeldet ist (false: nicht verbunden, nichts wird gepuffert).
  bool senden(Map<String, Object?> nachricht) {
    final k = _kanal;
    if (!_live || k == null) return false;
    try {
      k.sink.add(jsonEncode(nachricht));
      return true;
    } catch (_) {
      return false;
    }
  }

  void _ping(int lauf, WebSocketChannel kanal) {
    if (lauf != _lauf || !identical(kanal, _kanal)) return;
    try {
      kanal.sink.add(jsonEncode({'type': 'ping'}));
    } catch (_) {
      _getrennt(lauf, kanal, null);
      return;
    }
    _pongTimer?.cancel();
    _pongTimer = Timer(pongFrist, () => _getrennt(lauf, kanal, null));
  }

  void _getrennt(int lauf, WebSocketChannel kanal, int? code) {
    if (lauf != _lauf || !identical(kanal, _kanal)) return;
    _abbauen();
    _setLive(false);
    if (!_aktiv) return;
    if (code == 4401 && ++_unangemeldet <= 1) {
      // nicht (mehr) angemeldet: sofort über ein neues Ticket prüfen, ob die Sitzung noch gilt (sonst endet sie dort und wir geben auf)
      _spaeter(lauf, nach: Duration.zero);
    } else {
      _spaeter(lauf);
    }
  }
}
