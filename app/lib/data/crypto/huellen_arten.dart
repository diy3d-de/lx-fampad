// Die Art-Buchstaben der e1-Hüllen an EINER Stelle. Die Art steht im AAD und damit in der Signatur (`HuellenKontext.art`, huelle.dart): eine Hülle lässt sich nie als andere Art lesen.
// Jeder Buchstabe gehört genau einer Art; ein neuer Buchstabe wird hier ergänzt (und in [kHuellenArten]), nie anderswo erfunden. `test/huellen_arten_test.dart` hält die Eindeutigkeit fest.
// Nachrichten haben keine Art (kein Buchstabe im AAD). Der Server liest Hüllen nie, darum gibt es dort keine Liste.

/// Reaktion auf eine Nachricht.
const String kArtReaktion = 'r';

/// Stimme zu einer Umfrage.
const String kArtStimme = 's';

/// Medikament (Medikamenten-Plan).
const String kArtMedikament = 'm';

/// Einnahme (Medikamenten-Plan).
const String kArtEinnahme = 'n';

/// Zähler.
const String kArtZaehler = 'z';

/// Zählerstand.
const String kArtStand = 'a';

/// Tresor-Eintrag.
const String kArtTresor = 't';

/// Tresor-Anhang (Datei).
const String kArtAnhang = 'f';

/// Vorsorge-Profil.
const String kArtVorsorgeProfil = 'p';

/// Vorsorge-Eintrag.
const String kArtVorsorgeEintrag = 'v';

/// Alle vergebenen Art-Buchstaben (für den Eindeutigkeitstest).
const List<String> kHuellenArten = [
  kArtReaktion,
  kArtStimme,
  kArtMedikament,
  kArtEinnahme,
  kArtZaehler,
  kArtStand,
  kArtTresor,
  kArtAnhang,
  kArtVorsorgeProfil,
  kArtVorsorgeEintrag,
];
