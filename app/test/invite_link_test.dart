// Einladungslink-Parser: Fragment-Form, reines Token, ungültige Formen.
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/features/auth/invite_link.dart';

void main() {
  const token = 'AbCdEfGhIjKlMnOpQrStUvWxYz0123456789_-AbCdE'; // 43 Zeichen base64url wie vom Server
  const host = 'https://familie.lx-labs.dev';

  group('gültig', () {
    test('vollständiger Link mit Fragment', () {
      expect(parseInviteToken('$host/#/einladung/$token'), token);
    });
    test('ohne Schrägstrich vor dem Fragment', () {
      expect(parseInviteToken('$host#/einladung/$token'), token);
    });
    test('nur das Fragment (aus der Adresszeile)', () {
      expect(parseInviteToken('#/einladung/$token'), token);
      expect(parseInviteToken('/einladung/$token'), isNull, reason: 'ohne # ist es kein Fragment');
    });
    test('Leerraum und Zeilenumbruch drumherum (Einfügen aus Nachrichten)', () {
      expect(parseInviteToken('  $host/#/einladung/$token \n'), token);
    });
    test('abschließender Schrägstrich', () {
      expect(parseInviteToken('$host/#/einladung/$token/'), token);
    });
    test('Host unabhängig von Groß-/Kleinschreibung', () {
      expect(parseInviteToken('https://Familie.LX-Labs.dev/#/einladung/$token'), token);
    });
    test('reines Token eingefügt', () {
      expect(parseInviteToken(token), token);
    });
    test('anderer erlaubter Host (Entwicklung)', () {
      expect(parseInviteToken('https://dev.example/#/einladung/$token', erlaubterHost: 'dev.example'), token);
      expect(parseInviteToken('https://irgendwo.example/#/einladung/$token', erlaubterHost: null), token);
    });
  });

  group('ungültig', () {
    final faelle = <String, String>{
      'leer': '',
      'nur Leerzeichen': '   ',
      'Token im Pfad': '$host/einladung/$token',
      'Token in der Query': '$host/?token=$token',
      'Token in der Query vor dem Fragment': '$host/?x=1#/einladung/$token',
      'Token im Pfad statt im Fragment': '$host/einladung/$token#/',
      'fremder Host': 'https://boese.example/#/einladung/$token',
      'Host mit Zusatz': 'https://familie.lx-labs.dev.boese.example/#/einladung/$token',
      'Unterdomäne': 'https://x.familie.lx-labs.dev/#/einladung/$token',
      'http statt https': 'http://familie.lx-labs.dev/#/einladung/$token',
      'fremdes Schema': 'javascript:alert(1)//#/einladung/$token',
      'Benutzerangabe im Link': 'https://familie.lx-labs.dev@boese.example/#/einladung/$token',
      'anderer Port': 'https://familie.lx-labs.dev:8443/#/einladung/$token',
      'anderer Fragment-Pfad': '$host/#/anmelden/$token',
      'Token zu kurz': '$host/#/einladung/abc',
      'Token zu lang': '$host/#/einladung/${'a' * 129}',
      'Token mit Sonderzeichen': '$host/#/einladung/${token.substring(0, 20)}%00${token.substring(23)}',
      'Token mit Leerzeichen': '$host/#/einladung/${token.substring(0, 20)} ${token.substring(21)}',
      'Anhang nach dem Token': '$host/#/einladung/$token?x=1',
      'zweites Token': '$host/#/einladung/$token/$token',
      'Pfad nach Host': '$host/app/#/einladung/$token',
      'nur #': '#',
      'fast richtig (einladungen)': '$host/#/einladungen/$token',
      'zu lang insgesamt': 'x' * 3000,
      'kein Link': 'Hallo, hier ist deine Einladung!',
    };
    faelle.forEach((name, eingabe) {
      test(name, () => expect(parseInviteToken(eingabe), isNull));
    });
  });

  test('istEinladungsFragment erkennt auch ungültige Einladungsfragmente (sie werden trotzdem aus der Adresszeile entfernt)', () {
    expect(istEinladungsFragment('#/einladung/$token'), isTrue);
    expect(istEinladungsFragment('#/einladung/kaputt'), isTrue);
    expect(istEinladungsFragment('#/kalender'), isFalse);
    expect(istEinladungsFragment(''), isFalse);
  });
}
