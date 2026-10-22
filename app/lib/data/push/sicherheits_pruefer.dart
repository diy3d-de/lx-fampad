// Sicherheitshinweis nach einem Push-Wecker: Der Server weckt die Geräte einer Person ohne Inhalt, wenn ein Passwort-Reset für ihr Konto angefordert oder
// durchgeführt wurde. Die App holt danach die EIGENEN Sicherheitsereignisse (GET /me/security-events) und meldet, was seit dem letzten Mal neu ist:
// im Vordergrund als Hinweis in der Oberfläche, im Hintergrund als lokale Benachrichtigung auf dem eigenen Kanal "Sicherheit" mit festem Text (nie Namen).
//
// Regeln:
//  - Der Stand ("gemeldet bis", `sicherheitSeit` in `sync_meta`) rückt im Hintergrund erst vor, wenn die Benachrichtigung wirklich angezeigt wurde. Ging das nicht
//    (keine Erlaubnis, Plugin), holt der nächste Start der App im Vordergrund es nach.
//  - Der erste Lauf eines Geräts meldet nichts (der Bestand ist nichts Neues).
//  - Weckrufe prüfen höchstens alle fünf Minuten ([kSicherheitMindestabstand]); der Start der App immer.
//  - Kommt der Wecker, die Abfrage scheitert aber mit "Sitzung abgelehnt" obwohl das Zugangstoken laut Uhr noch gilt, ist die Sitzung widerrufen worden (ein Passwort-Reset
//    beendet alle Sitzungen): feste Benachrichtigung "Du wurdest abgemeldet ..." und ein dauerhafter Hinweis beim nächsten Anmelden (`sicherheitAbgemeldet`).
//    Ein schlicht abgelaufenes Zugangstoken (die Anfrage ging nie hinaus) löst das nie aus.
// Der Stand steht in `sync_meta` und verschwindet mit der lokalen Datenbank.
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_error.dart';
import '../api/fampad_api.dart';
import '../api/models.dart';
import '../api/token_store.dart';
import '../app_database.dart';
import '../auth/auth_state.dart';
import '../auth/eigener_abruf.dart';
import '../auth/reset_hinweis.dart';
import '../auth/sicherheit_text.dart';
import '../database_provider.dart';
import 'chat_benachrichtiger.dart';
import 'chat_benachrichtiger_provider.dart';

const kSicherheitSeitSchluessel = 'sicherheitSeit';
const kSicherheitGeprueftSchluessel = 'sicherheitGeprueft';

/// Gesetzt, wenn die App im Hintergrund erfahren hat, dass die Sitzung widerrufen wurde; bleibt, bis die Person den Hinweis nach dem Anmelden bestätigt.
const kSicherheitAbgemeldetSchluessel = 'sicherheitAbgemeldet';

/// Feste Kennungen der Benachrichtigungen (oberhalb der Kennungen für Chat und Standort).
const int kSicherheitBenachrichtigungsId = 0x700000;
const int kSicherheitAbgemeldetBenachrichtigungsId = 0x700001;

/// Weckrufe prüfen höchstens so oft.
const kSicherheitMindestabstand = Duration(minutes: 5);

const kSicherheitAbgemeldetTitel = 'Du wurdest abgemeldet';
const kSicherheitAbgemeldetText = 'Dein Passwort wurde zurückgesetzt. Warst du das nicht, melde dich mit einem Wiederherstellungscode an.';

class SicherheitsPruefer {
  final FampadApi api;
  final AppDatabase db;
  final ChatAnzeigePort anzeige;
  final TokenStore store;
  final DateTime Function() jetzt;
  SicherheitsPruefer({required this.api, required this.db, required this.anzeige, required this.store, DateTime Function()? jetzt}) : jetzt = jetzt ?? DateTime.now;

  Future<void> _markieren(DateTime zeit) => db.metaSchreiben(kSicherheitSeitSchluessel, zeit.toUtc().toIso8601String());

  /// Neue Ereignisse seit dem gemerkten Stand (neueste zuerst), OHNE den Stand fortzuschreiben. Beim ersten Lauf: der Bestand wird gemerkt, nichts gemeldet.
  Future<List<SicherheitsEreignisDto>> _neue() async {
    final liste = await api.sicherheitsEreignisse();
    final gemerkt = await db.metaLesen(kSicherheitSeitSchluessel);
    if (gemerkt == null) {
      // erster Lauf: den Bestand merken (leer: den Anfang der Zeit, damit spätere Ereignisse zählen)
      await _markieren(liste.isEmpty ? DateTime.utc(1970) : liste.first.zeit);
      return const [];
    }
    final seit = DateTime.tryParse(gemerkt);
    if (seit == null) {
      await db.metaLoeschen(kSicherheitSeitSchluessel);
      return const [];
    }
    return [for (final e in liste) if (e.zeit.isAfter(seit)) e];
  }

  /// Markiert alles Bisherige als gesehen (nach einem Reset, den die Person gerade selbst ausgelöst hat) und räumt den Hinweis "abgemeldet" ab. Fehler sind egal.
  Future<void> alsGesehenMarkieren() async {
    try {
      final neu = await _neue();
      if (neu.isNotEmpty) await _markieren(neu.first.zeit);
    } catch (_) {}
    try {
      await db.metaLoeschen(kSicherheitAbgemeldetSchluessel);
    } catch (_) {}
  }

