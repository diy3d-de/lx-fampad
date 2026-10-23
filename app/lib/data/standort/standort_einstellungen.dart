// Lokale Einstellungen der Standort-Seite (nur dieses Gerät, `sync_meta`, nichts davon geht an den Server):
//  - Stumm je Person: keine Hinweise "X teilt seinen Standort" (Benachrichtigung, Hinweis in der App). Der Eintrag bleibt in Liste und Karte sichtbar.
//  - Distanzfilter: Liste und Karte nach Entfernung zu mir. Gerechnet wird lokal (Haversine) aus meinem eigenen Standort, den das Gerät nur liefert, solange ich
//    selbst teile; nie wird dafür heimlich der Standort abgefragt oder gesendet.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database_provider.dart';
import 'standort_dienst.dart' show abstandMeter;
import 'standort_modelle.dart';
import 'standort_port.dart' show GeraetePosition;

const kStandortDistanzSchluessel = 'standort_distanz';

/// Auswahl "Entfernung zu mir". [meter] null = kein Filter.
enum DistanzFilter {
  alle('Alle', null),
  km1('unter 1 km', 1000),
  km5('unter 5 km', 5000),
  km25('unter 25 km', 25000);

  final String label;
  final double? meter;
  const DistanzFilter(this.label, this.meter);

  bool get aktiv => meter != null;
}

DistanzFilter distanzAusWert(String? wert) {
  for (final f in DistanzFilter.values) {
    if (f.name == wert) return f;
  }
  return DistanzFilter.alle;
}

/// Ergebnis des Filterns: sichtbare Einträge und wie viele ausgeblendet wurden (zu weit weg oder ohne Position).
class DistanzErgebnis {
  final List<GeteiltePosition> sichtbar;
  final int ausgeblendet;
  const DistanzErgebnis(this.sichtbar, this.ausgeblendet);
}

/// Filtert nach Entfernung zu [ich] (Luftlinie). Ohne Filter oder ohne eigenen Standort bleibt alles stehen (der Filter wirkt dann nicht: die Oberfläche
/// deaktiviert die Auswahl und sagt warum). Einträge ohne Position haben keine Entfernung und werden bei aktivem Filter ausgeblendet; genau die Grenze zählt dazu.
DistanzErgebnis filterNachDistanz(Iterable<GeteiltePosition> liste, GeraetePosition? ich, DistanzFilter filter) {
  final alle = liste.toList();
  final grenze = filter.meter;
  if (grenze == null || ich == null) return DistanzErgebnis(alle, 0);
  final sichtbar = [
    for (final p in alle)
      if (p.hatPosition && abstandMeter(ich.breite, ich.laenge, p.breite!, p.laenge!) <= grenze) p,
  ];
  return DistanzErgebnis(sichtbar, alle.length - sichtbar.length);
}

/// Entfernung in Metern für die Anzeige ("350 m", "4,2 km").
String entfernungText(double meter) {
  if (meter < 1000) return '${meter.round()} m';
  return '${(meter / 1000).toStringAsFixed(1).replaceAll('.', ',')} km';
}

class StandortEinstellungen {
  final Set<String> stumm;
  final DistanzFilter distanz;

  /// Schon aus der Datenbank gelesen (davor nichts anzeigen, was gleich anders aussähe).
  final bool geladen;
  const StandortEinstellungen({this.stumm = const {}, this.distanz = DistanzFilter.alle, this.geladen = false});

  bool istStumm(String userId) => stumm.contains(userId);
}

class StandortEinstellungenNotifier extends Notifier<StandortEinstellungen> {
  @override
  StandortEinstellungen build() {
    final db = ref.watch(appDatabaseProvider);
    Future(() async {
      try {
        final s = stummAusWert(await db.metaLesen(kStandortStummSchluessel));
        final d = distanzAusWert(await db.metaLesen(kStandortDistanzSchluessel));
        if (ref.mounted) {
          state = StandortEinstellungen(stumm: s, distanz: d, geladen: true);
        }
      } catch (_) {
        if (ref.mounted) state = const StandortEinstellungen(geladen: true);
      }
    });
    return const StandortEinstellungen();
  }

  Future<void> stummSetzen(String userId, bool stumm) async {
    final neu = {...state.stumm};
    stumm ? neu.add(userId) : neu.remove(userId);
    state = StandortEinstellungen(stumm: neu, distanz: state.distanz, geladen: true);
    try {
      await ref.read(appDatabaseProvider).metaSchreiben(kStandortStummSchluessel, stummZuWert(neu));
    } catch (_) {
      // nicht speicherbar: gilt bis zum Neustart der App
    }
  }

  Future<void> distanzSetzen(DistanzFilter f) async {
    state = StandortEinstellungen(stumm: state.stumm, distanz: f, geladen: true);
    try {
      await ref.read(appDatabaseProvider).metaSchreiben(kStandortDistanzSchluessel, f.name);
    } catch (_) {}
  }
}

final standortEinstellungenProvider = NotifierProvider<StandortEinstellungenNotifier, StandortEinstellungen>(StandortEinstellungenNotifier.new);
