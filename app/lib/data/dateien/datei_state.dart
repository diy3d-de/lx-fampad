// Dateiablage (Abschnitt 6n), Zustand für die Oberfläche: Gating über `GET /version` (`features.files`), Rechte, Streams der Ordner und Dateien, Zahlen des Servers, Fortsetzen der Übertragungen
// nach dem Start. Noch ohne Oberfläche und ohne Menüeinträge: die Dateien-UI und die Anhänge im Tresor folgen als eigene Teile und bauen auf diesen Providern auf.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_error.dart';
import '../api/models.dart' show Role;
import '../app_database.dart';
import '../auth/auth_state.dart';
import '../database_provider.dart';
import 'datei_logik.dart';
import 'datei_modelle.dart';
import 'datei_repository.dart';
import 'transfer_dienst.dart';

/// Schlüssel in `sync_meta`: zuletzt bekannte Antwort des Servers (`1`/`0`), damit der Bereich offline sichtbar bleibt.
const String kDateienVerfuegbarSchluessel = 'dateien_verfuegbar';

/// Bietet die App den Bereich Dateien (und Anhänge im Tresor) an? Nur wenn der Server `features.files` meldet (Schalter `FILES_ENABLED`); ein älterer Server ohne das Feld ergibt `false`.
/// Ist der Server gerade nicht erreichbar (offline), gilt die zuletzt bekannte Antwort (lokal gemerkt, ohne Angabe: nicht verfügbar). Nur mit Anmeldung; neu bestimmt beim Anmelden.
final dateienVerfuegbarProvider = FutureProvider<bool>((ref) async {
  if (ref.watch(authProvider.select((a) => a.status != AuthStatus.angemeldet))) return false;
  final db = ref.read(appDatabaseProvider);
  try {
    final an = (await ref.read(apiProvider).serverFaehigkeiten()).files;
    unawaited(db.metaSchreiben(kDateienVerfuegbarSchluessel, an ? '1' : '0'));
    return an;
  } on ApiException {
    return await db.metaLesen(kDateienVerfuegbarSchluessel) == '1';
  }
});

/// Rechte der Oberfläche (nur nach der Rolle der Sitzung).
final dateiRechteProvider = Provider<DateiRechte>((ref) {
  final u = ref.watch(authProvider.select((a) => a.user));
  // ohne Anmeldung die engsten Rechte (Kind, keine Person)
  if (u == null) return const DateiRechte(rolle: Role.child, ich: null);
  return DateiRechte(rolle: u.role, ich: u.id);
});

/// Alle Ordner, die die Person sehen darf (für Brotkrumen, Zielauswahl, Pfadanzeige).
final alleOrdnerProvider = StreamProvider<List<OrdnerZeile>>((ref) => ref.watch(dateiRepositoryProvider).alleOrdner());

/// Ordner direkt in einem Ordner (`null` = oberste Ebene), nach Namen sortiert.
final ordnerInProvider = StreamProvider.family<List<OrdnerZeile>, String?>((ref, parentId) => ref.watch(dateiRepositoryProvider).ordnerIn(parentId));

/// Dateien direkt in einem Ordner (`null` = oberste Ebene) mit ihrer neuesten Fassung, nach Namen sortiert.
final dateienInProvider = StreamProvider.family<List<DateiEintrag>, String?>((ref, ordnerId) => ref.watch(dateiRepositoryProvider).dateienIn(ordnerId));

/// Alle Fassungen einer Datei, neueste zuerst.
final dateiVersionenProvider = StreamProvider.family<List<DateiVersionZeile>, String>((ref, dateiId) => ref.watch(dateiRepositoryProvider).versionen(dateiId));

/// Zahlen des Servers (belegt, Kontingent, Grenzen); neu geholt, wenn die Seite sie wieder braucht. Ein Fehler (offline) wirft: die Oberfläche zeigt dann keine Anzeige.
final dateiNutzungProvider = FutureProvider.autoDispose<DateiNutzung>((ref) => ref.watch(apiProvider).dateiNutzung());

/// Kontingent-Anzeige aus den Zahlen des Servers.
final kontingentAnzeigeProvider = Provider.autoDispose<KontingentAnzeige?>((ref) {
  final n = ref.watch(dateiNutzungProvider).value;
  return n == null ? null : KontingentAnzeige.aus(n);
});

/// Nach dem Start (angemeldet, Dateiablage eingeschaltet): liegengebliebene Übertragungen wieder in die Schlange (eine nach der anderen). Am Wurzel-Widget beobachtet (app.dart). Ohne Dateiablage
/// auf dem Server oder ohne Anmeldung passiert nichts (und es gibt auch keine Zeilen).
final transferSteuerungProvider = Provider<void>((ref) {
  final an = ref.watch(dateienVerfuegbarProvider).value ?? false;
  if (!an || !ref.watch(authProvider.select((a) => a.status == AuthStatus.angemeldet))) return;
  Future.microtask(() async {
    if (!ref.mounted) return;
    try {
      await ref.read(transferDienstProvider).wiederaufnehmen();
    } on Object {
      // ein Fehler hier stört nichts: der nächste Start versucht es erneut
    }
  });
});
