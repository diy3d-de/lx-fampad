// Gerätespeicher defekt (Android, Keystore-Schlüssel verloren): Mit resetOnError: false heilt sich flutter_secure_storage nicht mehr selbst. Geprüft wird mit einem Fake,
// bei dem Lesen, Schreiben UND Löschen scheitern (nicht nur das Web-Verhalten):
//  - die Anmeldung meldet "Gerätespeicher defekt" nur bei einem Fehler, der nach dauerhaftem Defekt aussieht, sonst die normale Meldung,
//  - die Probe (drei Versuche) erkennt nur einen nachweislich dauerhaften Defekt, nie einen Aussetzer, vollen Speicher oder reine E/A-Fehler,
//  - die Reparatur läuft nur auf Klick, nach Probe, Rückfrage (alles Verlorene genannt) und getipptem Wort, prüft direkt vor dem Löschen noch einmal und meldet danach
//    ab und fordert zum Neustart auf,
//  - ein vorübergehender Lesefehler löscht in der Token-Ablage nichts.
import 'package:drift/drift.dart' show DatabaseConnection, Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/api/token_store.dart';
import 'package:lx_fampad/data/app_database.dart';
import 'package:lx_fampad/data/auth/auth_state.dart';
import 'package:lx_fampad/data/crypto/e2ee_state.dart';
import 'package:lx_fampad/data/crypto/sicherer_speicher.dart';
import 'package:lx_fampad/data/sync/sync_store.dart';
import 'package:lx_fampad/data/sync_state.dart';
import 'package:lx_fampad/features/auth/auth_widgets.dart';

import 'support/fake_server.dart' show fixDevice;
import 'support/harness.dart';

const _dauerhaft = 'InvalidKeyException: Key permanently lost';
const _nurEa = 'IOException: No space left on device';

/// Android-Speicher mit verlorenem Keystore-Schlüssel: alles scheitert, bis [repariert] gesetzt ist (dann ein einfacher Speicher).
class _KaputtAlles extends Fake implements FlutterSecureStorage {
  final String text;
  _KaputtAlles({this.text = _dauerhaft});

  bool repariert = false;
  int fehlversuche = 0;
  final daten = <String, String>{};
  final geloescht = <String>[];

  /// Die ersten [vorubergehend] Zugriffe scheitern, danach geht es (ein Aussetzer, kein Defekt).
  int vorubergehend = 0;

