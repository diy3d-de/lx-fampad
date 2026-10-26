// Zähler (Abschnitt 6l) für die Oberfläche: liest aus der lokalen Datenbank und schreibt sofort lokal (Tabelle und Ausgang, über SyncStore).
//
// Aufbau: Die Zähler des Haushalts hängen an EINER verborgenen Konversation der Art `zaehler` (feste ID `zaehlerChatId`, abgeleitet aus der Familie). Ihre Teilnehmer sind alle Eltern und
// Admins, NIE ein Kind; Epochenschlüssel, Wraps und Rotation laufen über dieselben Wege wie bei Gruppen (ChatKrypto, `SyncStore.aendernMehrere`). Zähler und Zählerstand liegen im Ausgang
// als lokaler Klartext (`l1:` + `z1:`/`a1:`), der Abgleich verschlüsselt sie erst beim Senden (ChatOpVorbereiter) in die Hülle `e1:`. Der Server sieht nie Art, Name, Preis, Stand oder
// Datum, nur Struktur (ID, Zeitstempel, Größe).
//
// Rechte: Nur Eltern und Admins (zaehler_teilnehmer.dart); der Server erzwingt dieselbe Regel gegen die Rollen seiner Datenbank. Neue Eltern (Kind wird Elternteil, neues Mitglied) nimmt
// [teilnehmerPflegen] auf (mit dem Verlauf nur über die vorhandene Verlauf-teilen-Mechanik, nie automatisch); wer kein Elternteil mehr ist, wirft der Server sofort hinaus.
import 'dart:async';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/models.dart' show UserDto;
import '../app_database.dart';
import '../auth/auth_state.dart';
import '../chat/chat_ids.dart';
import '../chat/chat_krypto.dart';
import '../chat/chat_krypto_state.dart';
import '../chat/chat_repository.dart' show ChatArt, teilnehmerIds;
import '../chat/nachrichten_inhalt.dart';
import '../database_provider.dart';
import '../lists/members.dart';
import '../medikamente/medikament_logik.dart' show familienTag;
import '../medikamente/medikament_modelle.dart' show tagText;
import '../sync/sync_entities.dart';
import '../sync/sync_store.dart';
import '../sync_state.dart';
import 'zaehler_logik.dart';
import 'zaehler_modelle.dart';
import 'zaehler_monate.dart';
import 'zaehler_teilnehmer.dart';

/// Wie viele Zähler es höchstens gibt (wie der Server).
const int kMaxZaehler = 50;

/// Gemeinsame Oberklasse der Fehler der Zähler (ohne Inhalte in der Meldung).
class ZaehlerFehler implements Exception {
  final String meldung;
  const ZaehlerFehler(this.meldung);
  @override
  String toString() => meldung;
}

/// Die Person darf die Zähler nicht sehen oder ändern (Kinder nie).
class ZaehlerNichtErlaubt extends ZaehlerFehler {
  const ZaehlerNichtErlaubt() : super('Die Zähler sind nur für Eltern und Admins.');
}

/// Der Inhalt lässt sich (noch) nicht lesen (kein Schlüssel, unbestätigter Absender, beschädigt, neuere App-Version).
class ZaehlerNichtLesbar extends ZaehlerFehler {
  const ZaehlerNichtLesbar() : super('Dieser Zähler lässt sich gerade nicht lesen.');
}

/// Ein Stand lässt sich so nicht erfassen (Datum in der Zukunft, ungültiger Wert, Endstand kleiner als der letzte Stand).
class StandUngueltig extends ZaehlerFehler {
  const StandUngueltig(super.meldung);
}

class ZaehlerRepository {
  final AppDatabase db;
  final SyncStore store;

  /// Die Verschlüsselung dieser Person (null, solange kein Schlüssel bereit ist).
  final Future<ChatKrypto?> Function() krypto;

  /// Angemeldete Person und ihre Familie.
  final String? Function() ich;
  final String? Function() familie;

  /// Aktive Mitglieder der Familie mit ihren Rollen (aus dem Zwischenspeicher der App); die Rolle entscheidet über den Zugriff.
  final Future<List<UserDto>> Function() mitglieder;
  final void Function() beiAenderung;
  final DateTime Function() _jetzt;
  final String Function() _neueId;

  ZaehlerRepository({
    required this.db,
    required this.store,
    required this.krypto,
    required this.ich,
    required this.familie,
    required this.mitglieder,
    required this.beiAenderung,
    DateTime Function()? jetzt,
    String Function()? neueId,
  }) : _jetzt = jetzt ?? DateTime.now,
       _neueId = neueId ?? neueUuid;

