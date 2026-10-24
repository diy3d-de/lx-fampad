// Dateiablage (Abschnitt 6n), Datenschicht: liest aus der lokalen Datenbank und schreibt sofort lokal (Tabelle und Ausgang, über SyncStore). Noch ohne Oberfläche.
//
// Die Bytes liegen nicht im Sync. Neue Dateien und Fassungen entstehen erst, wenn der Upload fertig ist (TransferDienst): dann legt [dateiMitFassungAnlegen] bzw. [fassungAnlegen] den Datensatz
// mit der Upload-ID an (der Server beansprucht den Blob atomar in der Sync-Transaktion). Alles Übrige (Ordner anlegen, umbenennen, verschieben, löschen, Freigabestufe) sind kleine Stapel, die
// die Server-Invariante in der richtigen Reihenfolge einhalten:
//  - ein Eintrag der Stufe `family` liegt nur in einem Ordner der Stufe `family` (oder ganz oben),
//  - ein Ordner lässt sich nur auf `parents` stellen, wenn darunter nichts `family` ist: die Kinder werden zuerst umgestellt (von unten nach oben),
//  - ein Ordner wird nur leer gelöscht: [ordnerMitInhaltLoeschen] löscht von unten nach oben,
//  - Tiefe höchstens 6, kein Zyklus.
// Die Rechte der Oberfläche (`DateiRechte`) hängen nur an der Rolle; der Server erzwingt dieselben Regeln.
import 'dart:async';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/models.dart' show Role;
import '../app_database.dart';
import '../auth/auth_state.dart';
import '../database_provider.dart';
import '../sync/sync_entities.dart' show zeitFuerServer;
import '../sync/sync_store.dart';
import '../sync_state.dart';
import 'datei_logik.dart';
import 'datei_modelle.dart';

/// Höchstens so viele Fassungen je Datei (wie der Server).
const int kMaxFassungenJeDatei = 100;

/// Eine Datei für die Oberfläche: der Datensatz mit seiner neuesten Fassung.
class DateiEintrag {
  final DateiZeile datei;

  /// Neueste Fassung (höchste Nummer); null, solange noch keine Fassung da ist (Upload läuft oder ist fehlgeschlagen).
  final DateiVersionZeile? neueste;
  final int fassungen;
  const DateiEintrag(this.datei, this.neueste, this.fassungen);

  String get id => datei.id;
  String get name => datei.name;
  String get audience => datei.audience;
  String? get mime => neueste?.mime;
  int get groesse => neueste?.size ?? 0;
  String? get thumbBlobId => neueste?.thumbBlobId;
  DateTime get geaendert => neueste?.createdAt ?? datei.createdAt;

  /// Noch nicht vom Server bestätigt (liegt im Ausgang).
  bool get lokalNeu => datei.rev == 0 || (neueste?.rev ?? 1) == 0;
  bool get ohneFassung => neueste == null;
}

class DateiRepository {
  final AppDatabase db;
  final SyncStore store;

  /// Angemeldete Person und ihre Rolle (null: nicht angemeldet).
  final String? Function() ich;
  final Role? Function() rolle;
  final void Function() beiAenderung;
  final DateTime Function() _jetzt;
  final String Function() _neueId;

  DateiRepository({
    required this.db,
    required this.store,
    required this.ich,
    required this.rolle,
    required this.beiAenderung,
    DateTime Function()? jetzt,
    String Function()? neueId,
  }) : _jetzt = jetzt ?? DateTime.now,
       _neueId = neueId ?? neueUuid;

  DateiRechte get rechte => DateiRechte(rolle: rolle() ?? Role.child, ich: ich());

  // Änderungen laufen nacheinander (schnelles Tippen, mehrere Geräte-Ereignisse): der Stand wird aus der Datenbank gelesen
  Future<void> _kette = Future.value();
  Future<T> _seriell<T>(Future<T> Function() f) {
    final r = _kette.then((_) => f());
    _kette = r.then<void>((_) {}).catchError((Object _) {});
    return r;
  }

  // ------------------------------------------------------------------ Lesen

