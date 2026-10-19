// Vertragsprüfung gegen den ECHTEN Server (gebauter Server aus server/, PostgreSQL 17): die App-Klassen (ApiClient, FampadApi, DTOs,
// Einladungslink-Parser, Passkey-Optionen) rufen die von der App genutzten Endpunkte einmal real auf.
// Gehört NICHT zu 'flutter test' (echte Netzverbindung, ändert die Datenbank, dauert ca. 1 Minute wegen der TOTP-Zeitschritte).
// Ablauf: frische Datenbank migrieren, 'node dist/cli/bootstrap.js --family "Familie Vertrag"' (Token aus dem Link), Server starten, dann
//   SERVER=http://127.0.0.1:4460 INVITE_TOKEN=<Token> SERVER_DIR=<server/-Ordner mit node_modules> DATABASE_URL=postgres://… flutter test test/vertrag_test.dart
// (die Datei dazu aus tool/ nach test/ kopieren; sie initialisiert kein Widget-Binding, damit HTTP echt läuft).
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:lx_fampad/data/api/api_client.dart';
import 'package:lx_fampad/data/api/api_error.dart';
import 'package:lx_fampad/data/api/fampad_api.dart';
import 'package:lx_fampad/data/api/models.dart';
import 'package:lx_fampad/data/api/token_store.dart';
import 'package:lx_fampad/data/passkey_service.dart';
import 'package:lx_fampad/features/auth/invite_link.dart';
import 'package:passkeys/types.dart' show AuthenticateRequestType, RegisterRequestType;

final server = Platform.environment['SERVER'] ?? 'http://127.0.0.1:4460';
final adminToken = Platform.environment['INVITE_TOKEN']!;
final serverDir = Platform.environment['SERVER_DIR'] ?? '../server';
final datenbank = Platform.environment['DATABASE_URL']!;

/// Zählt Anfragen je Pfad und merkt sich Cookies (Web-Modus).
class Spion extends http.BaseClient {
  final http.Client _inner = IOClient();
  final List<String> pfade = [];
  final Map<String, String> cookies = {};
  final bool cookiesNutzen;
  Spion({this.cookiesNutzen = false});

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    pfade.add('${request.method} ${request.url.path}');
    if (cookiesNutzen && cookies.isNotEmpty) request.headers['cookie'] = cookies.entries.map((e) => '${e.key}=${e.value}').join('; ');
    final res = await _inner.send(request);
    final sc = res.headersSplitValues['set-cookie'];
    if (cookiesNutzen && sc != null) {
      for (final c in sc) {
        final kv = c.split(';').first;
        final i = kv.indexOf('=');
        final name = kv.substring(0, i), value = kv.substring(i + 1);
        if (value.isEmpty || c.toLowerCase().contains('max-age=0') || c.contains('1970')) {
          cookies.remove(name);
        } else {
          cookies[name] = value;
        }
      }
    }
    return res;
  }

  int zaehle(String p) => pfade.where((x) => x == p).length;
}

class Gegenstelle {
  final Spion spion;
  final MemoryTokenStore store = MemoryTokenStore();
  late final ApiClient client;
  late final FampadApi api;
  Gegenstelle({bool web = false, DateTime Function()? now, String name = 'Contract-Test'})
    : spion = Spion(cookiesNutzen: web) {
    client = ApiClient(client: spion, store: store, web: web, base: server, now: now);
    api = FampadApi(client, geraet: () async => DeviceInfo(id: await store.readDeviceId(), name: name, platform: 'android', appVersion: '0.1.0'));
  }
}

// ---------------------------------------------------------------------------------------------------- TOTP (RFC 6238)

List<int> base32(String s) {
  const abc = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
  var bits = 0, wert = 0;
  final out = <int>[];
  for (final ch in s.toUpperCase().replaceAll('=', '').split('')) {
    wert = (wert << 5) | abc.indexOf(ch);
    bits += 5;
    if (bits >= 8) {
      out.add((wert >> (bits - 8)) & 0xff);
      bits -= 8;
    }
  }
  return out;
}

