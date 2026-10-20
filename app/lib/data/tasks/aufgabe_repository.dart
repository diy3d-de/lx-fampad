// Aufgaben für die Oberfläche: liest aus der lokalen Datenbank (Streams) und schreibt Änderungen sofort lokal (Tabelle und Ausgang, siehe
// SyncStore). Der Abgleich läuft im Hintergrund; hier wartet nichts auf das Netz.
//
// Wiederholung: Wird eine wiederkehrende Aufgabe erledigt, legt der Client die nächste an (Fälligkeit siehe naechsteFaelligkeit). Die ID der
// Folgeaufgabe ist fest aus der erledigten Aufgabe abgeleitet: erledigen zwei Geräte dieselbe Aufgabe, schreiben beide dieselbe Zeile, es
// entsteht nie eine doppelte Folgeaufgabe. Ist die abgeleitete ID schon belegt (berechenbar: jemand könnte sie vorab anlegen), nimmt die App
// eine zufällige und merkt sie sich in `folgeId` der erledigten Aufgabe. Die Unteraufgaben der Folgeaufgabe bekommen feste IDs aus ihrer ID und der des Originals.
import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/models.dart';
import '../app_database.dart';
import '../auth/auth_state.dart';
import '../calendar/expansion.dart' show tagText;
import '../calendar/termin_repository.dart' show ZeitzonenFehlen;
import '../calendar/zeitzonen.dart';
import '../database_provider.dart';
import '../sync/sync_entities.dart';
import '../sync/sync_store.dart';
import '../sync_state.dart';
import 'aufgabe_logik.dart';

/// Eine Unteraufgabe im Formular. Neue haben eine vom Formular vergebene ID.
class PunktEingabe {
  final String id;
  final String text;
  final bool erledigt;
  const PunktEingabe({required this.id, required this.text, this.erledigt = false});

  PunktEingabe mit({String? text, bool? erledigt}) => PunktEingabe(id: id, text: text ?? this.text, erledigt: erledigt ?? this.erledigt);
}

/// Alles, was die Person im Aufgaben-Formular festlegt. [faellig] ist eine Wanduhrzeit der Familienzone (`DateTime.utc`-Markierung); ohne
/// [mitUhrzeit] zählt nur der Tag.
class AufgabeEingabe {
  final String titel;
  final String beschreibung;
  final DateTime? faellig;
  final bool mitUhrzeit;
  final AufgabePrio prioritaet;
  final String? zustaendig;
  final AufgabeWdh wiederholung;
  final AufgabeSicht sicht;

  /// Minuten vor der Fälligkeit (null = keine Erinnerung); ohne Fälligkeit wird nichts gespeichert.
  final int? erinnerungMin;
  final List<PunktEingabe> punkte;
  const AufgabeEingabe({
    required this.titel,
    this.beschreibung = '',
    this.faellig,
    this.mitUhrzeit = false,
    this.prioritaet = AufgabePrio.keine,
    this.zustaendig,
    this.wiederholung = AufgabeWdh.keine,
    this.sicht = AufgabeSicht.family,
    this.erinnerungMin,
    this.punkte = const [],
  });
}

/// Feste ID (UUID-Form, SHA-1 wie Version 5) aus einem Text: gleiche Eingabe = gleiche ID auf jedem Gerät.
String _festeId(String text) {
  final h = sha1.convert(utf8.encode(text)).bytes;
  final b = List<int>.of(h.take(16));
  b[6] = (b[6] & 0x0f) | 0x50;
  b[8] = (b[8] & 0x3f) | 0x80;
  String x(int i) => b[i].toRadixString(16).padLeft(2, '0');
  return '${x(0)}${x(1)}${x(2)}${x(3)}-${x(4)}${x(5)}-${x(6)}${x(7)}-${x(8)}${x(9)}-${x(10)}${x(11)}${x(12)}${x(13)}${x(14)}${x(15)}';
}

/// ID der Folgeaufgabe einer erledigten wiederkehrenden Aufgabe.
String folgeAufgabeId(String aufgabeId) => _festeId('fampad-folgeaufgabe|$aufgabeId');

/// ID einer Unteraufgabe der Folgeaufgabe.
String folgePunktId(String folgeId, String punktId) => _festeId('fampad-folgepunkt|$folgeId|$punktId');

