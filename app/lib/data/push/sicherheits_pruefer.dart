// Sicherheitshinweis nach einem Push-Wecker: Der Server weckt die Geräte einer Person ohne Inhalt, wenn ein Passwort-Reset für ihr Konto angefordert oder
// durchgeführt wurde. Die App holt danach die EIGENEN Sicherheitsereignisse (GET /me/security-events) und meldet, was seit dem letzten Mal neu ist:
// im Vordergrund als Hinweis in der Oberfläche, im Hintergrund als lokale Benachrichtigung mit festem Text (nie Namen oder Einzelheiten).
// Der erste Lauf eines Geräts meldet nichts (der Bestand ist nichts Neues); der Stand steht in `sync_meta` und verschwindet mit der lokalen Datenbank.
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/fampad_api.dart';
import '../api/models.dart';
import '../app_database.dart';
import '../auth/auth_state.dart';
import '../auth/reset_hinweis.dart';
import '../auth/sicherheit_text.dart';
import '../database_provider.dart';
import 'chat_benachrichtiger.dart';
import 'chat_benachrichtiger_provider.dart';

const kSicherheitSeitSchluessel = 'sicherheitSeit';

/// Feste Kennung der Benachrichtigung (oberhalb der Kennungen für Chat und Standort).
const int kSicherheitBenachrichtigungsId = 0x700000;

class SicherheitsPruefer {
  final FampadApi api;
  final AppDatabase db;
  final ChatAnzeigePort anzeige;
  const SicherheitsPruefer({required this.api, required this.db, required this.anzeige});

  /// Ereignisse seit dem letzten Mal (neueste zuerst) und merkt den neuen Stand. Beim ersten Lauf: nichts.
  Future<List<SicherheitsEreignisDto>> neue() async {
    final liste = await api.sicherheitsEreignisse();
    final gemerkt = await db.metaLesen(kSicherheitSeitSchluessel);
    if (gemerkt == null) {
      // erster Lauf: den Bestand merken (leer: den Anfang der Zeit, damit spätere Ereignisse zählen)
      await db.metaSchreiben(kSicherheitSeitSchluessel, (liste.isEmpty ? DateTime.utc(1970) : liste.first.zeit).toUtc().toIso8601String());
      return const [];
    }
    final seit = DateTime.tryParse(gemerkt);
    if (seit == null) {
      await db.metaLoeschen(kSicherheitSeitSchluessel);
      return const [];
    }
    final neu = [for (final e in liste) if (e.zeit.isAfter(seit)) e];
    if (neu.isNotEmpty) await db.metaSchreiben(kSicherheitSeitSchluessel, neu.first.zeit.toUtc().toIso8601String());
    return neu;
  }

  /// Markiert alles Bisherige als gesehen (z. B. nach einem Reset, den die Person gerade selbst ausgelöst hat). Fehler sind egal.
  Future<void> alsGesehenMarkieren() async {
    try {
      await neue();
    } catch (_) {}
  }

  /// Prüft und meldet: im Vordergrund über [hinweis] (die Oberfläche zeigt ihn), sonst als lokale Benachrichtigung mit festem Text. Wirft nie.
  Future<void> pruefenUndMelden({required bool vordergrund, ResetHinweisController? hinweis}) async {
    try {
      final neu = await neue();
      if (neu.isEmpty) return;
      if (vordergrund) {
        hinweis?.setzen('Sicherheitshinweis: ${sicherheitsEreignisText(neu.first)} Details unter Profil > Sicherheitsereignisse.');
        return;
      }
      if (!await anzeige.initialisieren()) return;
      await anzeige.zeigen(
        id: kSicherheitBenachrichtigungsId,
        titel: 'Sicherheitshinweis',
        text: 'An deinem Konto hat sich etwas geändert. Details unter Profil > Sicherheitsereignisse.',
        sperrbildschirmTitel: false,
      );
    } catch (_) {
      // ein Zusatz: der Abgleich und alles andere laufen unabhängig davon
    }
  }
}

final sicherheitsPrueferProvider = Provider<SicherheitsPruefer>(
  (ref) => SicherheitsPruefer(api: ref.watch(apiProvider), db: ref.watch(appDatabaseProvider), anzeige: ref.watch(chatAnzeigePortProvider)),
);

/// Vordergrund oder nicht (für Aufrufer ohne eigenen Zustand).
bool appImVordergrund() => WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
