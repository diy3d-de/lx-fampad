// Kurzer Abruf des Standort-Kanals nach einem Push-Wecker (App im Hintergrund oder geschlossen). Der Wecker enthält nichts; deshalb verbindet sich die App
// kurz mit dem Standort-Kanal, meldet sich mit `loc_hello` (zählt nicht als "Gerät ist live") und bekommt dabei laufende Freigaben an sie nachgereicht
// (`loc_start` mit Absender und Ende). Daraus entsteht die lokale Benachrichtigung ([StandortBenachrichtiger]). Die Positionen und der Wrap werden hier NICHT
// geöffnet (im Hintergrund-Start gibt es keinen Schlüsselbund); das erledigt die App beim Öffnen der Standort-Seite. Danach wird die Verbindung geschlossen.
//
// Läuft nur, wenn die Hinweise eingeschaltet sind und die App nicht im Vordergrund ist (dort hat die laufende Standort-Verbindung `loc_start` ohnehin).
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_error.dart';
import '../auth/auth_state.dart' show apiProvider;
import '../sync/sync_socket.dart';
import 'standort_dienst.dart' show StandortSocketFabrik, standortSocketFabrikProvider;
import 'standort_hinweis.dart';

class StandortAbruf {
  final StandortSocketFabrik fabrik;
  final StandortBenachrichtiger benachrichtiger;
  final DateTime Function() jetzt;

  /// Sorgt vor dem Ticket für ein gültiges Zugangstoken (erneuert es einmal, serialisiert; wirft [ApiException]). Ohne: kein Erneuern (Tests der Verbindung).
  final Future<void> Function()? zugangSichern;
  StandortAbruf({required this.fabrik, required this.benachrichtiger, DateTime Function()? jetzt, this.zugangSichern}) : jetzt = jetzt ?? DateTime.now;

  /// Verbindet kurz und meldet neue Freigaben (höchstens einmal je 30 Sekunden und Gerät, gebucht in der lokalen Datenbank). [stille]: so lange nach dem Aufbau noch auf Nachreichungen warten; [hoechstens]: Obergrenze inklusive Aufbau.
  Future<void> abfragen({Duration stille = const Duration(milliseconds: 1500), Duration hoechstens = const Duration(seconds: 15), Duration aufbauFrist = const Duration(seconds: 8)}) async {
    Future<void> notiere(String code) => standortDiagnoseSchreiben(benachrichtiger.db, kDiagAbruf, code, benachrichtiger.jetzt());
    // wird überschrieben, sobald der Abruf zu Ende ist: bleibt "gestartet" stehen, wurde der Hintergrund-Start vorher beendet
    await notiere('gestartet');
    if (benachrichtiger.istVordergrund()) return notiere('im_vordergrund');
    if (!await benachrichtiger.aktiv()) return notiere('aus');
    if (!await benachrichtiger.abrufErlaubt()) return notiere('gedrosselt'); // höchstens einer je 30 Sekunden und Gerät (WebSocket-Ticket, Anmelde-Grenze je IP)
    // Das Zugangstoken (15 Minuten) ist nach einer Weile abgelaufen, der Hintergrund-Client erneuert nie von selbst: einmal erneuern, sonst ehrlich melden
    // (kein Ticket, keine Wiederholung; die Person öffnet die App, die Anmeldung läuft dort weiter).
    final sichern = zugangSichern;
    if (sichern != null) {
      try {
        await sichern();
      } on ApiException catch (e) {
        return notiere(e.kind == ApiErrorKind.nichtAngemeldet ? 'anmeldung_abgelaufen' : 'keine_verbindung');
      } catch (_) {
        return notiere('keine_verbindung');
      }
    }
    var verbunden = false;
    var freigaben = 0;
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
            freigaben++;
            aufgaben.add(benachrichtiger.freigabe(von: von, shareId: shareId, endsAt: DateTime.fromMillisecondsSinceEpoch(endsAt)));
          }
        case 'loc_stop':
          aufgaben.add(benachrichtiger.beendet(von));
      }
    }

    void beiStatus(bool live) {
      if (!live) return;
      verbunden = true;
      // diese Verbindung gehört dem Standort-Kanal: der Server zählt sie nicht als "Gerät ist live"
      socket?.senden({'type': 'loc_hello'});
      stilleTimer ??= Timer(stille, () {
        if (!fertig.isCompleted) fertig.complete();
      });
    }

    final frist = Timer(hoechstens, () {
      if (!fertig.isCompleted) fertig.complete();
    });
    // steht die Verbindung nach der Aufbaufrist nicht (Netz, Ticket abgelehnt, 429), ist Schluss: kein Wiederholen, jeder Versuch holt ein neues Ticket
    final aufbau = Timer(aufbauFrist, () {
      if (socket?.live != true && !fertig.isCompleted) fertig.complete();
    });
    try {
      socket = fabrik(beiNachricht: beiNachricht, beiStatus: beiStatus)..start();
      await fertig.future;
    } finally {
      frist.cancel();
      aufbau.cancel();
      stilleTimer?.cancel();
      socket?.stop();
    }
    await Future.wait(aufgaben.map((a) => a.catchError((Object _) {})));
    await notiere(!verbunden ? 'keine_verbindung' : (freigaben > 0 ? 'freigaben' : 'ok'));
  }
}

final standortAbrufProvider = Provider<StandortAbruf>(
  (ref) => StandortAbruf(fabrik: ref.read(standortSocketFabrikProvider), benachrichtiger: ref.read(standortBenachrichtigerProvider), zugangSichern: () => ref.read(apiProvider).client.zugangErneuern()),
);
