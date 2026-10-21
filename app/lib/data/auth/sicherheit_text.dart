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
    SicherheitsArt.andere => 'Es gab ein Sicherheitsereignis an deinem Konto.',
  };
}

