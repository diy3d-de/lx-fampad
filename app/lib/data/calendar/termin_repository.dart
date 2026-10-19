// Termine für die Oberfläche: liest aus der lokalen Datenbank (Streams) und schreibt Änderungen sofort lokal (Tabelle und Ausgang,
// siehe SyncStore). Der Abgleich läuft im Hintergrund; hier wartet nichts auf das Netz.
//
// Serien ändern: "dieses" = Ausnahme zum Vorkommen (eine Zeile je Termin und ursprünglichem Beginn, mit fester ID aus beiden, damit zwei
// Geräte dieselbe Zeile ansprechen und nie zwei entstehen), "alle" = der Termin selbst, "dieses und folgende" = die Serie endet per UNTIL
// vor dem Vorkommen und ab dort beginnt eine neue Serie.
import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/models.dart';
import '../app_database.dart';
import '../auth/auth_state.dart';
import '../database_provider.dart';
import '../lists/list_repository.dart' show ListenSicht;
import '../sync/sync_entities.dart';
import '../sync/sync_store.dart';
import '../sync_state.dart';
import 'expansion.dart';
import 'wiederholung.dart';
import 'zeitzonen.dart';

/// Wer einen Termin sieht (gleiche Stufen wie bei Listen).
typedef TerminSicht = ListenSicht;

/// Alles, was die Person im Termin-Formular festlegt. Zeiten sind Wanduhrzeiten der Familienzone (`DateTime.utc`-Markierung);
/// bei ganztägigen Terminen sind [startWand]/[endeWand] Kalendertage, das Ende ist exklusiv.
class TerminEingabe {
  final String titel;
  final String ort;
  final String beschreibung;
  final bool ganztaegig;
  final DateTime startWand;
  final DateTime endeWand;
  final String? rrule;
  final int? erinnerungMin;
  final TerminSicht sicht;
  final Set<String> teilnehmer;
  const TerminEingabe({
    required this.titel,
    this.ort = '',
    this.beschreibung = '',
    required this.ganztaegig,
    required this.startWand,
    required this.endeWand,
    this.rrule,
    this.erinnerungMin,
    this.sicht = TerminSicht.family,
    this.teilnehmer = const {},
  });
}

/// Feste ID einer Ausnahme aus Termin und ursprünglichem Beginn (UUID-Form, SHA-1 wie Version 5): zwei Geräte, die dasselbe Vorkommen
/// ändern, schreiben dieselbe Zeile.
String ausnahmeId(String terminId, String schluessel) {
  final h = sha1.convert(utf8.encode('fampad-ausnahme|$terminId|$schluessel')).bytes;
  final b = List<int>.of(h.take(16));
  b[6] = (b[6] & 0x0f) | 0x50;
  b[8] = (b[8] & 0x3f) | 0x80;
  String x(int i) => b[i].toRadixString(16).padLeft(2, '0');
  return '${x(0)}${x(1)}${x(2)}${x(3)}-${x(4)}${x(5)}-${x(6)}${x(7)}-${x(8)}${x(9)}-${x(10)}${x(11)}${x(12)}${x(13)}${x(14)}${x(15)}';
}

/// Alle lokalen Kalenderdaten, nach Termin gruppiert.
class KalenderDaten {
  final List<Termin> termine;
  final Map<String, List<TerminAusnahme>> ausnahmen;
  final Map<String, List<TerminTeilnehmerZeile>> teilnehmer;
  const KalenderDaten({this.termine = const [], this.ausnahmen = const {}, this.teilnehmer = const {}});

  /// Personen, die an einem Termin teilnehmen (ohne doppelte Zeilen).
  Set<String> teilnehmerIds(String terminId) => {for (final t in teilnehmer[terminId] ?? const <TerminTeilnehmerZeile>[]) t.userId};

  Termin? termin(String id) => termine.where((t) => t.id == id).firstOrNull;
}

class TerminRepository {
  final AppDatabase db;
  final SyncStore store;
  final String? Function() ich;
  final void Function() beiAenderung;
  final DateTime Function() _jetzt;
  final String Function() _neueId;

  TerminRepository({
    required this.db,
    required this.store,
    required this.ich,
    required this.beiAenderung,
    DateTime Function()? jetzt,
    String Function()? neueId,
  }) : _jetzt = jetzt ?? DateTime.now,
       _neueId = neueId ?? neueUuid;

  Stream<List<Termin>> termine() => (db.select(db.termine)..orderBy([(t) => OrderingTerm.asc(t.createdAt), (t) => OrderingTerm.asc(t.id)])).watch();
  Stream<List<TerminTeilnehmerZeile>> teilnehmer() => db.select(db.terminTeilnehmer).watch();
  Stream<List<TerminAusnahme>> ausnahmen() => db.select(db.terminAusnahmen).watch();

