// Anzeige-Hilfen der Betreiber-Ansicht: feste deutsche Texte zu den festen Codes des Servers (nie ein Servertext), Zahlen- und Zeitformate.
import 'package:flutter/material.dart';

import '../../constants.dart';
import '../../data/betrieb/betrieb_modelle.dart';

/// Farbe einer Stufe.
Color stufeFarbe(BetriebStufe s) => switch (s) {
  BetriebStufe.ok => kTerminal,
  BetriebStufe.warn => kWarn,
  BetriebStufe.fehler => kDanger,
  BetriebStufe.aus || BetriebStufe.unbekannt => kTextMuted,
};

/// Kurzwort der Stufe in der Pille ([okText] z. B. "läuft" oder "gültig").
String stufeText(BetriebStufe s, {String okText = 'läuft'}) => switch (s) {
  BetriebStufe.ok => okText,
  BetriebStufe.warn => 'Hinweis',
  BetriebStufe.fehler => 'Störung',
  BetriebStufe.aus => 'aus',
  BetriebStufe.unbekannt => 'unbekannt',
};

/// Farbe der Gesamtzeile: "in Ordnung" mit unbekannten Quellen ist neutral, nicht grün.
Color gesamtFarbe(BetriebStufe s, {int unbekannt = 0}) => s == BetriebStufe.ok && unbekannt > 0 ? kTextMuted : stufeFarbe(s);

/// Gesamtzustand für die Zeile oben auf der Übersicht.
String gesamtText(BetriebStufe s, {int unbekannt = 0}) => switch (s) {
  BetriebStufe.ok when unbekannt > 0 => 'in Ordnung, $unbekannt unbekannt',
  BetriebStufe.ok => 'alles in Ordnung',
  BetriebStufe.warn => 'Hinweise beachten',
  BetriebStufe.fehler => 'Störung',
  _ => 'Zustand unbekannt',
};

String _z(num v, [int stellen = 1]) => v.toStringAsFixed(stellen).replaceAll('.', ',');

/// "38 MB", "1,1 GB" (1024er-Schritte, wie die Betriebssysteme es zeigen).
String groesseText(int? bytes) {
  if (bytes == null) return '–';
  const kb = 1024;
  if (bytes < kb) return '$bytes B';
  if (bytes < kb * kb) return '${(bytes / kb).round()} KB';
  if (bytes < kb * kb * kb) return '${(bytes / (kb * kb)).round()} MB';
  return '${_z(bytes / (kb * kb * kb))} GB';
}

/// "3 T 4 Std", "5 Std 12 Min", "42 Min".
String laufzeitText(int sekunden) {
  final min = sekunden ~/ 60;
  final std = min ~/ 60;
  final tage = std ~/ 24;
  if (tage > 0) return '$tage T ${std % 24} Std';
  if (std > 0) return '$std Std ${min % 60} Min';
  return '$min Min';
}

String _zwei(int n) => n.toString().padLeft(2, '0');

String uhrzeit(DateTime t) {
  final l = t.toLocal();
  return '${_zwei(l.hour)}:${_zwei(l.minute)}';
}

String datumText(DateTime t) {
  final l = t.toLocal();
  return '${_zwei(l.day)}.${_zwei(l.month)}.${l.year}';
}

/// "heute 12:14", "gestern 22:03", sonst "19.10. 13:41".
String zeitText(DateTime t, DateTime jetzt) {
  final l = t.toLocal();
  final j = jetzt.toLocal();
  final tag = DateTime(l.year, l.month, l.day);
  final heute = DateTime(j.year, j.month, j.day);
  final diff = heute.difference(tag).inDays;
  if (diff == 0) return 'heute ${uhrzeit(l)}';
  if (diff == 1) return 'gestern ${uhrzeit(l)}';
  return '${_zwei(l.day)}.${_zwei(l.month)}. ${uhrzeit(l)}';
}

/// "vor 6 Min", "vor 5 Std", "vor 3 T".
String vorText(Duration d) {
  if (d.inMinutes < 1) return 'gerade eben';
  if (d.inHours < 1) return 'vor ${d.inMinutes} Min';
  if (d.inDays < 1) return 'vor ${d.inHours} Std';
  return 'vor ${d.inDays} T';
}

