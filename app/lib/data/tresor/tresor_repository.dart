// Tresor (Abschnitt 6m), Datenschicht: liest aus der lokalen Datenbank und schreibt sofort lokal (Tabelle und Ausgang, über SyncStore). Noch ohne Oberfläche und ohne Entsperr-Logik.
//
// Aufbau: Die Einträge des Tresors hängen an EINER verborgenen Konversation der Art `tresor` (feste ID `tresorChatId`, abgeleitet aus der Familie). Ihre Teilnehmer sind alle Eltern und
// Admins, NIE ein Kind; Epochenschlüssel, Wraps und Rotation laufen über dieselben Wege wie bei Gruppen (ChatKrypto, `SyncStore.aendernMehrere`). Ein Eintrag liegt im Ausgang als lokaler
// Klartext (`l1:` + `t1:`), der Abgleich verschlüsselt ihn erst beim Senden (ChatOpVorbereiter) in die Hülle `e1:`. Der Server sieht nie Kategorie, Titel, Feld oder Notiz, nur Struktur
// (ID, Zeitstempel, Größe). Der Tresor ist GEMEINSAM: jede teilnehmende Person liest, ändert und löscht jeden Eintrag.
//
// Rechte: Nur Eltern und Admins (tresor_teilnehmer.dart); der Server erzwingt dieselbe Regel gegen die Rollen seiner Datenbank. Neue Eltern (Kind wird Elternteil, neues Mitglied) nimmt
// [teilnehmerPflegen] auf (mit dem Verlauf, wenn [verlaufTeilen] gesetzt ist: die App-Steuerung tut das für Eltern immer); wer kein Elternteil mehr ist, wirft der Server sofort hinaus.
// Anhänge gibt es in dieser Version nicht; Notfallzugriff und Entsperren folgen später.
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
import 'tresor_logik.dart';
import 'tresor_modelle.dart';
import 'tresor_teilnehmer.dart';

/// Gemeinsame Oberklasse der Fehler des Tresors (ohne Inhalte in der Meldung).
class TresorFehler implements Exception {
  final String meldung;
  const TresorFehler(this.meldung);
  @override
  String toString() => meldung;
}

/// Die Person darf den Tresor nicht sehen oder ändern (Kinder nie).
class TresorNichtErlaubt extends TresorFehler {
  const TresorNichtErlaubt() : super('Der Tresor ist nur für Eltern und Admins.');
}

/// Der Inhalt lässt sich (noch) nicht lesen (kein Schlüssel, unbestätigter Absender, beschädigt, neuere App-Version).
class TresorNichtLesbar extends TresorFehler {
  const TresorNichtLesbar() : super('Dieser Eintrag lässt sich gerade nicht lesen.');
}

/// Der Eintrag lässt sich so nicht speichern (Pflichtangaben, Grenzen); [probleme] nennt die Gründe.
class TresorEingabeFehler extends TresorFehler {
  final List<TresorProblem> probleme;
  TresorEingabeFehler(this.probleme) : super(probleme.isEmpty ? 'Der Eintrag ist ungültig.' : probleme.first.meldung);
}

/// Ein Eintrag für die Oberfläche: gelesen oder mit Hinweis, warum nicht.
class TresorAnsicht {
  final String id;
  final String konversationId;
  final TresorInhalt? inhalt;
  final String? hinweis;
  final String? bearbeiterId;
  final DateTime erstelltAt;

  /// Noch nicht vom Server bestätigt (liegt im Ausgang).
  final bool lokalNeu;
  const TresorAnsicht({required this.id, required this.konversationId, required this.inhalt, required this.hinweis, required this.bearbeiterId, required this.erstelltAt, required this.lokalNeu});

  bool get lesbar => inhalt != null;
}

class TresorRepository {
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

