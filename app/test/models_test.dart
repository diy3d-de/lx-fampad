// Model-Parsing gegen Beispielantworten aus docs/API.md (Form wie vom Server geliefert, siehe test/support/fake_server.dart).
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/api/api_error.dart';
import 'package:lx_fampad/data/api/models.dart';

import 'support/fake_server.dart';

void main() {
  test('GET /me', () {
    final me = MeDto.fromJson(meJson(csrf: 'csrf-1', passkeys: 2, password: true, totp: true));
    expect(me.user.displayName, 'Anna');
    expect(me.user.role, Role.admin);
    expect(me.user.status, MemberStatus.active);
    expect(me.passkeys, 2);
    expect(me.hasPassword && me.hasTotp, isTrue);
    expect(me.csrfToken, 'csrf-1');
    expect(me.recoveryCodesRemaining, 8);
    expect(me.sessionDeviceId, fixDevice);
  });

  test('Sitzungen: Web (Cookie + CSRF) und App (Token)', () {
    final w = SessionDto.fromJson(webSession());
    expect(w.istApp, isFalse);
    expect(w.csrfToken, 'csrf-abc');
    final a = SessionDto.fromJson(appSession());
    expect(a.istApp, isTrue);
    expect(a.accessToken, 'access-1');
    expect(a.refreshToken, 'refresh-1');
    expect(a.deviceId, fixDevice);
  });

  test('Anmeldung per Wiederherstellungscode liefert die Restzahl', () {
    final r = LoginResult.fromJson({'user': userJson(), 'session': appSession(), 'recoveryCodesRemaining': 7});
    expect(r.recoveryCodesRemaining, 7);
    expect(LoginResult.fromJson({'user': userJson(), 'session': webSession()}).recoveryCodesRemaining, isNull);
  });

  test('Registrierung: aktiv mit Sitzung und 10 Codes, pending ohne Sitzung', () {
    final aktiv = RegistrationResult.fromJson({'member': userJson(), 'status': 'active', 'recoveryCodes': codes(), 'session': appSession()});
    expect(aktiv.recoveryCodes, hasLength(10));
    expect(aktiv.session, isNotNull);
    final wartend = RegistrationResult.fromJson({'member': userJson(role: 'child', status: 'pending'), 'status': 'pending', 'recoveryCodes': codes()});
    expect(wartend.status, MemberStatus.pending);
    expect(wartend.session, isNull);
  });

  test('Einladung prüfen (lookup)', () {
    final l = InviteLookup.fromJson({
      'role': 'child',
      'pinRequired': true,
      'requireApproval': true,
      'familyName': 'Familie Beispiel',
      'reset': false,
      'expiresAt': '2026-10-19T12:00:00.000Z',
    });
    expect(l.role, Role.child);
    expect(l.pinRequired && l.requireApproval, isTrue);
    expect(l.displayName, isNull);
    final r = InviteLookup.fromJson({
      'role': 'child',
      'pinRequired': false,
      'requireApproval': false,
      'familyName': 'F',
      'reset': true,
      'displayName': 'Ben',
      'expiresAt': '2026-10-19T12:00:00.000Z',
    });
    expect(r.reset, isTrue);
    expect(r.displayName, 'Ben');
  });

  test('Einladungsliste und neue Einladung', () {
    final i = InviteDto.fromJson(einladungJson(status: 'locked', pin: true));
    expect(i.status, InviteStatus.locked);
    expect(i.hasPin, isTrue);
    final neu = CreatedInvite.fromJson(neueEinladungJson()['invite']);
    expect(neu.link, 'https://familie.lx-labs.dev/#/einladung/$fixToken');
    expect(neu.pin, '123456');
    expect(CreatedInvite.fromJson(neueEinladungJson(pin: false)['invite']).pin, isNull);
  });

  test('Passwort-Registrierung: Start-Antwort', () {
    final s = PasswordStart.fromJson({'challengeId': 'c1', 'totpSecret': 'JBSWY3DPEHPK3PXP', 'totpUri': 'otpauth://totp/lx-familyhub:a@b.de?secret=JBSWY3DPEHPK3PXP'});
    expect(s.totpUri, startsWith('otpauth://'));
  });

  test('Geräte, Zugänge und Mitglieder (ohne E-Mail für Nicht-Admins)', () {
    final d = DeviceDto.fromJson({'id': fixDevice, 'name': 'Pixel 9', 'platform': 'android', 'appVersion': '0.1.0', 'createdAt': '2026-10-18T10:00:00.000Z', 'lastSeenAt': null, 'current': true});
    expect(d.current, isTrue);
    expect(d.lastSeenAt, isNull);
    final c = CredentialDto.fromJson({'id': 'c1', 'type': 'passkey', 'label': null, 'createdAt': '2026-10-18T10:00:00.000Z', 'lastUsedAt': '2026-10-18T11:00:00.000Z'});
    expect(c.istPasskey, isTrue);
    final m = UserDto.fromJson({'id': fixIdKind, 'displayName': 'Ben', 'colorIndex': 1, 'role': 'child', 'status': 'active'});
    expect(m.email, isNull);
  });

  test('WebAuthn-Optionen bleiben unverändert erhalten', () {
    final c = ChallengeDto.fromJson({'challengeId': 'x', 'options': webauthnOptionen()});
    expect(c.options['rp'], {'name': 'lx-familyhub', 'id': 'familie.lx-labs.dev'});
  });

  test('Rollen: Wire-Namen, Beschriftung und Einladungsrechte (Eltern nur Kind); unbekannte Werte (alter Server: "guest") gelten als Kind', () {
    expect(Role.parse('parent').label, 'Elternteil');
    expect(Role.admin.darfEinladen, Role.values);
    expect(Role.parent.darfEinladen, [Role.child]);
    expect(Role.child.darfEinladen, isEmpty);
    expect(Role.values.map((r) => r.wire), ['admin', 'parent', 'child']);
    expect(Role.parse('guest'), Role.child);
    expect(UserDto.fromJson(userJson(role: 'guest')).role, Role.child);
  });

  test('Gerätedaten: id nur, wenn bekannt', () {
    expect(const DeviceInfo(name: 'Pixel 9', platform: 'android', appVersion: '0.1.0').toJson(), {'name': 'Pixel 9', 'platform': 'android', 'appVersion': '0.1.0'});
    expect(const DeviceInfo(id: fixDevice, name: 'P', platform: 'android').toJson().containsKey('id'), isTrue);
  });

  test('Abweichende Antworten werden zu "unerwartete Antwort", nicht zu Abstürzen', () {
    for (final f in <void Function()>[
      () => MeDto.fromJson({'user': 5}),
      () => UserDto.fromJson({'id': 1}),
      () => SessionDto.fromJson({'kind': 'sonstwas'}),
      () => InviteDto.fromJson({...einladungJson(), 'status': 'weird'}),
      () => RegistrationResult.fromJson({'member': userJson(), 'status': 'active', 'recoveryCodes': 'nope'}),
      () => DeviceDto.fromJson({...{'id': 'x'}}),
      () => asJsonList('x'),
    ]) {
      expect(f, throwsA(isA<ApiException>().having((e) => e.kind, 'kind', ApiErrorKind.protokoll)));
    }
  });

  group('Listen sind pro Eintrag tolerant', () {
    test('Eintrag mit unbekannter Rolle, unbekanntem Status oder fehlendem Feld wird übersprungen, der Rest bleibt', () {
      final liste = parseListe([
        userJson(),
        userJson(role: 'superuser', name: 'Neu'),
        userJson(status: 'suspended', name: 'Neu2'),
        {'id': 'x'},
        'kein Objekt',
        userJson(id: 'z', name: 'Ben', role: 'child'),
      ], UserDto.fromJson);
      expect(liste.map((u) => u.displayName), ['Anna', 'Ben']);
    });

    test('Einladungen mit unbekanntem Status werden übersprungen', () {
      final l = parseListe([einladungJson(), einladungJson(id: 'i2', status: 'archived'), einladungJson(id: 'i3', status: 'used')], InviteDto.fromJson);
      expect(l.map((i) => i.id), ['i1', 'i3']);
    });

    test('Ist die Antwort gar keine Liste, bleibt es ein Fehler', () {
      expect(() => parseListe({'a': 1}, UserDto.fromJson), throwsA(isA<ApiException>()));
    });
  });
}