/// Alle lokalen Aufgabendaten, Unteraufgaben nach Aufgabe gruppiert (in Anzeigereihenfolge).
class AufgabenDaten {
  final List<Aufgabe> aufgaben;
  final Map<String, List<AufgabePunkt>> punkte;
  const AufgabenDaten({this.aufgaben = const [], this.punkte = const {}});

  List<AufgabePunkt> punkteVon(String id) => punkte[id] ?? const [];
  Aufgabe? aufgabe(String id) => aufgaben.where((a) => a.id == id).firstOrNull;
}

class AufgabeRepository {
  final AppDatabase db;
  final SyncStore store;
  final String? Function() ich;
  final void Function() beiAenderung;
  final DateTime Function() _jetzt;
  final String Function() _neueId;

  AufgabeRepository({
    required this.db,
    required this.store,
    required this.ich,
    required this.beiAenderung,
    DateTime Function()? jetzt,
    String Function()? neueId,
  }) : _jetzt = jetzt ?? DateTime.now,
       _neueId = neueId ?? neueUuid;

  Stream<List<Aufgabe>> aufgaben() => (db.select(db.aufgaben)..orderBy([(t) => OrderingTerm.asc(t.createdAt), (t) => OrderingTerm.asc(t.id)])).watch();
  Stream<List<AufgabePunkt>> punkte() => db.select(db.aufgabePunkte).watch();

  /// Neue ID für eine Unteraufgabe (das Formular vergibt sie, bevor die Aufgabe gespeichert wird).
  String neuePunktId() => _neueId();

  Map<String, dynamic> _felder(AufgabeEingabe e) {
    final f = e.faellig;
    final String? datum;
    final String? utc;
    final String? tzid;
    if (f == null) {
      datum = utc = tzid = null;
    } else if (e.mitUhrzeit) {
      if (!zeitzonenBereit()) throw const ZeitzonenFehlen();
      datum = null;
      utc = zeitFuerServer(instantAusWand(f, familienOrt));
      tzid = kFamilienZone;
    } else {
      datum = tagText(f);
      utc = tzid = null;
    }
    return {
      'titel': e.titel.trim(),
      'beschreibung': e.beschreibung.trim(),
      'faelligDate': datum,
      'faelligUtc': utc,
      'tzid': tzid,
      'prioritaet': e.prioritaet.wert,
      'assigneeId': e.zustaendig,
      // Wiederholung braucht eine Fälligkeit (sonst gäbe es keine nächste)
      'wiederholung': f == null ? null : e.wiederholung.wire,
      'wiederholungTag': f != null && e.wiederholung == AufgabeWdh.monatlich ? f.day : null,
      'erinnerungMin': f == null ? null : e.erinnerungMin,
      'audience': e.sicht.wire,
    };
  }

  // ------------------------------------------------------------------ Aufgabe

  /// Schneller Eintrag: nur ein Titel (ohne Fälligkeit).
  Future<String> schnellAnlegen(String titel, {String? zustaendig}) => anlegen(AufgabeEingabe(titel: titel, zustaendig: zustaendig));

  Future<String> anlegen(AufgabeEingabe e) async {
    final id = _neueId();
    final aenderungen = <SyncAenderung>[
      SyncAenderung('aufgabe', id, _felder(e), nurLokal: {'createdAt': zeitFuerServer(_jetzt()), 'ownerId': ich()}),
      for (var i = 0; i < e.punkte.length; i++)
        SyncAenderung(
          'aufgabe_punkt',
          e.punkte[i].id,
          {'aufgabeId': id, 'text': e.punkte[i].text.trim(), 'position': i.toDouble(), if (e.punkte[i].erledigt) 'doneAt': zeitFuerServer(_jetzt())},
          nurLokal: {'createdAt': zeitFuerServer(_jetzt())},
        ),
    ];
    await store.aendernMehrere(aenderungen);
    beiAenderung();
    return id;
  }

