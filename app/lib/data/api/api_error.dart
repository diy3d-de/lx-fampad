// Fehler des API-Clients mit verständlichen deutschen Meldungen. Gezeigt wird nie ein Text vom Server oder eine
// Systemmeldung (Interna), sondern nur die hier festgelegte Meldung je Fehlercode.
import 'dart:async';

import 'package:http/http.dart' as http;

enum ApiErrorKind {
  /// Keine Verbindung / Zeitüberschreitung.
  netzwerk,

  /// Nicht angemeldet bzw. Sitzung abgelaufen (401 an einer geschützten Stelle).
  nichtAngemeldet,

  /// Erneute Bestätigung nötig (403 step_up_required).
  stepUpNoetig,

  /// Zu viele Anfragen / verzögerte Sperre (429).
  zuVieleAnfragen,

  /// Server überlastet (503 server_busy).
  serverBusy,

  /// Konto wartet auf Freigabe (403 account_pending).
  kontoWartet,

  /// Antwort entspricht nicht der Schnittstelle.
  protokoll,

  /// Der Server spricht ein neueres Protokoll: die App muss aktualisiert werden (426 update_required).
  updateNoetig,

  /// Alles andere (Eingabe falsch, Konflikt, nicht erlaubt, Serverfehler ...).
  sonstiges,
}

class ApiException implements Exception {
  final ApiErrorKind kind;
  final int status;

  /// Fehlercode des Servers (z. B. `invalid_credentials`), leer bei Netzwerkfehlern.
  final String code;

  /// Meldung für die Anzeige (Deutsch, ohne Interna).
  final String message;

  /// Wartezeit bei 429/503 (Header `Retry-After`).
  final Duration? retryAfter;

  const ApiException({required this.kind, required this.status, required this.code, required this.message, this.retryAfter});

  bool get istStepUp => kind == ApiErrorKind.stepUpNoetig;
  bool get istNetzwerk => kind == ApiErrorKind.netzwerk;

  bool hatCode(String c) => code == c;

  @override
  String toString() => 'ApiException($status $code)';

  static const keineVerbindung = ApiException(
    kind: ApiErrorKind.netzwerk,
    status: 0,
    code: 'network',
    message: 'Keine Verbindung zum Server. Prüfe dein Netz und versuche es erneut.',
  );

  static const zeitueberschreitung = ApiException(
    kind: ApiErrorKind.netzwerk,
    status: 0,
    code: 'timeout',
    message: 'Der Server antwortet nicht. Bitte versuche es gleich noch einmal.',
  );

  /// Hintergrund-Abgleich ohne Refresh-Erlaubnis und abgelaufenes Access-Token: wie "kein Netz", die Sitzung bleibt unberührt.
  static const zugangAbgelaufen = ApiException(
    kind: ApiErrorKind.netzwerk,
    status: 0,
    code: 'access_expired',
    message: 'Die Anmeldung muss erst in der App erneuert werden.',
  );

  static const unerwarteteAntwort = ApiException(
    kind: ApiErrorKind.protokoll,
    status: 0,
    code: 'protocol',
    message: 'Die Antwort des Servers war unerwartet. Vielleicht ist ein Update der App nötig.',
  );