  // ------------------------------------------------------------------ Termin

  Map<String, dynamic> _felder(TerminEingabe e) {
    final ort = familienOrt;
    if (e.ganztaegig) {
      return {
        'titel': e.titel.trim(),
        'ort': e.ort.trim(),
        'beschreibung': e.beschreibung.trim(),
        'ganztaegig': true,
        'startDate': tagText(e.startWand),
        'endDate': tagText(e.endeWand),
        'startUtc': null,
        'endUtc': null,
        'tzid': null,
        'rrule': e.rrule,
        'erinnerungMin': e.erinnerungMin,
        'audience': e.sicht.wire,
      };
    }
    return {
      'titel': e.titel.trim(),
      'ort': e.ort.trim(),
      'beschreibung': e.beschreibung.trim(),
      'ganztaegig': false,
      'startUtc': zeitFuerServer(instantAusWand(e.startWand, ort)),
      'endUtc': zeitFuerServer(instantAusWand(e.endeWand, ort)),
      'tzid': kFamilienZone,
      'startDate': null,
      'endDate': null,
      'rrule': e.rrule,
      'erinnerungMin': e.erinnerungMin,
      'audience': e.sicht.wire,
    };
  }

  Future<String> anlegen(TerminEingabe e) async {
    final id = _neueId();
    await store.aendern('termin', id, _felder(e), nurLokal: {'createdAt': zeitFuerServer(_jetzt()), 'ownerId': ich()});
    for (final u in e.teilnehmer) {
      await store.aendern('termin_teilnehmer', _neueId(), {'terminId': id, 'userId': u});
    }
    beiAenderung();
    return id;
  }

  /// Ändert den Termin selbst (bei Serien: alle Vorkommen). Gesendet werden nur die tatsächlich geänderten Felder, damit gleichzeitige
  /// Änderungen anderer Felder auf anderen Geräten nicht kollidieren.
  Future<void> alleAendern(String id, TerminEingabe e) async {
    final alt = await (db.select(db.termine)..where((t) => t.id.equals(id))).getSingleOrNull();
    if (alt == null) return;
    final neu = _felder(e);
    final bisher = <String, dynamic>{
      'titel': alt.titel,
      'ort': alt.ort,
      'beschreibung': alt.beschreibung,
      'ganztaegig': alt.ganztaegig,
      'startDate': alt.startDate,
      'endDate': alt.endDate,
      'startUtc': alt.startUtc == null ? null : zeitFuerServer(alt.startUtc!),
      'endUtc': alt.endUtc == null ? null : zeitFuerServer(alt.endUtc!),
      'tzid': alt.tzid,
      'rrule': alt.rrule,
      'erinnerungMin': alt.erinnerungMin,
      'audience': alt.audience,
    };
    final geaendert = {for (final k in neu.keys) if (neu[k] != bisher[k]) k: neu[k]};
    // beim Umschalten ganztägig <-> Zeit gehören die Felder der Art zusammen (der Server prüft das Ganze)
    if (geaendert.containsKey('ganztaegig') || geaendert.keys.any(const {'startUtc', 'endUtc', 'tzid', 'startDate', 'endDate'}.contains)) {
      for (final k in const ['ganztaegig', 'startUtc', 'endUtc', 'tzid', 'startDate', 'endDate']) {
        geaendert[k] = neu[k];
      }
    }
    if (geaendert.isNotEmpty) await store.aendern('termin', id, geaendert);
    await _teilnehmerAbgleichen(id, e.teilnehmer);
    beiAenderung();
  }

  Future<void> _teilnehmerAbgleichen(String terminId, Set<String> soll) async {
    final zeilen = await (db.select(db.terminTeilnehmer)..where((t) => t.terminId.equals(terminId))).get();
    final vorhanden = {for (final z in zeilen) z.userId};
    for (final u in soll.difference(vorhanden)) {
      await store.aendern('termin_teilnehmer', _neueId(), {'terminId': terminId, 'userId': u});
    }
    for (final z in zeilen) {
      if (!soll.contains(z.userId)) await store.loeschen('termin_teilnehmer', z.id);
    }
  }

  Future<void> alleLoeschen(String id) async {
    await store.loeschen('termin', id);
    beiAenderung();
  }

  // ------------------------------------------------------------------ Ausnahmen (nur dieses Vorkommen)

  Future<TerminAusnahme?> _ausnahme(String terminId, String schluessel) =>
      (db.select(db.terminAusnahmen)..where((a) => a.terminId.equals(terminId) & a.originalStart.equals(schluessel))).getSingleOrNull();