  /// Speichert das Formular einer vorhandenen Aufgabe: nur geänderte Felder gehen in den Ausgang; Unteraufgaben werden gegen den
  /// bisherigen Stand abgeglichen (neu, geändert, entfernt).
  Future<void> speichern(Aufgabe alt, AufgabeEingabe e, {required List<AufgabePunkt> bisherigePunkte}) async {
    final neu = _felder(e);
    final geaendert = <String, dynamic>{
      for (final k in neu.entries)
        if (!_gleich(k.key, k.value, alt)) k.key: k.value,
    };
    final aenderungen = <SyncAenderung>[if (geaendert.isNotEmpty) SyncAenderung('aufgabe', alt.id, geaendert)];
    final vorher = {for (final p in bisherigePunkte) p.id: p};
    for (var i = 0; i < e.punkte.length; i++) {
      final p = e.punkte[i];
      final v = vorher[p.id];
      if (v == null) {
        aenderungen.add(SyncAenderung(
          'aufgabe_punkt',
          p.id,
          {'aufgabeId': alt.id, 'text': p.text.trim(), 'position': i.toDouble(), if (p.erledigt) 'doneAt': zeitFuerServer(_jetzt())},
          nurLokal: {'createdAt': zeitFuerServer(_jetzt())},
        ));
        continue;
      }
      final d = <String, dynamic>{
        if (p.text.trim() != v.inhalt) 'text': p.text.trim(),
        if (v.position != i.toDouble()) 'position': i.toDouble(),
        if (p.erledigt != (v.doneAt != null)) 'doneAt': p.erledigt ? zeitFuerServer(_jetzt()) : null,
      };
      if (d.isNotEmpty) aenderungen.add(SyncAenderung('aufgabe_punkt', p.id, d));
    }
    if (aenderungen.isNotEmpty) await store.aendernMehrere(aenderungen);
    final bleiben = {for (final p in e.punkte) p.id};
    for (final v in bisherigePunkte) {
      if (!bleiben.contains(v.id)) await store.loeschen('aufgabe_punkt', v.id);
    }
    beiAenderung();
  }

  bool _gleich(String feld, Object? wert, Aufgabe a) => switch (feld) {
    'titel' => wert == a.titel,
    'beschreibung' => wert == a.beschreibung,
    'faelligDate' => wert == a.faelligDate,
    'faelligUtc' => wert == (a.faelligUtc == null ? null : zeitFuerServer(a.faelligUtc!)),
    'tzid' => wert == a.tzid,
    'prioritaet' => wert == a.prioritaet,
    'assigneeId' => wert == a.assigneeId,
    'wiederholung' => wert == a.wiederholung,
    'wiederholungTag' => wert == a.wiederholungTag,
    'erinnerungMin' => wert == a.erinnerungMin,
    'audience' => wert == a.audience,
    _ => false,
  };

  final _laufend = <String>{};

  /// Haken setzen oder entfernen. Beim Erledigen einer wiederkehrenden Aufgabe entsteht die nächste (einmalig, siehe [folgeAufgabeId]); beim
  /// Zurücknehmen verschwindet die noch offene, unveränderte Folgeaufgabe wieder. Ein zweiter Tipp, während der erste noch läuft, tut nichts
  /// (und liest vor dem Schreiben den aktuellen Stand: ist die Aufgabe schon so, wie gewünscht, passiert nichts).
  Future<void> erledigt(Aufgabe a, bool erledigt) async {
    if (!_laufend.add(a.id)) return;
    try {
      final frisch = await (db.select(db.aufgaben)..where((t) => t.id.equals(a.id))).getSingleOrNull();
      if (frisch == null || istErledigt(frisch) == erledigt) return;
      final jetzt = _jetzt();
      final folge = erledigt ? await _folgeaufgabe(frisch, jetzt) : (aenderungen: const <SyncAenderung>[], id: null as String?);
      await store.aendernMehrere([
        SyncAenderung(
          'aufgabe',
          frisch.id,
          {'erledigtAt': erledigt ? zeitFuerServer(jetzt) : null, 'folgeId': ?folge.id},
          // erledigtVon setzt der Server (Akteur); lokal sofort nachgeführt
          nurLokal: {'erledigtVon': erledigt ? ich() : null},
        ),
        ...folge.aenderungen,
      ]);
      if (!erledigt) await _folgeZuruecknehmen(frisch);
      beiAenderung();
    } finally {
      _laufend.remove(a.id);
    }
  }