  // Änderungen laufen nacheinander (schnelles Tippen, zwei Geräte-Ereignisse): der Stand wird aus der Datenbank gelesen
  Future<void> _kette = Future.value();
  Future<T> _seriell<T>(Future<T> Function() f) {
    final r = _kette.then((_) => f());
    _kette = r.then<void>((_) {}).catchError((Object _) {});
    return r;
  }

  DateTime get _heute => familienTag(_jetzt());

  // ------------------------------------------------------------------ Konversation

  Future<ChatKrypto> _kryptoPflicht() async {
    final k = await krypto();
    if (k == null) throw const VerschluesselungNichtBereit('Richte zuerst den Nachrichten-Schutz ein (Profil › Sicherheit › Nachrichten-Schutz).');
    return k;
  }

  /// ID der Zähler-Konversation dieser Familie (null: Familie unbekannt).
  String? get konversationId {
    final f = familie();
    return f == null ? null : zaehlerChatId(f);
  }

  /// Die lokale Zähler-Konversation (null: gibt es (noch) nicht).
  Future<Konversation?> konversation() async {
    final id = konversationId;
    if (id == null) return null;
    return (db.select(db.konversationen)..where((k) => k.id.equals(id) & k.art.equals(ChatArt.zaehler.wire))).getSingleOrNull();
  }

  /// Darf diese Person die Zähler sehen und ändern?
  Future<void> _darf() async {
    final me = ich();
    if (me == null || !darfZaehlerSehen(ich: me, mitglieder: await mitglieder())) throw const ZaehlerNichtErlaubt();
  }

  /// Legt die Zähler-Konversation an, falls es lokal keine gibt (mit der ersten Epoche für alle Eltern und Admins mit vertrauenswürdigem Schlüssel; die übrigen kommen mit
  /// [teilnehmerPflegen] dazu, sobald sie so weit sind). Liefert die ID. Die anlegende Person braucht eine eingerichtete Verschlüsselung ([SchluesselFehlt] sonst).
  Future<String> konversationSicherstellen() => _seriell(() async {
    await _darf();
    final id = konversationId;
    if (id == null) throw const ZaehlerFehler('Die Familie ist nicht bekannt.');
    if (await konversation() != null) return id;
    final me = ich()!;
    final k = await _kryptoPflicht();
    final alle = await mitglieder();
    final soll = sollZaehlerTeilnehmer(mitglieder: alle);
    if (!soll.contains(me.toLowerCase())) throw const ZaehlerNichtErlaubt();
    final e = await k.empfaenger(soll);
    // die anlegende Person MUSS dabei sein (sonst könnte sie die Zähler nie lesen)
    if (!e.schluessel.keys.map((x) => x.toLowerCase()).contains(me.toLowerCase())) throw SchluesselFehlt([me]);
    final teilnehmer = e.schluessel.keys.toSet();
    final epoche = await k.epocheErstellen(konversationId: id, mitglieder: teilnehmer, unvertrauteAuslassen: true);
    await store.aendernMehrere([
      SyncAenderung(
        'konversation',
        id,
        {'art': ChatArt.zaehler.wire, 'encVersion': 'e1', 'teilnehmer': (teilnehmer.map((x) => x.toLowerCase()).toList()..sort())},
        nurLokal: {'createdAt': zeitFuerServer(_jetzt()), 'ownerId': me},
      ),
      ...epoche,
    ]);
    beiAenderung();
    return id;
  });

  /// Gleicht die Teilnehmer der Zähler-Konversation mit den Rollen ab: Eltern/Admins, die fehlen, kommen dazu (nur mit vertrauenswürdigem Schlüssel; den früheren Verlauf bekommen
  /// sie NICHT von selbst, sondern nur mit [verlaufTeilen] = true bzw. über [verlaufTeilen] auf ausdrücklichen Tipp einer Person, die ihn lesen kann), wer nach den Rollen nicht mehr hineingehört, geht (jede Änderung legt in derselben Transaktion eine neue Epoche an: wer geht, liest Neues nicht mehr).
  /// Der Server wirft nach einem Rollenwechsel ein Kind sofort aus der Liste; die Rotation übernimmt dann diese Pflege. Liefert true, wenn etwas geändert wurde. Nur Teilnehmer ändern.
  Future<bool> teilnehmerPflegen({bool verlaufTeilen = false}) => _seriell(() async {
    final me = ich();
    final konv = await konversation();
    if (me == null || konv == null || konv.encVersion != 'e1' || konv.rev == 0) return false;
    final aktuell = teilnehmerIds(konv).map((x) => x.toLowerCase()).toSet();
    if (!aktuell.contains(me.toLowerCase())) return false;
    final alle = await mitglieder();
    final k = await _kryptoPflicht();
    final sollAlle = sollZaehlerTeilnehmer(mitglieder: alle);
    if (sollAlle.isEmpty) return false;
    final e = await k.empfaenger(sollAlle);
    final vertraut = e.schluessel.keys.map((x) => x.toLowerCase()).toSet();
    final a = zaehlerAbgleichen(aktuell: aktuell, mitglieder: alle, nurMit: vertraut);
    if (a.leer) return false;
    final neu = {...aktuell, ...a.hinzu}..removeAll(a.weg);
    if (neu.isEmpty || !neu.contains(me.toLowerCase())) return false; // nie eine leere Liste; wer selbst nicht mehr hineingehört, ändert nichts mehr
    final sortiert = neu.toList()..sort();
    final aenderungen = <SyncAenderung>[SyncAenderung('konversation', konv.id, {'teilnehmer': sortiert})];
    aenderungen.addAll(await k.epocheErstellen(konversationId: konv.id, mitglieder: neu, historieFuer: verlaufTeilen ? a.hinzu : const {}, unvertrauteAuslassen: true));
    await store.aendernMehrere(aenderungen);
    beiAenderung();
    return true;
  });

