// Texte der Sicherheitsereignisse (Profil > Sicherheitsereignisse). Nur Art, Weg und der Name des auslösenden Familienmitglieds, nie Inhalte oder Geheimnisse.
import '../api/models.dart';

/// Satz für ein Ereignis ("Dein Passwort wurde … zurückgesetzt").
String sicherheitsEreignisText(SicherheitsEreignisDto e) {
  final wer = e.akteur ?? 'Ein Admin';
  return switch (e.art) {
    SicherheitsArt.passwortResetAngefordert => '$wer hat einen Link zum Zurücksetzen deines Passworts erstellt.',
    SicherheitsArt.passwortZurueckgesetzt => switch (e.weg) {
      SicherheitsWeg.admin => 'Dein Passwort wurde mit dem Link eines Admins zurückgesetzt.',
      SicherheitsWeg.wiederherstellungscode => 'Du hast dein Passwort mit einem Wiederherstellungscode zurückgesetzt.',
      SicherheitsWeg.passkey => 'Du hast dein Passwort mit deinem Passkey zurückgesetzt.',
      SicherheitsWeg.unbekannt => 'Dein Passwort wurde zurückgesetzt.',
    },
    SicherheitsArt.zugangZurueckgesetzt => '$wer hat deinen Zugang komplett zurückgesetzt. Alle Anmeldedaten wurden erneuert.',
    // Hinweis an die Familie: der Zugang einer anderen Person wurde komplett zurückgesetzt (der Weg, ein Konto zu übernehmen): ihren neuen Schlüssel nur nach Rücksprache annehmen
    SicherheitsArt.mitgliedZugangZurueckgesetzt =>
      'Der Zugang von ${e.betroffener ?? 'einem Familienmitglied'} wurde zurückgesetzt. Nimm einen neuen Schlüssel dieser Person nur nach Rücksprache an.',
    SicherheitsArt.passwortSicherungAbgerufen => 'Die Passwort-Sicherung deines Schlüssels wurde abgerufen (zum Beispiel beim Verbinden eines Geräts nach der Anmeldung). Warst du das nicht, ändere dein Passwort.',
    SicherheitsArt.andere => 'Es gab ein Sicherheitsereignis an deinem Konto.',
  };
}