  Future<bool> _gibt(String id) async => await (db.select(db.aufgaben)..where((t) => t.id.equals(id))).getSingleOrNull() != null;

  /// Die Folgeaufgabe einer Aufgabe, die gerade erledigt wird (Änderungen + ID für `folgeId` der Vorlage); ohne Änderungen, wenn keine entsteht.
  /// ID: abgeleitet aus der Vorlage (zwei Geräte schreiben dieselbe Zeile). Ist sie schon belegt (jemand hat die berechenbare ID vorab angelegt,
  /// oder die Folgeaufgabe wurde gelöscht), nimmt die App eine zufällige: die Wiederholung lässt sich so nicht blockieren.
  Future<({List<SyncAenderung> aenderungen, String? id})> _folgeaufgabe(Aufgabe a, DateTime jetzt) async {
    const keine = (aenderungen: <SyncAenderung>[], id: null as String?);
    final wdh = AufgabeWdh.von(a.wiederholung);
    final basis = faelligWand(a);
    if (wdh == AufgabeWdh.keine || basis == null) return keine;
    if (a.faelligUtc != null && !zeitzonenBereit()) return keine; // ohne Zeitzonen-Daten keine falsche Uhrzeit
    final String id;
    if (a.folgeId != null) {
      if (await _gibt(a.folgeId!)) return keine; // gibt es schon (z. B. von einem anderen Gerät)
      id = _neueId(); // die frühere ID ist verbraucht (Folgeaufgabe gelöscht oder abgelehnt)
    } else {
      final abgeleitet = folgeAufgabeId(a.id);
      id = await _gibt(abgeleitet) ? _neueId() : abgeleitet;
    }
    final mitUhr = a.faelligUtc != null;
    final wunschTag = wdh == AufgabeWdh.monatlich ? (a.wiederholungTag ?? basis.day) : null;
    final naechste = naechsteFaelligkeit(basisWand: basis, wdh: wdh, mitUhrzeit: mitUhr, jetzt: jetzt, wunschTag: wunschTag);
    if (naechste == null) return keine;
    final punkte = sortierePunkte(await (db.select(db.aufgabePunkte)..where((t) => t.aufgabeId.equals(a.id))).get());
    return (
      aenderungen: [
        SyncAenderung(
          'aufgabe',
          id,
          {
            'titel': a.titel,
            'beschreibung': a.beschreibung,
            'faelligDate': mitUhr ? null : tagText(naechste),
            'faelligUtc': mitUhr ? zeitFuerServer(instantAusWand(naechste, ortFuer(a.tzid))) : null,
            'tzid': mitUhr ? (a.tzid ?? kFamilienZone) : null,
            'prioritaet': a.prioritaet,
            'assigneeId': a.assigneeId,
            'wiederholung': a.wiederholung,
            'wiederholungTag': wunschTag,
            'erinnerungMin': a.erinnerungMin,
            'audience': a.audience,
          },
          nurLokal: {'createdAt': zeitFuerServer(jetzt), 'ownerId': ich()},
        ),
        for (var i = 0; i < punkte.length; i++)
          SyncAenderung(
            'aufgabe_punkt',
            folgePunktId(id, punkte[i].id),
            {'aufgabeId': id, 'text': punkte[i].inhalt, 'position': i.toDouble()},
            nurLokal: {'createdAt': zeitFuerServer(jetzt)},
          ),
      ],
      id: id,
    );
  }

  /// Aufgabe wieder geöffnet: die Folgeaufgabe, die beim Erledigen entstand, wird gelöscht, solange sie offen und unverändert ist
  /// (gleiche Angaben und Unteraufgaben ohne Haken). Hat jemand sie schon bearbeitet oder erledigt, bleibt sie. Die `folgeId` der Vorlage
  /// bleibt stehen (die ID ist verbraucht: beim nächsten Erledigen wird eine neue Folgeaufgabe mit anderer ID angelegt).
  Future<void> _folgeZuruecknehmen(Aufgabe a) async {
    final id = a.folgeId;
    if (id == null) return;
    final f = await (db.select(db.aufgaben)..where((t) => t.id.equals(id))).getSingleOrNull();
    if (f == null || istErledigt(f)) return;
    final vorlage = (await (db.select(db.aufgabePunkte)..where((t) => t.aufgabeId.equals(a.id))).get()).map((p) => p.inhalt).toList()..sort();
    final folge = await (db.select(db.aufgabePunkte)..where((t) => t.aufgabeId.equals(f.id))).get();
    final unveraendert = f.titel == a.titel &&
        f.beschreibung == a.beschreibung &&
        f.prioritaet == a.prioritaet &&
        f.assigneeId == a.assigneeId &&
        f.audience == a.audience &&
        f.wiederholung == a.wiederholung &&
        folge.every((p) => p.doneAt == null) &&
        (folge.map((p) => p.inhalt).toList()..sort()).join('\u0000') == vorlage.join('\u0000');
    if (unveraendert) await store.loeschen('aufgabe', f.id);
  }