/// Klartext zu den Ereignisarten des Audit-Protokolls (feste Liste des Servers; Unbekanntes heißt allgemein "Ereignis").
const _ereignisse = <String, String>{
  'bootstrap_created': 'Familie eingerichtet',
  'invite_created': 'Einladung erstellt',
  'invite_used': 'Einladung eingelöst',
  'invite_revoked': 'Einladung widerrufen',
  'invite_extended': 'Einladung verlängert',
  'invite_expired': 'Einladung abgelaufen',
  'invite_pin_failed': 'Einladungs-PIN falsch',
  'invite_locked': 'Einladung gesperrt',
  'member_registered': 'Mitglied registriert',
  'member_approved': 'Mitglied freigegeben',
  'member_rejected': 'Mitglied abgelehnt',
  'member_removed': 'Mitglied entfernt',
  'avatar_reset': 'Profilbild zurückgesetzt',
  'member_reset': 'Mitglied zurückgesetzt',
  'role_changed': 'Rolle geändert',
  'family_role_set': 'Familienrolle geändert',
  'login_ok': 'Anmeldung',
  'login_failed': 'Fehlgeschlagene Anmeldung',
  'device_added': 'Neues Gerät angemeldet',
  'device_removed': 'Gerät abgemeldet',
  'logout': 'Abmeldung',
  'logout_all': 'Überall abgemeldet',
  'session_reuse_detected': 'Sitzung mehrfach verwendet (widerrufen)',
  'session_refresh_retry': 'Sitzung erneuert (Wiederholung)',
  'step_up_ok': 'Identität bestätigt',
  'step_up_failed': 'Bestätigung fehlgeschlagen',
  'passkey_added': 'Passkey hinzugefügt',
  'passkey_removed': 'Passkey entfernt',
  'passkey_counter_regression': 'Passkey-Zähler zurückgesprungen',
  'password_added': 'Passwort eingerichtet',
  'password_setup_failed': 'Passwort-Einrichtung fehlgeschlagen',
  'password_changed': 'Passwort geändert',
  'password_removed': 'Passwort entfernt',
  'password_authkey_set': 'Passwort-Prüfwert gesetzt',
  'recovery_codes_created': 'Wiederherstellungscodes erzeugt',
  'recovery_code_used': 'Wiederherstellungscode benutzt',
  'ws_auth_failed': 'Live-Verbindung abgelehnt',
  'key_created': 'Verschlüsselungsschlüssel angelegt',
  'key_rotated': 'Verschlüsselungsschlüssel erneuert',
  'backup_set': 'Schlüssel-Sicherung gespeichert',
  'key_backup_read': 'Schlüssel-Sicherung gelesen',
  'transfer_claimed': 'Gerät verbunden',
  'key_backup_pw_set': 'Passwort-Sicherung gespeichert',
  'key_backup_pw_read': 'Passwort-Sicherung gelesen',
  'key_backup_pw_verified': 'Passwort-Sicherung bestätigt',
  'operator_granted': 'Betreiber-Rolle vergeben (Server)',
  'operator_revoked': 'Betreiber-Rolle entzogen (Server)',
  'operator_alert_cert': 'Betrieb-Warnung: Zertifikat',
  'operator_alert_backup': 'Betrieb-Warnung: Sicherung',
  'operator_alert_database': 'Betrieb-Warnung: Datenbank',
  'operator_alert_ntfy': 'Betrieb-Warnung: Push-Wecker (ntfy)',
  'operator_alert_disk': 'Betrieb-Warnung: Speicherplatz',
  'operator_alert_logins': 'Betrieb-Warnung: Fehlanmeldungen',
  'operator_alert_key': 'Betrieb-Warnung: Schlüssel-Ampel',
  'operator_alert_nas_pull': 'Betrieb-Warnung: Abholung durch das NAS',
  'operator_alert_nas_restore': 'Betrieb-Warnung: Wiederherstellungstest',
  'operator_warnings_set': 'Betrieb-Warnungen umgestellt',
  'operator_unlock': 'Konto entsperrt',
  'operator_maintenance_set': 'Wartungsmodus umgeschaltet',
  'operator_notice_set': 'Familienhinweis geändert',
};

