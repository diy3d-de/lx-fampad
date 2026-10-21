// Betreiber-Warnungen auf dem Gerät: Der Server weckt die Geräte des Betreibers OHNE Inhalt; die App holt danach `GET /admin/warnings` und zeigt einen festen Text
// ("Betrieb: Hinweis – öffne Betrieb"), nie eine Einzelheit, einen Namen oder einen Servertext. Im Vordergrund als kurzer Hinweis in der Oberfläche, im Hintergrund als
// lokale Benachrichtigung auf dem Kanal "Sicherheit".
//
// Regeln:
//  - Nur Konten, die der Server als Betreiber meldet (`operator: true` in /me), fragen überhaupt `/admin/warnings` ab: Das Konto-Flag steht lokal in `sync_meta`
//    (`betriebBetreiber`, gesetzt vom Wurzel-Widget, mit der lokalen Datenbank gelöscht), so fragt der Wecker anderer Mitglieder nie unnötig nach.
//  - Gemeldet wird, was seit dem letzten Mal neu ist (`lastNotifiedAt` des Servers gegen `betriebWarnSeit` hier). Der Stand rückt im Hintergrund erst vor, wenn die
//    Benachrichtigung wirklich angezeigt wurde. Der erste Lauf eines Geräts setzt nur die Grundlinie (der Bestand ist nichts Neues).
//  - Weckrufe prüfen höchstens alle fünf Minuten ([kBetriebMindestabstand]).
//  - Schaltet der Betreiber die Warnungen aus (`enabled: false`), meldet die App nichts.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_error.dart';
import '../api/fampad_api.dart';
import '../app_database.dart';
import '../auth/auth_state.dart';
import '../database_provider.dart';
import '../push/chat_benachrichtiger.dart';
import '../push/chat_benachrichtiger_provider.dart';
import 'betrieb_modelle.dart';

/// Nutzlast der Betrieb-Benachrichtigung (Tipp öffnet den Bereich "Betrieb").
const kBetriebPayload = 'betrieb';

/// Fester Text der Warnung (Titel der Benachrichtigung und des Hinweises in der Oberfläche).
const kBetriebHinweisTitel = 'Betrieb: Hinweis – öffne Betrieb';
const kBetriebHinweisText = 'Einzelheiten stehen in der Ansicht „Betrieb“.';

const kBetriebBetreiberSchluessel = 'betriebBetreiber';
const kBetriebWarnSeitSchluessel = 'betriebWarnSeit';
const kBetriebGeprueftSchluessel = 'betriebWarnGeprueft';

/// Feste Kennung der Benachrichtigung (oberhalb der Kennungen für Chat und Standort, neben den Sicherheitshinweisen).
const int kBetriebBenachrichtigungsId = 0x700002;

/// Weckrufe prüfen höchstens so oft.
const kBetriebMindestabstand = Duration(minutes: 5);

/// Anforderung, den Bereich "Betrieb" zu öffnen (Tipp auf die Benachrichtigung); die Shell reagiert darauf.
class BetriebOeffnenAnforderung extends Notifier<int> {
  @override
  int build() => 0;

  void anfordern() => state = state + 1;
}

final betriebOeffnenProvider = NotifierProvider<BetriebOeffnenAnforderung, int>(BetriebOeffnenAnforderung.new);

/// Zähler für den Hinweis im Vordergrund (die Shell zeigt dann den festen Text einmal).
class BetriebHinweisZaehler extends Notifier<int> {
  @override
  int build() => 0;

  void zeigen() => state = state + 1;
}

final betriebHinweisProvider = NotifierProvider<BetriebHinweisZaehler, int>(BetriebHinweisZaehler.new);

class BetriebWarnPruefer {
  final FampadApi api;
  final AppDatabase db;
  final ChatAnzeigePort anzeige;
  final DateTime Function() jetzt;
  BetriebWarnPruefer({required this.api, required this.db, required this.anzeige, DateTime Function()? jetzt}) : jetzt = jetzt ?? DateTime.now;