  /// Löscht alle übergebenen (erledigten) Aufgaben mit ihren Unteraufgaben; die Oberfläche übergibt nur, was die Person löschen darf.
  Future<void> erledigteLoeschen(List<Aufgabe> aufgaben) async {
    for (final a in aufgaben) {
      if (istErledigt(a)) await store.loeschen('aufgabe', a.id);
    }
    beiAenderung();
  }

  Future<void> punktErledigt(String id, bool erledigt) async {
    await store.aendern('aufgabe_punkt', id, {'doneAt': erledigt ? zeitFuerServer(_jetzt()) : null});
    beiAenderung();
  }

  Future<void> loeschen(String id) async {
    await store.loeschen('aufgabe', id);
    beiAenderung();
  }
}

final aufgabeRepositoryProvider = Provider<AufgabeRepository>((ref) {
  return AufgabeRepository(
    db: ref.watch(appDatabaseProvider),
    store: ref.watch(syncStoreProvider),
    ich: () => ref.read(authProvider).user?.id,
    beiAenderung: () => ref.read(syncProvider.notifier).lokaleAenderung(),
  );
});

final aufgabenProvider = StreamProvider.autoDispose<List<Aufgabe>>((ref) => ref.watch(aufgabeRepositoryProvider).aufgaben());
final aufgabePunkteProvider = StreamProvider.autoDispose<List<AufgabePunkt>>((ref) => ref.watch(aufgabeRepositoryProvider).punkte());

/// Aufgaben und Unteraufgaben zusammen (leer, solange die Datenbank noch nichts geliefert hat).
final aufgabenDatenProvider = Provider.autoDispose<AufgabenDaten>((ref) {
  final aufgaben = ref.watch(aufgabenProvider).value ?? const <Aufgabe>[];
  final punkte = ref.watch(aufgabePunkteProvider).value ?? const <AufgabePunkt>[];
  final nach = <String, List<AufgabePunkt>>{};
  for (final p in punkte) {
    nach.putIfAbsent(p.aufgabeId, () => []).add(p);
  }
  return AufgabenDaten(aufgaben: aufgaben, punkte: {for (final e in nach.entries) e.key: sortierePunkte(e.value)});
});

/// Was die Oberfläche der angemeldeten Rolle bei Aufgaben anbietet. Spiegelt server/src/sync/entities/aufgaben.ts; maßgeblich ist der Server.
class AufgabeRechte {
  final Role rolle;
  final String? userId;
  const AufgabeRechte(this.rolle, this.userId);

  bool get _erwachsen => rolle == Role.admin || rolle == Role.parent;

  /// Alle Rollen legen Aufgaben an; Kinder nur Familienaufgaben.
  bool get darfAnlegen => true;

  /// Eltern alle, Kinder nur ihre eigenen (Abhaken, Bearbeiten, Löschen, Unteraufgaben).
  bool darfAendern(Aufgabe a) => _erwachsen || (rolle == Role.child && userId != null && a.ownerId == userId);

  /// Abhaken (und Haken der Unteraufgaben): wer ändern darf, und die zuständige Person (auch ein Kind) bei der ihr zugewiesenen Aufgabe.
  bool darfStatus(Aufgabe a) => darfAendern(a) || (userId != null && a.assigneeId == userId);

  bool get darfFreigabeAendern => _erwachsen;

  List<AufgabeSicht> get freigaben => _erwachsen ? AufgabeSicht.values : const [AufgabeSicht.family];
}
