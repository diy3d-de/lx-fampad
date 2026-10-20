// Schnittstelle für die spätere Kartenansicht: Die Standort-Seite zeigt über der Liste eine Karte, sobald hier ein Builder eingetragen ist.
// Die Karte (maplibre mit selbst gehosteten PMTiles, siehe docs/KARTE-SPIKE.md) kommt erst nach der Sicherheitsprüfung; bis dahin bleibt der Builder
// leer und es gibt nur die Liste. Der Builder bekommt nur, was die Anzeige braucht (Personen mit Position, Farbe und Name über [mitglieder]) und darf
// nichts davon speichern oder weitergeben.
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/api/models.dart';
import '../../data/standort/standort_modelle.dart';
import 'standort_karte_ansicht.dart';

/// Baut die Karte für die Personen, die gerade mit mir teilen (nur solche mit [GeteiltePosition.hatPosition]).
typedef StandortKartenBuilder = Widget Function(BuildContext context, List<GeteiltePosition> positionen, Map<String, UserDto> mitglieder);

/// Die Karte der Standort-Seite (Voreinstellung: [standortKartenStandard]; null = keine Karte, nur die Liste).
final standortKartenBuilderProvider = Provider<StandortKartenBuilder?>((ref) => standortKartenStandard);

/// Die echte Karte (MapLibre, Kacheln vom eigenen Server); Tests setzen den Provider auf null oder auf einen eigenen Builder.
Widget standortKartenStandard(BuildContext context, List<GeteiltePosition> positionen, Map<String, UserDto> mitglieder) => StandortKarte(positionen: positionen, mitglieder: mitglieder);
