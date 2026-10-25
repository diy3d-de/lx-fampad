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
import 'termin_farben.dart';
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

  /// Nur für Geburtstage (Marke, siehe geburtstag.dart); sonst null = das Feld bleibt unberührt.
  final String? icalUid;

  /// Termin-Farbe (Index 0 bis 10, `kTerminFarben`); null = keine (Personenfarbe). Gehört zur Serie, Ausnahmen erben sie.
  final int? farbe;
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
    this.icalUid,
    this.farbe,
  });
}

/// Die Zeitzonen-Daten fehlen: Anlegen und Ändern würde Uhrzeiten und Sommerzeit falsch speichern.
class ZeitzonenFehlen implements Exception {
  const ZeitzonenFehlen();

  @override
  String toString() => 'Zeitzonen-Daten nicht geladen';
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

  void _pruefeZeit() {
    if (!zeitzonenBereit()) throw const ZeitzonenFehlen();
  }

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
        'icalUid': ?e.icalUid,
        'farbe': terminFarbeNummer(e.farbe),
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
      'farbe': terminFarbeNummer(e.farbe),
    };
  }

  /// Beim Anlegen wird nur eine gesetzte Farbe gesendet (alte Server und Termine ohne Farbe bleiben unberührt).
  Map<String, dynamic> _felderNeu(TerminEingabe e) => _felder(e)..removeWhere((k, v) => k == 'farbe' && v == null);

  Future<String> anlegen(TerminEingabe e) async {
    _pruefeZeit();
    final id = _neueId();
    await store.aendern('termin', id, _felderNeu(e), nurLokal: {'createdAt': zeitFuerServer(_jetzt()), 'ownerId': ich()});
    for (final u in e.teilnehmer) {
      await store.aendern('termin_teilnehmer', _neueId(), {'terminId': id, 'userId': u});
    }
    beiAenderung();
    return id;
  }

  /// Ändert den Termin selbst (bei Serien: alle Vorkommen). Gesendet werden nur die tatsächlich geänderten Felder, damit gleichzeitige
  /// Änderungen anderer Felder auf anderen Geräten nicht kollidieren. Ändern sich Beginn, Art oder Regel einer Serie, verlieren die Schlüssel
  /// ihrer Ausnahmen ihre Bedeutung: bei reiner Änderung der Uhrzeit ziehen sie mit, sonst werden sie zurückgesetzt. Liefert, wie viele Ausnahmen
  /// dabei zurückgesetzt wurden (die Oberfläche weist darauf hin).
  Future<int> alleAendern(String id, TerminEingabe e) async {
    _pruefeZeit();
    final alt = await (db.select(db.termine)..where((t) => t.id.equals(id))).getSingleOrNull();
    if (alt == null) return 0;
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
      'icalUid': alt.icalUid,
      'farbe': terminFarbeNummer(alt.farbe),
    };
    // Ein Termin in einer anderen Zeitzone (z. B. später importiert) behält sie, solange sein Beginn derselbe Zeitpunkt bleibt
    // (sonst änderte sich seine Wanduhrzeit in Serien über die Zeitumstellung).
    if (!alt.ganztaegig && alt.tzid != null && alt.tzid != kFamilienZone && neu['startUtc'] == bisher['startUtc']) neu['tzid'] = alt.tzid;
    final geaendert = {for (final k in neu.keys) if (neu[k] != bisher[k]) k: neu[k]};
    // beim Umschalten ganztägig <-> Zeit gehören die Felder der Art zusammen (der Server prüft das Ganze)
    if (geaendert.containsKey('ganztaegig') || geaendert.keys.any(const {'startUtc', 'endUtc', 'tzid', 'startDate', 'endDate'}.contains)) {
      for (final k in const ['ganztaegig', 'startUtc', 'endUtc', 'tzid', 'startDate', 'endDate']) {
        geaendert[k] = neu[k];
      }
    }
    final verworfen = await _ausnahmenAnpassen(alt, neu);
    if (geaendert.isNotEmpty) await store.aendern('termin', id, geaendert);
    await _teilnehmerAbgleichen(id, e.teilnehmer);
    beiAenderung();
    return verworfen;
  }

  static bool _leer(TerminAusnahme a) => !a.abgesagt && a.titel == null && a.start == null && a.ende == null && a.ort == null;

  /// Setzt eine Ausnahme zurück (alle Felder leer). Die Zeile wird nie gelöscht: ihre feste ID bliebe sonst als Tombstone am Server stehen und
  /// ließe sich für dasselbe Vorkommen nicht wieder verwenden.
  Future<void> _ausnahmeLeeren(TerminAusnahme a) async {
    if (_leer(a)) return;
    await store.aendern('termin_ausnahmen', a.id, {'abgesagt': false, 'titel': null, 'start': null, 'ende': null, 'ort': null});
  }

  /// Passt die Ausnahmen an einen geänderten Termin an (siehe [alleAendern]). Liefert die Zahl der zurückgesetzten Ausnahmen.
  Future<int> _ausnahmenAnpassen(Termin alt, Map<String, dynamic> neu) async {
    if (alt.rrule == null) return 0;
    final alle = await (db.select(db.terminAusnahmen)..where((a) => a.terminId.equals(alt.id))).get();
    final lebend = alle.where((a) => !_leer(a)).toList();
    if (lebend.isEmpty) return 0;
    Future<int> verwerfen() async {
      for (final a in lebend) {
        await _ausnahmeLeeren(a);
      }
      return lebend.length;
    }

    if (alt.ganztaegig != (neu['ganztaegig'] as bool) || alt.rrule != neu['rrule']) return verwerfen();
    if (alt.ganztaegig) return alt.startDate == neu['startDate'] ? 0 : verwerfen();
    if (alt.startUtc == null || neu['startUtc'] == null) return verwerfen();
    final ortAlt = ortFuer(alt.tzid);
    final ortNeu = ortFuer(neu['tzid'] as String?);
    final altWand = wandUhr(alt.startUtc!, ortAlt);
    final neuWand = wandUhr(DateTime.parse(neu['startUtc'] as String), ortNeu);
    if (alt.tzid != neu['tzid']) return verwerfen();
    if (altWand == neuWand) return 0;
    // nur die Uhrzeit hat sich geändert (derselbe Tag): die Schlüssel ziehen um, Absagen und Änderungen bleiben an ihrem Vorkommen
    if (altWand.year != neuWand.year || altWand.month != neuWand.month || altWand.day != neuWand.day) return verwerfen();
    final delta = neuWand.difference(altWand);
    for (final a in lebend) {
      final wandAlt = wandUhr(DateTime.parse(a.originalStart), ortAlt);
      final neuerSchluessel = zeitSchluessel(instantAusWand(wandAlt.add(delta), ortAlt));
      if (neuerSchluessel == a.originalStart) continue;
      await _ausnahmeSchreiben(alt.id, neuerSchluessel, {'abgesagt': a.abgesagt, 'titel': a.titel, 'start': a.start, 'ende': a.ende, 'ort': a.ort});
      await _ausnahmeLeeren(a);
    }
    return 0;
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

  /// Nur dieses Vorkommen ändern: Titel, Ort, Beginn und Ende (Wanduhr der Familienzone). Verglichen wird immer mit dem URSPRÜNGLICHEN
  /// Vorkommen der Serie (nicht mit einer schon verschobenen Anzeige): eine Änderung nur des Titels lässt eine frühere Verschiebung bestehen,
  /// und ein zurück auf die ursprüngliche Zeit hebt sie auf. Ist die Zeit geändert, werden Beginn und Ende gemeinsam gespeichert.
  Future<void> vorkommenAendern(Vorkommen v, TerminEingabe e) async {
    _pruefeZeit();
    final t = v.termin;
    final ortZone = familienOrt;
    String stempel(DateTime wand) => e.ganztaegig ? tagText(wand) : zeitSchluessel(instantAusWand(wand, ortZone));
    final startNeu = stempel(e.startWand);
    final endeNeu = stempel(e.endeWand);
    final zeitGeaendert = startNeu != stempel(v.originalStartWand) || endeNeu != stempel(v.originalEndeWand);
    await _ausnahmeSchreiben(t.id, v.schluessel, {
      'abgesagt': false,
      'titel': e.titel.trim() == t.titel ? null : e.titel.trim(),
      'ort': e.ort.trim() == t.ort ? null : e.ort.trim(),
      'start': zeitGeaendert ? startNeu : null,
      'ende': zeitGeaendert ? endeNeu : null,
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

  /// Tag des ursprünglichen Beginns (Kalendertag der Wanduhr der Familienzone, bei Zeitterminen in der Zeitzone des Termins).
  DateTime _originalTag(Vorkommen v) => v.termin.ganztaegig ? v.originalStartWand : _tagVon(wandUhr(v.originalStartUtc, ortFuer(v.termin.tzid)));

  static DateTime _tagVon(DateTime w) => DateTime.utc(w.year, w.month, w.day);

  /// Kürzt die Serie bis vor das ursprüngliche Vorkommen (nicht vor eine womöglich verschobene Anzeige).
  Future<void> _serieKuerzen(Termin t, Vorkommen v) async {
    final regel = regelBis(t.rrule!, ganztaegig: t.ganztaegig, startUtc: v.originalStartUtc, tag: _originalTag(v));
    await store.aendern('termin', t.id, {'rrule': regel});
  }

  /// Dieses und alle folgenden Vorkommen löschen: die Serie endet davor (das erste Vorkommen: die ganze Serie).
  Future<void> folgendeLoeschen(Vorkommen v) async {
    if (istErstes(v)) {
      await store.loeschen('termin', v.termin.id);
    } else {
      await _serieKuerzen(v.termin, v);
      // Ausnahmen ab diesem Vorkommen sind überflüssig: zurücksetzen statt löschen (die feste ID bliebe sonst als Tombstone stehen)
      final alle = await (db.select(db.terminAusnahmen)..where((a) => a.terminId.equals(v.termin.id))).get();
      for (final a in alle) {
        if (a.originalStart.compareTo(v.schluessel) >= 0) await _ausnahmeLeeren(a);
      }
    }
    beiAenderung();
  }

  /// Dieses und alle folgenden Vorkommen ändern: die alte Serie endet vor diesem Vorkommen, ab dort beginnt eine neue Serie mit [e]
  /// (dessen Beginn ist der Beginn des geänderten Vorkommens). Das erste Vorkommen: die ganze Serie wird geändert (Liefert dann null).
  ///
  /// Der neue Teil gehört der Person, die ihn anlegt (der Server setzt den Ersteller aus der Sitzung), auch wenn die alte Serie jemand anderem gehörte;
  /// eine Änderung durch Eltern an der Serie eines Kindes macht den neuen Teil also zu einem Elterntermin (das Kind ändert ihn nicht mehr).
  Future<String?> folgendeAendern(Vorkommen v, TerminEingabe e) async {
    _pruefeZeit();
    final t = v.termin;
    if (t.rrule == null || istErstes(v)) {
      await alleAendern(t.id, e);
      return null;
    }
    final ausnahmenAlt = await (db.select(db.terminAusnahmen)..where((a) => a.terminId.equals(t.id))).get();
    // Bleibt die Regel (und der ursprüngliche Beginn) wie sie war, behalten die Ausnahmen ab hier ihre Bedeutung und ziehen mit um.
    final regelGleich = e.rrule == t.rrule;
    final beginnGleich = e.ganztaegig == t.ganztaegig && e.startWand == v.originalStartWand;
    var rrule = e.rrule;
    final anzahl = t.rrule == null ? null : regelAnzahl(t.rrule!);
    if (regelGleich && anzahl != null && rrule != null) {
      final ort = ortFuer(t.tzid);
      final davor = vorkommenVor(
        t.rrule!,
        startWand: t.ganztaegig ? tagAusText(t.startDate)! : wandUhr(t.startUtc!, ort),
        vorWand: t.ganztaegig ? v.originalStartWand : wandUhr(v.originalStartUtc, ort),
        ganztaegig: t.ganztaegig,
        ort: ort,
      );
      rrule = regelMitAnzahl(rrule, (anzahl - davor).clamp(1, kMaxAnzahl));
    }
    await _serieKuerzen(t, v);
    final neuId = _neueId();
    final felder = _felderNeu(TerminEingabe(
      titel: e.titel,
      ort: e.ort,
      beschreibung: e.beschreibung,
      ganztaegig: e.ganztaegig,
      startWand: e.startWand,
      endeWand: e.endeWand,
      rrule: rrule,
      erinnerungMin: e.erinnerungMin,
      sicht: e.sicht,
      farbe: e.farbe,
    ));
    await store.aendern('termin', neuId, felder, nurLokal: {'createdAt': zeitFuerServer(_jetzt()), 'ownerId': ich()});
    for (final u in e.teilnehmer) {
      await store.aendern('termin_teilnehmer', _neueId(), {'terminId': neuId, 'userId': u});
    }
    for (final a in ausnahmenAlt) {
      if (a.originalStart.compareTo(v.schluessel) < 0) continue;
      if (regelGleich && beginnGleich && !_leer(a)) {
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
      await _ausnahmeLeeren(a);
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

  /// Alle Rollen legen Termine an; Kinder nur Familientermine.
  bool get darfAnlegen => true;

  /// Eltern alle, Kinder nur ihre eigenen.
  bool darfAendern(Termin t) => _erwachsen || (rolle == Role.child && userId != null && t.ownerId == userId);

  bool get darfFreigabeAendern => _erwachsen;

  List<TerminSicht> get freigaben => _erwachsen ? TerminSicht.values : const [TerminSicht.family];
}