String totp(String secret, int schritt) {
  final msg = List<int>.filled(8, 0);
  var s = schritt;
  for (var i = 7; i >= 0; i--) {
    msg[i] = s & 0xff;
    s >>= 8;
  }
  final h = Hmac(sha1, base32(secret)).convert(msg).bytes;
  final o = h.last & 0xf;
  final bin = ((h[o] & 0x7f) << 24) | (h[o + 1] << 16) | (h[o + 2] << 8) | h[o + 3];
  return (bin % 1000000).toString().padLeft(6, '0');
}

final Map<String, int> _letzterSchritt = {};

/// Code für einen Zeitschritt, der noch nie benutzt wurde (der Server lässt jeden Schritt nur einmal zu): wartet notfalls.
Future<String> frischerCode(String secret) async {
  while (true) {
    final schritt = DateTime.now().millisecondsSinceEpoch ~/ 30000;
    if (schritt > (_letzterSchritt[secret] ?? 0)) {
      _letzterSchritt[secret] = schritt;
      return totp(secret, schritt);
    }
    await Future<void>.delayed(const Duration(seconds: 1));
  }
}

/// Setzt die letzte Bestätigung (Step-up) aller Sitzungen in der Datenbank zurück, um 403 step_up_required real auszulösen.
Future<void> stepUpAltern() async {
  final r = await Process.run('node', [
    '-e',
    "const pg=require('pg');(async()=>{const c=new pg.Client({connectionString:process.env.DATABASE_URL});await c.connect();"
        "await c.query(\"update sessions set step_up_at = now() - interval '10 minutes'\");await c.end()})()",
  ], workingDirectory: serverDir, environment: {'DATABASE_URL': datenbank});
  expect(r.exitCode, 0, reason: '${r.stderr}');
}

void schritt(String s) => stdout.writeln('--- $s');

