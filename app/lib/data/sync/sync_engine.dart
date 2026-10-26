// Ein Abgleichslauf: Ausgang senden, Antwort übernehmen, weitere Seiten des Änderungsstroms holen, bis alles da ist.
// Kennt weder Oberfläche noch Zeitgeber (Wiederholen, Backoff, Auslöser: sync_state.dart); wirft nie, sondern meldet ein Ergebnis.
import '../api/api_error.dart';
import '../api/fampad_api.dart';
import '../app_database.dart';
import 'sync_store.dart';

enum SyncAusgang {
  /// Alles abgeglichen.
  ok,

  /// Keine Verbindung zum Server (Zeitüberschreitung eingeschlossen).
  offline,

  /// 401: die Sitzung ist weg. Der ApiClient hat das schon gemeldet (Auth-Zustand), nicht in der Sync-Schleife wiederholen.
  sitzungVerloren,

  /// 426: die App ist zu alt für den Server (Pflicht-Update).
  updateNoetig,

  /// Der Abgleich wurde abgebrochen (Abmelden, Stopp): die Antwort wird nicht mehr übernommen.
  abgebrochen,

  /// Das Gerät passt nicht (mehr) zur Sitzung: /me neu laden, dann erneut versuchen.
  geraetFalsch,

  /// Anfragelimit oder Überlast (429/503): später wieder, [SyncErgebnis.warten] nennt die Mindestwartezeit.
  ueberlastet,

  /// Der Betreiber hat den Wartungsmodus eingeschaltet (503 maintenance): später wieder, die Änderungen bleiben im Ausgang.
  wartung,

  /// Sonstiger Fehler (Server 5xx, unerwartete Antwort, lokaler Fehler).
  fehler,
}

class SyncErgebnis {
  final SyncAusgang ausgang;
  final List<SyncHinweis> hinweise;
  final Duration? warten;
  final String? meldung;
  final int ops;

  /// 429 des Sync-Mengenlimits (`rate_limited`) mit Wartezeit: der Abgleich wartet genau so lange, ohne den Backoff hochzuschaukeln.
  final bool mengenlimit;

  /// Stand der Familie laut Server nach dem letzten Aufruf (0: unbekannt).
  final int rev;
  const SyncErgebnis(this.ausgang, {this.hinweise = const [], this.warten, this.meldung, this.ops = 0, this.rev = 0, this.mengenlimit = false});

  bool get ok => ausgang == SyncAusgang.ok;
}

class SyncEngine {
  final SyncStore store;
  final FampadApi api;

  /// Geräte-ID der Sitzung (null: keine Sitzung bekannt).
  final Future<String?> Function() geraeteId;
  final int maxOps;
  final int seite;

  /// Bereitet Ops vor dem Senden vor (Chat: verschlüsseln); null: unverändert senden.
  final OpVorbereiter? vorbereiter;

  SyncEngine({required this.store, required this.api, required this.geraeteId, this.maxOps = 50, this.seite = 500, this.vorbereiter});