  /// "Verlauf teilen": gibt [personen] (Eltern und Admins, die schon Teilnehmer sind, aber den früheren Verlauf noch nicht lesen können) die Schlüssel der älteren Epochen, die dieses
  /// Gerät kennt. Nur auf ausdrücklichen Tipp, nie automatisch. Legt dafür eine neue Epoche für alle Teilnehmer an. Liefert true, wenn etwas geschrieben wurde.
  Future<bool> verlaufTeilen(Set<String> personen) => _seriell(() async {
    final me = ich();
    final konv = await konversation();
    if (me == null || konv == null || konv.encVersion != 'e1' || konv.rev == 0) return false;
    final aktuell = teilnehmerIds(konv).map((x) => x.toLowerCase()).toSet();
    if (!aktuell.contains(me.toLowerCase())) return false;
    await _darf();
    final fuer = {for (final p in personen) p.toLowerCase()}.where((p) => aktuell.contains(p) && p != me.toLowerCase()).toSet();
    if (fuer.isEmpty) return false;
    final k = await _kryptoPflicht();
    final aenderungen = await k.epocheErstellen(konversationId: konv.id, mitglieder: aktuell, historieFuer: fuer, unvertrauteAuslassen: true);
    await store.aendernMehrere(aenderungen);
    beiAenderung();
    return true;
  });

  // ------------------------------------------------------------------ Lesen

  /// Alle lesbaren Zähler (für die Zuordnung der Home-Assistant-Kanäle); nicht lesbare fehlen.
  Future<List<ZaehlerAnsicht>> alleZaehler() async => lesen(await db.select(db.zaehler).get());

  /// Die Zähler-Zeilen (älteste zuerst); leer, wenn es die Konversation lokal nicht gibt.
  Stream<List<ZaehlerZeile>> zeilen() {
    final id = konversationId;
    if (id == null) return Stream.value(const []);
    return (db.select(db.zaehler)
          ..where((z) => z.konversationId.equals(id))
          ..orderBy([(z) => OrderingTerm.asc(z.createdAt), (z) => OrderingTerm.asc(z.id)]))
        .watch();
  }

  /// Die Stand-Zeilen eines Zählers (älteste zuerst nach Anlage).
  Stream<List<ZaehlerstandZeile>> standZeilen(String zaehlerId) =>
      (db.select(db.zaehlerstaende)
            ..where((e) => e.zaehlerId.equals(zaehlerId))
            ..orderBy([(e) => OrderingTerm.asc(e.createdAt), (e) => OrderingTerm.asc(e.id)]))
          .watch();

  /// Klartext einer Zeile (Zähler `z`, Stand `a`); null mit Grund, wenn er sich nicht öffnen lässt. Lokaler Klartext (`l1:`) gilt nur für eigene, noch nicht bestätigte Zeilen.
  Future<({String? text, String? hinweis})> _oeffnen({
    required String id,
    required String konversationId,
    required String? bearbeiterId,
    required String wire,
    required String art,
    String? bezug,
  }) async {
    if (wire.startsWith(kPraefixLokal)) {
      final me = ich();
      if (bearbeiterId != null && bearbeiterId == me) return (text: wire.substring(kPraefixLokal.length), hinweis: null);
      return (text: null, hinweis: 'unverschlüsselt');
    }
    if (bearbeiterId == null) return (text: null, hinweis: 'Person nicht mehr in der Familie');
    final k = await krypto();
    if (k == null) return (text: null, hinweis: 'Nachrichten-Schutz nicht bereit');
    try {
      final d = await k.nachrichtOeffnen(konversationId: konversationId, nachrichtId: id, autorId: bearbeiterId, wire: wire, antwortAuf: bezug, art: art);
      return d.lesbar ? (text: d.text, hinweis: null) : (text: null, hinweis: d.hinweis ?? 'nicht lesbar');
    } on Object {
      return (text: null, hinweis: 'nicht lesbar');
    }
  }

