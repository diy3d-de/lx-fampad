// Fake-Verteiler (ntfy-App) für die Push-Tests: zeichnet Aufrufe auf und liefert Endpunkt, Wecker und Fehler auf Zuruf.
import 'package:lx_fampad/data/push/push_plattform.dart';

const fixEndpunkt = 'https://ntfy.familie.lx-labs.dev/upAbCdEfGhIjKl?up=1';

class FakePush implements PushPlattform {
  @override
  bool unterstuetzt = true;

  /// Installierte Verteiler und der gespeicherte.
  List<String> installiert = ['io.heckel.ntfy'];
  String? gespeichert;

  /// Der Verteiler nimmt den vom System vorgeschlagenen Standard (nur wenn genau einer installiert ist, wie im echten Plugin).
  bool standardMoeglich = true;

  PushRueckrufe? rueckrufe;
  int initialisiert = 0;
  int registriert = 0;
  int abgemeldet = 0;

  /// Nach registrieren() sofort den Endpunkt melden.
  bool endpunktMelden = true;
  String endpunkt = fixEndpunkt;
  Object? registrierenFehler;

  @override
  Future<void> initialisieren(PushRueckrufe r) async {
    initialisiert++;
    rueckrufe = r;
  }

  @override
  Future<String?> aktuellerVerteiler() async => gespeichert;

  @override
  Future<bool> standardVerteilerNutzen() async {
    if (gespeichert != null) return true;
    if (standardMoeglich && installiert.length == 1) {
      gespeichert = installiert.first;
      return true;
    }
    return false;
  }

  @override
  Future<List<String>> verteiler() async => installiert;

  @override
  Future<void> verteilerSpeichern(String name) async => gespeichert = name;

  @override
  Future<void> registrieren() async {
    if (registrierenFehler != null) throw registrierenFehler!;
    registriert++;
    if (endpunktMelden) {
      // wie das echte Plugin: der Endpunkt kommt asynchron über den Rückruf
      Future<void>.microtask(() => rueckrufe?.beiEndpunkt(endpunkt));
    }
  }

  @override
  Future<void> abmelden() async => abgemeldet++;

  /// Ein Wecker trifft ein.
  void wecker() => rueckrufe!.beiWecker();
}
