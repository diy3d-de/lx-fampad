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

/// Gesamtzustand für die Zeile oben auf der Übersicht.
String gesamtText(BetriebStufe s) => switch (s) {
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
};

String ereignisText(String code) => _ereignisse[code] ?? 'Ereignis';

Color artFarbe(ProtokollArt a) => switch (a) {
  ProtokollArt.fehler => kDanger,
  ProtokollArt.anmeldung => kTerminal,
  _ => kTextMuted,
};