  TresorRepository({
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

  // ------------------------------------------------------------------ Konversation

  Future<ChatKrypto> _kryptoPflicht() async {
    final k = await krypto();
    if (k == null) throw const VerschluesselungNichtBereit('Richte zuerst den Nachrichten-Schutz ein (Profil › Sicherheit › Nachrichten-Schutz).');
    return k;
  }

  /// ID der Tresor-Konversation dieser Familie (null: Familie unbekannt).
  String? get konversationId {
    final f = familie();
    return f == null ? null : tresorChatId(f);
  }

  /// Die lokale Tresor-Konversation (null: gibt es (noch) nicht).
  Future<Konversation?> konversation() async {
    final id = konversationId;
    if (id == null) return null;
    return (db.select(db.konversationen)..where((k) => k.id.equals(id) & k.art.equals(ChatArt.tresor.wire))).getSingleOrNull();
  }

  /// Darf diese Person den Tresor sehen und ändern?
  Future<void> _darf() async {
    final me = ich();
    if (me == null || !darfTresorSehen(ich: me, mitglieder: await mitglieder())) throw const TresorNichtErlaubt();
  }

  /// Legt die Tresor-Konversation an, falls es lokal keine gibt (mit der ersten Epoche für alle Eltern und Admins mit vertrauenswürdigem Schlüssel; die übrigen kommen mit
  /// [teilnehmerPflegen] dazu, sobald sie so weit sind). Liefert die ID. Die anlegende Person braucht eine eingerichtete Verschlüsselung ([SchluesselFehlt] sonst).
  Future<String> konversationSicherstellen() => _seriell(() async {
    await _darf();
    final id = konversationId;
    if (id == null) throw const TresorFehler('Die Familie ist nicht bekannt.');
    if (await konversation() != null) return id;
    final me = ich()!;
    final k = await _kryptoPflicht();
    final alle = await mitglieder();
    final soll = sollTresorTeilnehmer(mitglieder: alle);
    if (!soll.contains(me.toLowerCase())) throw const TresorNichtErlaubt();
    final e = await k.empfaenger(soll);
    // die anlegende Person MUSS dabei sein (sonst könnte sie den Tresor nie lesen)
    if (!e.schluessel.keys.map((x) => x.toLowerCase()).contains(me.toLowerCase())) throw SchluesselFehlt([me]);
    final teilnehmer = e.schluessel.keys.toSet();
    final epoche = await k.epocheErstellen(konversationId: id, mitglieder: teilnehmer, unvertrauteAuslassen: true);
    await store.aendernMehrere([
      SyncAenderung(
        'konversation',
        id,
        {'art': ChatArt.tresor.wire, 'encVersion': 'e1', 'teilnehmer': (teilnehmer.map((x) => x.toLowerCase()).toList()..sort())},
        nurLokal: {'createdAt': zeitFuerServer(_jetzt()), 'ownerId': me},
      ),
      ...epoche,
    ]);
    beiAenderung();
    return id;
  });

  /// Gleicht die Teilnehmer der Tresor-Konversation mit den Rollen ab: Eltern/Admins, die fehlen, kommen dazu (nur mit vertrauenswürdigem Schlüssel; den früheren Verlauf bekommen sie mit
  /// [verlaufTeilen] = true bzw. über [verlaufFreigeben]), wer nach den Rollen nicht mehr hineingehört, geht (jede Änderung legt in derselben Transaktion eine neue Epoche an: wer geht, liest
  /// Neues nicht mehr). Der Server wirft nach einem Rollenwechsel ein Kind sofort aus der Liste; die Rotation übernimmt dann diese Pflege. Liefert true, wenn etwas geändert wurde.
  Future<bool> teilnehmerPflegen({bool verlaufTeilen = false}) => _seriell(() async {
    final me = ich();
    final konv = await konversation();
    if (me == null || konv == null || konv.encVersion != 'e1' || konv.rev == 0) return false;
    final aktuell = teilnehmerIds(konv).map((x) => x.toLowerCase()).toSet();
    if (!aktuell.contains(me.toLowerCase())) return false;
    final alle = await mitglieder();
    final k = await _kryptoPflicht();
    final sollAlle = sollTresorTeilnehmer(mitglieder: alle);
    if (sollAlle.isEmpty) return false;
    final e = await k.empfaenger(sollAlle);
    final vertraut = e.schluessel.keys.map((x) => x.toLowerCase()).toSet();
    final a = tresorAbgleichen(aktuell: aktuell, mitglieder: alle, nurMit: vertraut);
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
  /// Gerät kennt. Legt dafür eine neue Epoche für alle Teilnehmer an. Liefert true, wenn etwas geschrieben wurde. Ein Kind bekommt nie etwas (nie Teilnehmer).
  Future<bool> verlaufFreigeben(Set<String> personen) => _seriell(() async {
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

  /// Die Eintrags-Zeilen (älteste zuerst); leer, wenn es die Konversation lokal nicht gibt.
  Stream<List<TresorEintragZeile>> zeilen() {
    final id = konversationId;
    if (id == null) return Stream.value(const []);
    return (db.select(db.tresorEintraege)
          ..where((z) => z.konversationId.equals(id))
          ..orderBy([(z) => OrderingTerm.asc(z.createdAt), (z) => OrderingTerm.asc(z.id)]))
        .watch();
  }

  /// Klartext einer Zeile (Art `t`); null mit Grund, wenn er sich nicht öffnen lässt. Lokaler Klartext (`l1:`) gilt nur für eigene, noch nicht bestätigte Zeilen.
  Future<({String? text, String? hinweis})> _oeffnen(TresorEintragZeile z) async {
    if (z.inhalt.startsWith(kPraefixLokal)) {
      if (z.bearbeiterId != null && z.bearbeiterId == ich()) return (text: z.inhalt.substring(kPraefixLokal.length), hinweis: null);
      return (text: null, hinweis: 'unverschlüsselt');
    }
    if (z.bearbeiterId == null) return (text: null, hinweis: 'Person nicht mehr in der Familie');
    final k = await krypto();
    if (k == null) return (text: null, hinweis: 'Nachrichten-Schutz nicht bereit');
    try {
      final d = await k.nachrichtOeffnen(konversationId: z.konversationId, nachrichtId: z.id, autorId: z.bearbeiterId, wire: z.inhalt, art: kArtTresor);
      return d.lesbar ? (text: d.text, hinweis: null) : (text: null, hinweis: d.hinweis ?? 'nicht lesbar');
    } on Object {
      return (text: null, hinweis: 'nicht lesbar');
    }
  }

  /// Liest Einträge (entschlüsselt, geprüft: Signatur, Konversation, eigene ID, Art). Nicht lesbare Zeilen kommen mit Hinweis und ohne Inhalt.
  Future<List<TresorAnsicht>> lesen(Iterable<TresorEintragZeile> zeilen) async => [
    for (final z in zeilen)
      await () async {
        final r = await _oeffnen(z);
        final inhalt = r.text == null ? null : tresorLesen(r.text!);
        return TresorAnsicht(
          id: z.id,
          konversationId: z.konversationId,
          inhalt: inhalt,
          hinweis: inhalt != null ? null : (r.hinweis ?? 'neuere App-Version nötig oder beschädigt'),
          bearbeiterId: z.bearbeiterId,
          erstelltAt: z.createdAt,
          lokalNeu: z.rev == 0,
        );
      }(),
  ];

  /// Wie [lesen] für die Oberfläche: nicht blockierend über den Zwischenspeicher der Entschlüsselung ([NachrichtenInhalt.zusatz]).
  TresorAnsicht ansicht(TresorEintragZeile z, NachrichtenInhalt inhalt) {
    final d = z.bearbeiterId == null && !z.inhalt.startsWith(kPraefixLokal)
        ? const DekodierterInhalt('', InhaltStatus.nichtEntschluesselbar, hinweis: 'Person nicht mehr in der Familie')
        : inhalt.zusatz(ZusatzRef(id: z.id, konversationId: z.konversationId, nachrichtId: '', userId: z.bearbeiterId ?? '', wire: z.inhalt, rev: z.rev, art: kArtTresor));
    final i = d.lesbar ? tresorLesen(d.text) : null;
    return TresorAnsicht(
      id: z.id,
      konversationId: z.konversationId,
      inhalt: i,
      hinweis: i != null ? null : (d.lesbar ? 'neuere App-Version nötig oder beschädigt' : d.hinweis ?? 'wird entschlüsselt'),
      bearbeiterId: z.bearbeiterId,
      erstelltAt: z.createdAt,
      lokalNeu: z.rev == 0,
    );
  }

  // ------------------------------------------------------------------ Schreiben

  Future<TresorEintragZeile> _zeile(String id) async {
    final z = await (db.select(db.tresorEintraege)..where((t) => t.id.equals(id))).getSingleOrNull();
    if (z == null) throw const TresorFehler('Den Eintrag gibt es nicht mehr.');
    return z;
  }

  /// Rechte prüfen und den aktuellen Klartext lesen.
  Future<(TresorEintragZeile, TresorInhalt)> _aktuell(String id) async {
    await _darf();
    final z = await _zeile(id);
    final r = await _oeffnen(z);
    final i = r.text == null ? null : tresorLesen(r.text!);
    if (i == null) throw const TresorNichtLesbar();
    return (z, i);
  }

  /// Der Inhalt, wie er geschrieben wird: mit dem Zeitpunkt dieser Änderung. Ein ungültiger oder zu großer Inhalt wird nie geschrieben ([TresorEingabeFehler]).
  String _klartext(TresorInhalt inhalt) {
    final mitZeit = inhalt.kopie(geaendert: _jetzt().toUtc().millisecondsSinceEpoch);
    final probleme = tresorProbleme(mitZeit);
    if (probleme.isNotEmpty) throw TresorEingabeFehler(probleme);
    return tresorKodieren(mitZeit);
  }

  /// Legt einen Eintrag an (die Konversation entsteht bei Bedarf). Liefert die ID.
  Future<String> anlegen(TresorInhalt inhalt) async {
    final klar = _klartext(inhalt);
    final konv = await konversationSicherstellen();
    return _seriell(() async {
      final me = ich();
      if (me == null) throw const TresorNichtErlaubt();
      final vorhanden = await (db.select(db.tresorEintraege)..where((z) => z.konversationId.equals(konv))).get();
      if (vorhanden.length >= kMaxTresorEintraege) throw const TresorFehler('Es sind zu viele Einträge vorhanden.');
      final id = _neueId();
      await store.aendern(
        'tresor_eintrag',
        id,
        {'konversationId': konv, 'inhalt': '$kPraefixLokal$klar'},
        nurLokal: {'createdAt': zeitFuerServer(_jetzt()), 'bearbeiterId': me},
      );
      beiAenderung();
      return id;
    });
  }

  /// Ersetzt den Inhalt eines Eintrags (jede Person mit Zugriff darf jeden Eintrag ändern; der Bearbeiter ist, wer ihn zuletzt schrieb).
  Future<void> aendern(String id, TresorInhalt neu) => _seriell(() async {
    final klar = _klartext(neu);
    await _aktuell(id); // Rechte und Lesbarkeit (kein blindes Überschreiben eines unlesbaren Eintrags)
    await store.aendern('tresor_eintrag', id, {'inhalt': '$kPraefixLokal$klar'}, nurLokal: {'bearbeiterId': ich()});
    beiAenderung();
  });

  /// Ordnet die Felder eines Eintrags um (Feld [von] an Stelle [nach]).
  Future<void> feldVerschieben(String id, int von, int nach) => _seriell(() async {
    final (_, i) = await _aktuell(id);
    final klar = _klartext(i.kopie(felder: tresorFeldVerschieben(i.felder, von, nach)));
    await store.aendern('tresor_eintrag', id, {'inhalt': '$kPraefixLokal$klar'}, nurLokal: {'bearbeiterId': ich()});
    beiAenderung();
  });

  /// Löscht den Eintrag endgültig (auch auf allen Geräten und beim Server). Der Server löscht nie von selbst.
  Future<void> loeschen(String id) => _seriell(() async {
    await _darf();
    await _zeile(id);
    await store.loeschen('tresor_eintrag', id);
    beiAenderung();
  });
}

final tresorRepositoryProvider = Provider<TresorRepository>((ref) {
  return TresorRepository(
    db: ref.watch(appDatabaseProvider),
    store: ref.watch(syncStoreProvider),
    krypto: () => ref.read(chatKryptoProvider.notifier).krypto(),
    ich: () => ref.read(authProvider).user?.id,
    familie: () => ref.read(authProvider).me?.familyId,
    mitglieder: () async => ref.read(mitgliederProvider.future),
    beiAenderung: () => ref.read(syncProvider.notifier).lokaleAenderung(),
  );
});
