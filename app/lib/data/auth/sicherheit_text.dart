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
    SicherheitsArt.passkeySicherungAbgerufen =>
      'Die Passkey-Sicherung deines Schlüssels wurde abgerufen (zum Beispiel beim Verbinden eines Geräts nach der Anmeldung). Warst du das nicht, entferne den Passkey unter Profil > Passkeys.',
    SicherheitsArt.passkeySicherungAngelegt =>
      'Für deinen Schlüssel wurde eine Passkey-Sicherung angelegt. Warst du das nicht, entferne den Passkey unter Profil > Passkeys und ändere dein Passwort.',
    SicherheitsArt.elternHinterlegungAngelegt => 'Du hast deinen Eltern erlaubt, dir bei der Wiederherstellung deines Schlüssels zu helfen.',
    SicherheitsArt.elternHinterlegungZurueckgenommen => 'Du hast die Eltern-Wiederherstellung zurückgenommen.',
    SicherheitsArt.elternAnfrageGestellt =>
      'Für dein Konto wurde die Wiederherstellung durch deine Eltern angefragt. Warst du das nicht, brich die Anfrage ab (Profil > Verschlüsselung > Eltern-Wiederherstellung).',
    SicherheitsArt.elternAnfrageFuerKind =>
      '${e.betroffener ?? 'Ein Kind'} bittet um die Wiederherstellung des Schlüssels. Sprich mit dem Kind, bevor du hilfst. Sobald die Wartefrist vorbei ist, geht es unter Profil > Verschlüsselung > Eltern-Wiederherstellung weiter.',
    SicherheitsArt.elternAnfrageUebernommen =>
      '${e.akteur ?? 'Ein Elternteil'} hat deine Anfrage übernommen. Öffne Profil > Verschlüsselung > Eltern-Wiederherstellung und nenne dem Elternteil den Code, der dort steht.',
    SicherheitsArt.elternFreigegeben => '${e.akteur ?? 'Ein Elternteil'} hat deinen Schlüssel freigegeben. Öffne die App auf dem Gerät, auf dem du ihn wiederherstellen willst.',
    SicherheitsArt.elternAnfrageBeendet => e.betroffener != null
        ? 'Die Anfrage von ${e.betroffener} zur Wiederherstellung ist beendet.'
        : 'Deine Anfrage zur Wiederherstellung wurde beendet (abgebrochen, abgelehnt oder abgelaufen).',
    SicherheitsArt.andere => 'Es gab ein Sicherheitsereignis an deinem Konto.',
  };
}

