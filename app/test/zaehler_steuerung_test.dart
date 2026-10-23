// Zähler (Teil 2): die Teilnehmerpflege am Wurzel-Widget. Neue Eltern und Admins werden in die Zähler-Konversation aufgenommen und bekommen den Verlauf OHNE Tipp und ohne Hinweis
// (`verlaufTeilen: true`, wie beim Medikamenten-Plan); für Kinder läuft nichts; eine neue Zähler-Konversation löst einen weiteren Lauf aus; nie zwei Läufe gleichzeitig.
import 'dart:async';

import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/app_database.dart';
import 'package:lx_fampad/data/erinnerungen/erinnerung_dienst.dart' show erinnerungPortProvider;
import 'package:lx_fampad/data/zaehler/zaehler_repository.dart';

import 'support/fake_erinnerung_port.dart';
import 'support/harness.dart';
import 'support/test_app.dart';

class _Repo implements ZaehlerRepository {
  final aufrufe = <bool>[];
  var gleichzeitig = 0;
  var maximal = 0;
  Completer<void>? halt;

  @override
  Future<bool> teilnehmerPflegen({bool verlaufTeilen = false}) async {
    gleichzeitig++;
    if (gleichzeitig > maximal) maximal = gleichzeitig;
    aufrufe.add(verlaufTeilen);
    if (halt != null) await halt!.future;
    gleichzeitig--;
    return false;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError('${invocation.memberName}');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  setUpAll(testVorbereiten);

  Future<(_Repo, TestUmgebung)> start(WidgetTester tester, String rolle) async {
    final repo = _Repo();
    final env = await angemeldeteUmgebung(role: rolle);
    env.extraOverrides.addAll([erinnerungPortProvider.overrideWithValue(FakeErinnerungPort()..verfuegbar = false), zaehlerRepositoryProvider.overrideWithValue(repo)]);
    await starteApp(tester, env);
    return (repo, env);
  }

  testWidgets('Admin: die Pflege läuft beim Start und gibt den Verlauf automatisch frei', (tester) async {
    final (repo, _) = await start(tester, 'admin');
    expect(repo.aufrufe, isNotEmpty);
    expect(repo.aufrufe.every((v) => v), isTrue, reason: 'immer mit Verlauf (ohne Tipp), nie mit einem Hinweis');
  });

  testWidgets('Elternteil: ebenso', (tester) async {
    final (repo, _) = await start(tester, 'parent');
    expect(repo.aufrufe, isNotEmpty);
    expect(repo.aufrufe.every((v) => v), isTrue);
  });

  testWidgets('Kind: die Pflege läuft nie', (tester) async {
    final (repo, env) = await start(tester, 'child');
    await env.db.into(env.db.konversationen).insert(KonversationenCompanion.insert(id: 'zzzzzzzz-0000-4000-8000-000000000001', art: 'zaehler', createdAt: DateTime.utc(2026, 10, 19), rev: const Value(1)));
    await warte(tester);
    expect(repo.aufrufe, isEmpty);
  });

  testWidgets('eine neue Zähler-Konversation löst einen weiteren Lauf aus; nie zwei Läufe gleichzeitig', (tester) async {
    final (repo, env) = await start(tester, 'admin');
    final vorher = repo.aufrufe.length;
    repo.halt = Completer<void>();
    await env.db.into(env.db.konversationen).insert(KonversationenCompanion.insert(id: 'zzzzzzzz-0000-4000-8000-000000000001', art: 'zaehler', createdAt: DateTime.utc(2026, 10, 19), rev: const Value(1)));
    await warte(tester);
    expect(repo.aufrufe.length, vorher + 1);
    // ein weiterer Auslöser während des Laufs ergibt genau einen weiteren Lauf, nicht zwei gleichzeitige
    await env.db.into(env.db.konversationen).insert(KonversationenCompanion.insert(id: 'zzzzzzzz-0000-4000-8000-000000000002', art: 'zaehler', createdAt: DateTime.utc(2026, 10, 19), rev: const Value(1)));
    await warte(tester);
    expect(repo.maximal, 1);
    repo.halt!.complete();
    repo.halt = null;
    await warte(tester);
    expect(repo.aufrufe.length, vorher + 2);
    expect(repo.maximal, 1);
  });
}
