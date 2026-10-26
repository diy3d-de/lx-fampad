// Zähler (Abschnitt 6l): gemeinsame Hilfen der Oberfläche: Zahlen- und Datumsformate (deutsch), Farben und Symbole der Zählerarten, die Zahlen für Badge und Startseite.
// Alles wird nur lokal aus den Zählern berechnet (nie Server, nie Push) und nur für Eltern und Admins; für alle anderen sind die Zahlen immer 0.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/chat/chat_krypto.dart' show SchluesselFehlt, VerschluesselungNichtBereit;
import '../../data/zaehler/zaehler_modelle.dart';
import '../../data/zaehler/zaehler_repository.dart' show StandUngueltig, ZaehlerFehler;
import '../../data/zaehler/zaehler_state.dart';
import '../../data/zaehler/zaehler_uebersicht.dart';
import '../calendar/calendar_anzeige.dart' show minutenTaktProvider;

export '../../data/zaehler/zaehler_format.dart';

/// Farbe der Veränderung zum Vorjahr: beim Verbrauch ist weniger gut (grün), mehr zeigt sich warm; bei Erzeugung umgekehrt.
Color prozentFarbe(double? p, {required bool erzeugung}) {
  if (p == null || p.abs() < 0.5) return kTextMuted;
  final gut = erzeugung ? p > 0 : p < 0;
  return gut ? kTerminal : kWarn;
}

/// Farbe und Symbol einer Zählerart.
Color zaehlerFarbe(ZaehlerArt a) => switch (a) {
  ZaehlerArt.strom => kWarn,
  ZaehlerArt.kaltwasser => kZaehlerKalt,
  ZaehlerArt.warmwasser => kZaehlerWarm,
  ZaehlerArt.gas => kZaehlerGas,
  ZaehlerArt.waerme => kZaehlerWaerme,
  ZaehlerArt.erzeugung => kZaehlerSolar,
  ZaehlerArt.eigen => kZaehlerEigen,
};

IconData zaehlerSymbol(ZaehlerArt a) => switch (a) {
  ZaehlerArt.strom => Icons.bolt,
  ZaehlerArt.kaltwasser => Icons.water_drop_outlined,
  ZaehlerArt.warmwasser => Icons.water_drop,
  ZaehlerArt.gas => Icons.local_fire_department_outlined,
  ZaehlerArt.waerme => Icons.thermostat,
  ZaehlerArt.erzeugung => Icons.wb_sunny_outlined,
  ZaehlerArt.eigen => Icons.speed_outlined,
};

/// Kurzbezeichnung einer Art für die Wahl ("Strom · kWh").
String artAuswahlText(ZaehlerArt a) => a.einheit.isEmpty ? a.anzeige : '${a.anzeige} · ${a.einheit}';

/// Erzeugung (Solar) ist die einzige Art, bei der mehr besser ist.
bool istErzeugung(ZaehlerArt a) => a == ZaehlerArt.erzeugung;

/// Meldung zu einem Fehler beim Speichern (nie ein Inhalt, nie ein Servertext).
String zaehlerFehlerText(Object e) => switch (e) {
  StandUngueltig f => f.meldung,
  ZaehlerFehler f => f.meldung,
  VerschluesselungNichtBereit v => v.meldung,
  SchluesselFehlt _ => 'Für eine Person ist der Nachrichten-Schutz noch nicht eingerichtet. Sie muss sich einmal anmelden und ihn einrichten.',
  ArgumentError _ => 'Die Eingaben sind nicht stimmig.',
  _ => 'Das hat gerade nicht geklappt. Versuche es gleich noch einmal.',
};

/// Zahl der Zähler, die jetzt abgelesen werden sollen: das Badge hinter "Mehr" und am Eintrag der Seitenleiste. Für alle außer Eltern und Admins immer 0 (ohne etwas zu lesen).
final zaehlerFaelligProvider = Provider.autoDispose<int>((ref) {
  if (!ref.watch(zaehlerDarfProvider)) return 0;
  final d = ref.watch(zaehlerDatenProvider);
  if (d.reihen.isEmpty) return 0; // ohne Zähler kein Minutentakt
  final jetzt = ref.watch(minutenTaktProvider).value ?? DateTime.now();
  return faelligeReihen(d.reihen, zaehlerHeute(jetzt)).length;
});

/// Gibt es Zähler (Kachel in der Anpassen-Liste anbieten)? Nur für Eltern und Admins.
final zaehlerVorhandenProvider = Provider.autoDispose<bool>((ref) => ref.watch(zaehlerDarfProvider) && ref.watch(zaehlerDatenProvider.select((d) => d.reihen.isNotEmpty)));