  /// Baut den Fehler aus Status, Fehlercode und (optional) Retry-After in Sekunden.
  factory ApiException.vonAntwort({required int status, required String code, int? retryAfterSekunden}) {
    final warte = retryAfterSekunden == null || retryAfterSekunden < 0 ? null : Duration(seconds: retryAfterSekunden > 86400 ? 86400 : retryAfterSekunden); // vor der Umrechnung gedeckelt (Überlauf)
    String wartetext(String basis) {
      if (warte == null) return basis;
      final s = warte.inSeconds;
      return '$basis Bitte warte ${s == 1 ? 'eine Sekunde' : '$s Sekunden'}.';
    }

    if (code == 'step_up_required') {
      return ApiException(
        kind: ApiErrorKind.stepUpNoetig,
        status: status,
        code: code,
        message: 'Bitte bestätige diese Aktion noch einmal mit Passkey oder Code.',
      );
    }
    // gesperrt wegen einer Anmeldung per Wiederherstellungscode oder eines Zurücksetzens: mit Dauer, wenn der Server sie nennt
    if (code == 'destructive_locked') {
      return ApiException(
        kind: ApiErrorKind.sonstiges,
        status: status,
        code: code,
        retryAfter: warte,
        message:
            'Aus Sicherheitsgründen ist das gerade gesperrt, weil du dich erst vor Kurzem mit einem Wiederherstellungscode angemeldet oder dein Konto zurückgesetzt hast. '
            '${warte == null ? 'Versuche es später noch einmal.' : 'Das ist frühestens in ${_dauerText(warte)} wieder möglich.'}',
      );
    }
    if (status == 429 || code == 'too_many_attempts' || code == 'rate_limited') {
      return ApiException(
        kind: ApiErrorKind.zuVieleAnfragen,
        status: status,
        code: code,
        retryAfter: warte,
        message: wartetext('Zu viele Versuche.'),
      );
    }
    // Push ist auf dem Server nicht eingerichtet: kein Überlast-Hinweis (503 ist hier ein dauerhafter Zustand)
    if (code == 'push_unavailable') {
      return ApiException(kind: ApiErrorKind.sonstiges, status: status, code: code, message: _texte[code]!);
    }
    if (status == 503) {
      return ApiException(
        kind: ApiErrorKind.serverBusy,
        status: status,
        code: code,
        retryAfter: warte,
        message: wartetext('Der Server ist gerade ausgelastet.'),
      );
    }
    if (status == 426 || code == 'update_required') {
      return ApiException(
        kind: ApiErrorKind.updateNoetig,
        status: status,
        code: code,
        message: 'Bitte aktualisiere die App, damit der Abgleich wieder funktioniert.',
      );
    }
    if (code == 'account_pending') {
      return ApiException(
        kind: ApiErrorKind.kontoWartet,
        status: status,
        code: code,
        message: 'Dein Konto wartet noch auf die Freigabe durch einen Admin.',
      );
    }
    final text = _texte[code];
    final kind = (status == 401 && (code == 'unauthenticated' || code == 'invalid_token'))
        ? ApiErrorKind.nichtAngemeldet
        : ApiErrorKind.sonstiges;
    return ApiException(kind: kind, status: status, code: code, message: text ?? _nachStatus(status));
  }

  /// "5 Minuten", "3 Stunden", "2 Tagen" (aufgerundet; für "frühestens in …").
  static String _dauerText(Duration d) {
    final sek = d.inSeconds < 1 ? 1 : d.inSeconds;
    final min = (sek / 60).ceil();
    if (min < 60) return min == 1 ? 'einer Minute' : '$min Minuten';
    final std = (sek / 3600).ceil();
    if (std <= 1) return 'einer Stunde';
    if (std < 48) return '$std Stunden';
    return '${(sek / 86400).ceil()} Tagen';
  }

  static String _nachStatus(int status) {
    if (status == 401) return 'Du bist nicht angemeldet.';
    if (status == 403) return 'Dazu fehlt dir die Berechtigung.';
    if (status == 404) return 'Das wurde nicht gefunden.';
    if (status == 409) return 'Das ist so gerade nicht möglich.';
    if (status == 413) return 'Die Anfrage ist zu groß.';
    if (status >= 500) return 'Auf dem Server ist ein Fehler aufgetreten. Bitte versuche es später erneut.';
    return 'Die Eingabe wurde abgelehnt. Bitte prüfe sie.';
  }

