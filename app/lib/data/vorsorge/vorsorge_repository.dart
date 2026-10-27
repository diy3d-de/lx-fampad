// Vorsorge und Impfungen (Abschnitt 6p) für die Oberfläche: liest aus der lokalen Datenbank und schreibt sofort lokal (Tabelle und Ausgang, über SyncStore).
//
// Aufbau: Profil und Einträge einer Person hängen an ihrer verborgenen Konversation der Art `meds` (feste ID `medsChatId`; dieselbe wie beim Medikamenten-Plan, dieselbe Sichtgrenze).
// Die Konversation, ihre Teilnehmer und Epochenschlüssel verwaltet `MedikamentRepository` (konversationSicherstellen, teilnehmerPflegen); hier kommen nur die Inhalte dazu. Sie liegen im Ausgang
// als lokaler Klartext (`l1:` + `vp1:`/`ve1:`), der Abgleich verschlüsselt sie erst beim Senden in die Hülle `e1:`. Der Server sieht nie Geburtsdatum, Namen oder Erledigt-Daten.
//
// Rechte: Wessen Daten jemand sehen und ändern darf, steht in medikament_subjekte.dart (Eltern und Admins die ihrer Kinder, nie die eines anderen Erwachsenen; Kinder nur die eigenen);
// der Server erzwingt dieselbe Regel.
import 'dart:async';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/models.dart' show UserDto;
import '../app_database.dart';
import '../auth/auth_state.dart';
import '../chat/chat_ids.dart';
import '../chat/chat_krypto.dart';
import '../chat/chat_krypto_state.dart';
import '../chat/chat_repository.dart' show ChatArt;
import '../chat/nachrichten_inhalt.dart';
import '../database_provider.dart';
import '../lists/members.dart';
import '../medikamente/medikament_repository.dart';
import '../medikamente/medikament_subjekte.dart';
import '../sync/sync_entities.dart';
import '../sync/sync_store.dart';
import '../sync_state.dart';
import 'vorsorge_modelle.dart';

/// Fehler der Vorsorge (ohne Inhalte in der Meldung).
class VorsorgeFehler implements Exception {
  final String meldung;
  const VorsorgeFehler(this.meldung);
  @override
  String toString() => meldung;
}

class VorsorgeNichtErlaubt extends VorsorgeFehler {
  const VorsorgeNichtErlaubt() : super('Du darfst die Vorsorge dieser Person nicht sehen.');
}

class VorsorgeNichtLesbar extends VorsorgeFehler {
  const VorsorgeNichtLesbar() : super('Dieser Eintrag lässt sich gerade nicht lesen.');
}

class VorsorgeUngueltig extends VorsorgeFehler {
  const VorsorgeUngueltig(super.meldung);
}

/// Das Profil einer Person für die Oberfläche.
class VorsorgeProfilAnsicht {
  final String subjektId;
  final VorsorgeProfilInhalt? inhalt;
  final String? hinweis;
  const VorsorgeProfilAnsicht({required this.subjektId, this.inhalt, this.hinweis});
}

class VorsorgeRepository {
  final AppDatabase db;
  final SyncStore store;
  final Future<ChatKrypto?> Function() krypto;
  final String? Function() ich;
  final Future<List<UserDto>> Function() mitglieder;

  /// Legt die Medikamenten-Konversation der Person bei Bedarf an (`MedikamentRepository.konversationSicherstellen`).
  final Future<String> Function(String subjektId) konversationSicherstellen;
  final void Function() beiAenderung;
  final DateTime Function() _jetzt;
  final String Function() _neueId;

  VorsorgeRepository({
    required this.db,
    required this.store,
    required this.krypto,
    required this.ich,
    required this.mitglieder,
    required this.konversationSicherstellen,
    required this.beiAenderung,
    DateTime Function()? jetzt,
    String Function()? neueId,
  }) : _jetzt = jetzt ?? DateTime.now,
       _neueId = neueId ?? neueUuid;

  Future<void> _kette = Future.value();
  Future<T> _seriell<T>(Future<T> Function() f) {
    final r = _kette.then((_) => f());
    _kette = r.then<void>((_) {}).catchError((Object _) {});
    return r;
  }

  Future<void> _darfSubjekt(String subjektId) async {
    final me = ich();
    if (me == null || !darfSubjektSehen(ich: me, subjekt: subjektId, mitglieder: await mitglieder())) throw const VorsorgeNichtErlaubt();
  }