  /// Liest Zähler-Zeilen (entschlüsselt, geprüft: Signatur, Konversation, eigene ID, Art). Nicht lesbare Zeilen kommen mit Hinweis und ohne Inhalt.
  Future<List<ZaehlerAnsicht>> lesen(Iterable<ZaehlerZeile> zeilen) async => [
    for (final z in zeilen)
      await () async {
        final r = await _oeffnen(id: z.id, konversationId: z.konversationId, bearbeiterId: z.bearbeiterId, wire: z.inhalt, art: kArtZaehler);
        final inhalt = r.text == null ? null : zaehlerLesen(r.text!);
        return ZaehlerAnsicht(
          id: z.id,
          konversationId: z.konversationId,
          inhalt: inhalt,
          hinweis: inhalt != null ? null : (r.hinweis ?? 'neuere App-Version nötig oder beschädigt'),
          erstelltAt: z.createdAt,
          lokalNeu: z.rev == 0,
        );
      }(),
  ];

  Future<List<StandAnsicht>> lesenStaende(Iterable<ZaehlerstandZeile> zeilen) async => [
    for (final z in zeilen)
      await () async {
        final r = await _oeffnen(id: z.id, konversationId: z.konversationId, bearbeiterId: z.bearbeiterId, wire: z.inhalt, art: kArtStand, bezug: z.zaehlerId);
        final inhalt = r.text == null ? null : standLesen(r.text!);
        return StandAnsicht(id: z.id, zaehlerId: z.zaehlerId, inhalt: inhalt, hinweis: inhalt != null ? null : (r.hinweis ?? 'neuere App-Version nötig oder beschädigt'), erstelltAt: z.createdAt);
      }(),
  ];

  /// Wie [lesen] für die Oberfläche: nicht blockierend über den Zwischenspeicher der Entschlüsselung ([NachrichtenInhalt.zusatz]).
  ZaehlerAnsicht ansicht(ZaehlerZeile z, NachrichtenInhalt inhalt) {
    final d = z.bearbeiterId == null && !z.inhalt.startsWith(kPraefixLokal)
        ? const DekodierterInhalt('', InhaltStatus.nichtEntschluesselbar, hinweis: 'Person nicht mehr in der Familie')
        : inhalt.zusatz(ZusatzRef(id: z.id, konversationId: z.konversationId, nachrichtId: '', userId: z.bearbeiterId ?? '', wire: z.inhalt, rev: z.rev, art: kArtZaehler));
    final i = d.lesbar ? zaehlerLesen(d.text) : null;
    return ZaehlerAnsicht(
      id: z.id,
      konversationId: z.konversationId,
      inhalt: i,
      hinweis: i != null ? null : (d.lesbar ? 'neuere App-Version nötig oder beschädigt' : d.hinweis ?? 'wird entschlüsselt'),
      erstelltAt: z.createdAt,
      lokalNeu: z.rev == 0,
    );
  }

  StandAnsicht standAnsicht(ZaehlerstandZeile z, NachrichtenInhalt inhalt) {
    final d = z.bearbeiterId == null && !z.inhalt.startsWith(kPraefixLokal)
        ? const DekodierterInhalt('', InhaltStatus.nichtEntschluesselbar, hinweis: 'Person nicht mehr in der Familie')
        : inhalt.zusatz(ZusatzRef(id: z.id, konversationId: z.konversationId, nachrichtId: z.zaehlerId, userId: z.bearbeiterId ?? '', wire: z.inhalt, rev: z.rev, art: kArtStand));
    final i = d.lesbar ? standLesen(d.text) : null;
    return StandAnsicht(id: z.id, zaehlerId: z.zaehlerId, inhalt: i, hinweis: i != null ? null : (d.lesbar ? 'neuere App-Version nötig oder beschädigt' : d.hinweis ?? 'wird entschlüsselt'), erstelltAt: z.createdAt);
  }