  /// Räumt nur den Hinweis "abgemeldet" ab (die Person setzt ihr Passwort gerade selbst zurück: es wäre nichts Neues für sie).
  Future<void> hinweisAbgemeldetLoeschen() async {
    try {
      await db.metaLoeschen(kSicherheitAbgemeldetSchluessel);
    } catch (_) {}
  }

  /// Prüft und meldet: im Vordergrund über [hinweis] (die Oberfläche zeigt ihn), sonst als lokale Benachrichtigung mit festem Text. Mit [mindestAbstand] höchstens
  /// so oft (Weckrufe). Wirft nie.
  Future<void> pruefenUndMelden({required bool vordergrund, ResetHinweisController? hinweis, Duration? mindestAbstand}) async {
    try {
      if (mindestAbstand != null) {
        final zuletzt = DateTime.tryParse(await db.metaLesen(kSicherheitGeprueftSchluessel) ?? '');
        if (zuletzt != null && jetzt().difference(zuletzt) < mindestAbstand) return;
      }
      await db.metaSchreiben(kSicherheitGeprueftSchluessel, jetzt().toUtc().toIso8601String());
      final alle = await _neue();
      if (alle.isEmpty) return;
      // Nur das EIGENE Abrufen der Passwort-Sicherung (dieses Gerät hat sie kurz davor selbst geholt, z. B. beim automatischen Verbinden; siehe eigener_abruf.dart)
      // ist keine Warnung: es bleibt in der Liste, löst aber weder Dialog noch Benachrichtigung aus; der Stand rückt trotzdem vor. Abrufe anderer Geräte
      // zählen wie jedes Sicherheitsereignis (Warnhinweis bei Passwort-Diebstahl).
      final marke = DateTime.tryParse(await db.metaLesen(kEigenerPwAbrufSchluessel) ?? '');
      bool eigen(SicherheitsEreignisDto e) =>
          e.art == SicherheitsArt.passwortSicherungAbgerufen && marke != null && e.zeit.difference(marke).abs() <= kEigenerAbrufFenster;
      final neu = [for (final e in alle) if (!eigen(e)) e];
      if (neu.isEmpty) {
        await _markieren(alle.first.zeit);
        return;
      }
      if (vordergrund) {
        hinweis?.setzen('Sicherheitshinweis: ${sicherheitsEreignisText(neu.first)} Details unter Profil > Sicherheitsereignisse.');
        await _markieren(alle.first.zeit);
        return;
      }
      if (!await anzeige.initialisieren()) return; // der Stand bleibt: der nächste Start der App holt es nach
      // fester Text, nie ein Name; nur der Hinweis an die Familie (ein anderer Zugang wurde zurückgesetzt) sagt, dass es nicht das eigene Konto ist
      final nurFamilie = neu.every((e) => e.art == SicherheitsArt.mitgliedZugangZurueckgesetzt);
      final gezeigt = await anzeige.zeigenSicherheit(
        id: kSicherheitBenachrichtigungsId,
        titel: 'Sicherheitshinweis',
        text: nurFamilie
            ? 'In der Familie wurde ein Zugang zurückgesetzt. Details unter Profil > Sicherheitsereignisse.'
            : 'An deinem Konto hat sich etwas geändert. Details unter Profil > Sicherheitsereignisse.',
      );
      if (gezeigt) await _markieren(alle.first.zeit);
    } on ApiException catch (e) {
      if (!vordergrund) await _vielleichtAbgemeldet(e);
    } catch (_) {
      // ein Zusatz: der Abgleich und alles andere laufen unabhängig davon
    }
  }

  /// Hintergrund: Die Abfrage wurde abgelehnt, obwohl das Zugangstoken laut Uhr gilt (die Anfrage ging also hinaus): die Sitzung ist widerrufen.
  Future<void> _vielleichtAbgemeldet(ApiException e) async {
    if (e.code != ApiException.zugangAbgelaufen.code) return;
    try {
      final t = await store.readTokens();
      if (t == null || !t.accessExpiresAt.subtract(const Duration(seconds: 5)).isAfter(jetzt())) return; // abgelaufen: die Anfrage ging nie hinaus
      await db.metaSchreiben(kSicherheitAbgemeldetSchluessel, '1');
      if (!await anzeige.initialisieren()) return;
      await anzeige.zeigenSicherheit(id: kSicherheitAbgemeldetBenachrichtigungsId, titel: kSicherheitAbgemeldetTitel, text: kSicherheitAbgemeldetText);
    } catch (_) {}
  }
}

final sicherheitsPrueferProvider = Provider<SicherheitsPruefer>(
  (ref) => SicherheitsPruefer(api: ref.watch(apiProvider), db: ref.watch(appDatabaseProvider), anzeige: ref.watch(chatAnzeigePortProvider), store: ref.watch(tokenStoreProvider)),
);

/// Vordergrund oder nicht (für Aufrufer ohne eigenen Zustand).
bool appImVordergrund() => WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