  Future<Konversation?> _konversationVon(String id) => (db.select(db.konversationen)..where((k) => k.id.equals(id) & k.art.equals(ChatArt.meds.wire))).getSingleOrNull();

  // ------------------------------------------------------------------ Lesen (nicht blockierend über den Zwischenspeicher der Entschlüsselung)

  VorsorgeProfilAnsicht profilAnsicht(String subjektId, VorsorgeProfilZeile z, NachrichtenInhalt inhalt) {
    final d = z.bearbeiterId == null && !z.inhalt.startsWith(kPraefixLokal)
        ? const DekodierterInhalt('', InhaltStatus.nichtEntschluesselbar, hinweis: 'Person nicht mehr in der Familie')
        : inhalt.zusatz(ZusatzRef(id: z.id, konversationId: z.konversationId, nachrichtId: '', userId: z.bearbeiterId ?? '', wire: z.inhalt, rev: z.rev, art: kArtVorsorgeProfil));
    final p = d.lesbar ? vorsorgeProfilLesen(d.text) : null;
    return VorsorgeProfilAnsicht(subjektId: subjektId, inhalt: p, hinweis: p != null ? null : (d.lesbar ? 'neuere App-Version nötig oder beschädigt' : d.hinweis ?? 'wird entschlüsselt'));
  }

  VorsorgeAnsicht ansicht(String subjektId, VorsorgeEintragZeile z, NachrichtenInhalt inhalt) {
    final d = z.bearbeiterId == null && !z.inhalt.startsWith(kPraefixLokal)
        ? const DekodierterInhalt('', InhaltStatus.nichtEntschluesselbar, hinweis: 'Person nicht mehr in der Familie')
        : inhalt.zusatz(ZusatzRef(id: z.id, konversationId: z.konversationId, nachrichtId: '', userId: z.bearbeiterId ?? '', wire: z.inhalt, rev: z.rev, art: kArtVorsorgeEintrag));
    final e = d.lesbar ? vorsorgeEintragLesen(d.text) : null;
    return VorsorgeAnsicht(
      id: z.id,
      konversationId: z.konversationId,
      subjektId: subjektId,
      inhalt: e,
      hinweis: e != null ? null : (d.lesbar ? 'neuere App-Version nötig oder beschädigt' : d.hinweis ?? 'wird entschlüsselt'),
      erstelltAt: z.createdAt,
      lokalNeu: z.rev == 0,
    );
  }

  /// Klartext einer Zeile (Profil `p`, Eintrag `v`); null mit Grund, wenn er sich nicht öffnen lässt. Lokaler Klartext (`l1:`) gilt nur für eigene, noch nicht bestätigte Zeilen.
  Future<String?> _klartext({required String id, required String konversationId, required String? bearbeiterId, required String wire, required String art}) async {
    if (wire.startsWith(kPraefixLokal)) {
      return bearbeiterId != null && bearbeiterId == ich() ? wire.substring(kPraefixLokal.length) : null;
    }
    if (bearbeiterId == null) return null;
    final k = await krypto();
    if (k == null) return null;
    try {
      final d = await k.nachrichtOeffnen(konversationId: konversationId, nachrichtId: id, autorId: bearbeiterId, wire: wire, art: art);
      return d.lesbar ? d.text : null;
    } on Object {
      return null;
    }
  }

  /// Die Eintrag-Zeilen der Person (älteste zuerst); leer, wenn es die Konversation lokal nicht gibt.
  Stream<List<VorsorgeEintragZeile>> zeilen(String subjektId) {
    final q = db.select(db.vorsorgeEintraege).join([innerJoin(db.konversationen, db.konversationen.id.equalsExp(db.vorsorgeEintraege.konversationId))])
      ..where(db.konversationen.subjektId.equals(subjektId.toLowerCase()) & db.konversationen.art.equals(ChatArt.meds.wire))
      ..orderBy([OrderingTerm.asc(db.vorsorgeEintraege.createdAt), OrderingTerm.asc(db.vorsorgeEintraege.id)]);
    return q.watch().map((l) => [for (final r in l) r.readTable(db.vorsorgeEintraege)]);
  }