  /// Alle lesbaren Stände eines Zählers als Rechen-Stände (in der Reihenfolge der Anlage; am selben Tag gilt der zuletzt angelegte).
  Future<List<Stand>> staende(String zaehlerId) async {
    final zeilen = await (db.select(db.zaehlerstaende)
          ..where((e) => e.zaehlerId.equals(zaehlerId))
          ..orderBy([(e) => OrderingTerm.asc(e.createdAt), (e) => OrderingTerm.asc(e.id)]))
        .get();
    // ein Stand je Tag (zwei Abholgeräte können denselben Tag doppelt schreiben): der zuletzt geschriebene gilt
    return standeZusammenfuehren([
      for (final a in await lesenStaende(zeilen))
        if (a.inhalt != null && !a.inhalt!.istMonatswert && a.inhalt!.tag != null) StandQuelle(a.id, a.erstelltAt.millisecondsSinceEpoch, Stand(a.inhalt!.tag!, a.inhalt!.milli, marke: a.inhalt!.marke)),
    ]);
  }

  // ------------------------------------------------------------------ Schreiben: Zähler

  Future<ZaehlerZeile> _zeile(String id) async {
    final z = await (db.select(db.zaehler)..where((t) => t.id.equals(id))).getSingleOrNull();
    if (z == null) throw const ZaehlerFehler('Den Zähler gibt es nicht mehr.');
    return z;
  }

  /// Rechte prüfen und den aktuellen Klartext lesen.
  Future<(ZaehlerZeile, ZaehlerInhalt)> _aktuell(String id) async {
    await _darf();
    final z = await _zeile(id);
    final r = await _oeffnen(id: z.id, konversationId: z.konversationId, bearbeiterId: z.bearbeiterId, wire: z.inhalt, art: kArtZaehler);
    final i = r.text == null ? null : zaehlerLesen(r.text!);
    if (i == null) throw const ZaehlerNichtLesbar();
    return (z, i);
  }

  /// Legt einen Zähler an (die Konversation entsteht bei Bedarf). Liefert die ID. Ein ungültiger Inhalt wird nie geschrieben ([ArgumentError]).
  Future<String> anlegen(ZaehlerInhalt inhalt) async {
    final klar = zaehlerKodieren(inhalt);
    final konv = await konversationSicherstellen();
    return _seriell(() async {
      final me = ich();
      if (me == null) throw const ZaehlerNichtErlaubt();
      final vorhanden = await (db.select(db.zaehler)..where((z) => z.konversationId.equals(konv))).get();
      if (vorhanden.length >= kMaxZaehler) throw const ZaehlerFehler('Es sind zu viele Zähler vorhanden.');
      final id = _neueId();
      await store.aendern(
        'zaehler',
        id,
        {'konversationId': konv, 'inhalt': '$kPraefixLokal$klar'},
        nurLokal: {'createdAt': zeitFuerServer(_jetzt()), 'bearbeiterId': me},
      );
      beiAenderung();
      return id;
    });
  }

  /// Ersetzt den Inhalt eines Zählers (der Bearbeiter ist, wer ihn zuletzt schrieb).
  Future<void> aendern(String id, ZaehlerInhalt neu) => _seriell(() async {
    final klar = zaehlerKodieren(neu);
    await _aktuell(id); // Rechte und Lesbarkeit (kein blindes Überschreiben eines unlesbaren Stands)
    await store.aendern('zaehler', id, {'inhalt': '$kPraefixLokal$klar'}, nurLokal: {'bearbeiterId': ich()});
    beiAenderung();
  });

  Future<void> _umbauen(String id, ZaehlerInhalt Function(ZaehlerInhalt z) f) => _seriell(() async {
    final (_, z) = await _aktuell(id);
    final klar = zaehlerKodieren(f(z));
    await store.aendern('zaehler', id, {'inhalt': '$kPraefixLokal$klar'}, nurLokal: {'bearbeiterId': ich()});
    beiAenderung();
  });

  /// Archiviert den Zähler ab [ab] (Standard: heute): er zählt nicht mehr, alle Stände bleiben.
  Future<void> archivieren(String id, {DateTime? ab}) => _umbauen(id, (z) => z.kopie(archiviertAb: () => tagText(ab ?? _heute)));

  /// Holt einen archivierten Zähler zurück.
  Future<void> reaktivieren(String id) => _umbauen(id, (z) => z.kopie(archiviertAb: () => null));

  /// Setzt (oder löscht mit leerem Text) die Gruppe, z. B. für die Summe mehrerer Wasserzähler.
  Future<void> gruppeSetzen(String id, String gruppe) => _umbauen(id, (z) => z.kopie(gruppe: gruppe.trim()));

  /// Löscht den Zähler endgültig samt allen Ständen (auch auf allen Geräten und beim Server). Archivieren ist der sanfte Weg.
  Future<void> loeschen(String id) => _seriell(() async {
    await _darf();
    await _zeile(id);
    await store.loeschen('zaehler', id);
    beiAenderung();
  });

