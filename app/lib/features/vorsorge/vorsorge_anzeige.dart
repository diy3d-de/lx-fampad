// Vorsorge und Impfungen: gemeinsame Hilfen der Oberfläche (Texte, Symbole, heutiger Tag). Nichts davon verlässt die App.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/api/models.dart' show Role;
import '../../data/chat/chat_krypto.dart' show SchluesselFehlt, VerschluesselungNichtBereit;
import '../../data/medikamente/medikament_logik.dart' show familienTag;
import '../../data/medikamente/medikament_modelle.dart' show tagLesen;
import '../../data/vorsorge/vorsorge_logik.dart';
import '../../data/vorsorge/vorsorge_vorlagen.dart';
import '../../data/vorsorge/vorsorge_modelle.dart';
import '../../data/vorsorge/vorsorge_repository.dart' show VorsorgeFehler;
import '../../data/vorsorge/vorsorge_state.dart' show vorsorgeDatenProvider;
import '../calendar/calendar_anzeige.dart' show minutenTaktProvider;

/// Heutiger Kalendertag in der Familienzone (UTC-Mitternacht).
DateTime vorsorgeHeute() => vorsorgeHeuteAus(DateTime.now());

/// Der Kalendertag in der Familienzone zu einem Zeitpunkt (die Oberfläche nimmt die Uhr des Minutentakts, Tests eine feste).
DateTime vorsorgeHeuteAus(DateTime jetzt) => nurTag(familienTag(jetzt));

/// Fällige und überfällige Einträge aller Personen, die diese Person sehen darf (Zahl am Eintrag im Blatt "Mehr"); nur Zahlen, nie Namen, Art oder Person. Liest die Vorsorge-Daten nur,
/// wenn es welche gibt (ohne Daten kein Mitgliederabruf und kein Minutentakt).
final vorsorgeHinweisProvider = Provider.autoDispose<({int offen, int ueberfaellig})>((ref) {
  final d = ref.watch(vorsorgeDatenProvider);
  if (d.eintraege.isEmpty) return (offen: 0, ueberfaellig: 0);
  final heute = vorsorgeHeuteAus(ref.watch(minutenTaktProvider).value ?? DateTime.now());
  var offen = 0;
  var ueber = 0;
  for (final p in d.personen) {
    final profil = d.profilVon(p.id);
    final k = vorsorgeKarten(d.von(p.id), geburt: profil?.geburtTag, geschlecht: profil?.geschlecht, heute: heute);
    offen += k.faellig.length;
    ueber += k.faellig.where((x) => x.faelligkeit.status == VorsorgeStatus.ueberfaellig).length;
  }
  return (offen: offen, ueberfaellig: ueber);
});

/// Kinder dürfen in Vorsorge nur ansehen (der Server lässt für sie nur Lesen zu); Eltern und Admins tragen ein.
bool vorsorgeDarfSchreiben(Role? rolle) => rolle != Role.child;

/// Meldung zu einem Fehler beim Speichern (nie ein Inhalt, nie ein Servertext).
String vorsorgeFehlerText(Object e, {String? person}) => switch (e) {
  VorsorgeFehler f => f.meldung,
  VerschluesselungNichtBereit v => v.meldung,
  SchluesselFehlt _ => person == null
      ? 'Für diese Person ist der Nachrichten-Schutz noch nicht eingerichtet.'
      : 'Für $person ist der Nachrichten-Schutz noch nicht eingerichtet. Sie muss sich einmal anmelden und ihn einrichten.',
  ArgumentError _ => 'Die Eingaben sind nicht stimmig.',
  _ => 'Das hat gerade nicht geklappt. Versuche es gleich noch einmal.',
};

/// Symbol zur Art (zusätzlich zum Text, nie die Farbe allein).
IconData vorsorgeArtSymbol(VorsorgeArt a) => switch (a) {
  VorsorgeArt.impfung => Icons.vaccines_outlined,
  VorsorgeArt.vorsorge => Icons.health_and_safety_outlined,
  VorsorgeArt.zahn => Icons.mood_outlined,
  VorsorgeArt.sonstiges => Icons.event_note_outlined,
};

/// Symbol zum Stand (zusätzlich zum Text).
IconData vorsorgeStatusSymbol(VorsorgeStatus s) => switch (s) {
  VorsorgeStatus.ueberfaellig => Icons.error_outline,
  VorsorgeStatus.faellig => Icons.priority_high,
  VorsorgeStatus.bald => Icons.schedule,
  VorsorgeStatus.spaeter => Icons.event_outlined,
  VorsorgeStatus.erledigt => Icons.check_circle_outline,
  VorsorgeStatus.keinTermin => Icons.info_outline,
};

/// Deutsches Datum aus einem Tag-Text `YYYY-MM-DD` (unlesbar: der Text selbst).
String vorsorgeTagAnzeige(String tag) {
  final t = tagLesen(tag);
  return t == null ? tag : vorsorgeDatum(t);
}

/// Hinweis zur Verlässlichkeit einer Vorlage (leer: keiner).
String? vorsorgeVerlaessigkeitText(VorsorgeVorlage? v) {
  if (v == null) return null;
  if (v.nurHinweis) return 'Nur ein Hinweis, kein festes Zeitfenster.';
  if (v.freiwillig) return 'Freiwillige Leistung der Krankenkasse.';
  if (v.ungeprueft) return 'Bitte mit Impfpass oder Arztpraxis prüfen.';
  return null;
}
