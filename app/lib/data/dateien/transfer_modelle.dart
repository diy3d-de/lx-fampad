// Übertragungen der Dateiablage (Abschnitt 6n): Zustände, Arten und die Schnittstelle zum Hintergrund (Android-Vordergrunddienst). Die Warteschlange selbst steht in `transfer_dienst.dart`,
// die Zeilen in der lokalen Tabelle `transfers` (nie synchronisiert, nie Dateiinhalte).
import '../app_database.dart';

/// Zustand einer Übertragung. `wartet` heißt: in der Schlange oder (mit `naechsterVersuch`) wartet auf den nächsten Versuch; `abschliessen`: alle Bytes sind oben, der Datensatz wird angelegt;
/// `fertig`: der Datensatz liegt im Ausgang bzw. die Datei im Cache; `datei_noetig`: die Quelle fehlt (Web nach dem Neuladen), die Person wählt die Datei erneut.
enum TransferZustand {
  wartet('wartet'),
  laeuft('laeuft'),
  abschliessen('abschliessen'),
  fertig('fertig'),
  fehler('fehler'),
  abgebrochen('abgebrochen'),
  dateiNoetig('datei_noetig');

  final String wire;
  const TransferZustand(this.wire);

  static TransferZustand von(String wire) => TransferZustand.values.firstWhere((z) => z.wire == wire, orElse: () => TransferZustand.fehler);

  /// Noch nicht am Ende (läuft oder kommt noch dran).
  bool get aktiv => this == wartet || this == laeuft || this == abschliessen;
}

/// Art einer Übertragung: neue Datei, neue Fassung einer Datei, verschlüsselter Tresor-Anhang (alle Upload) oder Download.
enum TransferArt {
  datei('datei'),
  fassung('fassung'),
  anhang('anhang'),
  runter('runter');

  final String wire;
  const TransferArt(this.wire);

  static TransferArt von(String wire) => TransferArt.values.firstWhere((a) => a.wire == wire, orElse: () => TransferArt.datei);
  bool get hoch => this != runter;
}

extension TransferAnsicht on TransferZeile {
  TransferZustand get zustandTyp => TransferZustand.von(zustand);
  TransferArt get artTyp => TransferArt.von(art);

  /// Fortschritt 0 bis 1 (1 bei leerer Größe).
  double get fortschritt => groesse <= 0 ? 1 : (uebertragen / groesse).clamp(0.0, 1.0);

  bool get aktiv => zustandTyp.aktiv;
}

/// Feste, verständliche Texte zu den Fehlercodes einer Übertragung (nie ein Text des Servers, nie ein Dateiname).
String transferFehlerText(String? code) => switch (code) {
  null => '',
  'quota_exceeded' => 'Der Speicher der Familie ist voll.',
  'file_too_large' => 'Die Datei ist größer als erlaubt (höchstens 100 MB).',
  'insufficient_storage' => 'Auf dem Server ist gerade kein Platz mehr.',
  'invalid_file' => 'Der Server hat die Datei abgelehnt (der Dateityp passt nicht zum Inhalt).',
  'invalid_reference' => 'Der Upload ist nicht mehr gültig und muss neu hochgeladen werden.',
  'nr_belegt' => 'Eine andere Fassung war schneller. Es wird mit einer neuen Nummer erneut versucht.',
  'network' || 'timeout' || 'access_expired' => 'Keine Verbindung. Es geht weiter, sobald das Netz wieder da ist.',
  'maintenance' => 'Die Familienzentrale ist gerade in Wartung.',
  'rate_limited' || 'too_many_uploads' => 'Zu viele Uploads auf einmal. Es geht gleich weiter.',
  'datei_geaendert' => 'Die Datei hat sich geändert. Bitte wähle sie noch einmal.',
  'quelle_fehlt' => 'Die Datei ist nicht mehr da. Bitte wähle sie noch einmal.',
  'anhang_neu' => 'Der Anhang muss neu gewählt werden.',
  'pruefsumme' => 'Die geladene Datei ist beschädigt. Bitte versuche es noch einmal.',
  'nicht_gefunden' || 'not_found' => 'Die Datei gibt es nicht mehr.',
  'nicht_erlaubt' || 'forbidden' => 'Dazu fehlt dir die Berechtigung.',
  'kein_platz_lokal' => 'Auf dem Gerät ist nicht genug Platz.',
  _ => 'Die Übertragung hat nicht geklappt.',
};

/// Vordergrunddienst (Android, Typ `dataSync`): hält die App am Leben, solange Übertragungen aktiv sind, und zeigt eine dauerhafte Benachrichtigung OHNE Namen und Inhalte
/// ("Übertragung läuft" / "n Übertragungen", Prozent). Android-Seite: `TransferService.kt`/`TransferKanal.kt`, Dart-Seite `transfer_hintergrund_android.dart` (bedingter Import).
abstract interface class TransferHintergrundPort {
  /// Beginnt den Vordergrunddienst (idempotent).
  Future<void> starten({required int anzahl});

  /// Aktualisiert die Anzeige (Anzahl und Prozent des Gesamtstapels, 0 bis 100).
  Future<void> aktualisieren({required int anzahl, required int prozent});

  /// Beendet ihn (idempotent).
  Future<void> beenden();
}

/// Ohne Vordergrunddienst (Web, Tests, solange die Android-Seite fehlt).
class KeinTransferHintergrund implements TransferHintergrundPort {
  const KeinTransferHintergrund();
  @override
  Future<void> starten({required int anzahl}) async {}
  @override
  Future<void> aktualisieren({required int anzahl, required int prozent}) async {}
  @override
  Future<void> beenden() async {}
}