  // ------------------------------------------------------------------ Schreiben: Stände

  void _standPruefenHart(DateTime datum, int milli) {
    if (milli < 0 || milli > kMaxStandMilli) throw const StandUngueltig('Dieser Zählerstand ist nicht möglich.');
    if (tagNummer(datum) > tagNummer(_heute)) throw const StandUngueltig('Ein Zählerstand kann nicht in der Zukunft liegen.');
  }

  /// Prüft einen (neuen oder geänderten) Stand auf Plausibilität (Zukunft, Doppelter Tag, niedriger als der vorige, Sprung). [ausser]: ein Stand, der ersetzt wird, zählt nicht mit.
  Future<Plausibilitaet> standPruefen(String zaehlerId, {required DateTime datum, required int milli, String? ausser}) async {
    final zeilen = await (db.select(db.zaehlerstaende)..where((e) => e.zaehlerId.equals(zaehlerId) & (ausser == null ? const Constant(true) : e.id.equals(ausser).not()))).get();
    final bestehende = standeZusammenfuehren([
      for (final a in await lesenStaende(zeilen))
        if (a.inhalt != null && !a.inhalt!.istMonatswert && a.inhalt!.tag != null) StandQuelle(a.id, a.erstelltAt.millisecondsSinceEpoch, Stand(a.inhalt!.tag!, a.inhalt!.milli)),
    ]);
    return pruefeStand(datum: datum, milli: milli, bestehende: bestehende, heute: _heute);
  }

  /// Erfasst eine Ablesung ([automatisch]: aus Home Assistant eingetragen, Herkunft im Stand vermerkt). Ein Datum in der Zukunft und unmögliche Werte werden abgelehnt ([StandUngueltig]); Hinweise ([standPruefen]) entscheidet die Person vorher.
  Future<String> standErfassen(String zaehlerId, {required DateTime datum, required int milli, String notiz = '', StandMarke? marke, bool automatisch = false}) => _seriell(() async {
    final (z, zi) = await _aktuell(zaehlerId);
    if (zi.monatlich) throw const StandUngueltig('Dieser Zähler nimmt Monatswerte statt Zählerstände.');
    _standPruefenHart(datum, milli);
    final inhalt = StandInhalt(datum: tagText(datum), milli: milli, notiz: notiz, marke: marke, automatisch: automatisch);
    final klar = standKodieren(inhalt);
    final id = _neueId();
    await store.aendern(
      'zaehlerstand',
      id,
      {'konversationId': z.konversationId, 'zaehlerId': zaehlerId, 'inhalt': '$kPraefixLokal$klar'},
      nurLokal: {'createdAt': zeitFuerServer(_jetzt()), 'bearbeiterId': ich()},
    );
    beiAenderung();
    return id;
  });

  Future<(ZaehlerstandZeile, StandInhalt)> _standAktuell(String standId) async {
    await _darf();
    final z = await (db.select(db.zaehlerstaende)..where((t) => t.id.equals(standId))).getSingleOrNull();
    if (z == null) throw const ZaehlerFehler('Den Zählerstand gibt es nicht mehr.');
    final r = await _oeffnen(id: z.id, konversationId: z.konversationId, bearbeiterId: z.bearbeiterId, wire: z.inhalt, art: kArtStand, bezug: z.zaehlerId);
    final i = r.text == null ? null : standLesen(r.text!);
    if (i == null) throw const ZaehlerNichtLesbar();
    return (z, i);
  }

  /// Ändert einen Stand (Datum, Wert oder Notiz; die Marke bleibt).
  Future<void> standAendern(String standId, {DateTime? datum, int? milli, String? notiz}) => _seriell(() async {
    final (_, alt) = await _standAktuell(standId);
    final neu = alt.kopie(datum: datum == null ? null : tagText(datum), milli: milli, notiz: notiz);
    _standPruefenHart(neu.tag ?? _heute, neu.milli);
    final klar = standKodieren(neu);
    await store.aendern('zaehlerstand', standId, {'inhalt': '$kPraefixLokal$klar'}, nurLokal: {'bearbeiterId': ich()});
    beiAenderung();
  });

  /// Löscht einen Stand.
  Future<void> standLoeschen(String standId) => _seriell(() async {
    await _darf();
    final z = await (db.select(db.zaehlerstaende)..where((t) => t.id.equals(standId))).getSingleOrNull();
    if (z == null) return;
    await store.loeschen('zaehlerstand', standId);
    beiAenderung();
  });

  // ------------------------------------------------------------------ Monatswerte

