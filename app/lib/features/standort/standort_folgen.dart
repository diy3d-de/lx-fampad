// "Folgen" auf der Standortkarte: die Karte wandert mit einer teilenden Person mit, sodass ihre Nadel in der Mitte bleibt. Hier nur die Entscheidung als reine Funktion;
// die Kamerabewegung steht in standort_karte_ansicht.dart.

/// Wem gefolgt würde: der gewählten Person (wenn sie auf der Karte ist), sonst der einzigen Person auf der Karte; bei mehreren ohne Auswahl niemandem.
String? folgeZiel({required String? gewaehlt, required Iterable<String> ids}) {
  final liste = ids.toList();
  if (gewaehlt != null && liste.contains(gewaehlt)) return gewaehlt;
  if (liste.length == 1) return liste.first;
  return null;
}