  /// Liest Eintrag-Zeilen (entschlüsselt, geprüft: Signatur, Konversation, eigene ID, Art). Nicht lesbare kommen mit Hinweis und ohne Inhalt.
  Future<List<VorsorgeAnsicht>> lesen(String subjektId, Iterable<VorsorgeEintragZeile> zeilen) async => [
    for (final z in zeilen)
      await () async {
        final t = await _klartext(id: z.id, konversationId: z.konversationId, bearbeiterId: z.bearbeiterId, wire: z.inhalt, art: kArtVorsorgeEintrag);
        final e = t == null ? null : vorsorgeEintragLesen(t);
        return VorsorgeAnsicht(id: z.id, konversationId: z.konversationId, subjektId: subjektId, inhalt: e, hinweis: e != null ? null : 'nicht lesbar', erstelltAt: z.createdAt, lokalNeu: z.rev == 0);
      }(),
  ];

  /// Das Profil der Person (null: keines oder nicht lesbar).
  Future<VorsorgeProfilInhalt?> profilLesen(String subjektId) async {
    final konv = medsChatId(subjektId);
    final z = await (db.select(db.vorsorgeProfile)..where((t) => t.id.equals(vorsorgeProfilId(konv)))).getSingleOrNull();
    if (z == null) return null;
    final t = await _klartext(id: z.id, konversationId: z.konversationId, bearbeiterId: z.bearbeiterId, wire: z.inhalt, art: kArtVorsorgeProfil);
    return t == null ? null : vorsorgeProfilLesen(t);
  }

  // ------------------------------------------------------------------ Schreiben: Profil

  /// Setzt (oder ändert) das Profil der Person; die Konversation entsteht bei Bedarf. Ein ungültiges Profil wird nie geschrieben ([ArgumentError]).
  Future<void> profilSetzen(String subjektId, VorsorgeProfilInhalt profil) async {
    final klar = vorsorgeProfilKodieren(profil);
    if (profil.geburtTag!.isAfter(_jetzt().toUtc().add(const Duration(days: 1)))) throw const VorsorgeUngueltig('Das Geburtsdatum kann nicht in der Zukunft liegen.');
    await _darfSubjekt(subjektId);
    final konv = await konversationSicherstellen(subjektId);
    return _seriell(() async {
      final me = ich();
      if (me == null) throw const VorsorgeNichtErlaubt();
      final id = vorsorgeProfilId(konv);
      final vorhanden = await (db.select(db.vorsorgeProfile)..where((t) => t.id.equals(id))).getSingleOrNull();
      if (vorhanden == null) {
        await store.aendern('vorsorge_profil', id, {'konversationId': konv, 'inhalt': '$kPraefixLokal$klar'}, nurLokal: {'createdAt': zeitFuerServer(_jetzt()), 'bearbeiterId': me});
      } else {
        await store.aendern('vorsorge_profil', id, {'inhalt': '$kPraefixLokal$klar'}, nurLokal: {'bearbeiterId': me});
      }
      beiAenderung();
    });
  }

  // ------------------------------------------------------------------ Schreiben: Einträge

  Future<VorsorgeEintragZeile> _zeile(String id) async {
    final z = await (db.select(db.vorsorgeEintraege)..where((t) => t.id.equals(id))).getSingleOrNull();
    if (z == null) throw const VorsorgeFehler('Den Eintrag gibt es nicht mehr.');
    return z;
  }

  /// Subjekt und Rechte der Zeile prüfen und den aktuellen Klartext lesen (ein nicht lesbarer Stand wird nie blind überschrieben).
  Future<(VorsorgeEintragZeile, VorsorgeEintragInhalt)> _aktuell(String id) async {
    final z = await _zeile(id);
    final konv = await (db.select(db.konversationen)..where((k) => k.id.equals(z.konversationId))).getSingleOrNull();
    final subjekt = konv?.subjektId;
    if (konv == null || subjekt == null) throw const VorsorgeFehler('Den Eintrag gibt es nicht mehr.');
    await _darfSubjekt(subjekt);
    final t = await _klartext(id: z.id, konversationId: z.konversationId, bearbeiterId: z.bearbeiterId, wire: z.inhalt, art: kArtVorsorgeEintrag);
    final e = t == null ? null : vorsorgeEintragLesen(t);
    if (e == null) throw const VorsorgeNichtLesbar();
    return (z, e);
  }

