// Medikamenten-Plan (Abschnitt 6k) für die Oberfläche: liest aus der lokalen Datenbank und schreibt sofort lokal (Tabelle und Ausgang, über SyncStore).
//
// Aufbau: Die Medikamente einer Person (Subjekt) hängen an einer verborgenen Konversation der Art `meds` (feste ID `medsChatId`). Ihre Teilnehmer sind das Subjekt und, nur bei einem Kind,
// alle Eltern und Admins; Epochenschlüssel, Wraps und Rotation laufen über dieselben Wege wie bei Gruppen (ChatKrypto, `SyncStore.aendernMehrere`). Medikament und Einnahme liegen im Ausgang
// als lokaler Klartext (`l1:` + `m1:`/`n1:`), der Abgleich verschlüsselt sie erst beim Senden (ChatOpVorbereiter) in die Hülle `e1:`. Der Server sieht nie Name, Dosis, Rhythmus,
// Uhrzeiten, Vorrat oder Einnahmezeitpunkt, nur Struktur (ID, Person, Zeitstempel, Größe).
//
// Rechte: Wessen Medikamente jemand sehen und ändern darf, steht in medikament_subjekte.dart (Eltern und Admins die ihrer Kinder, nie die eines anderen Erwachsenen; Kinder nur die eigenen);
// der Server erzwingt dieselbe Regel gegen die Rollen seiner Datenbank.
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
import '../sync/sync_entities.dart';
import '../sync/sync_store.dart';
import '../sync_state.dart';
import 'medikament_logik.dart';
import 'medikament_logik.dart' as logik show vorratAuffuellen;
import 'medikament_modelle.dart';
import 'medikament_subjekte.dart';

/// Gemeinsame Oberklasse der Fehler des Medikamenten-Plans (ohne Inhalte in der Meldung).
class MedikamentFehler implements Exception {
  final String meldung;
  const MedikamentFehler(this.meldung);
  @override
  String toString() => meldung;
}

/// Die Person darf die Medikamente dieser Person nicht sehen oder ändern.
class MedikamentNichtErlaubt extends MedikamentFehler {
  const MedikamentNichtErlaubt() : super('Du darfst die Medikamente dieser Person nicht sehen.');
}

/// Der Inhalt lässt sich (noch) nicht lesen (kein Schlüssel, unbestätigter Absender, beschädigt, neuere App-Version).
class MedikamentNichtLesbar extends MedikamentFehler {
  const MedikamentNichtLesbar() : super('Dieses Medikament lässt sich gerade nicht lesen.');
}

/// Eine Einnahme lässt sich so nicht erfassen (Zeitpunkt zu weit zurück oder in der Zukunft).
class EinnahmeUngueltig extends MedikamentFehler {
  const EinnahmeUngueltig(super.meldung);
}

class MedikamentRepository {
  final AppDatabase db;
  final SyncStore store;

  /// Die Verschlüsselung dieser Person (null, solange kein Schlüssel bereit ist).
  final Future<ChatKrypto?> Function() krypto;

  /// Angemeldete Person.
  final String? Function() ich;

  /// Aktive Mitglieder der Familie mit ihren Rollen (aus dem Zwischenspeicher der App); die Rolle entscheidet, wessen Medikamente zugänglich sind.
  final Future<List<UserDto>> Function() mitglieder;
  final void Function() beiAenderung;
  final DateTime Function() _jetzt;
  final String Function() _neueId;