  Future<void> _ausnahmeSchreiben(String terminId, String schluessel, Map<String, dynamic> felder) async {
    final vorhanden = await _ausnahme(terminId, schluessel);
    if (vorhanden != null) {
      await store.aendern('termin_ausnahmen', vorhanden.id, felder);
    } else {
      await store.aendern('termin_ausnahmen', ausnahmeId(terminId, schluessel), {'terminId': terminId, 'originalStart': schluessel, ...felder});
    }
  }

  /// Nur dieses Vorkommen absagen (die Serie bleibt).
  Future<void> vorkommenAbsagen(Vorkommen v) async {
    await _ausnahmeSchreiben(v.termin.id, v.schluessel, {'abgesagt': true});
    beiAenderung();
  }

  /// Nur dieses Vorkommen ändern: Titel, Ort, Beginn und Ende (Wanduhr der Familienzone). Unveränderte Felder bleiben ohne Überschreibung.
  Future<void> vorkommenAendern(Vorkommen v, TerminEingabe e) async {
    final t = v.termin;
    final ortZone = familienOrt;
    String stempel(DateTime wand) => e.ganztaegig ? tagText(wand) : zeitSchluessel(instantAusWand(wand, ortZone));
    final startNeu = stempel(e.startWand);
    final endeNeu = stempel(e.endeWand);
    final startAlt = stempel(v.startWand);
    final endeAlt = stempel(v.endeWand);
    await _ausnahmeSchreiben(t.id, v.schluessel, {
      'abgesagt': false,
      'titel': e.titel.trim() == t.titel ? null : e.titel.trim(),
      'ort': e.ort.trim() == t.ort ? null : e.ort.trim(),
      'start': startNeu == startAlt ? null : startNeu,
      'ende': endeNeu == endeAlt && startNeu == startAlt ? null : endeNeu,
    });
    beiAenderung();
  }

  /// Hebt die Ausnahme zu diesem Vorkommen auf (es gilt wieder die Serie). Die Zeile bleibt als leere Ausnahme stehen.
  Future<void> vorkommenZuruecksetzen(Vorkommen v) async {
    if (await _ausnahme(v.termin.id, v.schluessel) == null) return;
    await _ausnahmeSchreiben(v.termin.id, v.schluessel, {'abgesagt': false, 'titel': null, 'ort': null, 'start': null, 'ende': null});
    beiAenderung();
  }

  // ------------------------------------------------------------------ dieses und alle folgenden

  /// Ist [v] das erste Vorkommen der Serie (dann ist "dieses und folgende" gleich "alle")?
  bool istErstes(Vorkommen v) {
    final t = v.termin;
    return t.ganztaegig ? v.schluessel == t.startDate : (t.startUtc != null && v.schluessel == zeitSchluessel(t.startUtc!));
  }

  Future<void> _serieKuerzen(Termin t, Vorkommen v) async {
    final regel = regelBis(t.rrule!, ganztaegig: t.ganztaegig, startUtc: v.startUtc, tag: v.ersterTag);
    await store.aendern('termin', t.id, {'rrule': regel});
  }

  /// Dieses und alle folgenden Vorkommen löschen: die Serie endet davor (das erste Vorkommen: die ganze Serie).
  Future<void> folgendeLoeschen(Vorkommen v) async {
    if (istErstes(v)) {
      await store.loeschen('termin', v.termin.id);
    } else {
      await _serieKuerzen(v.termin, v);
      // Ausnahmen ab diesem Vorkommen sind überflüssig
      final alle = await (db.select(db.terminAusnahmen)..where((a) => a.terminId.equals(v.termin.id))).get();
      for (final a in alle) {
        if (a.originalStart.compareTo(v.schluessel) >= 0) await store.loeschen('termin_ausnahmen', a.id);
      }
    }
    beiAenderung();
  }

