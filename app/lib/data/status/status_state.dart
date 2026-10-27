// Familien-Status (Abschnitt 6o): Schalter (nur lokal je Gerät in `sync_meta`, Standard AN), Repository (eigenen Status lokal schreiben, über den Sync) und die geltenden Stati.
// Ist der Schalter aus, liefert [familienStatusProvider] nichts: kein Status einer Person wird irgendwo gezeigt. Der eigene Status bleibt beim Server liegen und
// gilt wieder, sobald der Schalter an ist.
import 'dart:async';

import 'package:drift/drift.dart' show OrderingTerm;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_state.dart';
import '../app_database.dart';
import '../calendar/feiertage.dart' show feiertageSpeicherProvider;
import '../chat/chat_ids.dart' show statusId;
import '../database_provider.dart';
import '../sync/sync_store.dart';
import '../sync/sync_entities.dart' show zeitFuerServer;
import '../sync_state.dart' show syncProvider, syncStoreProvider;
import 'status_logik.dart';

const kStatusAnzeigenSchluessel = 'familien_status_anzeigen';

/// Schalter "Familien-Status anzeigen" (Standard an). Lese- und Schreibfehler ergeben den Standard bzw. gelten nur bis zum Schließen der App.
class StatusAnzeigenNotifier extends Notifier<bool> {
  /// Fertig, sobald der gespeicherte Wert gelesen ist.
  late Future<void> bereit;
  int _generation = 0;

  @override
  bool build() {
    final gen = ++_generation;
    bereit = _laden(gen);
    return true;
  }

  Future<void> _laden(int gen) async {
    var neu = true;
    try {
      neu = await ref.read(feiertageSpeicherProvider).lesen(schluessel: kStatusAnzeigenSchluessel) != 'nein';
    } catch (_) {
      // nicht lesbar: Standard
    }
    if (!ref.mounted || gen != _generation) return;
    state = neu;
  }

  // Eine Änderung wartet, bis der gespeicherte Stand gelesen ist (sonst überschriebe das späte Lesen die Eingabe der Person)
  Future<void> setzen(bool an) async {
    final gen = _generation;
    await bereit;
    if (!ref.mounted || gen != _generation) return;
    state = an;
    try {
      await ref.read(feiertageSpeicherProvider).schreiben(an ? 'ja' : 'nein', schluessel: kStatusAnzeigenSchluessel);
    } catch (_) {
      // gilt dann nur bis zum Schließen der App
    }
  }
}

final statusAnzeigenProvider = NotifierProvider<StatusAnzeigenNotifier, bool>(StatusAnzeigenNotifier.new);

/// Die Uhr des Status (in Tests überschreibbar).
final statusJetztProvider = Provider<DateTime Function()>((ref) => DateTime.now);

/// Eigenen Status schreiben und löschen. Nur die eigene Zeile (feste ID aus der Person); die Rechte prüft zusätzlich der Server.
class StatusRepository {
  final AppDatabase db;
  final SyncStore store;
  final String? Function() ich;
  final void Function() beiAenderung;
  final DateTime Function() jetzt;
  StatusRepository({required this.db, required this.store, required this.ich, required this.beiAenderung, required this.jetzt});

  /// Setzt den eigenen Status; false, wenn der Text nicht gültig ist, das Ende schon vorbei oder zu weit weg liegt (nichts wird geschrieben).
  Future<bool> setzen(String text, DateTime? bis) async {
    final me = ich();
    final t = statusTextPruefen(text);
    if (me == null || t == null) return false;
    final jetztZeit = jetzt();
    if (bis != null && (!bis.isAfter(jetztZeit) || bis.isAfter(jetztZeit.add(const Duration(days: kStatusMaxTage))))) return false;
    await store.aendern(
      'status',
      statusId(me),
      {'userId': me, 'text': t, 'bis': bis == null ? null : zeitFuerServer(bis)},
      nurLokal: {'createdAt': zeitFuerServer(jetztZeit)},
    );
    beiAenderung();
    return true;
  }

  /// Löscht den eigenen Status (nichts zu tun, wenn es keinen gibt).
  Future<void> loeschen() async {
    final me = ich();
    if (me == null) return;
    await store.loeschen('status', statusId(me));
    beiAenderung();
  }
}

final statusRepositoryProvider = Provider<StatusRepository>((ref) {
  return StatusRepository(
    db: ref.watch(appDatabaseProvider),
    store: ref.watch(syncStoreProvider),
    ich: () => ref.read(authProvider).user?.id,
    beiAenderung: () => ref.read(syncProvider.notifier).lokaleAenderung(),
    jetzt: ref.watch(statusJetztProvider),
  );
});

/// Alle Zeilen aus der lokalen Datenbank (auch abgelaufene).
final statusZeilenProvider = StreamProvider.autoDispose<List<FamilienStatusZeile>>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return (db.select(db.familienStati)..orderBy([(t) => OrderingTerm.asc(t.createdAt)])).watch();
});

/// Die Uhr für die Anzeige (jede Minute neu).
final statusUhrProvider = StreamProvider.autoDispose<DateTime>((ref) async* {
  final jetzt = ref.watch(statusJetztProvider);
  yield jetzt();
  yield* Stream<DateTime>.periodic(const Duration(minutes: 1), (_) => jetzt());
});

/// Die geltenden Stati der Familie. Leer, wenn der Schalter aus ist oder niemand angemeldet.
final familienStatusProvider = Provider.autoDispose<List<StatusEintrag>>((ref) {
  if (!ref.watch(statusAnzeigenProvider)) return const [];
  if (ref.watch(authProvider.select((a) => a.user?.id)) == null) return const [];
  final jetzt = ref.watch(statusUhrProvider).value ?? ref.watch(statusJetztProvider)();
  final zeilen = ref.watch(statusZeilenProvider).value ?? const <FamilienStatusZeile>[];
  return geltendeStati([for (final z in zeilen) StatusEintrag(userId: z.userId, text: z.statusText, bis: z.bis)], jetzt);
});

/// Der eigene geltende Status (null: keiner).
final eigenerStatusProvider = Provider.autoDispose<StatusEintrag?>((ref) {
  final ich = ref.watch(authProvider.select((a) => a.user?.id));
  if (ich == null) return null;
  return ref.watch(familienStatusProvider).where((s) => s.userId == ich).firstOrNull;
});