  static const _texte = <String, String>{
    'invalid_request': 'Die Eingabe ist nicht gültig. Bitte prüfe sie.',
    'invalid_credentials': 'Die Anmeldung hat nicht geklappt. Prüfe E-Mail, Passwort und Code.',
    'unauthenticated': 'Du bist nicht angemeldet.',
    'invalid_token': 'Deine Anmeldung ist abgelaufen. Bitte melde dich neu an.',
    'step_up_failed': 'Die Bestätigung hat nicht geklappt. Bitte versuche es noch einmal.',
    'forbidden': 'Dazu fehlt dir die Berechtigung.',
    'csrf_invalid': 'Die Anfrage wurde abgelehnt. Bitte lade die Seite neu.',
    'origin_not_allowed': 'Die Anfrage wurde abgelehnt. Bitte lade die Seite neu.',
    'invite_invalid': 'Die Einladung ist ungültig oder abgelaufen, oder die PIN stimmt nicht.',
    'invite_not_open': 'Die Einladung ist nicht mehr offen.',
    'weak_password': 'Das Passwort ist zu schwach. Nimm mindestens 12 Zeichen.',
    'challenge_invalid': 'Der Vorgang ist abgelaufen. Bitte beginne noch einmal von vorn.',
    'invalid_code': 'Der Code stimmt nicht. Prüfe ihn und versuche es noch einmal.',
    'registration_failed': 'Die Registrierung ist mit diesen Angaben nicht möglich. Prüfe sie oder frage bei der Familie nach.',
    'last_admin': 'Der letzte Admin kann nicht herabgestuft oder entfernt werden.',
    'last_credential': 'Das ist dein letzter Zugang. Lege zuerst einen anderen an.',
    'password_exists': 'Für dein Konto gibt es schon ein Passwort. Du kannst es ändern.',
    'no_password': 'Für dein Konto ist noch kein Passwort eingerichtet.',
    'cannot_reset_self': 'Dein eigenes Passwort änderst du im Profil, oder du nutzt auf der Anmeldeseite „Passwort vergessen?“.',
    'no_second_factor': 'Für dieses Konto ist kein Authenticator eingerichtet.',
    'not_active': 'Dieses Mitglied ist nicht aktiv.',
    'email_mismatch': 'Die E-Mail-Adresse gehört nicht zu diesem Passkey.',
    'no_passkey': 'Für dein Konto ist noch kein Passkey eingerichtet.',
    'passkey_exists': 'Für dieses Gerät gibt es schon einen Passkey.',
    'not_pending': 'Dieses Mitglied wartet nicht auf eine Freigabe.',
    'cannot_remove_self': 'Du kannst dich nicht selbst entfernen.',
    'multiple_families': 'Dieses Konto gehört zu mehreren Familien. Das geht hier noch nicht.',
    'already_bootstrapped': 'Die Familie ist schon eingerichtet.',
    'not_found': 'Das wurde nicht gefunden.',
    'keys_exist': 'Für dein Konto gibt es schon einen Schlüssel.',
    'no_keys': 'Du hast die Verschlüsselung noch nicht eingerichtet.',
    'transfer_conflict': 'Das hat gerade nicht geklappt. Bitte versuche es noch einmal.',
    'key_version_mismatch': 'Der Schlüssel hat sich inzwischen geändert. Bitte öffne die Ansicht neu.',
    'payload_too_large': 'Die Anfrage ist zu groß.',
    'device_mismatch': 'Dieses Gerät passt nicht mehr zur Anmeldung. Bitte versuche es gleich noch einmal.',
    'invalid_endpoint':
        'Der Push-Endpunkt gehört nicht zum Familien-Server. Trage in der ntfy-App unter Einstellungen den Standardserver https://ntfy.familie.lx-labs.dev ein und schalte Benachrichtigungen dann neu ein.',
    'endpoint_in_use': 'Dieser Push-Endpunkt ist schon vergeben. Schalte Benachrichtigungen aus und wieder ein.',
    'push_unavailable': 'Push ist auf dem Server noch nicht eingerichtet.',
    'no_endpoint': 'Für dieses Gerät ist Push noch nicht angemeldet.',
    'no_device': 'Für diese Anmeldung gibt es kein Gerät. Melde dich neu an.',
    'legacy_login_disabled': 'Diese App-Version ist zu alt für die Anmeldung. Bitte aktualisiere die App.',
    'password_change_needs_update': 'Zum Ändern des Passworts brauchst du die neueste App-Version. Bitte aktualisiere die App.',
    'backup_not_current': 'Die Passwort-Sicherung ist nicht mehr aktuell. Bitte versuche es noch einmal.',
    'internal_error': 'Auf dem Server ist ein Fehler aufgetreten. Bitte versuche es später erneut.',
  };
}

/// Wandelt Fehler beim Senden in einen [ApiException] um.
ApiException netzwerkFehler(Object e) {
  if (e is TimeoutException) return ApiException.zeitueberschreitung;
  return ApiException.keineVerbindung;
}

/// Der Verbindungsaufbau scheiterte (Adresse nicht auflösbar, Verbindung abgelehnt, Netz weg, TLS-Aushandlung, Zeitlimit beim
/// Aufbau), bevor irgendein Byte der Anfrage gesendet wurde. Wirft der Android-Client ([PhasenClient]); der Browser-Client kann
/// das nicht unterscheiden.
class VerbindungsaufbauFehler extends http.ClientException {
  VerbindungsaufbauFehler(super.message, [super.uri]);
}

/// true, wenn der Fehler mit Sicherheit auftrat, BEVOR die Anfrage den Server erreichen konnte ([VerbindungsaufbauFehler]).
/// Dann ist ein erneuter Versuch gefahrlos. Bei Zeitüberschreitung der Antwort oder Abbruch mitten in der Übertragung ist unklar,
/// ob der Server die Anfrage verarbeitet hat (beim Refresh-Token wäre ein blindes Wiederholen riskant: der Server widerruft bei
/// Wiederverwendung die Token-Familie, nur ein kurzes Toleranzfenster fängt eine verlorene Antwort auf).
/// Die Einstufung hängt nur vom Typ der Ausnahme ab, nie vom Meldungstext.
bool vorDemSenden(Object e) => e is VerbindungsaufbauFehler;
