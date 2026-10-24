// Tresor (Abschnitt 6m): Vorlagen für neue Einträge als reine Daten (keine Logik, kein Netz). Eine Vorlage belegt Kategorie und die Felder vor (deutsche Bezeichnungen, Werte leer);
// die Person füllt sie aus, ändert, löscht oder ergänzt Felder. Gespeichert wird nur die Kennung ([TresorVorlage]), nie ein Verweis auf diese Liste.
import 'tresor_modelle.dart';

class TresorVorlagenDaten {
  final TresorVorlage kennung;
  final String name;
  final String beschreibung;
  final TresorKategorie kategorie;
  final List<TresorFeld> felder;
  const TresorVorlagenDaten({required this.kennung, required this.name, required this.beschreibung, required this.kategorie, required this.felder});

  /// Ein neuer, noch leerer Eintrag aus dieser Vorlage (Titel leer: die Person vergibt ihn).
  TresorInhalt neu({String titel = ''}) => TresorInhalt(kategorie: kategorie, titel: titel, felder: List.of(felder), vorlage: kennung);
}

const List<TresorVorlagenDaten> kTresorVorlagen = [
  TresorVorlagenDaten(
    kennung: TresorVorlage.wlan,
    name: 'WLAN',
    beschreibung: 'Netzname, Passwort, Router',
    kategorie: TresorKategorie.haushalt,
    felder: [
      TresorFeld(bezeichnung: 'Netzname'),
      TresorFeld(bezeichnung: 'Passwort', geheim: true),
      TresorFeld(bezeichnung: 'Router-Adresse'),
      TresorFeld(bezeichnung: 'Router-Passwort', geheim: true),
    ],
  ),
  TresorVorlagenDaten(
    kennung: TresorVorlage.versicherung,
    name: 'Versicherung',
    beschreibung: 'Versicherer, Vertragsnummer, Kündigungsfrist',
    kategorie: TresorKategorie.dokumente,
    felder: [
      TresorFeld(bezeichnung: 'Versicherer'),
      TresorFeld(bezeichnung: 'Vertragsnummer', geheim: true),
      TresorFeld(bezeichnung: 'Versicherte Person oder Sache'),
      TresorFeld(bezeichnung: 'Kündigungsfrist'),
      TresorFeld(bezeichnung: 'Kontakt im Schadensfall'),
    ],
  ),
  TresorVorlagenDaten(
    kennung: TresorVorlage.ausweis,
    name: 'Ausweis',
    beschreibung: 'Nummer, Gültigkeit, Behörde',
    kategorie: TresorKategorie.dokumente,
    felder: [
      TresorFeld(bezeichnung: 'Person'),
      TresorFeld(bezeichnung: 'Art des Dokuments'),
      TresorFeld(bezeichnung: 'Nummer', geheim: true),
      TresorFeld(bezeichnung: 'Gültig bis'),
      TresorFeld(bezeichnung: 'Ausstellende Behörde'),
    ],
  ),
  TresorVorlagenDaten(
    kennung: TresorVorlage.arzt,
    name: 'Arzt',
    beschreibung: 'Praxis, Telefon, Versichertennummer',
    kategorie: TresorKategorie.notfall,
    felder: [
      TresorFeld(bezeichnung: 'Person'),
      TresorFeld(bezeichnung: 'Praxis'),
      TresorFeld(bezeichnung: 'Telefon'),
      TresorFeld(bezeichnung: 'Adresse'),
      TresorFeld(bezeichnung: 'Versichertennummer', geheim: true),
    ],
  ),
  TresorVorlagenDaten(
    kennung: TresorVorlage.eigener,
    name: 'Eigener Eintrag',
    beschreibung: 'Leer, Felder frei wählen',
    kategorie: TresorKategorie.zugang,
    felder: [],
  ),
];

/// Die Vorlage zu einer Kennung.
TresorVorlagenDaten tresorVorlage(TresorVorlage kennung) => kTresorVorlagen.firstWhere((v) => v.kennung == kennung);
