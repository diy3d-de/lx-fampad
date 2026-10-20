// Hintergrund-Start durch einen Push-Wecker. Das Android-Plugin (unifiedpush_android) startet bei einer Nachricht, wenn gerade keine
// Flutter-Engine mit dem Plugin läuft, eine Engine OHNE Oberfläche und ruft main() mit dem Argument "--unifiedpush-bg" auf.
// Dann wird nur abgeglichen (und neue Ereignisse an [EreignisBenachrichtiger] gemeldet), nie runApp aufgerufen.
//
// Regeln:
//  - Nie das Refresh-Token einlösen: Der Hintergrund-Client ist ein ApiClient mit refreshErlaubt: false. Ist das Access-Token abgelaufen
//    oder wird es abgelehnt, endet der Lauf ohne Tokenzugriff und ohne die Sitzung zu verwerfen; der nächste Start der App gleicht ab.
//    (Zwei Engines dürften sonst dasselbe Refresh-Token einlösen: der Server würde die ganze Familie widerrufen.)
//  - Serialisiert und gedrosselt ([WeckerLauf]): höchstens ein Lauf zugleich, mindestens 10 s zwischen zwei Läufen, Wecker dazwischen
//    werden zu einem Lauf zusammengefasst. Das Plugin ruft den Dart-Code auf jeden Wecker; eine Flut (auch von fremden Apps, die die
//    exportierte Empfänger-Komponente ansprechen) führt so zu höchstens einem Abgleich je 10 s.
//  - Jeder Lauf nutzt einen eigenen, kurzlebigen ProviderContainer, der danach samt Datenbankverbindung geschlossen wird: So hält diese
//    Engine die lokale Datenbank nicht offen, wenn die Person die App später öffnet (zwei Engines, eine SQLite-Datei; busy_timeout 5 s).
//  - Höchstdauer 25 s: danach wird der Lauf abgebrochen (keine Schreibzugriffe mehr) und der Container geschlossen.
//
// Grenzen (bewusst): Der Abgleich läuft nur, solange Android den Prozess lässt (wenige Sekunden nach dem Wecker). Scheitert er, holt die
// App es beim nächsten Öffnen nach: der Sync läuft ohnehin bei jedem Start. Mit geöffneter App bekommt die laufende Engine den Wecker
// (PushController), nicht diese Funktion.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;

import '../api/api_client.dart';
import '../api/api_error.dart';
import '../auth/auth_state.dart';
import '../providers.dart';
import '../sync/sync_engine.dart';
import '../standort/standort_abruf.dart';
import '../sync_state.dart';
import 'chat_benachrichtiger_provider.dart';
import 'push_plattform.dart';
import 'push_plattform_fabrik.dart';
import 'push_wecker.dart';

/// Argument, mit dem das Plugin den Hintergrund-Start kennzeichnet.
const kPushHintergrundArgument = '--unifiedpush-bg';

/// Container des Hintergrund-Abgleichs: der API-Client darf nie das Refresh-Token einlösen.
ProviderContainer hintergrundContainer({List<Override> zusaetzlich = const []}) => ProviderContainer(
  overrides: [
    ...zusaetzlich,
    // keine Chat-Verschlüsselung im Wecker-Start: kein Schlüsselbund, kein ChatKryptoController (Klartext im Ausgang geht hier nie hinaus)
    opVorbereiterProvider.overrideWithValue(null),
    // lokale Benachrichtigung über neue Chat-Nachrichten (ohne Inhalt)
    ereignisBenachrichtigerProvider.overrideWith((ref) => ref.watch(chatBenachrichtigerProvider)),
    apiClientProvider.overrideWith((ref) => ApiClient(client: ref.watch(httpClientProvider), store: ref.watch(tokenStoreProvider), refreshErlaubt: false)),
  ],
);

/// Mit austauschbarer Plattform und Container-Fabrik für Tests.
Future<WeckerLauf?> pushHintergrundStarten({
  PushPlattform? plattform,
  ProviderContainer Function()? containerFabrik,
  EreignisBenachrichtiger? ereignisse,
  Duration abstand = const Duration(seconds: 10),
  Duration hoechstdauer = const Duration(seconds: 25),
}) async {
  final p = plattform ?? neuePushPlattform();
  if (!p.unterstuetzt) return null;
  ProviderContainer neu() => containerFabrik != null ? containerFabrik() : hintergrundContainer();

  final lauf = WeckerLauf(
    abstand: abstand,
    lauf: () async {
      final c = neu();
      var abgebrochen = false;
      try {
        final engine = c.read(syncEngineProvider);
        await weckerAbgleichen(
          store: c.read(syncStoreProvider),
          abgleich: () async {
            await engine
                .abgleichen(abgebrochen: () => abgebrochen)
                .timeout(
                  hoechstdauer,
                  onTimeout: () {
                    abgebrochen = true;
                    return const SyncErgebnis(SyncAusgang.abgebrochen);
                  },
                );
          },
          ereignisse: ereignisse ?? c.read(ereignisBenachrichtigerProvider),
        );
        // Standortfreigaben: der Wecker enthält nichts, die App fragt den Standort-Kanal kurz ab und meldet neue Freigaben lokal
        if (!abgebrochen) {
          try {
            await c.read(standortAbrufProvider).abfragen();
          } catch (_) {
            // Zusatz: ein Fehler hier darf den Wecker nicht stören
          }
        }
      } finally {
        abgebrochen = true;
        c.dispose();
      }
    },
  );

  // Ein Verteiler kann den Endpunkt auch ändern, während die App geschlossen ist: dann dem Server den neuen melden.
  Future<void> endpunkt(String url) async {
    final c = neu();
    try {
      await c.read(apiProvider).pushAnmelden(url);
    } on ApiException {
      // abgelehnt, offline oder Access-Token abgelaufen: beim nächsten Öffnen der App meldet sie sich selbst neu an
    } catch (_) {
    } finally {
      c.dispose();
    }
  }

  await p.initialisieren(
    PushRueckrufe(
      beiEndpunkt: (url) => unawaited(endpunkt(url)),
      beiFehler: (_) {},
      beiAbgemeldet: () {},
      beiWecker: lauf.ausloesen,
    ),
  );
  return lauf;
}
