// Anzeige-Modelle und reine Hilfen fürs Standort teilen (ohne Flutter-Oberfläche, getestet in test/standort_modelle_test.dart).
import '../api/models.dart';

/// Längste Freigabe (wie am Server und im Empfänger begrenzt).
const Duration kStandortHoechstdauer = Duration(hours: 12);

/// Ab diesem Alter gilt eine Position als veraltet (die Anzeige warnt: "zuletzt gesehen vor …").
const Duration kStandortVeraltetNach = Duration(minutes: 5);

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
