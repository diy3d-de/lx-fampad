// ICS-Import: aus dem gelesenen Ergebnis (ics_parser.dart) einen Plan machen (neu / schon vorhanden / geändert / übersprungen, Duplikate
// über die UID der Datei = `icalUid` des Termins) und ihn in die lokale Datenbank schreiben. Geschrieben wird wie überall offline-first über
// den SyncStore (Tabelle und Ausgang in einer Transaktion); der Abgleich mit dem Server läuft danach im Hintergrund.
//
// Ein erneuter Import legt nie doppelte Termine an: Termine mit bekannter UID werden übersprungen oder (auf Wunsch) aktualisiert.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/models.dart';
import '../app_database.dart';
import '../database_provider.dart';
import '../auth/auth_state.dart';
import '../sync/sync_entities.dart';
import '../sync/sync_store.dart';
import '../sync_state.dart';
import 'ics_parser.dart';
import 'termin_repository.dart';

enum IcsStatus { neu, vorhanden, geaendert, uebersprungen }

class IcsPlanEintrag {
  final IcsTermin termin;
  final IcsStatus status;

  /// Grund bei [IcsStatus.uebersprungen] und bei einem nicht änderbaren vorhandenen Termin.
  final String? grund;

  /// ID des vorhandenen Termins ([IcsStatus.vorhanden], [IcsStatus.geaendert]).
  final String? vorhandenId;
  const IcsPlanEintrag(this.termin, this.status, {this.grund, this.vorhandenId});
}

class IcsPlan {
  final List<IcsPlanEintrag> eintraege;
  final List<IcsHinweis> hinweise;
  final bool abgeschnitten;
  const IcsPlan({required this.eintraege, required this.hinweise, required this.abgeschnitten});

  int anzahl(IcsStatus s) => eintraege.where((e) => e.status == s).length;
  int get neu => anzahl(IcsStatus.neu);
  int get vorhanden => anzahl(IcsStatus.vorhanden);
  int get geaendert => anzahl(IcsStatus.geaendert);
  int get uebersprungen => anzahl(IcsStatus.uebersprungen) + hinweise.where((h) => h.uebersprungen).length;
}

const kMaxTermineFamilie = 5000;
const kMaxTermineKind = 500;

/// Alle Felder des Termins in der Form des Sync (wie `TerminRepository._felder`, aber mit Zeitzone und UID der Datei).
Map<String, dynamic> _felder(IcsTermin t) => {
  'titel': t.titel,
  'ort': t.ort,
  'beschreibung': t.beschreibung,
  'ganztaegig': t.ganztaegig,
  'startDate': t.ganztaegig ? t.startDate : null,
  'endDate': t.ganztaegig ? t.endDate : null,
  'startUtc': t.ganztaegig ? null : zeitFuerServer(t.startUtc!),
  'endUtc': t.ganztaegig ? null : zeitFuerServer(t.endUtc!),
  'tzid': t.ganztaegig ? null : t.tzid,
  'rrule': t.rrule,
  'erinnerungMin': t.erinnerungMin,
  'icalUid': t.uid,
};

Map<String, dynamic> _bisher(Termin t) => {
  'titel': t.titel,
  'ort': t.ort,
  'beschreibung': t.beschreibung,
  'ganztaegig': t.ganztaegig,
  'startDate': t.startDate,
  'endDate': t.endDate,
  'startUtc': t.startUtc == null ? null : zeitFuerServer(t.startUtc!),
  'endUtc': t.endUtc == null ? null : zeitFuerServer(t.endUtc!),
  'tzid': t.tzid,
  'rrule': t.rrule,
  'erinnerungMin': t.erinnerungMin,
  'icalUid': t.icalUid,
};

const _kZeitFelder = ['ganztaegig', 'startUtc', 'endUtc', 'tzid', 'startDate', 'endDate'];

/// Felder, die sich gegenüber dem vorhandenen Termin ändern (leer = gleich). Gehört die Zeit dazu, gehen alle Zeitfelder gemeinsam
/// (der Server prüft die Stimmigkeit nach dem Zusammenführen).
Map<String, dynamic> _unterschiede(Termin alt, IcsTermin neu) {
  final a = _bisher(alt), n = _felder(neu);
  final d = {for (final k in n.keys) if (n[k] != a[k]) k: n[k]};
  if (d.keys.any(_kZeitFelder.contains)) {
    for (final k in _kZeitFelder) {
      d[k] = n[k];
    }
  }
  return d;
}