  /// Alle Ordner, die die Person sehen darf (Kinder nur `family`), ohne bestimmte Reihenfolge.
  Stream<List<OrdnerZeile>> alleOrdner() => db.select(db.ordner).watch().map((l) => [for (final o in l) if (rechte.darfSehen(o.audience)) o]);

  /// Ordner direkt in [parentId] (null = oberste Ebene), nach Namen sortiert.
  Stream<List<OrdnerZeile>> ordnerIn(String? parentId) {
    final q = db.select(db.ordner)..where((o) => parentId == null ? o.parentId.isNull() : o.parentId.equals(parentId));
    return q.watch().map((l) => ordnerSortiert([for (final o in l) if (rechte.darfSehen(o.audience)) o]));
  }

  Stream<List<DateiVersionZeile>> versionen(String dateiId) =>
      (db.select(db.dateiVersionen)
            ..where((v) => v.dateiId.equals(dateiId))
            ..orderBy([(v) => OrderingTerm.desc(v.nr)]))
          .watch();

  List<DateiEintrag> _zusammen(List<DateiZeile> dateien, List<DateiVersionZeile> versionen) {
    final nach = <String, List<DateiVersionZeile>>{};
    for (final v in versionen) {
      (nach[v.dateiId] ??= []).add(v);
    }
    return [
      for (final d in dateien)
        if (rechte.darfSehen(d.audience))
          () {
            final l = nach[d.id] ?? const <DateiVersionZeile>[];
            DateiVersionZeile? neu;
            for (final v in l) {
              if (neu == null || v.nr > neu.nr) neu = v;
            }
            return DateiEintrag(d, neu, l.length);
          }(),
    ];
  }

  /// Dateien direkt in [ordnerId] (null = oberste Ebene) mit ihrer neuesten Fassung, nach Namen sortiert (die Oberfläche sortiert bei Bedarf mit [dateienSortiert] neu).
  Stream<List<DateiEintrag>> dateienIn(String? ordnerId) {
    final dq = db.select(db.dateien)..where((d) => ordnerId == null ? d.ordnerId.isNull() : d.ordnerId.equals(ordnerId));
    final q = dq.join([leftOuterJoin(db.dateiVersionen, db.dateiVersionen.dateiId.equalsExp(db.dateien.id))]);
    return q.watch().map((rows) {
      final dateien = <String, DateiZeile>{};
      final vers = <DateiVersionZeile>[];
      for (final r in rows) {
        final d = r.readTable(db.dateien);
        dateien[d.id] = d;
        final v = r.readTableOrNull(db.dateiVersionen);
        if (v != null) vers.add(v);
      }
      final l = _zusammen(dateien.values.toList(), vers);
      l.sort((a, b) => namensVergleich(a.name, b.name));
      return l;
    });
  }

  /// Eine Datei mit ihrer neuesten Fassung (null: gibt es nicht oder ist nicht sichtbar).
  Future<DateiEintrag?> eintrag(String dateiId) async {
    final d = await (db.select(db.dateien)..where((t) => t.id.equals(dateiId))).getSingleOrNull();
    if (d == null) return null;
    final v = await (db.select(db.dateiVersionen)..where((t) => t.dateiId.equals(dateiId))).get();
    final l = _zusammen([d], v);
    return l.isEmpty ? null : l.single;
  }

  Future<List<OrdnerZeile>> _ordnerAlle() => db.select(db.ordner).get();

  // ------------------------------------------------------------------ Prüfungen

  String _name(String roh) => bereinigeName(roh) ?? (throw DateiFehler.nameUngueltig);

  String _ich() => ich() ?? (throw DateiFehler.nichtErlaubt);

  Future<OrdnerZeile> _ordner(String id) async => await (db.select(db.ordner)..where((o) => o.id.equals(id))).getSingleOrNull() ?? (throw DateiFehler.nichtGefunden);

  Future<DateiZeile> _datei(String id) async => await (db.select(db.dateien)..where((d) => d.id.equals(id))).getSingleOrNull() ?? (throw DateiFehler.nichtGefunden);

