// Ein "Rückgängig" lässt sich nicht mehr ausführen (Person gewechselt, Liste oder zuständige Person gibt es nicht mehr): die Repositories werfen das,
// der Hinweis (`widgets/rueckgaengig.dart`) sagt den Grund in einem kurzen Satz, statt etwas Verwaistes anzulegen.

class RueckgaengigAbgelehnt implements Exception {
  /// Kurzer deutscher Satz für die Anzeige.
  final String meldung;
  const RueckgaengigAbgelehnt(this.meldung);
  @override
  String toString() => meldung;
}