  /// Alle lesbaren Monatswert-Einträge eines Zählers (auch Doppelte eines Monats), ältester zuerst.
  Future<List<MonatsWert>> _monatsEintraege(String zaehlerId) async {
    final zeilen = await (db.select(db.zaehlerstaende)
          ..where((e) => e.zaehlerId.equals(zaehlerId))
          ..orderBy([(e) => OrderingTerm.asc(e.createdAt), (e) => OrderingTerm.asc(e.id)]))
        .get();
    return [
      for (final a in await lesenStaende(zeilen))
        if (a.inhalt != null && a.inhalt!.istMonatswert)
          MonatsWert(jahr: monatLesen(a.inhalt!.monat)!.jahr, monat: monatLesen(a.inhalt!.monat)!.monat, milli: a.inhalt!.milli, zeit: a.inhalt!.zeit, id: a.id, notiz: a.inhalt!.notiz),
    ];
  }

  /// Die Monatswerte eines Zählers: ein Wert je Monat (der zuletzt geschriebene), aufsteigend.
  Future<List<MonatsWert>> monatswerte(String zaehlerId) async => monatswerteZusammenfuehren(await _monatsEintraege(zaehlerId));

  /// Prüft einen Monatswert (Zukunft, schon vorhanden, mehr als doppelt so hoch wie im Vorjahresmonat). Hinweise entscheidet die Person vorher; nur ein Monat in der Zukunft sperrt.
  Future<MonatswertPlausibilitaet> monatswertPruefen(String zaehlerId, {required int jahr, required int monat, required int milli}) async =>
      pruefeMonatswert(jahr: jahr, monat: monat, milli: milli, werte: await monatswerte(zaehlerId), heute: _heute);

  void _monatPruefenHart(int jahr, int monat, int milli) {
    if (monatLesen(monatText(jahr, monat)) == null) throw const StandUngueltig('Dieser Monat ist nicht möglich.');
    if (milli < 0 || milli > kMaxMonatswertMilli) throw const StandUngueltig('Dieser Monatswert ist nicht möglich (0 bis 100 000).');
    final h = _heute;
    if (jahr * 12 + monat - 1 > h.year * 12 + h.month - 1) throw const StandUngueltig('Ein Monatswert kann nicht in der Zukunft liegen.');
  }

  /// Trägt den Wert eines Monats ein oder ERSETZT ihn: ein Monat zählt genau einmal. Der Server kennt für Stände nur Zufalls-IDs, darum wird ein vorhandener Eintrag des Monats
  /// überschrieben (neue Schreibzeit), Doppelte (von einem anderen Gerät) werden mit entfernt; entstehen zwei Einträge gleichzeitig auf zwei Geräten, gilt beim Lesen der mit der
  /// größten Schreibzeit ([monatswerteZusammenfuehren]). Liefert die ID des Eintrags.
  Future<String> monatswertErfassen(String zaehlerId, {required int jahr, required int monat, required int milli, String notiz = ''}) => _seriell(() async {
    final (z, zi) = await _aktuell(zaehlerId);
    if (!zi.monatlich) throw const StandUngueltig('Dieser Zähler nimmt Zählerstände statt Monatswerte.');
    _monatPruefenHart(jahr, monat, milli);
    final eintraege = (await _monatsEintraege(zaehlerId)).where((w) => w.jahr == jahr && w.monat == monat).toList();
    final gewinner = monatswerteZusammenfuehren(eintraege).firstOrNull;
    final jetztMs = _jetzt().millisecondsSinceEpoch;
    final zeit = gewinner != null && gewinner.zeit >= jetztMs ? gewinner.zeit + 1 : jetztMs;
    final klar = standKodieren(StandInhalt.monatswert(monat: monatText(jahr, monat), milli: milli, zeit: zeit, notiz: notiz));
    final String id;
    if (gewinner != null) {
      id = gewinner.id;
      await store.aendern('zaehlerstand', id, {'inhalt': '$kPraefixLokal$klar'}, nurLokal: {'bearbeiterId': ich()});
      for (final w in eintraege) {
        if (w.id != id) await store.loeschen('zaehlerstand', w.id);
      }
    } else {
      id = _neueId();
      await store.aendern(
        'zaehlerstand',
        id,
        {'konversationId': z.konversationId, 'zaehlerId': zaehlerId, 'inhalt': '$kPraefixLokal$klar'},
        nurLokal: {'createdAt': zeitFuerServer(_jetzt()), 'bearbeiterId': ich()},
      );
    }
    beiAenderung();
    return id;
  });

