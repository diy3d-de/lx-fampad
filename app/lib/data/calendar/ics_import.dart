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

  /// Der vorhandene Termin (für die Vorschau: was würde überschrieben, und wem gehört er).
  final Termin? vorhanden;
  const IcsPlanEintrag(this.termin, this.status, {this.grund, this.vorhandenId, this.vorhanden});
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

bool _leereAusnahme(TerminAusnahme z) => !z.abgesagt && z.titel == null && z.start == null && z.ende == null && z.ort == null;

bool _ausnahmeGleich(TerminAusnahme z, IcsAusnahme a) => z.abgesagt == a.abgesagt && z.titel == a.titel && z.start == a.start && z.ende == a.ende && z.ort == a.ort;

/// Plan für den Import: Duplikate über die UID, Obergrenzen (5000 Termine je Familie, 500 je Kind), Rechte zum Aktualisieren.
IcsPlan icsPlanen(
  IcsErgebnis datei, {
  required List<Termin> bestehende,
  required Map<String, List<TerminAusnahme>> ausnahmen,
  required TerminRechte rechte,
}) {
  final nachUid = <String, Termin>{};
  final mehrfach = <String>{};
  for (final t in bestehende) {
    final u = t.icalUid;
    if (u == null) continue;
    if (nachUid.containsKey(u)) mehrfach.add(u);
    nachUid.putIfAbsent(u, () => t);
  }
  final hinweise = [...datei.hinweise];
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
      final dateiSchluessel = {for (final a in t.ausnahmen) a.schluessel};
      var ausnahmenGleich = t.ausnahmen.every((a) => zeilen[a.schluessel] != null && _ausnahmeGleich(zeilen[a.schluessel]!, a));
      // Ausnahmen, die es nur in der App gibt, würden beim Aktualisieren zurückgesetzt: das ist eine Änderung
      if (zeilen.values.any((z) => !dateiSchluessel.contains(z.originalStart) && !_leereAusnahme(z))) ausnahmenGleich = false;
      if (mehrfach.contains(t.uid)) hinweise.add(IcsHinweis(t.titel, 'Diese UID gibt es in der App mehrfach, es wird der erste Termin verglichen'));
      if (d.isEmpty && ausnahmenGleich) {
        eintraege.add(IcsPlanEintrag(t, IcsStatus.vorhanden, vorhandenId: alt.id, vorhanden: alt));
      } else if (!rechte.darfAendern(alt)) {
        eintraege.add(IcsPlanEintrag(t, IcsStatus.vorhanden, grund: 'Schon vorhanden, aber von jemand anderem angelegt (nicht änderbar)', vorhandenId: alt.id, vorhanden: alt));
      } else {
        eintraege.add(IcsPlanEintrag(t, IcsStatus.geaendert, vorhandenId: alt.id, vorhanden: alt));
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
  return IcsPlan(eintraege: eintraege, hinweise: hinweise, abgeschnitten: datei.abgeschnitten);
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

/// Termine je Etappe (eine Transaktion, danach Luft für die Oberfläche).
const _kEtappe = 25;

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
    required TerminRechte rechte,
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
    var erledigt = 0;
    for (var von = 0; von < arbeit.length; von += _kEtappe) {
      if (abbruch?.angefordert ?? false) {
        abgebrochen = true;
        break;
      }
      final teil = arbeit.sublist(von, von + _kEtappe > arbeit.length ? arbeit.length : von + _kEtappe);
      // vorbereiten: je Termin die Liste seiner Änderungen (Termin, Teilnehmer, Ausnahmen)
      final vorbereitet = <(IcsPlanEintrag, List<SyncAenderung>)>[];
      for (final e in teil) {
        try {
          if (e.status == IcsStatus.neu) {
            vorbereitet.add((e, _anlegenOps(e.termin, sicht, teilnehmer)));
          } else {
            // die Rechte werden hier noch einmal gegen den aktuellen Stand geprüft (zwischen Vorschau und Import kann sich etwas ändern)
            final alt = await (db.select(db.termine)..where((x) => x.id.equals(e.vorhandenId!))).getSingleOrNull();
            if (alt == null || !rechte.darfAendern(alt)) {
              probleme.add(IcsHinweis(e.termin.titel, 'Nicht aktualisiert: keine Berechtigung oder inzwischen gelöscht', uebersprungen: true));
            } else {
              vorbereitet.add((e, await _aktualisierenOps(alt, e.termin)));
            }
          }
        } catch (err) {
          probleme.add(IcsHinweis(e.termin.titel, 'Konnte nicht gespeichert werden (${err.runtimeType})', uebersprungen: true));
        }
      }
      // schreiben: die ganze Etappe in EINER Transaktion (schnell). Scheitert sie, jeder Termin einzeln in einer eigenen Transaktion,
      // damit ein kaputter Termin nur sich selbst auslässt. Nie verschachtelt (Web: drift/WASM kann das nicht zurückrollen).
      try {
        await store.aendernMehrere([for (final v in vorbereitet) ...v.$2]);
        for (final v in vorbereitet) {
          v.$1.status == IcsStatus.neu ? neu++ : akt++;
        }
      } catch (_) {
        for (final v in vorbereitet) {
          try {
            await store.aendernMehrere(v.$2);
            v.$1.status == IcsStatus.neu ? neu++ : akt++;
          } catch (err) {
            probleme.add(IcsHinweis(v.$1.termin.titel, 'Konnte nicht gespeichert werden (${err.runtimeType})', uebersprungen: true));
          }
        }
      }
      erledigt += teil.length;
      fortschritt?.call(erledigt, arbeit.length);
      await Future<void>.delayed(Duration.zero);
    }
    fortschritt?.call(arbeit.length, arbeit.length);
    if (neu > 0 || akt > 0) beiAenderung();
    final vorhanden = plan.eintraege.where((e) => e.status == IcsStatus.vorhanden || (e.status == IcsStatus.geaendert && !aktualisieren)).length;
    return IcsBericht(neu: neu, aktualisiert: akt, vorhanden: vorhanden, uebersprungen: probleme, abgebrochen: abgebrochen);
  }

  List<SyncAenderung> _anlegenOps(IcsTermin t, TerminSicht sicht, Set<String> teilnehmer) {
    final id = _neueId();
    return [
      SyncAenderung('termin', id, {..._felder(t), 'audience': sicht.wire}, nurLokal: {'createdAt': zeitFuerServer(_jetzt()), 'ownerId': ich()}),
      for (final u in teilnehmer) SyncAenderung('termin_teilnehmer', _neueId(), {'terminId': id, 'userId': u}),
      for (final a in t.ausnahmen) SyncAenderung('termin_ausnahmen', ausnahmeId(id, a.schluessel), {'terminId': id, 'originalStart': a.schluessel, ..._ausnahmeFelder(a)}),
    ];
  }

  Future<List<SyncAenderung>> _aktualisierenOps(Termin alt, IcsTermin t) async {
    final id = alt.id;
    final d = _unterschiede(alt, t);
    final zeilen = await (db.select(db.terminAusnahmen)..where((a) => a.terminId.equals(id))).get();
    final nachSchluessel = {for (final z in zeilen) z.originalStart: z};
    final inDatei = {for (final a in t.ausnahmen) a.schluessel};
    return [
      if (d.isNotEmpty) SyncAenderung('termin', id, d),
      for (final a in t.ausnahmen)
        if (nachSchluessel[a.schluessel] == null)
          SyncAenderung('termin_ausnahmen', ausnahmeId(id, a.schluessel), {'terminId': id, 'originalStart': a.schluessel, ..._ausnahmeFelder(a)})
        else if (!_ausnahmeGleich(nachSchluessel[a.schluessel]!, a))
          SyncAenderung('termin_ausnahmen', nachSchluessel[a.schluessel]!.id, _ausnahmeFelder(a)),
      // Ausnahmen, die es in der Datei nicht (mehr) gibt, werden zurückgesetzt (die Zeile bleibt, ihre feste ID kann nie neu vergeben werden)
      for (final z in zeilen)
        if (!inDatei.contains(z.originalStart) && !_leereAusnahme(z))
          SyncAenderung('termin_ausnahmen', z.id, {'abgesagt': false, 'titel': null, 'start': null, 'ende': null, 'ort': null}),
    ];
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