  Never _scheitern() {
    fehlversuche++;
    throw PlatformException(code: 'Exception encountered', message: text);
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

/// Fake der Probe und Reparatur: [antworten] sind die Ergebnisse der Proben nacheinander (danach gilt die letzte).
class _FakeGeraeteSpeicher implements GeraeteSpeicher {
  final List<bool> antworten;
  int proben = 0;
  int zuruecksetzer = 0;
  _FakeGeraeteSpeicher({this.antworten = const [true]});

  @override
  Future<bool> nachweislichDefekt() async => antworten[proben++ < antworten.length ? proben - 1 : antworten.length - 1];

  @override
  Future<void> zuruecksetzen() async => zuruecksetzer++;
}

class _Auth extends AuthController {
  final bool sauber;
  final bool serverOk;
  _Auth({this.sauber = true, this.serverOk = true});
  final List<bool> abmeldungen = [];
  @override
  AuthState build() => const AuthState(status: AuthStatus.abgemeldet);

  @override
  Future<AbmeldeErgebnis> abmelden({bool ueberall = false, bool nurLokal = false}) async {
    abmeldungen.add(nurLokal);
    return AbmeldeErgebnis(serverAbgemeldet: serverOk, lokalSauber: sauber);
  }
}

class _E2ee extends E2eeController {
  final E2eeState fest;
  _E2ee(this.fest);
  @override
  E2eeState build() => fest;
  @override
  Future<void> laden() async {}
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

Future<void> main() async {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Token-Ablage bei defektem Gerätespeicher', () {
    test('Schreiben scheitert mit dauerhaftem Fehler: GeraeteSpeicherDefekt mit klarer Meldung (nicht die allgemeine Fehlermeldung)', () async {
      final s = SecureTokenStore(_KaputtAlles());
      await expectLater(s.writeTokens(_tokens()), throwsA(isA<GeraeteSpeicherDefekt>()));
      await expectLater(s.writeProfile({'a': 1}), throwsA(isA<GeraeteSpeicherDefekt>()));
      expect(fehlerText(const GeraeteSpeicherDefekt()), kGeraeteSpeicherDefektText);
      expect(kGeraeteSpeicherDefektText, contains('Gerätespeicher defekt'));
    });

    test('reiner E/A-Fehler beim Schreiben: normale Fehlermeldung, kein "Gerätespeicher defekt"', () async {
      final f = _KaputtAlles(text: _nurEa);
      await expectLater(SecureTokenStore(f).writeTokens(_tokens()), throwsA(isA<PlatformException>()));
      expect(fehlerText(PlatformException(code: 'x')), isNot(contains('Gerätespeicher defekt')));
      expect(f.fehlversuche, 2, reason: 'ein zweiter Versuch wurde gemacht');
    });

    test('Aussetzer beim Schreiben: der zweite Versuch gelingt, nichts wird gemeldet', () async {
      final f = _KaputtAlles(text: _nurEa)..vorubergehend = 1;
      await SecureTokenStore(f).writeTokens(_tokens());
      expect(f.daten, isNotEmpty);
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
    test('alle Proben scheitern mit Schlüsselfehler: nachweislich defekt; die Reparatur ruft deleteAll der Reparatur-Instanz und der Speicher geht danach wieder', () async {
      final alltag = _KaputtAlles();
      final rep = _Reparatur(alltag);
      final g = PluginGeraeteSpeicher(alltag: alltag, reparatur: rep, pause: Duration.zero);
      expect(await g.nachweislichDefekt(), isTrue);
      expect(alltag.fehlversuche, 3, reason: 'drei Versuche');
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

    test('erst der dritte Versuch gelingt: nicht defekt', () async {
      final alltag = _KaputtAlles()..vorubergehend = 2;
      expect(await PluginGeraeteSpeicher(alltag: alltag, reparatur: _Reparatur(alltag), pause: Duration.zero).nachweislichDefekt(), isFalse);
    });

    test('alle Versuche scheitern, aber nur mit E/A-Fehler (voller Speicher): kein dauerhafter Defekt', () async {
      final alltag = _KaputtAlles(text: _nurEa);
      expect(await PluginGeraeteSpeicher(alltag: alltag, reparatur: _Reparatur(alltag), pause: Duration.zero).nachweislichDefekt(), isFalse);
      expect(alltag.fehlversuche, 3);
    });

    test('gesunder Speicher: nicht defekt', () async {
      final alltag = _KaputtAlles()..repariert = true;
      expect(await PluginGeraeteSpeicher(alltag: alltag, reparatur: _Reparatur(alltag), pause: Duration.zero).nachweislichDefekt(), isFalse);
    });
  });

  group('Oberfläche "Gerätespeicher zurücksetzen"', () {
    Future<(_Auth, AppDatabase)> aufbau(
      WidgetTester tester,
      _FakeGeraeteSpeicher speicher, {
      double skala = 1.0,
      _Auth? auth,
      E2eeState? e2ee,
      Future<void> Function(AppDatabase db)? daten,
    }) async {
      tester.view.physicalSize = const Size(360, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final a = auth ?? _Auth();
      final db = AppDatabase(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
      addTearDown(db.close);
      if (daten != null) await tester.runAsync(() => daten(db));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            geraeteSpeicherProvider.overrideWithValue(speicher),
            authProvider.overrideWith(() => a),
            syncStoreProvider.overrideWithValue(SyncStore(db)),
            if (e2ee != null) e2eeProvider.overrideWith(() => _E2ee(e2ee)),
          ],
          child: MaterialApp(
            builder: (c, w) => MediaQuery(data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(skala)), child: w!),
            home: const Scaffold(body: SingleChildScrollView(padding: EdgeInsets.all(16), child: MeldungsBox(kGeraeteSpeicherDefektText))),
          ),
        ),
      );
      return (a, db);
    }

    /// Wort tippen, alle Haken setzen, "Zurücksetzen" tippen (der Dialog scrollt, darum immer erst sichtbar machen).
    Future<void> bestaetigen(WidgetTester tester) async {
      await tester.enterText(find.byType(TextField), 'zurücksetzen');
      await tester.pump();
      final haken = find.byType(CheckboxListTile);
      for (var i = 0; i < haken.evaluate().length; i++) {
        await tester.ensureVisible(haken.at(i));
        await tester.tap(haken.at(i));
        await tester.pump();
      }
      await tester.ensureVisible(find.text('Zurücksetzen'));
      await tester.tap(find.text('Zurücksetzen'));
      await tester.pumpAndSettle();
    }

    Future<void> klickeKnopf(WidgetTester tester) async {
      await tester.ensureVisible(find.text('Gerätespeicher zurücksetzen'));
      await tester.tap(find.text('Gerätespeicher zurücksetzen'));
      await tester.pumpAndSettle();
    }

    for (final skala in [1.0, 1.5]) {
      testWidgets('Meldung mit Knopf; Probe, Rückfrage mit Wort und Haken, erneute Probe, Zurücksetzen, Abmelden, Aufforderung zum Neustart (360 px, Textskala $skala)', (tester) async {
        final g = _FakeGeraeteSpeicher();
        final (auth, _) = await aufbau(tester, g, skala: skala);
        expect(find.textContaining('Gerätespeicher defekt'), findsOneWidget);
        pruefeLayout(tester, 'Meldung Gerätespeicher defekt');
        await klickeKnopf(tester);
        expect(g.proben, 1);
        expect(find.text('Gerätespeicher zurücksetzen?'), findsOneWidget);
        expect(find.textContaining('ohnehin nicht mehr lesbar'), findsOneWidget, reason: 'ehrlicher Text');
        expect(find.textContaining('lokale Datenbank'), findsOneWidget, reason: 'alle lokalen Daten werden genannt');
        expect(find.textContaining('Einstellungen'), findsOneWidget);
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
        expect(g.proben, 3, reason: 'Probe vorab, noch einmal direkt vor dem Löschen, und danach');
        expect(auth.abmeldungen, [true], reason: 'nicht angemeldet: nur lokal neu anfangen');
        expect(find.textContaining('Schließe die App jetzt ganz'), findsOneWidget, reason: 'Aufforderung zum Neustart statt "fertig"');
        expect(find.textContaining('Melde dich'), findsNothing);
      });
    }

    testWidgets('Probe zeigt einen gesunden Speicher: nichts wird zurückgesetzt, keine Rückfrage', (tester) async {
      final g = _FakeGeraeteSpeicher(antworten: const [false]);
      final (auth, _) = await aufbau(tester, g);
      await klickeKnopf(tester);
      expect(g.proben, 1);
      expect(find.byType(AlertDialog), findsNothing);
      expect(g.zuruecksetzer, 0);
      expect(auth.abmeldungen, isEmpty);
      expect(find.textContaining('antwortet wieder'), findsOneWidget);
    });

    testWidgets('der Speicher erholt sich während der Rückfrage: direkt vor dem Löschen wird noch einmal geprüft, nichts wird gelöscht', (tester) async {
      final g = _FakeGeraeteSpeicher(antworten: const [true, false]);
      final (auth, _) = await aufbau(tester, g);
      await klickeKnopf(tester);
      expect(find.byType(AlertDialog), findsOneWidget);
      await bestaetigen(tester);
      expect(g.proben, 2);
      expect(g.zuruecksetzer, 0, reason: 'nichts gelöscht');
      expect(auth.abmeldungen, isEmpty);
      expect(find.textContaining('funktioniert inzwischen wieder'), findsOneWidget);
    });

    testWidgets('die Rückfrage nennt ungesendete und abgelehnte Änderungen und frühere Schlüssel, je mit eigenem Pflicht-Haken', (tester) async {
      final g = _FakeGeraeteSpeicher();
      await aufbau(
        tester,
        g,
        e2ee: E2eeState(status: E2eeStatus.geraetNichtVerbunden, quarantaene: [QuarantaeneEintrag('e2ee.quarantaene.a.1', null), QuarantaeneEintrag('e2ee.quarantaene.a.2', null)]),
        daten: (db) async {
          Future<void> op(String id, {String? fehler}) => db
              .into(db.outbox)
              .insert(OutboxCompanion.insert(opId: id, op: 'upsert', entity: 'listen', entityId: id, fehlerCode: Value(fehler)));
          await op('o1');
          await op('o2');
          await op('o3', fehler: 'abgelehnt');
        },
      );
      await klickeKnopf(tester);
      expect(find.textContaining('2 noch nicht gesendete Änderungen'), findsOneWidget);
      expect(find.textContaining('1 nicht gesendete Nachricht (Änderung) mit Fehler'), findsOneWidget);
      expect(find.textContaining('2 frühere Schlüssel'), findsOneWidget);
      expect(find.byType(CheckboxListTile), findsNWidgets(4), reason: 'offen, abgelehnt, frühere Schlüssel, keine bestätigte Sicherung');
      pruefeLayout(tester, 'Rückfrage mit allen Haken');
      await tester.enterText(find.byType(TextField), 'zurücksetzen');
      await tester.pump();
      // erst mit ALLEN Haken ist der Knopf frei
      final haken = find.byType(CheckboxListTile);
      for (var i = 0; i < 3; i++) {
        await tester.ensureVisible(haken.at(i));
        await tester.tap(haken.at(i));
        await tester.pump();
      }
      await tester.ensureVisible(find.text('Zurücksetzen'));
      await tester.tap(find.text('Zurücksetzen'), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(g.zuruecksetzer, 0, reason: 'der vierte Haken fehlt');
    });

    testWidgets('Abmelden-Ergebnis wird ausgewertet: lokale Daten nicht sauber gelöscht und Server nicht erreichbar werden genannt, keine falsche Erfolgsmeldung', (tester) async {
      final g = _FakeGeraeteSpeicher();
      final (auth, _) = await aufbau(tester, g, auth: _Auth(sauber: false, serverOk: false));
      await klickeKnopf(tester);
      await bestaetigen(tester);
      expect(g.zuruecksetzer, 1);
      expect(auth.abmeldungen, [true]);
      expect(find.textContaining('nicht vollständig löschen'), findsOneWidget);
      expect(find.textContaining('Schließe die App jetzt ganz'), findsOneWidget);
    });

    testWidgets('Abbrechen in der Rückfrage lässt alles unberührt', (tester) async {
      final g = _FakeGeraeteSpeicher();
      final (auth, _) = await aufbau(tester, g);
      await klickeKnopf(tester);
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