void main() {
  test('Vertrag App <-> echter Server', timeout: const Timeout(Duration(minutes: 8)), () async {
    // ---------------------------------------------------------------- Anmeldeoptionen ohne Anmeldung
    schritt('Passkey-Anmeldeoptionen werden vom Paket verstanden');
    final anon = Gegenstelle();
    final loginOpt = await anon.api.passkeyAnmeldeOptionen();
    final authReq = AuthenticateRequestType.fromJson(normalisiereOptionen(loginOpt.options));
    expect(authReq.relyingPartyId, 'familie.lx-labs.dev');
    expect(authReq.userVerification, 'required');
    expect(authReq.challenge, isNotEmpty);

    // ---------------------------------------------------------------- Erster Admin (Passwort + TOTP)
    schritt('Einladung prüfen, parser, Passkey-Registrierungsoptionen');
    final admin = Gegenstelle(name: 'Pixel 9');
    final info = await admin.api.einladungPruefen(adminToken);
    expect(info.role, Role.admin);
    expect(info.familyName, 'Familie Vertrag');
    expect(info.pinRequired, isFalse);
    expect(parseInviteToken('https://familie.lx-labs.dev/#/einladung/$adminToken'), adminToken);

    final pkOpt = await admin.api.passkeyRegistrierungStart(token: adminToken, email: 'anna@beispiel.de', anzeigename: 'Anna');
    final regReq = RegisterRequestType.fromJson(normalisiereOptionen(pkOpt.options));
    expect(regReq.relyingParty.id, 'familie.lx-labs.dev');
    expect(regReq.user.name, 'anna@beispiel.de');
    expect(regReq.authSelectionType!.userVerification, 'required');
    expect(regReq.pubKeyCredParams, isNotEmpty);

    schritt('Passwort-Registrierung: Start (Secret, otpauth) und Bestätigung mit TOTP');
    final start = await admin.api.passwortRegistrierungStart(
      token: adminToken,
      passwort: 'Contract-Passwort-12',
      email: 'anna@beispiel.de',
      anzeigename: 'Anna',
    );
    expect(start.totpUri, startsWith('otpauth://totp/'));
    expect(start.totpUri, contains(start.totpSecret));
    final secretAdmin = start.totpSecret;
    final reg = await admin.api.passwortRegistrierungFertig(challengeId: start.challengeId, code: await frischerCode(secretAdmin));
    expect(reg.status, MemberStatus.active);
    expect(reg.recoveryCodes, hasLength(10));
    expect(RegExp(r'^[A-Z0-9]{4}(-[A-Z0-9]{4}){3}$').hasMatch(reg.recoveryCodes.first), isTrue);
    expect(reg.session!.istApp, isTrue);
    await admin.client.sitzungUebernehmen(reg.session!);
    final adminId = reg.member.id;

    schritt('Einladung ist verbraucht (eine Antwort für alle Fälle)');
    await expectLater(anon.api.einladungPruefen(adminToken), throwsA(isA<ApiException>().having((e) => e.code, 'code', 'invite_invalid')));

    schritt('/me, Zugänge, Geräte, Mitglieder, Einladungen');
    var me = await admin.api.ich();
    expect(me.user.role, Role.admin);
    expect(me.user.email, 'anna@beispiel.de');
    expect(me.hasPassword && me.hasTotp, isTrue);
    expect(me.passkeys, 0);
    expect(me.recoveryCodesRemaining, 10);
    final zugaenge = await admin.api.zugaenge();
    expect(zugaenge.map((c) => c.type).toSet(), {'password', 'totp'});
    final geraete = await admin.api.geraete();
    expect(geraete.single.current, isTrue);
    expect(geraete.single.name, 'Pixel 9');
    expect(geraete.single.platform, 'android');
    expect(geraete.single.appVersion, '0.1.0');
    expect((await admin.api.mitglieder()).single.id, adminId);
    expect((await admin.api.einladungen()).where((i) => i.status == InviteStatus.open), isEmpty);
    await admin.api.profilAendern(anzeigename: 'Anna A.', farbe: 4);
    me = await admin.api.ich();
    expect((me.user.displayName, me.user.colorIndex), ('Anna A.', 4));

    // ---------------------------------------------------------------- Einladungen
    schritt('Kind-Einladung mit PIN: erstellen, Liste, Parser auf den Link');
    final kindInv = await admin.api.einladungErstellen(rolle: Role.child, stunden: 24, pin: true);
    expect(kindInv.pin, matches(RegExp(r'^\d{6}$')));
    expect(parseInviteToken(kindInv.link), kindInv.token);
    expect(kindInv.requireApproval, isFalse);
    final liste = (await admin.api.einladungen()).firstWhere((i) => i.id == kindInv.id);
    expect(liste.status, InviteStatus.open);
    expect(liste.hasPin, isTrue);
    expect(liste.role, Role.child);

    schritt('Registrierung des Kindes: falsche PIN -> invite_invalid, richtige PIN -> Konto');
    final kind = Gegenstelle(name: 'Kinder-Handy');
    final kindInfo = await kind.api.einladungPruefen(kindInv.token);
    expect(kindInfo.pinRequired, isTrue);
    await expectLater(
      kind.api.passwortRegistrierungStart(token: kindInv.token, passwort: 'Kind-Passwort-123', pin: '000000', email: 'ben@beispiel.de', anzeigename: 'Ben'),
      throwsA(isA<ApiException>().having((e) => e.code, 'code', 'invite_invalid').having((e) => e.message, 'message', contains('PIN'))),
    );
    final kStart = await kind.api.passwortRegistrierungStart(
      token: kindInv.token,
      passwort: 'Kind-Passwort-123',
      pin: kindInv.pin,
      email: 'ben@beispiel.de',
      anzeigename: 'Ben',
    );
    final kReg = await kind.api.passwortRegistrierungFertig(challengeId: kStart.challengeId, code: await frischerCode(kStart.totpSecret));
    await kind.client.sitzungUebernehmen(kReg.session!);
    final kindId = kReg.member.id;
    expect((await kind.api.ich()).user.role, Role.child);
    // Kinder verwalten keine Einladungen
    await expectLater(kind.api.einladungen(), throwsA(isA<ApiException>().having((e) => e.status, 'status', 403)));

    schritt('Gast-Einladung (Freigabe Standard): pending, Anmeldung 403 account_pending, Freigabe, dann Anmeldung');
    final gastInv = await admin.api.einladungErstellen(rolle: Role.guest, stunden: 6, pin: false);
    expect(gastInv.requireApproval, isTrue);
    final gast = Gegenstelle(name: 'Omas Tablet');
    final gStart = await gast.api.passwortRegistrierungStart(token: gastInv.token, passwort: 'Gast-Passwort-1234', email: 'oma@beispiel.de', anzeigename: 'Oma');
    final gReg = await gast.api.passwortRegistrierungFertig(challengeId: gStart.challengeId, code: await frischerCode(gStart.totpSecret));
    expect(gReg.status, MemberStatus.pending);
    expect(gReg.session, isNull);
    expect(gReg.recoveryCodes, hasLength(10));
    await expectLater(
      gast.api.passwortAnmelden(email: 'oma@beispiel.de', passwort: 'Gast-Passwort-1234', wiederherstellungscode: gReg.recoveryCodes.first),
      throwsA(isA<ApiException>().having((e) => e.kind, 'kind', ApiErrorKind.kontoWartet)),
    );
    var mitglieder = await admin.api.mitglieder();
    final oma = mitglieder.firstWhere((m) => m.displayName == 'Oma');
    expect(oma.status, MemberStatus.pending);
    expect(oma.email, 'oma@beispiel.de'); // Admin sieht E-Mail
    await admin.api.freigeben(oma.id);
    // Beobachtung: der Server verbraucht den Code schon bei der abgelehnten Anmeldung (pending) -> der zweite Code wird gebraucht
    final omaLogin = await gast.api.passwortAnmelden(email: 'oma@beispiel.de', passwort: 'Gast-Passwort-1234', wiederherstellungscode: gReg.recoveryCodes[1]);
    expect(omaLogin.user.role, Role.guest);
    expect(omaLogin.session.istApp, isTrue);
    await gast.client.sitzungUebernehmen(omaLogin.session);
    // Nicht-Admins sehen E-Mails anderer nicht
    final sichtKind = await kind.api.mitglieder();
    expect(sichtKind.where((m) => m.id != kindId).every((m) => m.email == null), isTrue);
    expect(sichtKind.firstWhere((m) => m.id == kindId).email, 'ben@beispiel.de');

    schritt('Verlängern (verkürzt nie), Widerrufen');
    final extra = await admin.api.einladungErstellen(rolle: Role.guest, stunden: 24, pin: false);
    final vorher = (await admin.api.einladungen()).firstWhere((i) => i.id == extra.id).expiresAt;
    final neu = await admin.api.einladungVerlaengern(extra.id, 1);
    expect(neu.isBefore(vorher.subtract(const Duration(seconds: 1))), isFalse, reason: 'verkürzt nie');
    await admin.api.einladungWiderrufen(extra.id);
    expect((await admin.api.einladungen()).firstWhere((i) => i.id == extra.id).status, InviteStatus.revoked);
    await expectLater(admin.api.einladungWiderrufen(extra.id), throwsA(isA<ApiException>().having((e) => e.code, 'code', 'invite_not_open')));
    await expectLater(anon.api.einladungPruefen(extra.token), throwsA(isA<ApiException>().having((e) => e.code, 'code', 'invite_invalid')));

    // ---------------------------------------------------------------- Step-up
    schritt('Step-up: Admin-Einladung nach 10 Minuten verlangt Bestätigung (403 step_up_required), TOTP bestätigt, Wiederholung klappt');
    await stepUpAltern();
    await expectLater(
      admin.api.einladungErstellen(rolle: Role.admin, stunden: 1, pin: false),
      throwsA(isA<ApiException>().having((e) => e.istStepUp, 'step-up', isTrue).having((e) => e.message, 'message', contains('bestätige'))),
    );
    await expectLater(admin.api.stepUpCode(totp: '000000'), throwsA(isA<ApiException>().having((e) => e.code, 'code', 'step_up_failed')));
    // Fehlversuch zählt; der Code gilt nur für einen neuen Zeitschritt
    await admin.api.stepUpCode(totp: await frischerCode(secretAdmin));
    final adminInv = await admin.api.einladungErstellen(rolle: Role.admin, stunden: 1, pin: false);
    expect(adminInv.token, isNotEmpty);
    await admin.api.einladungWiderrufen(adminInv.id);

    schritt('Step-up per Passkey: Optionen kommen an (Konto ohne Passkey: nur Fehler, kein Absturz)');
    await expectLater(
      admin.api.stepUpPasskeyOptionen(),
      throwsA(isA<ApiException>().having((e) => e.code, 'code', 'no_passkey').having((e) => e.message, 'message', contains('Passkey'))),
    );

    schritt('Rolle ändern widerruft Sitzungen der Person: Kind wird zu Elternteil, seine App merkt es und meldet ab');
    await admin.api.rolleAendern(kindId, Role.parent);
    var kindVerloren = false;
    kind.client.onSessionLost = (_) => kindVerloren = true;
    await expectLater(kind.api.ich(), throwsA(isA<ApiException>().having((e) => e.kind, 'kind', ApiErrorKind.nichtAngemeldet)));
    expect(kindVerloren, isTrue);
    expect(await kind.store.readTokens(), isNull);

    schritt('Wiederherstellungscode-Anmeldung (Kind, neue Sitzung)');
    final kind2 = Gegenstelle(name: 'Kinder-Handy 2');
    final rec = await kind2.api.wiederherstellungAnmelden(email: 'ben@beispiel.de', code: kReg.recoveryCodes.first);
    expect(rec.user.role, Role.parent);
    expect(rec.recoveryCodesRemaining, 9);
    await kind2.client.sitzungUebernehmen(rec.session);
    // gleicher Code ist verbraucht -> eine Meldung für alle Fälle
    await expectLater(
      Gegenstelle().api.wiederherstellungAnmelden(email: 'ben@beispiel.de', code: kReg.recoveryCodes.first),
      throwsA(isA<ApiException>().having((e) => e.code, 'code', 'invalid_credentials').having((e) => e.message, 'message', isNot(contains('Code ist'))) ),
    );
    // Eltern: Kind-/Gast-Einladungen ja, Elternteil nein
    final nachRolle = await kind2.api.einladungErstellen(rolle: Role.guest, stunden: 1, pin: false);
    expect(nachRolle.requireApproval, isTrue, reason: 'Eltern: Gäste immer mit Freigabe');
    await expectLater(kind2.api.einladungErstellen(rolle: Role.parent, stunden: 1, pin: false), throwsA(isA<ApiException>().having((e) => e.status, 'status', 403)));
    await expectLater(kind2.api.rolleAendern(adminId, Role.guest), throwsA(isA<ApiException>().having((e) => e.status, 'status', 403)));

    schritt('Neue Wiederherstellungscodes (Step-up), alte entfallen');
    final neueCodes = await admin.api.neueWiederherstellungscodes();
    expect(neueCodes, hasLength(10));
    expect((await admin.api.ich()).recoveryCodesRemaining, 10);

    // ---------------------------------------------------------------- Refresh (echte Rotation)
    schritt('Refresh: abgelaufenes Access-Token, fünf gleichzeitige Aufrufe -> genau EIN POST /auth/refresh, Rotation gespeichert');
    // eigenes Gerät (eigene Token-Familie), damit der Admin-Zugang des Tests unberührt bleibt
    final basis = Gegenstelle(name: 'Zeitreise-Basis');
    final basisLogin = await basis.api.passwortAnmelden(email: 'anna@beispiel.de', passwort: 'Contract-Passwort-12', wiederherstellungscode: neueCodes[3]);
    await basis.client.sitzungUebernehmen(basisLogin.session);
    final alt = (await basis.store.readTokens())!;
    final spaeter = Gegenstelle(now: () => DateTime.now().add(const Duration(minutes: 20)), name: 'Zeitreise');
    await spaeter.store.writeTokens(alt);
    await Future.wait([for (var i = 0; i < 5; i++) spaeter.api.ich()]);
    expect(spaeter.spion.zaehle('POST /api/v1/auth/refresh'), 1);
    final rotiert = (await spaeter.store.readTokens())!;
    expect(rotiert.refreshToken, isNot(alt.refreshToken));
    expect(rotiert.accessToken, isNot(alt.accessToken));
    expect(rotiert.deviceId, alt.deviceId);
    // die alte Sitzung des Admin lebt weiter? Rotation betrifft dieselbe Familie: das alte Paar ist ersetzt
    // zweite Erneuerung mit dem NEUEN Paar funktioniert (kein Mehrfach-Einlösen)
    final spaeter2 = Gegenstelle(now: () => DateTime.now().add(const Duration(minutes: 40)), name: 'Zeitreise');
    await spaeter2.store.writeTokens(rotiert);
    await spaeter2.api.ich();
    expect(spaeter2.spion.zaehle('POST /api/v1/auth/refresh'), 1);

    schritt('Wiederverwendung eines alten Refresh-Tokens widerruft die Familie (genau deshalb wird serialisiert)');
    Object? erneut;
    try {
      await spaeter2.client.post('/auth/refresh', {'refreshToken': alt.refreshToken, 'deviceId': alt.deviceId}, false);
    } catch (e) {
      erneut = e;
    }
    expect(erneut, isA<ApiException>().having((e) => e.status, 'status', 401));
    final nachher = Gegenstelle();
    await nachher.store.writeTokens((await spaeter2.store.readTokens())!);
    await expectLater(nachher.api.ich(), throwsA(isA<ApiException>().having((e) => e.kind, 'kind', ApiErrorKind.nichtAngemeldet)));

    // ---------------------------------------------------------------- Sperre / Fehlermeldungen
    schritt('Falsche Anmeldung: invalid_credentials, nach mehreren Fehlversuchen too_many_attempts mit Retry-After');
    final falsch = Gegenstelle();
    ApiException? sperre;
    for (var i = 0; i < 8 && sperre == null; i++) {
      try {
        await falsch.api.passwortAnmelden(email: 'anna@beispiel.de', passwort: 'falsch', totp: '000000');
      } on ApiException catch (e) {
        if (e.kind == ApiErrorKind.zuVieleAnfragen) {
          sperre = e;
        } else {
          expect(e.code, 'invalid_credentials');
          expect(e.message, contains('Anmeldung hat nicht geklappt'));
        }
      }
    }
    expect(sperre, isNotNull, reason: 'verzögerte Sperre nach Fehlversuchen');
    expect(sperre!.retryAfter, isNotNull);
    expect(sperre.retryAfter!.inSeconds, inInclusiveRange(1, 90));
    expect(sperre.message, contains('Bitte warte'));

    // ---------------------------------------------------------------- Web-Modus (Cookie + CSRF)
    schritt('Web-Modus: Anmeldung per Passkey-losem Weg nicht möglich, daher Passwort + TOTP mit client=web, Cookie, CSRF-Header');
    final web = Gegenstelle(web: true);
    // die IP-Sperre der falschen Versuche gilt nur für Konto+IP (30-90 s): hier läuft ein anderes Konto (Oma)
    final secretOma = gStart.totpSecret;
    final w = await web.api.passwortAnmelden(email: 'oma@beispiel.de', passwort: 'Gast-Passwort-1234', totp: await frischerCode(secretOma));
    expect(w.session.istApp, isFalse);
    expect(w.session.csrfToken, isNotEmpty);
    await web.client.sitzungUebernehmen(w.session);
    expect(web.spion.cookies.keys, contains('__Host-lxsid'));
    final webMe = await web.api.ich();
    expect(webMe.csrfToken, w.session.csrfToken);
    expect(webMe.user.displayName, 'Oma');
    // ändernde Anfrage mit CSRF-Header klappt (Gast: Profil ändern)
    await web.api.profilAendern(anzeigename: 'Oma Erna');
    // ohne CSRF-Header: 403 csrf_invalid
    web.client.csrfSetzen(null);
    await expectLater(web.api.profilAendern(anzeigename: 'Oma X'), throwsA(isA<ApiException>().having((e) => e.code, 'code', 'csrf_invalid')));
    web.client.csrfSetzen(webMe.csrfToken);
    expect((await web.api.geraete()).any((d) => d.current && d.platform == 'web'), isTrue);

    // ---------------------------------------------------------------- Zurücksetzen, Entfernen, Geräte, Abmelden
    schritt('Zurücksetzen: neue Einladung für dasselbe Konto (lookup zeigt reset + Name)');
    final resetInv = await admin.api.mitgliedZuruecksetzen(kindId, stunden: 2, pin: false);
    final rl = await anon.api.einladungPruefen(resetInv.token);
    expect(rl.reset, isTrue);
    expect(rl.displayName, 'Ben');
    expect(parseInviteToken(resetInv.link), resetInv.token);
    final rpk = await anon.api.passkeyRegistrierungStart(token: resetInv.token);
    expect(RegisterRequestType.fromJson(normalisiereOptionen(rpk.options)).user.displayName, 'Ben');

    schritt('Mitglied ablehnen / entfernen');
    final g2 = await admin.api.einladungErstellen(rolle: Role.guest, stunden: 1, pin: false);
    final g2c = Gegenstelle();
    final g2s = await g2c.api.passwortRegistrierungStart(token: g2.token, passwort: 'Gast2-Passwort-123', email: 'opa@beispiel.de', anzeigename: 'Opa');
    await g2c.api.passwortRegistrierungFertig(challengeId: g2s.challengeId, code: await frischerCode(g2s.totpSecret));
    final opa = (await admin.api.mitglieder()).firstWhere((m) => m.displayName == 'Opa');
    await admin.api.ablehnen(opa.id);
    expect((await admin.api.mitglieder()).any((m) => m.displayName == 'Opa'), isFalse);
    await admin.api.mitgliedEntfernen(kindId);
    expect((await admin.api.mitglieder()).any((m) => m.id == kindId), isFalse);
    await expectLater(admin.api.mitgliedEntfernen(adminId), throwsA(isA<ApiException>()));

    schritt('Geräte: weiteres Gerät des Admin anlegen, einzeln abmelden, dann überall abmelden');
    final adminZwei = Gegenstelle(name: 'Zweitgerät');
    // das Konto ist nach den Fehlversuchen oben noch verzögert gesperrt: so wartet die App laut Retry-After
    LoginResult? al;
    for (var versuch = 0; versuch < 3 && al == null; versuch++) {
      try {
        al = await adminZwei.api.passwortAnmelden(email: 'anna@beispiel.de', passwort: 'Contract-Passwort-12', wiederherstellungscode: neueCodes.first);
      } on ApiException catch (e) {
        if (e.kind != ApiErrorKind.zuVieleAnfragen) rethrow;
        stdout.writeln('    warte ${e.retryAfter!.inSeconds + 1} s (Retry-After)');
        await Future<void>.delayed(e.retryAfter! + const Duration(seconds: 1));
      }
    }
    expect(al, isNotNull);
    await adminZwei.client.sitzungUebernehmen(al!.session);
    final dev = await admin.api.geraete();
    expect(dev.length, greaterThanOrEqualTo(2));
    final anderes = dev.firstWhere((d) => !d.current && d.name == 'Zweitgerät');
    await admin.api.geraetAbmelden(anderes.id);
    await expectLater(adminZwei.api.ich(), throwsA(isA<ApiException>().having((e) => e.kind, 'kind', ApiErrorKind.nichtAngemeldet)));
    await admin.api.abmelden();
    await expectLater(admin.api.ich(), throwsA(isA<ApiException>()));
    stdout.writeln('--- Vertrag erfüllt');
  });
}
