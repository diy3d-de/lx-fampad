// Medikamenten-Plan: gemeinsame Hilfen der Oberfläche (Zähler für Badge und Startseite, Texte). Die Zähler werden nur lokal aus den Plänen der Person berechnet (nie Server, nie Push).
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/calendar/zeitzonen.dart';
import '../../data/chat/chat_krypto.dart' show SchluesselFehlt, VerschluesselungNichtBereit;
import '../../data/medikamente/medikament_heute.dart';
import '../../data/medikamente/medikament_modelle.dart';
import '../../data/medikamente/medikament_repository.dart' show MedikamentFehler;
import '../../data/medikamente/medikament_state.dart';
import '../calendar/calendar_anzeige.dart' show minutenTaktProvider;

/// Fällige (Uhrzeit erreicht) und verpasste Einnahmen heute aus allen sichtbaren Plänen: die Zahl im "Mehr"-Blatt und am Feld "Mehr".
final medikamenteFaelligProvider = Provider.autoDispose<int>((ref) {
  final d = ref.watch(medDatenProvider);
  if (d.eintraege.isEmpty) return 0; // ohne Pläne kein Minutentakt (kein Zeitgeber ohne Nutzen)
  final jetzt = ref.watch(minutenTaktProvider).value ?? DateTime.now();
  return heuteAnsicht(d.eintraege, jetzt).faellig;
});

/// Noch nicht erledigte Einnahmen heute (auch spätere), für die Startseiten-Kachel (ohne Treffer gibt es die Kachel nicht).
final medikamenteOffenProvider = Provider.autoDispose<int>((ref) {
  final d = ref.watch(medDatenProvider);
  if (d.eintraege.isEmpty) return 0;
  final jetzt = ref.watch(minutenTaktProvider).value ?? DateTime.now();
  return nichtErledigtHeute(d.eintraege, jetzt);
});

/// Gibt es Pläne, die diese Person sieht (Kachel in der Anpassen-Liste anbieten)?
final medikamenteVorhandenProvider = Provider.autoDispose<bool>((ref) => ref.watch(medDatenProvider.select((d) => d.eintraege.isNotEmpty)));

const _wochentage = ['Mo', 'Di', 'Mi', 'Do', 'Fr', 'Sa', 'So'];
const _wochentageLang = ['Montag', 'Dienstag', 'Mittwoch', 'Donnerstag', 'Freitag', 'Samstag', 'Sonntag'];
const _monate = ['Jan', 'Feb', 'Mär', 'Apr', 'Mai', 'Jun', 'Jul', 'Aug', 'Sep', 'Okt', 'Nov', 'Dez'];

String wochentagKurz(int weekday) => _wochentage[weekday - 1];
String wochentagLang(int weekday) => _wochentageLang[weekday - 1];

/// "Fr, 23. Okt" (Kalendertag, UTC-Mitternacht).
String datumKurz(DateTime tag) => '${_wochentage[tag.weekday - 1]}, ${tag.day}. ${_monate[tag.month - 1]}';

/// "02. Nov 2026".
String datumLang(DateTime tag) => '${tag.day.toString().padLeft(2, '0')}. ${_monate[tag.month - 1]} ${tag.year}';

/// Uhrzeit `HH:MM` (Wanduhr der Familienzone) eines Zeitpunkts.
String uhrzeitVon(DateTime instant) {
  final w = wandUhr(instant, familienOrt);
  return '${w.hour.toString().padLeft(2, '0')}:${w.minute.toString().padLeft(2, '0')}';
}

/// Menge ohne unnötige Nachkommastelle: "1", "0,5", "2".
String zahlText(double v) {
  final s = v == v.roundToDouble() ? v.round().toString() : v.toString().replaceAll('.', ',');
  return s;
}

/// "Täglich · 08:00, 20:00", "Mo, Mi, Fr · 08:00", "Alle 2 Tage · 08:00", "Bei Bedarf".
String rhythmusText(MedikamentInhalt m) {
  final zeiten = m.zeiten.join(', ');
  final r = m.rhythmus;
  return switch (r.art) {
    RhythmusArt.taeglich => 'Täglich · $zeiten',
    RhythmusArt.wochentage => '${([...r.wochentage]..sort()).map(wochentagKurz).join(', ')} · $zeiten',
    RhythmusArt.intervall => '${r.alleNTage == 1 ? 'Jeden Tag' : 'Alle ${r.alleNTage} Tage'} · $zeiten',
    RhythmusArt.bedarf => 'Bei Bedarf',
  };
}

/// "Name · Dosis" (Dosis nur, wenn vorhanden).
String titelText(MedikamentInhalt m) => m.dosis.trim().isEmpty ? m.name : '${m.name} · ${m.dosis}';

/// Meldung zu einem Fehler beim Speichern (nie ein Inhalt, nie ein Servertext).
String medFehlerText(Object e, {String? person}) => switch (e) {
  MedikamentFehler f => f.meldung,
  VerschluesselungNichtBereit v => v.meldung,
  SchluesselFehlt _ => person == null
      ? 'Für diese Person ist die Verschlüsselung noch nicht eingerichtet.'
      : 'Für $person ist die Verschlüsselung noch nicht eingerichtet. Sie muss sich einmal anmelden und sie einrichten.',
  ArgumentError _ => 'Die Eingaben sind nicht stimmig.',
  _ => 'Das hat gerade nicht geklappt. Versuche es gleich noch einmal.',
};