String ereignisText(String code) => _ereignisse[code] ?? 'Ereignis';

Color artFarbe(ProtokollArt a) => switch (a) {
  ProtokollArt.fehler => kDanger,
  ProtokollArt.anmeldung => kTerminal,
  _ => kTextMuted,
};

// ------------------------------------------------------------------ Paket 2a

/// Farbe einer Ampel ([BetriebAmpel.unbekannt]: neutral, nie grün).
Color ampelFarbe(BetriebAmpel a) => switch (a) {
  BetriebAmpel.gruen => kTerminal,
  BetriebAmpel.gelb => kWarn,
  BetriebAmpel.rot => kDanger,
  BetriebAmpel.unbekannt => kTextMuted,
};

/// Kurzwort der Ampel in der Pille.
String ampelText(BetriebAmpel a) => switch (a) {
  BetriebAmpel.gruen => 'grün',
  BetriebAmpel.gelb => 'gelb',
  BetriebAmpel.rot => 'rot',
  BetriebAmpel.unbekannt => 'unbekannt',
};

/// Erklärung der Ampel einer Person in einem Satz (für die Zeile unter dem Namen und für Screenreader).
String ampelErklaerung(SchluesselPerson p) {
  if (!p.hatSchluessel) return 'noch kein Schlüssel eingerichtet';
  return switch (p.ampel) {
    BetriebAmpel.gruen => 'geschützt: ${p.wege.anzahl} unabhängige Wege zum Schlüssel',
    BetriebAmpel.gelb => p.wege.geraet ? 'nur ein Weg: ein Gerät, keine Sicherung' : 'Sicherungen vorhanden, aber kein Gerät mit dem Schlüssel',
    BetriebAmpel.rot => p.wege.anzahl == 0 ? 'kein Weg zum Schlüssel' : 'nur eine Sicherung und kein Gerät mit dem Schlüssel',
    BetriebAmpel.unbekannt => 'Stand unbekannt',
  };
}

/// Familienampel in der Übersicht: kurze Aussage zum Stichtag.
String familienAmpelText(SchluesselStatus s) {
  if (s.anzahl == 0) return 'keine Mitglieder';
  if (s.bereit) return 'alle grün: Stichtag-bereit';
  final teile = [if (s.rot > 0) '${s.rot} rot', if (s.gelb > 0) '${s.gelb} gelb'];
  return '${s.gruen} von ${s.anzahl} grün${teile.isEmpty ? '' : ' (${teile.join(', ')})'}, noch nicht Stichtag-bereit';
}

/// Stand des Schlüssels auf einem Gerät in einem Wort.
String geraetSchluesselText(GeraeteSchluesselStand s) => switch (s) {
  GeraeteSchluesselStand.aktuell => 'Schlüssel aktuell',
  GeraeteSchluesselStand.veraltet => 'Meldung über 30 Tage alt',
  GeraeteSchluesselStand.alterSchluessel => 'alter Schlüssel',
  GeraeteSchluesselStand.keiner => 'kein Schlüssel',
  GeraeteSchluesselStand.unbekannt => 'Stand unbekannt',
};

Color geraetSchluesselFarbe(GeraeteSchluesselStand s) => switch (s) {
  GeraeteSchluesselStand.aktuell => kTerminal,
  GeraeteSchluesselStand.veraltet || GeraeteSchluesselStand.alterSchluessel => kWarn,
  GeraeteSchluesselStand.keiner => kDanger,
  GeraeteSchluesselStand.unbekannt => kTextMuted,
};