  /// Dieses und alle folgenden Vorkommen ändern: die alte Serie endet vor diesem Vorkommen, ab dort beginnt eine neue Serie mit [e]
  /// (dessen Beginn ist der Beginn des geänderten Vorkommens). Das erste Vorkommen: die ganze Serie wird geändert.
  Future<String?> folgendeAendern(Vorkommen v, TerminEingabe e) async {
    final t = v.termin;
    if (t.rrule == null || istErstes(v)) {
      await alleAendern(t.id, e);
      return null;
    }
    final ausnahmenAlt = await (db.select(db.terminAusnahmen)..where((a) => a.terminId.equals(t.id))).get();
    // Bleibt die Regel (und die Uhrzeit) wie sie war, behalten die Ausnahmen ab hier ihre Bedeutung und ziehen mit um.
    final regelGleich = e.rrule == t.rrule;
    final uhrzeitGleich = e.ganztaegig == t.ganztaegig && e.startWand == v.startWand;
    var rrule = e.rrule;
    final anzahl = t.rrule == null ? null : regelAnzahl(t.rrule!);
    if (regelGleich && anzahl != null && rrule != null) {
      final davor = vorkommenVor(
        t.rrule!,
        startWand: t.ganztaegig ? tagAusText(t.startDate)! : wandUhr(t.startUtc!, ortFuer(t.tzid)),
        vorWand: t.ganztaegig ? v.ersterTag : wandUhr(v.startUtc, ortFuer(t.tzid)),
        ganztaegig: t.ganztaegig,
        ort: ortFuer(t.tzid),
      );
      rrule = regelMitAnzahl(rrule, (anzahl - davor).clamp(1, kMaxAnzahl));
    }
    await _serieKuerzen(t, v);
    final neuId = _neueId();
    final felder = _felder(TerminEingabe(
      titel: e.titel,
      ort: e.ort,
      beschreibung: e.beschreibung,
      ganztaegig: e.ganztaegig,
      startWand: e.startWand,
      endeWand: e.endeWand,
      rrule: rrule,
      erinnerungMin: e.erinnerungMin,
      sicht: e.sicht,
    ));
    await store.aendern('termin', neuId, felder, nurLokal: {'createdAt': zeitFuerServer(_jetzt()), 'ownerId': t.ownerId ?? ich()});
    for (final u in e.teilnehmer) {
      await store.aendern('termin_teilnehmer', _neueId(), {'terminId': neuId, 'userId': u});
    }
    for (final a in ausnahmenAlt) {
      if (a.originalStart.compareTo(v.schluessel) < 0) continue;
      if (regelGleich && uhrzeitGleich) {
        await store.aendern('termin_ausnahmen', ausnahmeId(neuId, a.originalStart), {
          'terminId': neuId,
          'originalStart': a.originalStart,
          'abgesagt': a.abgesagt,
          'titel': a.titel,
          'start': a.start,
          'ende': a.ende,
          'ort': a.ort,
        });
      }
      await store.loeschen('termin_ausnahmen', a.id);
    }
    beiAenderung();
    return neuId;
  }
}

final terminRepositoryProvider = Provider<TerminRepository>((ref) {
  return TerminRepository(
    db: ref.watch(appDatabaseProvider),
    store: ref.watch(syncStoreProvider),
    ich: () => ref.read(authProvider).user?.id,
    beiAenderung: () => ref.read(syncProvider.notifier).lokaleAenderung(),
  );
});

final termineProvider = StreamProvider.autoDispose<List<Termin>>((ref) => ref.watch(terminRepositoryProvider).termine());
final terminTeilnehmerProvider = StreamProvider.autoDispose<List<TerminTeilnehmerZeile>>((ref) => ref.watch(terminRepositoryProvider).teilnehmer());
final terminAusnahmenProvider = StreamProvider.autoDispose<List<TerminAusnahme>>((ref) => ref.watch(terminRepositoryProvider).ausnahmen());

/// Termine, Ausnahmen und Teilnehmer zusammen (leer, solange die Datenbank noch nichts geliefert hat).
final kalenderDatenProvider = Provider.autoDispose<KalenderDaten>((ref) {
  final termine = ref.watch(termineProvider).value ?? const <Termin>[];
  final ausnahmen = ref.watch(terminAusnahmenProvider).value ?? const <TerminAusnahme>[];
  final teilnehmer = ref.watch(terminTeilnehmerProvider).value ?? const <TerminTeilnehmerZeile>[];
  final nachTermin = <String, List<TerminAusnahme>>{};
  for (final a in ausnahmen) {
    nachTermin.putIfAbsent(a.terminId, () => []).add(a);
  }
  final tn = <String, List<TerminTeilnehmerZeile>>{};
  for (final z in teilnehmer) {
    tn.putIfAbsent(z.terminId, () => []).add(z);
  }
  return KalenderDaten(termine: termine, ausnahmen: nachTermin, teilnehmer: tn);
});

/// Was die Oberfläche der angemeldeten Rolle bei Terminen anbietet. Spiegelt server/src/sync/entities/termine.ts; maßgeblich ist der Server.
class TerminRechte {
  final Role rolle;
  final String? userId;
  const TerminRechte(this.rolle, this.userId);

  bool get _erwachsen => rolle == Role.admin || rolle == Role.parent;

  /// Gäste legen keine Termine an.
  bool get darfAnlegen => rolle != Role.guest;

  /// Eltern alle, Kinder nur ihre eigenen.
  bool darfAendern(Termin t) => _erwachsen || (rolle == Role.child && userId != null && t.ownerId == userId);

  bool get darfFreigabeAendern => _erwachsen;

  List<TerminSicht> get freigaben => _erwachsen ? TerminSicht.values : const [TerminSicht.family];
}
