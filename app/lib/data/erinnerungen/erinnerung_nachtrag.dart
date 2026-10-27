// Einmalige Nachtragung der Standard-Erinnerung (Profil > Kalender) bei vorhandenen Terminen ohne Erinnerung.
//
// Warum so: `erinnerungMin` ist ein geteiltes Termin-Feld (Sync). `null` = nie gesetzt (Altbestand), -1 = bewusst keine Erinnerung
// (`termin_erinnerung.dart`, Server seit Migration 0038). Die Nachtragung fasst darum NUR `null` an und setzt die Standard-Erinnerung; eine
// bewusste Wahl "Keine" (-1) wird nie überschrieben, auch nicht von einem zweiten Gerät. Die Marke in `sync_meta` (je Person und Gerät, erst
// nach vollständigem Lauf gesetzt) spart nur Aufwand: der Lauf passiert einmal. Sie fasst nur Termine an,die noch bevorstehen (bzw. laufende Serien), die die Person ändern darf und die sie
// selbst betreffen (Ersteller oder Teilnehmer; andere Personen holen ihre eigenen Termine auf ihren Geräten nach), nie Geburtstage.
// Geschrieben wird in Stapeln zu 50 Änderungen (= Obergrenze einer Sync-Anfrage) über `SyncStore.aendernMehrere`, nie ohne Marke.
// Ist die Standard-Erinnerung dieses Geräts "Keine", wird nichts nachgetragen (die Marke wird trotzdem gesetzt).
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/models.dart' show Role;
import '../app_database.dart';
import '../auth/auth_state.dart';
import '../calendar/expansion.dart' show tagAusText;
import '../calendar/geburtstag.dart' show hatGeburtstagsMarke;
import '../calendar/termin_repository.dart';
import '../calendar/zeitzonen.dart' show familienOrt, wandUhr, zeitzonenBereit;
import '../database_provider.dart';
import '../sync/sync_store.dart';
import '../sync_state.dart';
import 'erinnerung_einstellungen.dart';
import 'erinnerung_planung.dart' show betrifftPerson;

const kNachtragStapel = 50;

/// Schlüssel der Marke je Person in `sync_meta`.
String nachtragMarke(String userId) => 'kalender_erinnerung_nachtrag_$userId';

final _untilMuster = RegExp(r'UNTIL=(\d{4})(\d{2})(\d{2})');

/// Termine, die die Nachtragung anfasst (rein). [heute] ist der Kalendertag in der Familienzone (`DateTime.utc(j, m, t)`).
List<Termin> nachtragKandidaten({
  required KalenderDaten daten,
  required String? ich,
  required Role rolle,
  required DateTime jetzt,
  required DateTime heute,
}) {
  if (ich == null) return const [];
  final rechte = TerminRechte(rolle, ich);
  final out = <Termin>[];
  for (final t in daten.termine) {
    if (t.erinnerungMin != null || hatGeburtstagsMarke(t)) continue;
    if (!rechte.darfAendern(t) || !betrifftPerson(t.ownerId, daten.teilnehmerIds(t.id), ich)) continue;
    if (!_bevorstehend(t, jetzt, heute)) continue;
    out.add(t);
  }
  return out;
}

bool _bevorstehend(Termin t, DateTime jetzt, DateTime heute) {
  final regel = t.rrule;
  if (regel != null && regel.isNotEmpty) {
    // Serie: läuft noch, solange kein UNTIL in der Vergangenheit liegt (COUNT wird nicht ausgewertet: im Zweifel nachtragen)
    final m = _untilMuster.firstMatch(regel);
    if (m == null) return true;
    final bis = DateTime.utc(int.parse(m.group(1)!), int.parse(m.group(2)!), int.parse(m.group(3)!));
    return !bis.isBefore(heute);
  }
  if (t.ganztaegig) {
    final s = tagAusText(t.startDate);
    return s != null && !s.isBefore(heute);
  }
  final s = t.startUtc;
  return s != null && s.toUtc().isAfter(jetzt.toUtc());
}

/// Führt die Nachtragung aus und liefert die Zahl der geänderten Termine (0 = nichts zu tun oder schon erledigt).
Future<int> nachtragAusfuehren({
  required AppDatabase db,
  required SyncStore store,
  required KalenderDaten daten,
  required String ich,
  required Role rolle,
  required int? standardVorlauf,
  required DateTime jetzt,
  void Function()? beiAenderung,
}) async {
  final marke = nachtragMarke(ich);
  if (await db.metaLesen(marke) != null) return 0;
  var n = 0;
  if (standardVorlauf != null && standardVorlauf >= 0) {
    final w = wandUhr(jetzt.toUtc(), familienOrt);
    final liste = nachtragKandidaten(daten: daten, ich: ich, rolle: rolle, jetzt: jetzt, heute: DateTime.utc(w.year, w.month, w.day));
    for (var i = 0; i < liste.length; i += kNachtragStapel) {
      final stapel = liste.skip(i).take(kNachtragStapel).toList();
      await store.aendernMehrere([for (final t in stapel) SyncAenderung('termin', t.id, {'erinnerungMin': standardVorlauf})]);
      n += stapel.length;
    }
    if (n > 0) beiAenderung?.call();
  }
  await db.metaSchreiben(marke, '1');
  return n;
}

/// Löst die Nachtragung aus, sobald angemeldet, abgeglichen und die lokalen Daten da sind (am Wurzel-Widget beobachtet, auf allen Plattformen).
final erinnerungNachtragProvider = Provider<void>((ref) {
  var laeuft = false;
  Future<void> versuche() async {
    if (laeuft) return;
    final auth = ref.read(authProvider);
    final user = auth.user;
    if (auth.status != AuthStatus.angemeldet || user == null) return;
    if (ref.read(syncProvider).status != SyncStatus.synchron || !zeitzonenBereit()) return;
    laeuft = true;
    try {
      await ref.read(erinnerungEinstellungenProvider.notifier).bereit;
      if (!ref.mounted) return;
      final termine = await ref.read(termineProvider.future);
      if (!ref.mounted || termine.isEmpty) return; // ohne Termine noch nichts zu tun: später erneut
      await nachtragAusfuehren(
        db: ref.read(appDatabaseProvider),
        store: ref.read(syncStoreProvider),
        daten: ref.read(kalenderDatenProvider),
        ich: user.id,
        rolle: user.role,
        standardVorlauf: ref.read(erinnerungEinstellungenProvider).standardVorlauf,
        jetzt: DateTime.now(),
        beiAenderung: () => ref.read(syncProvider.notifier).lokaleAenderung(),
      );
    } catch (_) {
      // nicht schlimm: ohne Marke folgt der nächste Versuch beim nächsten Abgleich
    } finally {
      laeuft = false;
    }
  }

  ref.listen(syncProvider.select((s) => s.status), (_, _) => unawaited(versuche()));
  ref.listen(authProvider.select((a) => (a.status, a.user?.id)), (_, _) => unawaited(versuche()));
  Future.microtask(versuche);
});