  /// Legt einen Eintrag für die Person an. Liefert die ID. Ein ungültiger Inhalt wird nie geschrieben ([ArgumentError]).
  Future<String> anlegen(String subjektId, VorsorgeEintragInhalt inhalt) async {
    final klar = vorsorgeEintragKodieren(inhalt);
    _pruefeZukunft(inhalt);
    await _darfSubjekt(subjektId);
    final konv = await konversationSicherstellen(subjektId);
    return _seriell(() async {
      final me = ich();
      if (me == null) throw const VorsorgeNichtErlaubt();
      final id = _neueId();
      await store.aendern('vorsorge_eintrag', id, {'konversationId': konv, 'inhalt': '$kPraefixLokal$klar'}, nurLokal: {'createdAt': zeitFuerServer(_jetzt()), 'bearbeiterId': me});
      beiAenderung();
      return id;
    });
  }

  void _pruefeZukunft(VorsorgeEintragInhalt e) {
    final heute = vorsorgeTagText(_jetzt().toLocal());
    // ein Erledigt-Datum liegt nie in der Zukunft (einen Tag Spielraum für die Zeitzone)
    final morgen = vorsorgeTagText(_jetzt().toLocal().add(const Duration(days: 1)));
    if (e.erledigt.any((t) => t.compareTo(morgen) > 0)) throw VorsorgeUngueltig('Ein erledigter Termin kann nicht nach dem $heute liegen.');
  }

  /// Ersetzt den Inhalt eines Eintrags.
  Future<void> aendern(String id, VorsorgeEintragInhalt neu) => _seriell(() async {
    final klar = vorsorgeEintragKodieren(neu);
    _pruefeZukunft(neu);
    await _aktuell(id);
    await store.aendern('vorsorge_eintrag', id, {'inhalt': '$kPraefixLokal$klar'}, nurLokal: {'bearbeiterId': ich()});
    beiAenderung();
  });

  Future<void> _umbauen(String id, VorsorgeEintragInhalt Function(VorsorgeEintragInhalt e) f) => _seriell(() async {
    final (_, e) = await _aktuell(id);
    final neu = f(e);
    final klar = vorsorgeEintragKodieren(neu);
    _pruefeZukunft(neu);
    if (neu == e) return;
    await store.aendern('vorsorge_eintrag', id, {'inhalt': '$kPraefixLokal$klar'}, nurLokal: {'bearbeiterId': ich()});
    beiAenderung();
  });

  /// Trägt ein erledigtes Datum ein (Standard: heute). Ein schon eingetragener Tag ändert nichts. Ein von Hand gesetztes nächstes Datum, das damit erreicht ist, entfällt.
  Future<void> erledigtEintragen(String id, {DateTime? tag, String? notiz}) => _umbauen(id, (e) {
    final t = vorsorgeTagText(tag ?? _jetzt().toLocal());
    final liste = {...e.erledigt, t}.toList()..sort();
    while (liste.length > kMaxVorsorgeErledigt) {
      liste.removeAt(0);
    }
    final naechstesErreicht = e.naechstes != null && t.compareTo(e.naechstes!) >= 0;
    return e.kopie(erledigt: liste, naechstes: naechstesErreicht ? () => null : null, notiz: notiz ?? e.notiz);
  });

  /// Nimmt ein erledigtes Datum zurück.
  Future<void> erledigtZuruecknehmen(String id, String tag) => _umbauen(id, (e) => e.kopie(erledigt: [for (final t in e.erledigt) if (t != tag) t]));

  /// Löscht den Eintrag endgültig (auch auf allen Geräten und beim Server).
  Future<void> loeschen(String id) => _seriell(() async {
    final z = await _zeile(id);
    final konv = await _konversationVon(z.konversationId);
    if (konv?.subjektId != null) await _darfSubjekt(konv!.subjektId!);
    await store.loeschen('vorsorge_eintrag', id);
    beiAenderung();
  });
}

final vorsorgeRepositoryProvider = Provider<VorsorgeRepository>((ref) {
  return VorsorgeRepository(
    db: ref.watch(appDatabaseProvider),
    store: ref.watch(syncStoreProvider),
    krypto: () => ref.read(chatKryptoProvider.notifier).krypto(),
    ich: () => ref.read(authProvider).user?.id,
    mitglieder: () async => ref.read(mitgliederProvider.future),
    konversationSicherstellen: (s) => ref.read(medikamentRepositoryProvider).konversationSicherstellen(s),
    beiAenderung: () => ref.read(syncProvider.notifier).lokaleAenderung(),
  );
});