  /// Zielordner prüfen: lebt, ist sichtbar, bei Stufe `family` selbst `family`; liefert ihn (null = oberste Ebene).
  Future<OrdnerZeile?> _ziel(String? ordnerId, String audience) async {
    if (ordnerId == null) return null;
    final z = await _ordner(ordnerId);
    if (!rechte.darfSehen(z.audience)) throw DateiFehler.nichtGefunden;
    if (!rechte.darfZielOrdner(z, audience)) throw DateiFehler.stufeFamilieNurInFamilie;
    return z;
  }

  // ------------------------------------------------------------------ Ordner

  /// Legt einen Ordner an. Kinder legen nur Ordner der Stufe `family` an. Liefert die ID.
  Future<String> ordnerAnlegen({required String name, String? parentId, String audience = kStufeFamilie}) => _seriell(() async {
    final me = _ich();
    final n = _name(name);
    if (!rechte.darfAnlegen(audience)) throw DateiFehler.nichtErlaubt;
    await _ziel(parentId, audience);
    final alle = await _ordnerAlle();
    if (parentId != null) {
      final t = ordnerTiefe(alle, parentId);
      if (t < 0 || t + 1 > kMaxOrdnerTiefe) throw DateiFehler.zuTief;
    }
    final id = _neueId();
    await store.aendern('ordner', id, {'parentId': parentId, 'name': n, 'audience': audience}, nurLokal: {'createdAt': zeitFuerServer(_jetzt()), 'ownerId': me});
    beiAenderung();
    return id;
  });

  Future<void> ordnerUmbenennen(String id, String name) => _seriell(() async {
    final n = _name(name);
    final o = await _ordner(id);
    if (!rechte.darfAendern(o.ownerId)) throw DateiFehler.nichtErlaubt;
    if (o.name == n) return;
    await store.aendern('ordner', id, {'name': n});
    beiAenderung();
  });

  /// Verschiebt einen Ordner in [neuerParent] (null = oberste Ebene). Nie in sich selbst oder einen Unterordner, nie tiefer als 6 Ebenen; ein für alle sichtbarer Ordner nur in einen für alle
  /// sichtbaren Ordner (oder nach oben).
  Future<void> ordnerVerschieben(String id, String? neuerParent) => _seriell(() async {
    final o = await _ordner(id);
    if (!rechte.darfAendern(o.ownerId)) throw DateiFehler.nichtErlaubt;
    if (o.parentId == neuerParent) return;
    final alle = await _ordnerAlle();
    if (neuerParent != null && liegtUnterOderIn(alle, neuerParent, id)) throw DateiFehler.zyklus;
    await _ziel(neuerParent, o.audience);
    final t = ordnerTiefe(alle, neuerParent);
    if (t < 0 || t + 1 + hoeheUnter(alle, id) > kMaxOrdnerTiefe) throw DateiFehler.zuTief;
    await store.aendern('ordner', id, {'parentId': neuerParent});
    beiAenderung();
  });

  /// Ändert die Freigabestufe eines Ordners (nur Eltern und Admins). Auf `parents` stellt der Stapel zuerst alles darunter um (Dateien und Unterordner der Stufe `family`, von unten nach
  /// oben), damit die Invariante bei jedem Schritt gilt; auf `family` nur, wenn der Ordner oben oder in einem `family`-Ordner liegt.
  Future<void> ordnerStufeAendern(String id, String stufe) => _seriell(() async {
    if (stufe != kStufeEltern && stufe != kStufeFamilie) throw DateiFehler.nichtErlaubt;
    if (!rechte.darfStufeAendern) throw DateiFehler.nichtErlaubt;
    final o = await _ordner(id);
    if (o.audience == stufe) return;
    final alle = await _ordnerAlle();
    if (stufe == kStufeFamilie) {
      if (o.parentId != null && alle.where((x) => x.id == o.parentId).any((p) => p.audience != kStufeFamilie)) throw DateiFehler.stufeFamilieNurInFamilie;
      await store.aendern('ordner', id, {'audience': kStufeFamilie});
      beiAenderung();
      return;
    }
    final aenderungen = <SyncAenderung>[];
    for (final unter in [...unterordnerVonUnten(alle, id), o]) {
      for (final d in await (db.select(db.dateien)..where((t) => t.ordnerId.equals(unter.id) & t.audience.equals(kStufeFamilie))).get()) {
        aenderungen.add(SyncAenderung('datei', d.id, {'audience': kStufeEltern}));
      }
      if (unter.audience == kStufeFamilie) aenderungen.add(SyncAenderung('ordner', unter.id, {'audience': kStufeEltern}));
    }
    await store.aendernMehrere(aenderungen);
    beiAenderung();
  });

