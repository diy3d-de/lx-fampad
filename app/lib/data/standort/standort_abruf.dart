// Kurzer Abruf des Standort-Kanals nach einem Push-Wecker (App im Hintergrund oder geschlossen). Der Wecker enthält nichts; deshalb verbindet sich die App
// kurz mit dem Standort-Kanal, meldet sich mit `loc_hello` (zählt nicht als "Gerät ist live") und bekommt dabei laufende Freigaben an sie nachgereicht
// (`loc_start` mit Absender und Ende). Daraus entsteht die lokale Benachrichtigung ([StandortBenachrichtiger]). Die Positionen und der Wrap werden hier NICHT
// geöffnet (im Hintergrund-Start gibt es keinen Schlüsselbund); das erledigt die App beim Öffnen der Standort-Seite. Danach wird die Verbindung geschlossen.
//
// Läuft nur, wenn die Hinweise eingeschaltet sind und die App nicht im Vordergrund ist (dort hat die laufende Standort-Verbindung `loc_start` ohnehin).
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../sync/sync_socket.dart';
import 'standort_dienst.dart' show StandortSocketFabrik, standortSocketFabrikProvider;
import 'standort_hinweis.dart';

class StandortAbruf {
  final StandortSocketFabrik fabrik;
  final StandortBenachrichtiger benachrichtiger;
  final DateTime Function() jetzt;
  StandortAbruf({required this.fabrik, required this.benachrichtiger, DateTime Function()? jetzt}) : jetzt = jetzt ?? DateTime.now;

  /// Verbindet kurz und meldet neue Freigaben. [stille]: so lange nach dem Aufbau noch auf Nachreichungen warten; [hoechstens]: Obergrenze inklusive Aufbau.
  Future<void> abfragen({Duration stille = const Duration(seconds: 3), Duration hoechstens = const Duration(seconds: 10)}) async {
    if (benachrichtiger.istVordergrund()) return;
    if (!await benachrichtiger.aktiv()) return;
    final fertig = Completer<void>();
    final aufgaben = <Future<void>>[];
    Timer? stilleTimer;
    SyncSocket? socket;

    void beiNachricht(Map<String, Object?> m) {
      final von = m['from'];
      if (von is! String) return;
      switch (m['type']) {
        case 'loc_start':
          final shareId = m['shareId'];
          final endsAt = m['endsAt'];
          if (shareId is String && endsAt is int) {
            aufgaben.add(benachrichtiger.freigabe(von: von, shareId: shareId, endsAt: DateTime.fromMillisecondsSinceEpoch(endsAt)));
          }
        case 'loc_stop':
          aufgaben.add(benachrichtiger.beendet(von));
      }
    }

    void beiStatus(bool live) {
      if (!live) return;
      // diese Verbindung gehört dem Standort-Kanal: der Server zählt sie nicht als "Gerät ist live"
      socket?.senden({'type': 'loc_hello'});
      stilleTimer ??= Timer(stille, () {
        if (!fertig.isCompleted) fertig.complete();
      });
    }

    final frist = Timer(hoechstens, () {
      if (!fertig.isCompleted) fertig.complete();
    });
    try {
      socket = fabrik(beiNachricht: beiNachricht, beiStatus: beiStatus)..start();
      await fertig.future;
    } finally {
      frist.cancel();
      stilleTimer?.cancel();
      socket?.stop();
    }
    await Future.wait(aufgaben.map((a) => a.catchError((Object _) {})));
  }
}

final standortAbrufProvider = Provider<StandortAbruf>((ref) => StandortAbruf(fabrik: ref.read(standortSocketFabrikProvider), benachrichtiger: ref.read(standortBenachrichtigerProvider)));