const _schluesselEreignisse = <String, String>{
  'key_rotated': 'Schlüssel gewechselt',
  'key_backup_replaced': 'Sicherung ersetzt',
  'key_backup_read': 'Sicherung abgerufen',
  'key_backup_pw_read': 'Passwort-Sicherung abgerufen',
  'key_backup_archive_read': 'Archiv abgerufen',
  'key_transfer_created': 'Geräte-Übertragung angelegt',
  'key_transfer_claimed': 'Gerät verbunden',
  'recovery_code_login': 'Anmeldung mit Wiederherstellungscode',
};

String schluesselEreignisText(String art) => _schluesselEreignisse[art] ?? 'Ereignis';

/// Klartext zu den Warnarten (feste Liste des Servers; Unbekanntes heißt allgemein "Hinweis").
String warnArtText(String art) => switch (art) {
  'cert' => 'Zertifikat läuft in weniger als 14 Tagen ab',
  'backup' => 'Letzte Sicherung ist älter als 36 Stunden',
  'database' => 'Datenbank nicht erreichbar',
  'ntfy' => 'Push-Wecker (ntfy) nicht erreichbar',
  'disk' => 'Speicherplatz über 85 % belegt',
  'logins' => 'Viele fehlgeschlagene Anmeldungen',
  'key' => 'Schlüssel-Ampel einer Person ist rot',
  'nas_pull' => 'Das NAS hat die Sicherung seit über 36 Stunden nicht abgeholt (oder die Abholung ist fehlgeschlagen)',
  'nas_restore' => 'Der Wiederherstellungstest ist älter als 10 Tage oder fehlgeschlagen',
  _ => 'Hinweis des Servers',
};

/// Eine Zeile der Warnliste: der feste Text zur Art, bei mehreren (Schlüssel-Ampel mehrerer Personen) mit der Anzahl.
String warnZeile(String art, int anzahl) => anzahl > 1 ? '${warnArtText(art)} ($anzahl)' : warnArtText(art);

/// Feste Wörter der Plattform in der Geräteliste ("android" wird "Android").
String plattformText(String p) => switch (p) {
  'android' => 'Android',
  'web' => 'Web',
  '' => 'Gerät',
  _ => p.length > 16 ? p.substring(0, 16) : p,
};

/// Feste Wörter zu den Fehlercodes des Wetter-Dienstes (Codes des Servers, nie ein Rohtext; Unbekanntes heißt allgemein "Fehler beim Abruf").
String wetterFehlerText(String code) {
  if (RegExp(r'^http_\d{3}$').hasMatch(code)) return 'Antwort des Wetterdienstes mit Fehlercode (${code.substring(5)})';
  return switch (code) {
    'network' => 'Wetterdienst nicht erreichbar',
    'invalid_grant' => 'Zugangsdaten ungültig',
    'auth_rejected' => 'Zugang vom Wetterdienst abgelehnt',
    'station_not_found' => 'Station nicht in der Antwort',
    'measurement_old' => 'Messung zu alt',
    'rotate_persist' => 'neues Zugangstoken nur ersatzweise gespeichert',
    'too_large' => 'Antwort zu groß',
    'bad_json' => 'Antwort nicht lesbar',
    'token_bad' => 'Zugangstoken unbrauchbar',
    _ when code.startsWith('token_http_') => 'Token-Abruf abgelehnt',
    _ => 'Fehler beim Abruf',
  };
}

/// App-Stand eines Geräts in einem Wort (feste Texte zu den festen Codes des Servers).
String appStandText(AppStand s) => switch (s) {
  AppStand.aktuell => 'aktuell',
  AppStand.aelter => 'ältere Version',
  AppStand.unterMindestversion => 'Update nötig',
  AppStand.inaktiv => 'lange nicht gesehen',
  AppStand.unbekannt => 'Version unbekannt',
};

Color appStandFarbe(AppStand s) => switch (s) {
  AppStand.aktuell => kTerminal,
  AppStand.aelter => kWarn,
  AppStand.unterMindestversion => kDanger,
  AppStand.inaktiv || AppStand.unbekannt => kTextMuted,
};

/// Dauer der Anmeldesperre: "noch 45 s" bzw. "noch 2 Min".
String sperreText(int sekunden) => sekunden < 90 ? 'noch $sekunden s' : 'noch ${(sekunden / 60).ceil()} Min';
