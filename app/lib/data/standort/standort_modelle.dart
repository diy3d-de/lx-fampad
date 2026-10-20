// Anzeige-Modelle und reine Hilfen fürs Standort teilen (ohne Flutter-Oberfläche, getestet in test/standort_modelle_test.dart).
import '../api/models.dart';

/// Längste Freigabe (wie am Server und im Empfänger begrenzt).
const Duration kStandortHoechstdauer = Duration(hours: 12);

/// Ab diesem Alter gilt eine Position als veraltet (die Anzeige warnt: "zuletzt gesehen vor …").
const Duration kStandortVeraltetNach = Duration(minutes: 5);

/// Wie oft die Position gesendet wird, solange sich das Gerät bewegt (die Auswahl "Aktualisierung" beim Start). Je kürzer, desto mehr Akku.
/// In Ruhe (keine Bewegung über die Schwelle) wiederholt das Gerät die Position seltener ([ruhe]), damit die anderen sehen, dass sie noch aktuell ist.
enum StandortTakt {
  genau('Genau (3 s)', 3),
  normal('Normal (5 s)', 5),
  sparsam('Sparsam (15 s)', 15);

  final String label;
  final int sekunden;
  const StandortTakt(this.label, this.sekunden);

  Duration get intervall => Duration(seconds: sekunden);

  /// Wiederholung ohne Bewegung: 30 s, im sparsamen Modus 60 s (also mindestens das Doppelte des Intervalls).
  Duration get ruhe => Duration(seconds: sekunden * 2 > 30 ? sekunden * 2 : 30);
}

const kStandortTaktStandard = StandortTakt.normal;

/// Mindeststrecke seit der zuletzt gesendeten Position, ab der es als Bewegung zählt: 5 m, bei ungenauer Messung die Hälfte der Genauigkeit (höchstens 30 m),
/// sonst würde das Rauschen des GPS ständig "Bewegung" auslösen.
double bewegungsSchwelle(double? genauigkeit) {
  final h = (genauigkeit ?? 0) * 0.5;
  return h < 5 ? 5 : (h > 30 ? 30 : h);
}

/// Die Auswahl der Dauer beim Start. [dauer] null = "bis ich beende": bis zur Höchstdauer.
class StandortDauer {
  final String label;
  final Duration? dauer;
  const StandortDauer(this.label, this.dauer);

  Duration get wirksam => dauer ?? kStandortHoechstdauer;
}

const kStandortDauern = <StandortDauer>[
  StandortDauer('15 Minuten', Duration(minutes: 15)),
  StandortDauer('1 Stunde', Duration(hours: 1)),
  StandortDauer('8 Stunden', Duration(hours: 8)),
  StandortDauer('Bis ich beende', null),
];

/// Eine Person, die ihren Standort mit mir teilt, samt dem, was wir von ihr wissen.
class GeteiltePosition {
  final String userId;
  final String shareId;

  /// Bis wann die Person teilt (Ende laut ihrer letzten gültigen Nachricht).
  final DateTime endetAt;

  /// Letzte angenommene Messung; null, solange noch keine Position angekommen ist.
  final double? breite;
  final double? laenge;
  final double? genauigkeit;
  final DateTime? messzeit;

  /// Die Freigabe ließ sich nicht prüfen (Schlüssel der Person nicht bestätigt, beschädigt): es wird keine Position angezeigt.
  final bool ungeprueft;
  const GeteiltePosition({
    required this.userId,
    required this.shareId,
    required this.endetAt,
    this.breite,
    this.laenge,
    this.genauigkeit,
    this.messzeit,
    this.ungeprueft = false,
  });

  bool get hatPosition => breite != null && laenge != null && messzeit != null;

  /// Alter der Messung (null ohne Position).
  Duration? alter(DateTime jetzt) => messzeit == null ? null : jetzt.difference(messzeit!).isNegative ? Duration.zero : jetzt.difference(messzeit!);

  bool veraltet(DateTime jetzt) => (alter(jetzt) ?? Duration.zero) >= kStandortVeraltetNach;

  bool abgelaufen(DateTime jetzt) => !endetAt.isAfter(jetzt);

  GeteiltePosition mitEnde(DateTime ende) => GeteiltePosition(userId: userId, shareId: shareId, endetAt: ende, breite: breite, laenge: laenge, genauigkeit: genauigkeit, messzeit: messzeit, ungeprueft: ungeprueft);

  GeteiltePosition mitPosition({required double breite, required double laenge, double? genauigkeit, required DateTime messzeit, required DateTime endetAt}) => GeteiltePosition(
    userId: userId,
    shareId: shareId,
    endetAt: endetAt,
    breite: breite,
    laenge: laenge,
    genauigkeit: genauigkeit,
    messzeit: messzeit,
  );
}

/// "vor 3 Min", "vor 2 Std", "gerade eben": Alter für die Anzeige.
String alterText(Duration d) {
  if (d.inSeconds < 45) return 'gerade eben';
  if (d.inMinutes < 60) return 'vor ${d.inMinutes < 1 ? 1 : d.inMinutes} Min';
  if (d.inHours < 24) return 'vor ${d.inHours} Std';
  return 'vor ${d.inDays} Tg';
}

/// "± 12 m" bzw. "± 1,4 km" (null: unbekannt).
String genauigkeitText(double? meter) {
  if (meter == null) return 'Genauigkeit unbekannt';
  if (meter < 1000) return '± ${meter.round()} m';
  return '± ${(meter / 1000).toStringAsFixed(1).replaceAll('.', ',')} km';
}

/// "48,13720, 11,57550" für die Detailansicht.
String koordinatenText(double breite, double laenge) => '${breite.toStringAsFixed(5).replaceAll('.', ',')}, ${laenge.toStringAsFixed(5).replaceAll('.', ',')}';

/// Voreinstellung der Empfänger: Eltern und Admins teilen mit allen aktiven Mitgliedern; ein Kind teilt zunächst nur mit Eltern und Admins. Die Person kann
/// die Auswahl vor dem Start ändern (auch ausweiten oder einschränken); die Voreinstellung ist keine Regel und keine Rolle bekommt dadurch Rechte.
Set<String> standardEmpfaenger(UserDto ich, Iterable<UserDto> mitglieder) => {
  for (final m in mitglieder)
    if (m.id != ich.id && m.status == MemberStatus.active && (ich.role != Role.child || m.role != Role.child)) m.id,
};
