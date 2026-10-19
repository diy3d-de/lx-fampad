// Schnittstelle zur Push-Plattform (UnifiedPush mit der ntfy-App als Verteiler, nur Android). Die Oberfläche und der Zustand
// sprechen nur mit dieser Schnittstelle; Tests setzen einen Fake ein, das Web eine leere Umsetzung (push_plattform_stub.dart).
//
// Datenschutz: Der Inhalt einer Nachricht wird nie gelesen oder ausgewertet. Ein Wecker bedeutet nur "es gibt Neues, gleiche ab".

/// Rückrufe der Plattform (kommen vom Verteiler, auch im Hintergrund).
class PushRueckrufe {
  /// Neuer oder bestätigter Endpunkt (URL), den der Server von uns bekommen muss.
  final void Function(String endpunkt) beiEndpunkt;

  /// Anmeldung beim Verteiler nicht möglich (Grund nur zur Anzeige; kein Netz, Verteiler nicht erreichbar ...).
  final void Function(String grund) beiFehler;

  /// Der Verteiler hat die Anmeldung beendet (z. B. ntfy-App deinstalliert oder Abo gelöscht).
  final void Function() beiAbgemeldet;

  /// Ein Wecker ist eingetroffen (Inhalt wird verworfen).
  final void Function() beiWecker;
  const PushRueckrufe({required this.beiEndpunkt, required this.beiFehler, required this.beiAbgemeldet, required this.beiWecker});
}

abstract class PushPlattform {
  /// Gibt es Push auf dieser Plattform (Android)? Web und Desktop: nein.
  bool get unterstuetzt;

  /// Hängt die Rückrufe ein; auf jedem App-Start (auch im Hintergrund-Start durch einen Wecker) nötig.
  Future<void> initialisieren(PushRueckrufe rueckrufe);

  /// Der gespeicherte Verteiler (Paketname) oder null.
  Future<String?> aktuellerVerteiler();

  /// Nimmt den gespeicherten oder den vom System vorgeschlagenen Verteiler; false, wenn eine Auswahl nötig oder keiner da ist.
  Future<bool> standardVerteilerNutzen();

  /// Alle installierten Verteiler (Paketnamen).
  Future<List<String>> verteiler();

  Future<void> verteilerSpeichern(String name);

  /// Meldet die App beim Verteiler an; der Endpunkt kommt danach über [PushRueckrufe.beiEndpunkt].
  Future<void> registrieren();

  /// Meldet die App beim Verteiler ab.
  Future<void> abmelden();
}

/// Anzeigename eines Verteilers (die ntfy-App hat den Paketnamen io.heckel.ntfy).
String verteilerName(String paket) => switch (paket) {
  'io.heckel.ntfy' => 'ntfy',
  _ => paket,
};