  /// Löscht den Wert eines Monats (alle Einträge dieses Monats).
  Future<void> monatswertLoeschen(String zaehlerId, {required int jahr, required int monat}) => _seriell(() async {
    await _darf();
    for (final w in (await _monatsEintraege(zaehlerId)).where((w) => w.jahr == jahr && w.monat == monat)) {
      await store.loeschen('zaehlerstand', w.id);
    }
    beiAenderung();
  });

  // ------------------------------------------------------------------ Zählerwechsel

  /// Zählerwechsel: Der alte Zähler bekommt am Tag [datum] seinen Endstand ([endstandMilli], Marke "Ende") und wird archiviert; ein neuer Zähler (mit denselben Einstellungen, [neu]
  /// überschreibt sie, z. B. andere Zählernummer) beginnt am selben Tag mit [startstandMilli] (Marke "Start") und merkt den alten als Vorgänger. Der Verbrauch läuft nahtlos weiter
  /// (Kette alter -> neuer Zähler, `kette` und `Verbrauchskurve.verkettet`). Alles in EINER Transaktion. Liefert die ID des neuen Zählers. Der Endstand darf nicht kleiner sein als der
  /// letzte Stand des alten Zählers ([StandUngueltig]).
  Future<String> zaehlerWechseln(
    String alterId, {
    required DateTime datum,
    required int endstandMilli,
    required int startstandMilli,
    ZaehlerInhalt Function(ZaehlerInhalt alt)? neu,
  }) => _seriell(() async {
    final (alt, altInhalt) = await _aktuell(alterId);
    if (altInhalt.monatlich) throw const StandUngueltig('Bei Monatswerten gibt es keinen Zählerwechsel.');
    _standPruefenHart(datum, endstandMilli);
    _standPruefenHart(datum, startstandMilli);
    final vorhandene = await staende(alterId);
    final letzter = normalisiere(vorhandene).lastOrNull;
    if (letzter != null && (endstandMilli < letzter.milli || tagNummer(datum) < tagNummer(letzter.tag))) {
      throw const StandUngueltig('Der Endstand darf nicht kleiner sein als der letzte Stand des alten Zählers.');
    }
    final anzahl = (await (db.select(db.zaehler)..where((z) => z.konversationId.equals(alt.konversationId))).get()).length;
    if (anzahl >= kMaxZaehler) throw const ZaehlerFehler('Es sind zu viele Zähler vorhanden.');
    final tag = tagText(datum);
    final neuerInhalt = (neu != null ? neu(altInhalt) : altInhalt.kopie(nummer: '')).kopie(vorgaenger: () => alterId, archiviertAb: () => null);
    final altNeu = altInhalt.kopie(archiviertAb: () => tag);
    final endKlar = standKodieren(StandInhalt(datum: tag, milli: endstandMilli, marke: StandMarke.ende));
    final startKlar = standKodieren(StandInhalt(datum: tag, milli: startstandMilli, marke: StandMarke.start));
    final altKlar = zaehlerKodieren(altNeu);
    final neuKlar = zaehlerKodieren(neuerInhalt);
    final neuId = _neueId();
    final me = ich();
    final jetzt = zeitFuerServer(_jetzt());
    await store.aendernMehrere([
      SyncAenderung('zaehlerstand', _neueId(), {'konversationId': alt.konversationId, 'zaehlerId': alterId, 'inhalt': '$kPraefixLokal$endKlar'}, nurLokal: {'createdAt': jetzt, 'bearbeiterId': me}),
      SyncAenderung('zaehler', alterId, {'inhalt': '$kPraefixLokal$altKlar'}, nurLokal: {'bearbeiterId': me}),
      SyncAenderung('zaehler', neuId, {'konversationId': alt.konversationId, 'inhalt': '$kPraefixLokal$neuKlar'}, nurLokal: {'createdAt': jetzt, 'bearbeiterId': me}),
      SyncAenderung('zaehlerstand', _neueId(), {'konversationId': alt.konversationId, 'zaehlerId': neuId, 'inhalt': '$kPraefixLokal$startKlar'}, nurLokal: {'createdAt': jetzt, 'bearbeiterId': me}),
    ]);
    beiAenderung();
    return neuId;
  });
}

final zaehlerRepositoryProvider = Provider<ZaehlerRepository>((ref) {
  return ZaehlerRepository(
    db: ref.watch(appDatabaseProvider),
    store: ref.watch(syncStoreProvider),
    krypto: () => ref.read(chatKryptoProvider.notifier).krypto(),
    ich: () => ref.read(authProvider).user?.id,
    familie: () => ref.read(authProvider).me?.familyId,
    mitglieder: () async => ref.read(mitgliederProvider.future),
    beiAenderung: () => ref.read(syncProvider.notifier).lokaleAenderung(),
  );
});
