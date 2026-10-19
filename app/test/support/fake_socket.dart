// Fake-WebSocket für die Tests des Sync-Sockets: zeichnet gesendete Nachrichten auf, der Test lässt den "Server" antworten oder schließen.
import 'dart:async';
import 'dart:convert';

import 'package:lx_fampad/data/sync/sync_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class FakeSocket implements WebSocketChannel {
  final _eingehend = StreamController<dynamic>();
  final gesendet = <Map<String, dynamic>>[];
  final Completer<void> _bereit = Completer<void>();
  int? _code;
  String? _grund;
  bool geschlossen = false;

  /// Beantwortet {type:auth} automatisch mit {type:ready} und {type:ping} mit {type:pong}.
  bool autoBereit;
  bool autoPong;

  FakeSocket({this.autoBereit = true, this.autoPong = true, Object? verbindungsfehler}) {
    if (verbindungsfehler != null) {
      _bereit.future.catchError((Object _) {});
      _bereit.completeError(verbindungsfehler);
    } else {
      _bereit.complete();
    }
  }

  void vomServer(Map<String, dynamic> nachricht) {
    if (!_eingehend.isClosed) _eingehend.add(jsonEncode(nachricht));
  }

  /// Der Server schließt die Verbindung mit einem Code (z. B. 4401).
  void serverSchliesst(int code, [String grund = '']) {
    _code = code;
    _grund = grund;
    geschlossen = true;
    unawaited(_eingehend.close());
  }

  @override
  Future<void> get ready => _bereit.future;

  @override
  Stream get stream => _eingehend.stream;

  @override
  WebSocketSink get sink => _Senke(this);

  @override
  int? get closeCode => _code;

  @override
  String? get closeReason => _grund;

  @override
  String? get protocol => null;

  // StreamChannelMixin (cast, pipe, transform ...) wird von den Tests nicht gebraucht
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(invocation.memberName.toString());

  void _empfangen(Object? daten) {
    if (daten is! String) return;
    final m = jsonDecode(daten) as Map<String, dynamic>;
    gesendet.add(m);
    if (autoBereit && m['type'] == 'auth') scheduleMicrotask(() => vomServer({'type': 'ready'}));
    if (autoPong && m['type'] == 'ping') scheduleMicrotask(() => vomServer({'type': 'pong'}));
  }
}

class _Senke implements WebSocketSink {
  final FakeSocket _s;
  _Senke(this._s);

  @override
  void add(Object? data) => _s._empfangen(data);

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream stream) async {}

  @override
  Future<void> close([int? closeCode, String? closeReason]) async {
    if (!_s.geschlossen) {
      _s.geschlossen = true;
      _s._code ??= closeCode;
      await _s._eingehend.close();
    }
  }

  @override
  Future<void> get done => Future.value();
}

/// Öffnet Fake-Sockets und merkt sich Adressen und Verbindungen.
class FakeSocketFabrik {
  final sockets = <FakeSocket>[];
  final adressen = <Uri>[];

  /// So viele nächste Verbindungsversuche scheitern.
  int scheitern = 0;
  bool autoBereit = true;
  bool autoPong = true;

  SocketOeffner get oeffner => (uri) {
    adressen.add(uri);
    if (scheitern > 0) {
      scheitern--;
      final s = FakeSocket(verbindungsfehler: Exception('Verbindung abgelehnt'));
      sockets.add(s);
      return s;
    }
    final s = FakeSocket(autoBereit: autoBereit, autoPong: autoPong);
    sockets.add(s);
    return s;
  };

  FakeSocket get letzter => sockets.last;
}