  MedikamentRepository({
    required this.db,
    required this.store,
    required this.krypto,
    required this.ich,
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

  // ------------------------------------------------------------------ Konversation je Person

  Future<ChatKrypto> _kryptoPflicht() async {
    final k = await krypto();
    if (k == null) throw const VerschluesselungNichtBereit('Richte zuerst die Verschlüsselung ein (Profil, Verschlüsselung).');
    return k;
  }

  /// Die lokale Medikamenten-Konversation dieser Person (null: gibt es (noch) nicht).
  Future<Konversation?> konversationVon(String subjektId) =>
      (db.select(db.konversationen)..where((k) => k.id.equals(medsChatId(subjektId)) & k.art.equals(ChatArt.meds.wire))).getSingleOrNull();

  Future<void> _darfSubjekt(String subjektId) async {
    final me = ich();
    if (me == null || !darfSubjektSehen(ich: me, subjekt: subjektId, mitglieder: await mitglieder())) throw const MedikamentNichtErlaubt();
  }

  /// Legt die Medikamenten-Konversation der Person an, falls es lokal keine gibt (mit der ersten Epoche für alle, die sie sehen sollen und einen vertrauenswürdigen Schlüssel haben;
  /// die übrigen kommen mit [teilnehmerPflegen] dazu, sobald sie so weit sind). Liefert die ID. Das Subjekt selbst braucht eine eingerichtete Verschlüsselung ([SchluesselFehlt] sonst).
  Future<String> konversationSicherstellen(String subjektId) => _seriell(() async {
    final id = medsChatId(subjektId);
    await _darfSubjekt(subjektId);
    if (await konversationVon(subjektId) != null) return id;
    final me = ich()!;
    final k = await _kryptoPflicht();
    final alle = await mitglieder();
    final soll = sollTeilnehmer(subjekt: subjektId, mitglieder: alle);
    if (!soll.contains(me.toLowerCase())) throw const MedikamentNichtErlaubt();
    final e = await k.empfaenger(soll);
    // das Subjekt MUSS dabei sein (sonst könnte es seine Medikamente nie lesen)
    if (!e.schluessel.keys.map((x) => x.toLowerCase()).contains(subjektId.toLowerCase())) throw SchluesselFehlt([subjektId]);
    final teilnehmer = e.schluessel.keys.toSet();
    final epoche = await k.epocheErstellen(konversationId: id, mitglieder: teilnehmer, unvertrauteAuslassen: true);
    await store.aendernMehrere([
      SyncAenderung(
        'konversation',
        id,
        {'art': ChatArt.meds.wire, 'encVersion': 'e1', 'subjektId': subjektId.toLowerCase(), 'teilnehmer': (teilnehmer.map((x) => x.toLowerCase()).toList()..sort())},
        nurLokal: {'createdAt': zeitFuerServer(_jetzt()), 'ownerId': me},
      ),
      ...epoche,
    ]);
    beiAenderung();
    return id;
  });

  /// Gleicht die Teilnehmer der Medikamenten-Konversation mit den Rollen ab: Eltern/Admins eines Kindes kommen dazu (mit dem Verlauf, sobald sie einen vertrauenswürdigen Schlüssel haben),
  /// wer nach den Rollen nicht mehr hineingehört, geht (jede Änderung legt in derselben Transaktion eine neue Epoche an: wer geht, liest Neues nicht mehr). Der Server zieht die Liste
  /// nach einem Rollenwechsel selbst nach; die Rotation übernimmt dann die Schlüsselpflege der App. Liefert true, wenn etwas geändert wurde. Nur Teilnehmer ändern.
  Future<bool> teilnehmerPflegen(String subjektId) => _seriell(() async {
    final me = ich();
    final konv = await konversationVon(subjektId);
    if (me == null || konv == null || konv.encVersion != 'e1' || konv.rev == 0) return false;
    final aktuell = teilnehmerIds(konv).map((x) => x.toLowerCase()).toSet();
    if (!aktuell.contains(me.toLowerCase())) return false;
    final alle = await mitglieder();
    final k = await _kryptoPflicht();
    final sollAlle = sollTeilnehmer(subjekt: subjektId, mitglieder: alle);
    if (sollAlle.isEmpty) return false; // das Subjekt ist nicht (mehr) aktiv: die Konversation räumt der Server auf
    final e = await k.empfaenger(sollAlle);
    final vertraut = e.schluessel.keys.map((x) => x.toLowerCase()).toSet();
    final a = teilnehmerAbgleichen(subjekt: subjektId, aktuell: aktuell, mitglieder: alle, nurMit: vertraut);
    if (a.leer) return false;
    final neu = ({...aktuell, ...a.hinzu}..removeAll(a.weg))..add(subjektId.toLowerCase());
    final sortiert = neu.toList()..sort();
    final aenderungen = <SyncAenderung>[SyncAenderung('konversation', konv.id, {'teilnehmer': sortiert})];
    if (neu.contains(me.toLowerCase())) {
      aenderungen.addAll(await k.epocheErstellen(konversationId: konv.id, mitglieder: neu, historieFuer: a.hinzu, unvertrauteAuslassen: true));
    }
    await store.aendernMehrere(aenderungen);
    beiAenderung();
    return true;
  });

  /// [teilnehmerPflegen] für alle Medikamenten-Konversationen, die dieses Gerät kennt (nach Änderungen der Mitglieder oder Rollen).
  Future<int> alleTeilnehmerPflegen() async {
    var n = 0;
    for (final k in await (db.select(db.konversationen)..where((t) => t.art.equals(ChatArt.meds.wire))).get()) {
      final subjekt = k.subjektId;
      if (subjekt == null) continue;
      try {
        if (await teilnehmerPflegen(subjekt)) n++;
      } on MedikamentFehler {
        // nicht lesbar oder nicht erlaubt: beim nächsten Auslöser erneut
      } on VerschluesselungNichtBereit {
        // dieses Gerät ist gerade nicht bereit
      }
    }
    return n;
  }

  // ------------------------------------------------------------------ Lesen

  /// Die Medikament-Zeilen der Person (älteste zuerst); leer, wenn es die Konversation lokal nicht gibt.
  Stream<List<MedikamentZeile>> zeilen(String subjektId) {
    final q = db.select(db.medikamente).join([innerJoin(db.konversationen, db.konversationen.id.equalsExp(db.medikamente.konversationId))])
      ..where(db.konversationen.subjektId.equals(subjektId.toLowerCase()) & db.konversationen.art.equals(ChatArt.meds.wire))
      ..orderBy([OrderingTerm.asc(db.medikamente.createdAt), OrderingTerm.asc(db.medikamente.id)]);
    return q.watch().map((l) => [for (final r in l) r.readTable(db.medikamente)]);
  }

  /// Die Einnahme-Zeilen eines Medikaments (älteste zuerst).
  Stream<List<EinnahmeZeile>> einnahmenZeilen(String medikamentId) =>
      (db.select(db.einnahmen)
            ..where((e) => e.medikamentId.equals(medikamentId))
            ..orderBy([(e) => OrderingTerm.asc(e.createdAt), (e) => OrderingTerm.asc(e.id)]))
          .watch();

  /// Klartext einer Zeile (Medikament `m`, Einnahme `n`); null mit Grund, wenn er sich nicht öffnen lässt. Lokaler Klartext (`l1:`) gilt nur für eigene, noch nicht bestätigte Zeilen.
  Future<({String? text, String? hinweis})> _oeffnen({
    required String id,
    required String konversationId,
    required String? bearbeiterId,
    required String wire,
    required int rev,
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
    if (k == null) return (text: null, hinweis: 'Verschlüsselung nicht bereit');
    try {
      final d = await k.nachrichtOeffnen(konversationId: konversationId, nachrichtId: id, autorId: bearbeiterId, wire: wire, antwortAuf: bezug, art: art);
      return d.lesbar ? (text: d.text, hinweis: null) : (text: null, hinweis: d.hinweis ?? 'nicht lesbar');
    } on Object {
      return (text: null, hinweis: 'nicht lesbar');
    }
  }

  /// Liest Medikament-Zeilen (entschlüsselt, geprüft: Signatur, Konversation, eigene ID, Art). Nicht lesbare Zeilen kommen mit Hinweis und ohne Inhalt.
  Future<List<MedikamentAnsicht>> lesen(String subjektId, Iterable<MedikamentZeile> zeilen) async => [
    for (final z in zeilen)
      await () async {
        final r = await _oeffnen(id: z.id, konversationId: z.konversationId, bearbeiterId: z.bearbeiterId, wire: z.inhalt, rev: z.rev, art: kArtMedikament);
        return MedikamentAnsicht(
          id: z.id,
          konversationId: z.konversationId,
          subjektId: subjektId,
          inhalt: r.text == null ? null : medikamentLesen(r.text!),
          hinweis: r.text == null ? r.hinweis : (medikamentLesen(r.text!) == null ? 'neuere App-Version nötig oder beschädigt' : null),
          erstelltAt: z.createdAt,
          lokalNeu: z.rev == 0,
        );
      }(),
  ];

  Future<List<EinnahmeAnsicht>> lesenEinnahmen(Iterable<EinnahmeZeile> zeilen) async => [
    for (final z in zeilen)
      await () async {
        final r = await _oeffnen(id: z.id, konversationId: z.konversationId, bearbeiterId: z.bearbeiterId, wire: z.inhalt, rev: z.rev, art: kArtEinnahme, bezug: z.medikamentId);
        final inhalt = r.text == null ? null : einnahmeLesen(r.text!);
        return EinnahmeAnsicht(id: z.id, medikamentId: z.medikamentId, inhalt: inhalt, hinweis: inhalt != null ? null : (r.hinweis ?? 'neuere App-Version nötig oder beschädigt'), erstelltAt: z.createdAt);
      }(),
  ];

  /// Wie [lesen] für die Oberfläche: nicht blockierend über den Zwischenspeicher der Entschlüsselung ([NachrichtenInhalt.zusatz]; "wird entschlüsselt" ergibt einen Inhalt null mit Hinweis, die
  /// Oberfläche baut sich neu auf, sobald er da ist).
  MedikamentAnsicht ansicht(String subjektId, MedikamentZeile z, NachrichtenInhalt inhalt) {
    final d = z.bearbeiterId == null && !z.inhalt.startsWith(kPraefixLokal)
        ? const DekodierterInhalt('', InhaltStatus.nichtEntschluesselbar, hinweis: 'Person nicht mehr in der Familie')
        : inhalt.zusatz(ZusatzRef(id: z.id, konversationId: z.konversationId, nachrichtId: '', userId: z.bearbeiterId ?? '', wire: z.inhalt, rev: z.rev, art: kArtMedikament));
    final m = d.lesbar ? medikamentLesen(d.text) : null;
    return MedikamentAnsicht(
      id: z.id,
      konversationId: z.konversationId,
      subjektId: subjektId,
      inhalt: m,
      hinweis: m != null ? null : (d.lesbar ? 'neuere App-Version nötig oder beschädigt' : d.hinweis ?? 'wird entschlüsselt'),
      erstelltAt: z.createdAt,
      lokalNeu: z.rev == 0,
    );
  }

  EinnahmeAnsicht einnahmeAnsicht(EinnahmeZeile z, NachrichtenInhalt inhalt) {
    final d = z.bearbeiterId == null && !z.inhalt.startsWith(kPraefixLokal)
        ? const DekodierterInhalt('', InhaltStatus.nichtEntschluesselbar, hinweis: 'Person nicht mehr in der Familie')
        : inhalt.zusatz(ZusatzRef(id: z.id, konversationId: z.konversationId, nachrichtId: z.medikamentId, userId: z.bearbeiterId ?? '', wire: z.inhalt, rev: z.rev, art: kArtEinnahme));
    final e = d.lesbar ? einnahmeLesen(d.text) : null;
    return EinnahmeAnsicht(id: z.id, medikamentId: z.medikamentId, inhalt: e, hinweis: e != null ? null : (d.lesbar ? 'neuere App-Version nötig oder beschädigt' : d.hinweis ?? 'wird entschlüsselt'), erstelltAt: z.createdAt);
  }

  // ------------------------------------------------------------------ Schreiben: Plan

  Future<MedikamentZeile> _zeile(String id) async {
    final z = await (db.select(db.medikamente)..where((t) => t.id.equals(id))).getSingleOrNull();
    if (z == null) throw const MedikamentFehler('Das Medikament gibt es nicht mehr.');
    return z;
  }

  /// Subjekt und Rechte der Zeile prüfen (über die Konversation) und den aktuellen Klartext lesen.
  Future<(MedikamentZeile, Konversation, MedikamentInhalt)> _aktuell(String id) async {
    final z = await _zeile(id);
    final konv = await (db.select(db.konversationen)..where((k) => k.id.equals(z.konversationId))).getSingleOrNull();
    final subjekt = konv?.subjektId;
    if (konv == null || subjekt == null) throw const MedikamentFehler('Das Medikament gibt es nicht mehr.');
    await _darfSubjekt(subjekt);
    final r = await _oeffnen(id: z.id, konversationId: z.konversationId, bearbeiterId: z.bearbeiterId, wire: z.inhalt, rev: z.rev, art: kArtMedikament);
    final m = r.text == null ? null : medikamentLesen(r.text!);
    if (m == null) throw const MedikamentNichtLesbar();
    return (z, konv, m);
  }

  /// Legt ein Medikament für die Person an (die Medikamenten-Konversation entsteht bei Bedarf). Liefert die ID. Ein ungültiger Inhalt wird nie geschrieben ([ArgumentError]).
  Future<String> anlegen(String subjektId, MedikamentInhalt inhalt) async {
    final klar = medikamentKodieren(inhalt);
    final konv = await konversationSicherstellen(subjektId);
    return _seriell(() async {
      final me = ich();
      if (me == null) throw const MedikamentNichtErlaubt();
      final id = _neueId();
      await store.aendern(
        'medikament',
        id,
        {'konversationId': konv, 'inhalt': '$kPraefixLokal$klar'},
        nurLokal: {'createdAt': zeitFuerServer(_jetzt()), 'bearbeiterId': me},
      );
      beiAenderung();
      return id;
    });
  }

  /// Ersetzt den Inhalt eines Medikaments (ändern; der Bearbeiter ist, wer es zuletzt schrieb).
  Future<void> aendern(String id, MedikamentInhalt neu) => _seriell(() async {
    final klar = medikamentKodieren(neu);
    final (_, _, _) = await _aktuell(id); // Rechte und Lesbarkeit (kein blindes Überschreiben eines unlesbaren Stands)
    await store.aendern('medikament', id, {'inhalt': '$kPraefixLokal$klar'}, nurLokal: {'bearbeiterId': ich()});
    beiAenderung();
  });

  Future<void> _umbauen(String id, MedikamentInhalt Function(MedikamentInhalt m) f) => _seriell(() async {
    final (_, _, m) = await _aktuell(id);
    final klar = medikamentKodieren(f(m));
    await store.aendern('medikament', id, {'inhalt': '$kPraefixLokal$klar'}, nurLokal: {'bearbeiterId': ich()});
    beiAenderung();
  });

  /// Pausiert das Medikament ab [ab] (Standard: heute), optional bis einschließlich [bis]; danach läuft der Plan von selbst weiter.
  Future<void> pausieren(String id, {DateTime? ab, DateTime? bis}) => _umbauen(
    id,
    (m) => m.kopie(zustand: MedikamentZustand.pausiert, zustandAb: () => tagText(familienTag(ab ?? _jetzt())), pauseBis: () => bis == null ? null : tagText(bis)),
  );

  /// Setzt ein pausiertes oder beendetes Medikament fort.
  Future<void> fortsetzen(String id) => _umbauen(id, (m) => m.kopie(zustand: MedikamentZustand.aktiv, zustandAb: () => null, pauseBis: () => null));

  /// Beendet das Medikament ab [ab] (Standard: heute): der Plan und seine Historie bleiben, es gibt keine Slots mehr.
  Future<void> beenden(String id, {DateTime? ab}) =>
      _umbauen(id, (m) => m.kopie(zustand: MedikamentZustand.beendet, zustandAb: () => tagText(familienTag(ab ?? _jetzt())), pauseBis: () => null));

  /// Löscht das Medikament endgültig samt seinen Einnahmen (auch auf allen Geräten und beim Server). Beenden ist der sanfte Weg.
  Future<void> loeschen(String id) => _seriell(() async {
    final z = await _zeile(id);
    final konv = await (db.select(db.konversationen)..where((k) => k.id.equals(z.konversationId))).getSingleOrNull();
    if (konv?.subjektId != null) await _darfSubjekt(konv!.subjektId!);
    await store.loeschen('medikament', id);
    beiAenderung();
  });

  /// Füllt den Vorrat auf (Packungen oder Stück) und setzt den Stichtag auf jetzt.
  Future<void> vorratAuffuellen(String id, {int packungen = 0, double stueck = 0}) => _seriell(() async {
    final (z, _, m) = await _aktuell(id);
    final einnahmen = await lesenEinnahmen(await (db.select(db.einnahmen)..where((e) => e.medikamentId.equals(z.id))).get());
    final neu = logik.vorratAuffuellen(m, einnahmen, _jetzt(), packungen: packungen, stueck: stueck);
    await store.aendern('medikament', id, {'inhalt': '$kPraefixLokal${medikamentKodieren(neu)}'}, nurLokal: {'bearbeiterId': ich()});
    beiAenderung();
  });

  // ------------------------------------------------------------------ Schreiben: Einnahmen

  Future<List<EinnahmeAnsicht>> _einnahmenVon(String medikamentId) async => lesenEinnahmen(await (db.select(db.einnahmen)..where((e) => e.medikamentId.equals(medikamentId))).get());

  /// Erfasst eine Einnahme zu einem Slot ([slot]) oder außer der Reihe (ohne Slot: "bei Bedarf", zusätzlich). [um] ist der Zeitpunkt der Einnahme (Standard: jetzt; nachtragen: früher,
  /// höchstens [kEinnahmenAufbewahrungTage] Tage zurück, nie in der Zukunft). Mit [status] `uebersprungen` wird der Slot als bewusst nicht genommen vermerkt. Gibt es für den Slot schon einen
  /// Eintrag, wird er ersetzt statt verdoppelt ("übersprungen" -> "genommen"); ein bereits genommener Slot bleibt unverändert. Liefert die ID des Eintrags.
  Future<String> einnahmeErfassen(String medikamentId, {Slot? slot, EinnahmeStatus status = EinnahmeStatus.genommen, DateTime? um, double? menge}) => _seriell(() async {
    final (z, _, _) = await _aktuell(medikamentId);
    final jetzt = _jetzt().toUtc();
    final zeit = (um ?? jetzt).toUtc();
    if (zeit.isAfter(jetzt.add(const Duration(minutes: 5)))) throw const EinnahmeUngueltig('Eine Einnahme kann nicht in der Zukunft liegen.');
    if (zeit.isBefore(jetzt.subtract(const Duration(days: kEinnahmenAufbewahrungTage)))) throw const EinnahmeUngueltig('So weit zurück lässt sich nichts nachtragen.');
    final inhalt = EinnahmeInhalt(status: status, um: zeit, geplant: slot?.schluessel, menge: menge);
    final klar = einnahmeKodieren(inhalt);
    final me = ich()!;
    if (slot != null) {
      final vorhanden = einnahmeFuerSlot(await _einnahmenVon(medikamentId), slot);
      if (vorhanden != null) {
        if (vorhanden.inhalt!.status == EinnahmeStatus.genommen && status == EinnahmeStatus.genommen) return vorhanden.id;
        await store.aendern('einnahme', vorhanden.id, {'inhalt': '$kPraefixLokal$klar'}, nurLokal: {'bearbeiterId': me});
        beiAenderung();
        return vorhanden.id;
      }
    }
    final id = _neueId();
    await store.aendern(
      'einnahme',
      id,
      {'konversationId': z.konversationId, 'medikamentId': medikamentId, 'inhalt': '$kPraefixLokal$klar'},
      nurLokal: {'createdAt': zeitFuerServer(jetzt), 'bearbeiterId': me},
    );
    beiAenderung();
    return id;
  });

  /// Nimmt eine Einnahme zurück (löscht den Eintrag; der Slot ist danach wieder offen bzw. verpasst).
  Future<void> einnahmeZuruecknehmen(String einnahmeId) => _seriell(() async {
    final z = await (db.select(db.einnahmen)..where((e) => e.id.equals(einnahmeId))).getSingleOrNull();
    if (z == null) return;
    final konv = await (db.select(db.konversationen)..where((k) => k.id.equals(z.konversationId))).getSingleOrNull();
    if (konv?.subjektId != null) await _darfSubjekt(konv!.subjektId!);
    await store.loeschen('einnahme', einnahmeId);
    beiAenderung();
  });

  /// Nimmt alle Einträge zu einem Slot zurück (auch doppelte von einem zweiten Gerät).
  Future<void> slotZuruecknehmen(String medikamentId, Slot slot) async {
    for (final e in await _einnahmenVon(medikamentId)) {
      if (e.inhalt?.geplant == slot.schluessel) await einnahmeZuruecknehmen(e.id);
    }
  }

  /// Entfernt lokale Einnahmen, die der Server schon kennt und die älter als 120 Tage sind (der Server löscht sie ebenfalls; hier für Geräte, die lange offline waren). Eintrag im
  /// Ausgang oder nur lokal vorhandene (Revision 0) bleiben. Liefert die Anzahl.
  Future<int> aelteEinnahmenEntfernen() async {
    final grenze = _jetzt().toUtc().subtract(const Duration(days: kEinnahmenAufbewahrungTage));
    final offen = {for (final o in await db.select(db.outbox).get()) o.entityId};
    var n = 0;
    for (final z in await (db.select(db.einnahmen)..where((e) => e.rev.isBiggerThanValue(0))).get()) {
      if (offen.contains(z.id) || !z.createdAt.toUtc().isBefore(grenze)) continue;
      n += await (db.delete(db.einnahmen)..where((e) => e.id.equals(z.id))).go();
    }
    return n;
  }
}

final medikamentRepositoryProvider = Provider<MedikamentRepository>((ref) {
  return MedikamentRepository(
    db: ref.watch(appDatabaseProvider),
    store: ref.watch(syncStoreProvider),
    krypto: () => ref.read(chatKryptoProvider.notifier).krypto(),
    ich: () => ref.read(authProvider).user?.id,
    mitglieder: () async => ref.read(mitgliederProvider.future),
    beiAenderung: () => ref.read(syncProvider.notifier).lokaleAenderung(),
  );
});
