// Gerätespeicher defekt (Android, Keystore-Schlüssel verloren): Mit resetOnError: false heilt sich flutter_secure_storage nicht mehr selbst. Geprüft wird mit einem Fake,
// bei dem Lesen, Schreiben UND Löschen scheitern (nicht nur das Web-Verhalten):
//  - die Anmeldung meldet "Gerätespeicher defekt" statt einer allgemeinen Fehlermeldung (GeraeteSpeicherDefekt),
//  - die Probe erkennt nur einen nachweislich dauerhaften Defekt (zwei Versuche), nie einen Aussetzer,
//  - die Reparatur läuft nur auf Klick, nach Probe, Rückfrage und getipptem Wort, und meldet danach ab,
//  - ein vorübergehender Lesefehler löscht in der Token-Ablage nichts.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/api/token_store.dart';
import 'package:lx_fampad/data/auth/auth_state.dart';
import 'package:lx_fampad/data/crypto/sicherer_speicher.dart';
import 'package:lx_fampad/features/auth/auth_widgets.dart';

import 'support/harness.dart';
import 'support/fake_server.dart' show fixDevice;

/// Android-Speicher mit verlorenem Keystore-Schlüssel: alles scheitert, bis [repariert] gesetzt ist (dann ein einfacher Speicher).
class _KaputtAlles extends Fake implements FlutterSecureStorage {
  bool repariert = false;
  int fehlversuche = 0;
  final daten = <String, String>{};
  final geloescht = <String>[];

  /// Die ersten [vorubergehend] Zugriffe scheitern, danach geht es (ein Aussetzer, kein Defekt).
  int vorubergehend = 0;

  Never _scheitern() {
    fehlversuche++;
    throw PlatformException(code: 'Exception encountered', message: 'InvalidKeyException: Key permanently lost');
  }

  bool get _geht => repariert || (vorubergehend > 0 && fehlversuche >= vorubergehend);

  @override
  dynamic noSuchMethod(Invocation invocation) {
    final key = invocation.namedArguments[#key] as String?;
    switch (invocation.memberName) {
      case #read:
        if (!_geht) _scheitern();
        return Future<String?>.value(daten[key]);
      case #write:
        if (!_geht) _scheitern();
        daten[key!] = invocation.namedArguments[#value] as String;
        return Future<void>.value();
      case #delete:
        if (!_geht) _scheitern();
        geloescht.add(key!);
        daten.remove(key);
        return Future<void>.value();
    }
    return super.noSuchMethod(invocation);
  }
}

/// Die Reparatur-Instanz (resetOnError: true): deleteAll lässt das Plugin den kaputten Schlüssel verwerfen, danach geht der Alltagsspeicher wieder.
class _Reparatur extends Fake implements FlutterSecureStorage {
  final _KaputtAlles alltag;
  int aufrufe = 0;
  _Reparatur(this.alltag);

  @override
  Future<void> deleteAll({dynamic iOptions, dynamic aOptions, dynamic lOptions, dynamic webOptions, dynamic mOptions, dynamic wOptions}) async {
    aufrufe++;
    alltag
      ..daten.clear()
      ..repariert = true;
  }
}

class _FakeGeraeteSpeicher implements GeraeteSpeicher {
  bool defekt;
  int proben = 0;
  int zuruecksetzer = 0;
  _FakeGeraeteSpeicher({this.defekt = true});

  @override
  Future<bool> nachweislichDefekt() async {
    proben++;
    return defekt;
  }

  @override
  Future<void> zuruecksetzen() async => zuruecksetzer++;
}

class _Auth extends AuthController {
  final List<bool> abmeldungen = [];
  @override
  AuthState build() => const AuthState(status: AuthStatus.abgemeldet);

  @override
  Future<AbmeldeErgebnis> abmelden({bool ueberall = false, bool nurLokal = false}) async {
    abmeldungen.add(nurLokal);
    return const AbmeldeErgebnis(serverAbgemeldet: false, lokalSauber: true);
  }
}

Future<void> main() async {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Token-Ablage bei defektem Gerätespeicher', () {
    test('Schreiben scheitert: GeraeteSpeicherDefekt mit klarer Meldung (nicht die allgemeine Fehlermeldung)', () async {
      final s = SecureTokenStore(_KaputtAlles());
      await expectLater(s.writeTokens(_tokens()), throwsA(isA<GeraeteSpeicherDefekt>()));
      await expectLater(s.writeProfile({'a': 1}), throwsA(isA<GeraeteSpeicherDefekt>()));
      expect(fehlerText(const GeraeteSpeicherDefekt()), kGeraeteSpeicherDefektText);
      expect(kGeraeteSpeicherDefektText, contains('Gerätespeicher defekt'));
    });

    test('vorübergehender Lesefehler (Keystore gesperrt): null, aber nichts wird gelöscht', () async {
      final f = _TransientLesen();
      final s = SecureTokenStore(f);
      expect(await s.readTokens(), isNull);
      expect(f.geloescht, isEmpty, reason: 'ein Aussetzer löscht die Anmeldung nicht');
    });

    test('dauerhaft unlesbar (InvalidKey, BadPadding): der Eintrag wird gelöscht, null', () async {
      final f = _KaputtAlles();
      final s = SecureTokenStore(f);
      expect(await s.readTokens(), isNull);
      expect(f.fehlversuche, greaterThanOrEqualTo(2), reason: 'Lesen und der Löschversuch scheitern beide, ohne dass etwas abstürzt');
    });
  });