Map<String, dynamic> _ausnahmeFelder(IcsAusnahme a) => {'abgesagt': a.abgesagt, 'titel': a.titel, 'start': a.start, 'ende': a.ende, 'ort': a.ort};

bool _ausnahmeGleich(TerminAusnahme z, IcsAusnahme a) => z.abgesagt == a.abgesagt && z.titel == a.titel && z.start == a.start && z.ende == a.ende && z.ort == a.ort;

/// Plan für den Import: Duplikate über die UID, Obergrenzen (5000 Termine je Familie, 500 je Kind), Rechte zum Aktualisieren.
IcsPlan icsPlanen(
  IcsErgebnis datei, {
  required List<Termin> bestehende,
  required Map<String, List<TerminAusnahme>> ausnahmen,
  required TerminRechte rechte,
}) {
  final nachUid = <String, Termin>{};
  for (final t in bestehende) {
    final u = t.icalUid;
    if (u != null) nachUid.putIfAbsent(u, () => t);
  }
  final eigene = bestehende.where((t) => t.ownerId != null && t.ownerId == rechte.userId).length;
  var platzFamilie = kMaxTermineFamilie - bestehende.length;
  var platzKind = kMaxTermineKind - eigene;
  final kind = rechte.rolle == Role.child;
  final eintraege = <IcsPlanEintrag>[];
  for (final t in datei.termine) {
    final alt = nachUid[t.uid];
    if (alt != null) {
      final d = _unterschiede(alt, t);
      final zeilen = {for (final z in ausnahmen[alt.id] ?? const <TerminAusnahme>[]) z.originalStart: z};
      final ausnahmenGleich = t.ausnahmen.every((a) => zeilen[a.schluessel] != null && _ausnahmeGleich(zeilen[a.schluessel]!, a));
      if (d.isEmpty && ausnahmenGleich) {
        eintraege.add(IcsPlanEintrag(t, IcsStatus.vorhanden, vorhandenId: alt.id));
      } else if (!rechte.darfAendern(alt)) {
        eintraege.add(IcsPlanEintrag(t, IcsStatus.vorhanden, grund: 'Schon vorhanden, aber von jemand anderem angelegt (nicht änderbar)', vorhandenId: alt.id));
      } else {
        eintraege.add(IcsPlanEintrag(t, IcsStatus.geaendert, vorhandenId: alt.id));
      }
      continue;
    }
    if (platzFamilie <= 0) {
      eintraege.add(IcsPlanEintrag(t, IcsStatus.uebersprungen, grund: 'Grenze von $kMaxTermineFamilie Terminen je Familie erreicht'));
    } else if (kind && platzKind <= 0) {
      eintraege.add(IcsPlanEintrag(t, IcsStatus.uebersprungen, grund: 'Grenze von $kMaxTermineKind eigenen Terminen erreicht'));
    } else {
      platzFamilie--;
      platzKind--;
      eintraege.add(IcsPlanEintrag(t, IcsStatus.neu));
    }
  }
  return IcsPlan(eintraege: eintraege, hinweise: datei.hinweise, abgeschnitten: datei.abgeschnitten);
}

class IcsBericht {
  final int neu;
  final int aktualisiert;
  final int vorhanden;

  /// Übersprungen oder fehlgeschlagen, mit Grund (Titel + Text).
  final List<IcsHinweis> uebersprungen;
  final bool abgebrochen;
  const IcsBericht({required this.neu, required this.aktualisiert, required this.vorhanden, required this.uebersprungen, this.abgebrochen = false});
}

/// Hilfsmittel für den Abbruch eines laufenden Imports.
class IcsAbbruch {
  bool angefordert = false;
}

class IcsImporter {
  final AppDatabase db;
  final SyncStore store;
  final String? Function() ich;
  final void Function() beiAenderung;
  final DateTime Function() _jetzt;
  final String Function() _neueId;

  IcsImporter({required this.db, required this.store, required this.ich, required this.beiAenderung, DateTime Function()? jetzt, String Function()? neueId})
    : _jetzt = jetzt ?? DateTime.now,
      _neueId = neueId ?? neueUuid;