  /// Merkt lokal, ob dieses Konto Betreiber ist (nur dann fragt ein Wecker `/admin/warnings` ab). Wirft nie.
  Future<void> betreiberMerken(bool betreiber) async {
    try {
      if (betreiber) {
        await db.metaSchreiben(kBetriebBetreiberSchluessel, '1');
      } else {
        await db.metaLoeschen(kBetriebBetreiberSchluessel);
        await db.metaLoeschen(kBetriebWarnSeitSchluessel);
      }
    } catch (_) {}
  }

  Future<void> _markieren(DateTime zeit) => db.metaSchreiben(kBetriebWarnSeitSchluessel, zeit.toUtc().toIso8601String());

  /// Setzt beim ersten Mal die Grundlinie (der Bestand ist nichts Neues). Wirft nie.
  Future<void> grundlinieSetzen() async {
    try {
      if (await db.metaLesen(kBetriebBetreiberSchluessel) != '1') return;
      if (await db.metaLesen(kBetriebWarnSeitSchluessel) != null) return;
      final w = await api.betriebWarnungen();
      await _markieren(w.zuletztGewarnt ?? DateTime.utc(1970));
    } catch (_) {}
  }

  /// Prüft und meldet: im Vordergrund über [hinweis] (die Oberfläche zeigt den festen Text), sonst als lokale Benachrichtigung. Mit [mindestAbstand] höchstens so
  /// oft (Weckrufe). Wirft nie.
  Future<void> pruefenUndMelden({required bool vordergrund, void Function()? hinweis, Duration? mindestAbstand}) async {
    try {
      if (await db.metaLesen(kBetriebBetreiberSchluessel) != '1') return;
      if (mindestAbstand != null) {
        final zuletzt = DateTime.tryParse(await db.metaLesen(kBetriebGeprueftSchluessel) ?? '');
        if (zuletzt != null && jetzt().difference(zuletzt) < mindestAbstand) return;
      }
      await db.metaSchreiben(kBetriebGeprueftSchluessel, jetzt().toUtc().toIso8601String());
      final BetriebWarnungen w;
      try {
        w = await api.betriebWarnungen();
      } on ApiException catch (e) {
        // Kein Betreiber mehr (404): das Konto-Flag lokal löschen, damit kein Wecker mehr unnötig nachfragt
        if (e.status == 404) await betreiberMerken(false);
        return;
      }
      final neu = w.zuletztGewarnt;
      if (!w.an || neu == null) return;
      final seit = DateTime.tryParse(await db.metaLesen(kBetriebWarnSeitSchluessel) ?? '') ?? DateTime.utc(1970);
      if (!neu.isAfter(seit)) return;
      if (vordergrund) {
        hinweis?.call();
        await _markieren(neu);
        return;
      }
      if (!await anzeige.initialisieren()) return; // der Stand bleibt: der nächste Start der App holt es nach
      final gezeigt = await anzeige.zeigenSicherheit(id: kBetriebBenachrichtigungsId, titel: kBetriebHinweisTitel, text: kBetriebHinweisText, nutzlast: kBetriebPayload);
      if (gezeigt) await _markieren(neu);
    } catch (_) {
      // ein Zusatz: der Abgleich und alles andere laufen unabhängig davon
    }
  }
}

final betriebWarnPrueferProvider = Provider<BetriebWarnPruefer>(
  (ref) => BetriebWarnPruefer(api: ref.watch(apiProvider), db: ref.watch(appDatabaseProvider), anzeige: ref.watch(chatAnzeigePortProvider)),
);

/// Hält das lokale Betreiber-Flag aktuell und setzt die Grundlinie (am Wurzel-Widget beobachtet, siehe app.dart).
final betriebWarnSteuerungProvider = Provider<void>((ref) {
  final betreiber = ref.watch(authProvider.select((s) => s.status == AuthStatus.angemeldet && s.istBetreiber));
  final angemeldet = ref.watch(authProvider.select((s) => s.status == AuthStatus.angemeldet));
  if (!angemeldet) return;
  Future.microtask(() async {
    if (!ref.mounted) return;
    final p = ref.read(betriebWarnPrueferProvider);
    await p.betreiberMerken(betreiber);
    if (betreiber && ref.mounted) await p.grundlinieSetzen();
  });
});