  group('Probe und Reparatur', () {
    test('beide Proben scheitern: nachweislich defekt; die Reparatur ruft deleteAll der Reparatur-Instanz und der Speicher geht danach wieder', () async {
      final alltag = _KaputtAlles();
      final rep = _Reparatur(alltag);
      final g = PluginGeraeteSpeicher(alltag: alltag, reparatur: rep, pause: Duration.zero);
      expect(await g.nachweislichDefekt(), isTrue);
      await expectLater(SecureTokenStore(alltag).writeTokens(_tokens()), throwsA(isA<GeraeteSpeicherDefekt>()));
      await g.zuruecksetzen();
      expect(rep.aufrufe, 1);
      await SecureTokenStore(alltag).writeTokens(_tokens());
      expect((await SecureTokenStore(alltag).readTokens())?.refreshToken, _tokens().refreshToken);
      expect(await g.nachweislichDefekt(), isFalse);
    });

    test('ein Aussetzer (nur der erste Versuch scheitert): nicht defekt, nichts wird zurückgesetzt', () async {
      final alltag = _KaputtAlles()..vorubergehend = 1;
      final rep = _Reparatur(alltag);
      final g = PluginGeraeteSpeicher(alltag: alltag, reparatur: rep, pause: Duration.zero);
      expect(await g.nachweislichDefekt(), isFalse);
      expect(rep.aufrufe, 0);
    });

    test('gesunder Speicher: nicht defekt', () async {
      final alltag = _KaputtAlles()..repariert = true;
      expect(await PluginGeraeteSpeicher(alltag: alltag, reparatur: _Reparatur(alltag), pause: Duration.zero).nachweislichDefekt(), isFalse);
    });
  });

  group('Oberfläche "Gerätespeicher zurücksetzen"', () {
    Future<_Auth> aufbau(WidgetTester tester, _FakeGeraeteSpeicher speicher, {double skala = 1.0}) async {
      tester.view.physicalSize = const Size(360, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final auth = _Auth();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [geraeteSpeicherProvider.overrideWithValue(speicher), authProvider.overrideWith(() => auth)],
          child: MaterialApp(
            builder: (c, w) => MediaQuery(data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(skala)), child: w!),
            home: const Scaffold(body: SingleChildScrollView(padding: EdgeInsets.all(16), child: MeldungsBox(kGeraeteSpeicherDefektText))),
          ),
        ),
      );
      return auth;
    }