  /// Schreibt den Plan in die lokale Datenbank (in Päckchen, damit die Oberfläche bedienbar bleibt). [fortschritt] bekommt (erledigt, gesamt).
  /// Jeder Termin wird für sich in einer Transaktion geschrieben: ein Fehler lässt nur diesen Termin aus.
  Future<IcsBericht> importieren(
    IcsPlan plan, {
    required TerminSicht sicht,
    Set<String> teilnehmer = const {},
    bool aktualisieren = false,
    void Function(int erledigt, int gesamt)? fortschritt,
    IcsAbbruch? abbruch,
  }) async {
    final arbeit = [
      for (final e in plan.eintraege)
        if (e.status == IcsStatus.neu || (e.status == IcsStatus.geaendert && aktualisieren)) e,
    ];
    var neu = 0, akt = 0;
    final probleme = <IcsHinweis>[
      for (final h in plan.hinweise)
        if (h.uebersprungen) h,
      for (final e in plan.eintraege)
        if (e.status == IcsStatus.uebersprungen) IcsHinweis(e.termin.titel, e.grund ?? 'Übersprungen', uebersprungen: true),
    ];
    var abgebrochen = false;
    for (var i = 0; i < arbeit.length; i++) {
      if (abbruch?.angefordert ?? false) {
        abgebrochen = true;
        break;
      }
      final e = arbeit[i];
      try {
        if (e.status == IcsStatus.neu) {
          await db.transaction(() => _anlegen(e.termin, sicht, teilnehmer));
          neu++;
        } else {
          await db.transaction(() => _aktualisieren(e.vorhandenId!, e.termin));
          akt++;
        }
      } catch (_) {
        probleme.add(IcsHinweis(e.termin.titel, 'Konnte nicht gespeichert werden', uebersprungen: true));
      }
      if ((i + 1) % 20 == 0) {
        fortschritt?.call(i + 1, arbeit.length);
        await Future<void>.delayed(Duration.zero);
      }
    }
    fortschritt?.call(arbeit.length, arbeit.length);
    if (neu > 0 || akt > 0) beiAenderung();
    final vorhanden = plan.eintraege.where((e) => e.status == IcsStatus.vorhanden || (e.status == IcsStatus.geaendert && !aktualisieren)).length;
    return IcsBericht(neu: neu, aktualisiert: akt, vorhanden: vorhanden, uebersprungen: probleme, abgebrochen: abgebrochen);
  }

  Future<void> _anlegen(IcsTermin t, TerminSicht sicht, Set<String> teilnehmer) async {
    final id = _neueId();
    await store.aendern('termin', id, {..._felder(t), 'audience': sicht.wire}, nurLokal: {'createdAt': zeitFuerServer(_jetzt()), 'ownerId': ich()});
    for (final u in teilnehmer) {
      await store.aendern('termin_teilnehmer', _neueId(), {'terminId': id, 'userId': u});
    }
    for (final a in t.ausnahmen) {
      await store.aendern('termin_ausnahmen', ausnahmeId(id, a.schluessel), {'terminId': id, 'originalStart': a.schluessel, ..._ausnahmeFelder(a)});
    }
  }

  Future<void> _aktualisieren(String id, IcsTermin t) async {
    final alt = await (db.select(db.termine)..where((x) => x.id.equals(id))).getSingleOrNull();
    if (alt == null) return;
    final d = _unterschiede(alt, t);
    if (d.isNotEmpty) await store.aendern('termin', id, d);
    final zeilen = await (db.select(db.terminAusnahmen)..where((a) => a.terminId.equals(id))).get();
    final nachSchluessel = {for (final z in zeilen) z.originalStart: z};
    for (final a in t.ausnahmen) {
      final z = nachSchluessel[a.schluessel];
      if (z == null) {
        await store.aendern('termin_ausnahmen', ausnahmeId(id, a.schluessel), {'terminId': id, 'originalStart': a.schluessel, ..._ausnahmeFelder(a)});
      } else if (!_ausnahmeGleich(z, a)) {
        await store.aendern('termin_ausnahmen', z.id, _ausnahmeFelder(a));
      }
    }
  }
}

final icsImporterProvider = Provider<IcsImporter>((ref) {
  return IcsImporter(
    db: ref.watch(appDatabaseProvider),
    store: ref.watch(syncStoreProvider),
    ich: () => ref.read(authProvider).user?.id,
    beiAenderung: () => ref.read(syncProvider.notifier).lokaleAenderung(),
  );
});