  /// Löscht einen LEEREN Ordner (der Server löscht Ordner nur leer; sonst [DateiFehler.nichtLeer]).
  Future<void> ordnerLoeschen(String id) => _seriell(() async {
    final o = await _ordner(id);
    if (!rechte.darfLoeschen(o.ownerId)) throw DateiFehler.nichtErlaubt;
    if (await _hatInhalt(id)) throw DateiFehler.nichtLeer;
    await store.loeschen('ordner', id);
    beiAenderung();
  });

  /// Löscht einen Ordner samt allem darunter von unten nach oben (zuerst die Dateien, dann die Unterordner, zuletzt den Ordner; nur Eltern und Admins). Liefert die Zahl der gelöschten Einträge.
  Future<int> ordnerMitInhaltLoeschen(String id) => _seriell(() async {
    if (!rechte.erwachsen) throw DateiFehler.nichtErlaubt;
    final o = await _ordner(id);
    final alle = await _ordnerAlle();
    final liste = <(String, String)>[];
    for (final unter in [...unterordnerVonUnten(alle, id), o]) {
      for (final d in await (db.select(db.dateien)..where((t) => t.ordnerId.equals(unter.id))).get()) {
        liste.add(('datei', d.id));
      }
      liste.add(('ordner', unter.id));
    }
    await store.loeschenMehrere(liste);
    beiAenderung();
    return liste.length;
  });

  Future<bool> _hatInhalt(String ordnerId) async {
    final o = await (db.select(db.ordner)..where((t) => t.parentId.equals(ordnerId))..limit(1)).get();
    if (o.isNotEmpty) return true;
    final d = await (db.select(db.dateien)..where((t) => t.ordnerId.equals(ordnerId))..limit(1)).get();
    return d.isNotEmpty;
  }

  // ------------------------------------------------------------------ Dateien

  Future<void> dateiUmbenennen(String id, String name) => _seriell(() async {
    final n = _name(name);
    final d = await _datei(id);
    if (!rechte.darfAendern(d.ownerId)) throw DateiFehler.nichtErlaubt;
    if (d.name == n) return;
    await store.aendern('datei', id, {'name': n});
    beiAenderung();
  });

  Future<void> dateiVerschieben(String id, String? neuerOrdner) => _seriell(() async {
    final d = await _datei(id);
    if (!rechte.darfAendern(d.ownerId)) throw DateiFehler.nichtErlaubt;
    if (d.ordnerId == neuerOrdner) return;
    await _ziel(neuerOrdner, d.audience);
    await store.aendern('datei', id, {'ordnerId': neuerOrdner});
    beiAenderung();
  });

  /// Ändert die Freigabestufe einer Datei (nur Eltern und Admins); auf `family` nur, wenn sie oben oder in einem `family`-Ordner liegt.
  Future<void> dateiStufeAendern(String id, String stufe) => _seriell(() async {
    if (stufe != kStufeEltern && stufe != kStufeFamilie) throw DateiFehler.nichtErlaubt;
    if (!rechte.darfStufeAendern) throw DateiFehler.nichtErlaubt;
    final d = await _datei(id);
    if (d.audience == stufe) return;
    if (stufe == kStufeFamilie) await _ziel(d.ordnerId, kStufeFamilie);
    await store.aendern('datei', id, {'audience': stufe});
    beiAenderung();
  });

  /// Löscht die Datei mit allen Fassungen (der Server räumt die Blobs nach 7 Tagen Karenz auf).
  Future<void> dateiLoeschen(String id) => _seriell(() async {
    final d = await _datei(id);
    if (!rechte.darfLoeschen(d.ownerId)) throw DateiFehler.nichtErlaubt;
    await store.loeschen('datei', id);
    beiAenderung();
  });

  // ------------------------------------------------------------------ Anlegen nach dem Upload (Claim)