    for (final skala in [1.0, 1.5]) {
      testWidgets('Meldung mit Knopf; Probe, Rückfrage mit Wort und Haken, Zurücksetzen, Abmelden (360 px, Textskala $skala)', (tester) async {
        final g = _FakeGeraeteSpeicher();
        final auth = await aufbau(tester, g, skala: skala);
        expect(find.textContaining('Gerätespeicher defekt'), findsOneWidget);
        pruefeLayout(tester, 'Meldung Gerätespeicher defekt');
        await tester.ensureVisible(find.text('Gerätespeicher zurücksetzen'));
        await tester.tap(find.text('Gerätespeicher zurücksetzen'));
        await tester.pumpAndSettle();
        expect(g.proben, 1);
        expect(find.text('Gerätespeicher zurücksetzen?'), findsOneWidget);
        expect(find.textContaining('ohnehin nicht mehr lesbar'), findsOneWidget, reason: 'ehrlicher Text');
        expect(find.textContaining('Ohne bestätigte Sicherung'), findsOneWidget, reason: 'ohne bestätigte Sicherung: eigener Pflicht-Haken');
        pruefeLayout(tester, 'Rückfrage Gerätespeicher zurücksetzen');
        // ohne Wort und Haken geht es nicht
        await tester.tap(find.text('Zurücksetzen'), warnIfMissed: false);
        await tester.pumpAndSettle();
        expect(g.zuruecksetzer, 0);
        await tester.enterText(find.byType(TextField), 'zurücksetzen');
        await tester.pump();
        await tester.tap(find.text('Zurücksetzen'), warnIfMissed: false);
        await tester.pumpAndSettle();
        expect(g.zuruecksetzer, 0, reason: 'der Haken fehlt noch');
        await tester.tap(find.byType(CheckboxListTile));
        await tester.pump();
        await tester.tap(find.text('Zurücksetzen'));
        await tester.pumpAndSettle();
        expect(g.zuruecksetzer, 1);
        expect(auth.abmeldungen, [true], reason: 'nicht angemeldet: nur lokal neu anfangen');
        expect(find.textContaining('Melde dich neu an'), findsOneWidget);
      });
    }

    testWidgets('Probe zeigt einen gesunden Speicher: nichts wird zurückgesetzt, keine Rückfrage', (tester) async {
      final g = _FakeGeraeteSpeicher(defekt: false);
      final auth = await aufbau(tester, g);
      await tester.ensureVisible(find.text('Gerätespeicher zurücksetzen'));
      await tester.tap(find.text('Gerätespeicher zurücksetzen'));
      await tester.pumpAndSettle();
      expect(g.proben, 1);
      expect(find.byType(AlertDialog), findsNothing);
      expect(g.zuruecksetzer, 0);
      expect(auth.abmeldungen, isEmpty);
      expect(find.textContaining('antwortet wieder'), findsOneWidget);
    });

    testWidgets('Abbrechen in der Rückfrage lässt alles unberührt', (tester) async {
      final g = _FakeGeraeteSpeicher();
      final auth = await aufbau(tester, g);
      await tester.ensureVisible(find.text('Gerätespeicher zurücksetzen'));
      await tester.tap(find.text('Gerätespeicher zurücksetzen'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Abbrechen'));
      await tester.pumpAndSettle();
      expect(g.zuruecksetzer, 0);
      expect(auth.abmeldungen, isEmpty);
    });

    testWidgets('andere Fehlermeldungen zeigen den Knopf nicht', (tester) async {
      await tester.pumpWidget(const ProviderScope(child: MaterialApp(home: Scaffold(body: MeldungsBox('Etwas anderes ging schief.')))));
      expect(find.text('Gerätespeicher zurücksetzen'), findsNothing);
    });
  });
}

StoredTokens _tokens() => StoredTokens(
  accessToken: 'a',
  accessExpiresAt: DateTime.utc(2030),
  refreshToken: 'r',
  refreshExpiresAt: DateTime.utc(2031),
  deviceId: fixDevice,
);

/// Lesen scheitert vorübergehend (ohne eines der Muster eines dauerhaften Defekts).
class _TransientLesen extends Fake implements FlutterSecureStorage {
  final geloescht = <String>[];

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #read) {
      return Future<String?>.error(PlatformException(code: 'Exception encountered', message: 'KeyStoreException: key not accessible'));
    }
    if (invocation.memberName == #delete) {
      geloescht.add(invocation.namedArguments[#key] as String);
      return Future<void>.value();
    }
    return super.noSuchMethod(invocation);
  }
}