  /// [abgebrochen] wird nach jeder Antwort geprüft: ist der Dienst inzwischen gestoppt (Abmelden löscht die Datenbank), wird nichts mehr
  /// in die lokalen Tabellen geschrieben.
  Future<SyncErgebnis> abgleichen({bool Function()? abgebrochen}) async {
    final hinweise = <SyncHinweis>[];
    var gesendet = 0;
    try {
      final dev = await geraeteId();
      if (dev == null) return const SyncErgebnis(SyncAusgang.geraetFalsch); // Geräte-ID noch unbekannt (/me wird nachgeladen)
      await store.geraetZuordnen(dev);
      var rev = 0;
      // Klartext, der lange im Ausgang wartet (offline geschrieben): erst den Stand des Servers holen (neue Epoche?), dann verschlüsseln und senden
      final vorab = vorbereiter != null && await store.hatAltenKlartext(const Duration(seconds: 20));
      for (var runde = 0; runde < 300; runde++) {
        final nurAbholen = vorab && runde == 0;
        final ops = nurAbholen ? const <OutboxData>[] : await store.naechsteOps(maxOps, vorbereiter: vorbereiter);
        final since = await store.sinceRev();
        final snapshot = since > 0 ? await store.snapshotRev() : null; // läuft ein mehrseitiger Snapshot, ist sinceRev nur der Cursor
        final res = await api.sync(deviceId: dev, sinceRev: since, ops: [for (final o in ops) SyncStore.alsOp(o)], limit: seite, snapshotRev: snapshot);
        if (abgebrochen?.call() ?? false) return SyncErgebnis(SyncAusgang.abgebrochen, hinweise: hinweise, ops: gesendet);
        final bericht = await store.uebernehmen(res, ops);
        hinweise.addAll(bericht.hinweise);
        gesendet += res.acked.length;
        rev = res.rev;
        if (bericht.neuLaden) await store.neuLadenVormerken();
        // ohne Fortschritt nicht in der Schleife bleiben (der Server hat keine der gesendeten Ops bestätigt oder abgelehnt)
        if (ops.isNotEmpty && res.acked.isEmpty && res.rejected.isEmpty && !res.resyncNoetig && !res.hasMore) {
          return SyncErgebnis(SyncAusgang.fehler, hinweise: hinweise, meldung: 'Der Server hat die Änderungen nicht bestätigt.', ops: gesendet);
        }
        if (nurAbholen || bericht.resync || bericht.neuLaden || res.hasMore) continue;
        if (await store.offeneAnzahl() > 0 && ops.isNotEmpty) continue; // weitere Ops (mehr als eine Anfrage voll oder neu dazugekommen)
        return SyncErgebnis(SyncAusgang.ok, hinweise: hinweise, ops: gesendet, rev: rev);
      }
      return SyncErgebnis(SyncAusgang.fehler, hinweise: hinweise, meldung: 'Das Übertragen hat nicht abgeschlossen.', ops: gesendet);
    } on ApiException catch (e) {
      return _aus(e, hinweise, gesendet);
    } catch (_) {
      // lokale Datenbank oder unerwartete Daten: nie Interna zeigen
      return SyncErgebnis(SyncAusgang.fehler, hinweise: hinweise, meldung: 'Das Übertragen hat nicht geklappt.', ops: gesendet);
    }
  }

  SyncErgebnis _aus(ApiException e, List<SyncHinweis> hinweise, int ops) {
    if (e.code == 'device_mismatch') return SyncErgebnis(SyncAusgang.geraetFalsch, hinweise: hinweise, ops: ops);
    return switch (e.kind) {
      ApiErrorKind.netzwerk => SyncErgebnis(SyncAusgang.offline, hinweise: hinweise, meldung: e.message, ops: ops),
      ApiErrorKind.nichtAngemeldet => SyncErgebnis(SyncAusgang.sitzungVerloren, hinweise: hinweise, meldung: e.message, ops: ops),
      ApiErrorKind.updateNoetig => SyncErgebnis(SyncAusgang.updateNoetig, hinweise: hinweise, meldung: e.message, ops: ops),
      ApiErrorKind.wartung => SyncErgebnis(SyncAusgang.wartung, hinweise: hinweise, warten: e.retryAfter, meldung: e.message, ops: ops),
      ApiErrorKind.zuVieleAnfragen || ApiErrorKind.serverBusy => SyncErgebnis(
        SyncAusgang.ueberlastet,
        hinweise: hinweise,
        warten: e.retryAfter,
        meldung: e.message,
        ops: ops,
        mengenlimit: e.kind == ApiErrorKind.zuVieleAnfragen && e.code == 'rate_limited' && e.retryAfter != null,
      ),
      _ => SyncErgebnis(SyncAusgang.fehler, hinweise: hinweise, meldung: e.message, ops: ops),
    };
  }
}