  /// Legt Datei UND erste Fassung in EINEM Stapel an: [blobId] (und [thumbBlobId]) sind die fertigen Uploads; der Server beansprucht sie atomar. Größe, Typ und Prüfsumme setzt der Server;
  /// lokal stehen bis dahin die Werte des Geräts. Liefert die Fassungs-ID.
  Future<String> dateiMitFassungAnlegen({
    required String dateiId,
    required String versionId,
    required String name,
    required String? ordnerId,
    required String audience,
    required String blobId,
    String? thumbBlobId,
    required int groesse,
    String? mime,
    String? sha256,
  }) => _seriell(() async {
    final me = _ich();
    final n = _name(name);
    if (!rechte.darfAnlegen(audience)) throw DateiFehler.nichtErlaubt;
    await _ziel(ordnerId, audience);
    final jetzt = zeitFuerServer(_jetzt());
    await store.aendernMehrere([
      SyncAenderung('datei', dateiId, {'ordnerId': ordnerId, 'name': n, 'audience': audience}, nurLokal: {'createdAt': jetzt, 'ownerId': me}),
      SyncAenderung(
        'datei_version',
        versionId,
        {'dateiId': dateiId, 'nr': 1, 'blobId': blobId, 'thumbBlobId': thumbBlobId},
        nurLokal: {'size': groesse, 'mime': mime, 'sha256': sha256, 'createdAt': jetzt},
      ),
    ]);
    beiAenderung();
    return versionId;
  });

  /// Nächste freie Nummer der Fassungen einer Datei (höchste + 1).
  Future<int> naechsteNummer(String dateiId) async {
    final l = await (db.select(db.dateiVersionen)..where((v) => v.dateiId.equals(dateiId))).get();
    var h = 0;
    for (final v in l) {
      if (v.nr > h) h = v.nr;
    }
    return h + 1;
  }

  /// Legt eine neue Fassung einer vorhandenen Datei an (Upload fertig). Ein Kind nur für eigene Dateien. Liefert die Nummer; belegt ein anderes Gerät dieselbe Nummer, lehnt der Server ab
  /// (`nr_belegt`, siehe [DateiVersionEntitaet]) und der Transfer-Dienst legt sie mit einer neuen Nummer erneut an.
  Future<int> fassungAnlegen({
    required String dateiId,
    required String versionId,
    required String blobId,
    String? thumbBlobId,
    required int groesse,
    String? mime,
    String? sha256,
  }) => _seriell(() async {
    _ich();
    final d = await _datei(dateiId);
    if (!rechte.darfFassungHochladen(d.ownerId)) throw DateiFehler.nichtErlaubt;
    final nr = await naechsteNummer(dateiId);
    if (nr > kMaxFassungenJeDatei) throw DateiFehler.zuVieleFassungen;
    await store.aendern(
      'datei_version',
      versionId,
      {'dateiId': dateiId, 'nr': nr, 'blobId': blobId, 'thumbBlobId': thumbBlobId},
      nurLokal: {'size': groesse, 'mime': mime, 'sha256': sha256, 'createdAt': zeitFuerServer(_jetzt())},
    );
    beiAenderung();
    return nr;
  });

  /// Entfernt eine Datei ohne jede Fassung (ein abgelehnter Upload hat sie hinterlassen). Eine Datei mit Fassung bleibt unberührt.
  Future<bool> verwaisteDateiEntfernen(String dateiId) => _seriell(() async {
    final d = await (db.select(db.dateien)..where((t) => t.id.equals(dateiId))).getSingleOrNull();
    if (d == null) return false;
    final v = await (db.select(db.dateiVersionen)..where((t) => t.dateiId.equals(dateiId))..limit(1)).get();
    if (v.isNotEmpty) return false;
    await store.loeschen('datei', dateiId);
    beiAenderung();
    return true;
  });
}

final dateiRepositoryProvider = Provider<DateiRepository>((ref) {
  return DateiRepository(
    db: ref.watch(appDatabaseProvider),
    store: ref.watch(syncStoreProvider),
    ich: () => ref.read(authProvider).user?.id,
    rolle: () => ref.read(authProvider).user?.role,
    beiAenderung: () => ref.read(syncProvider.notifier).lokaleAenderung(),
  );
});
