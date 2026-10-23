// Medikamenten-Plan, Teil 2: Erinnerungsdienst mit Medikamenten (echte Datenbank, Fake-Port, kein Plugin). Geprüft: die Einnahme-Alarme stehen im gemeinsamen Fenster, der Schalter
// "Medikamenten-Erinnerungen" nimmt sie weg (unabhängig vom Schalter für Termine), ein Abhaken räumt die Alarme des Slots ab, ohne geladene Daten wird nichts angefasst, der Tipp auf eine
// Erinnerung öffnet die Medikamenten-Ansicht (Nutzlast ohne Inhalt).
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/api/models.dart';
import 'package:lx_fampad/data/auth/auth_state.dart';
import 'package:lx_fampad/data/erinnerungen/erinnerung_dienst.dart';
import 'package:lx_fampad/data/erinnerungen/erinnerung_einstellungen.dart';
import 'package:lx_fampad/data/medikamente/medikament_erinnerung.dart';
import 'package:lx_fampad/data/medikamente/medikament_hinweis.dart';
import 'package:lx_fampad/data/medikamente/medikament_modelle.dart';
import 'package:lx_fampad/data/medikamente/medikament_state.dart';
import 'package:lx_fampad/features/calendar/erinnerung_steuerung.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import 'support/fake_erinnerung_port.dart';
import 'support/fake_server.dart';
import 'support/harness.dart' show angemeldeteUmgebung;
import 'support/test_app.dart';

// Montag, 19. Oktober 2026, 07:00 Uhr in Berlin
final jetzt = DateTime.utc(2026, 10, 19, 5);
const medId = 'dddddddd-0000-4000-8000-000000000001';

final _testDaten = NotifierProvider<_Daten, MedDaten>(_Daten.new);

class _Daten extends Notifier<MedDaten> {
  @override
  MedDaten build() => _plan();
  void setzen(MedDaten d) => state = d;
}

MedDaten _plan({List<EinnahmeAnsicht> einnahmen = const [], bool geladen = true}) => MedDaten(
  geladen: geladen,
  ich: fixIdAdmin,
  ichRolle: Role.admin,
  eintraege: [
    MedEintrag(
      MedikamentAnsicht(
        id: medId,
        konversationId: 'k',
        subjektId: fixIdAdmin,
        inhalt: const MedikamentInhalt(name: 'Blutdrucktablette', dosis: '5 mg', zeiten: ['08:00', '20:00'], beginn: '2026-10-01'),
        erstelltAt: DateTime.utc(2026, 10, 1),
      ),
      einnahmen,
    ),
  ],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  tzdata.initializeTimeZones();

  late TestUmgebung env;
  late FakeErinnerungPort port;
  late MemoryErinnerungSpeicher speicher;
  late ProviderContainer c;

  Future<void> bis(bool Function() bedingung, {String grund = 'Bedingung'}) async {
    for (var i = 0; i < 100; i++) {
      if (bedingung()) return;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    fail('Zeitüberschreitung: $grund');
  }

  Future<void> ruhe() async {
    var n = -1;
    for (var i = 0; i < 20 && n != port.planungen.length + port.geloescht; i++) {
      n = port.planungen.length + port.geloescht;
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }
  }

  List<String> medAlarme() => [for (final x in port.letzte ?? const []) if (istMedikamentPayload(x.payload)) x.titel];

  Future<void> starten({MedDaten? daten}) async {
    env = await angemeldeteUmgebung();
    port = FakeErinnerungPort();
    speicher = MemoryErinnerungSpeicher();
    env.extraOverrides.addAll([
      erinnerungPortProvider.overrideWithValue(port),
      erinnerungSpeicherProvider.overrideWithValue(speicher),
      erinnerungUhrProvider.overrideWithValue(() => jetzt),
      erinnerungEntprellenProvider.overrideWithValue(Duration.zero),
      erinnerungWiederholenProvider.overrideWithValue(const Duration(milliseconds: 150)),
      medDatenProvider.overrideWith((ref) => ref.watch(_testDaten)),
    ]);
    c = env.container();
    addTearDown(c.dispose);
    if (daten != null) c.read(_testDaten.notifier).setzen(daten);
    await c.read(authProvider.notifier).start();
    c.listen(erinnerungSteuerungProvider, (_, _) {});
    await bis(() => port.planungen.isNotEmpty, grund: 'erste Planung');
    await ruhe();
  }

  test('Einnahme-Alarme stehen im Fenster: je Slot Alarm und eine Nachfass-Erinnerung, Text neutral', () async {
    await starten();
    final p = port.letzte!.where((x) => istMedikamentPayload(x.payload)).toList();
    // heute 08:00 und 20:00 (Alarm + Nachfass) und die nächsten 4 Tage: 5 Tage * 2 Slots * 2
    expect(p, hasLength(20));
    expect(p.every((x) => x.titel == kMedTitelEigen), isTrue);
    for (final x in p) {
      expect('${x.titel}${x.text}'.contains(RegExp('Blutdruck|mg|Anna', caseSensitive: false)), isFalse);
    }
  });

  test('Schalter "Medikamenten-Erinnerungen" aus: keine Einnahme-Alarme mehr; der Termin-Schalter ist davon unabhängig', () async {
    await starten();
    expect(medAlarme(), isNotEmpty);
    await c.read(erinnerungEinstellungenProvider.notifier).medikamenteAnSetzen(false);
    await bis(() => medAlarme().isEmpty, grund: 'Alarme weg');
    await c.read(erinnerungEinstellungenProvider.notifier).medikamenteAnSetzen(true);
    await bis(() => medAlarme().isNotEmpty, grund: 'Alarme wieder da');
    // Termin-Erinnerungen aus: die Einnahme-Alarme bleiben (eigener Schalter, wie bei den Abfuhrterminen)
    await c.read(erinnerungEinstellungenProvider.notifier).anSetzen(false);
    await ruhe();
    expect(medAlarme(), isNotEmpty);
  });

  test('Abhaken räumt die Alarme des Slots ab (Alarm und Nachfass), die übrigen bleiben', () async {
    await starten();
    final vorher = medAlarme().length;
    final hakt = EinnahmeAnsicht(
      id: 'e1',
      medikamentId: medId,
      inhalt: EinnahmeInhalt(status: EinnahmeStatus.genommen, um: DateTime.utc(2026, 10, 19, 5, 0), geplant: '2026-10-19T08:00'),
      erstelltAt: DateTime.utc(2026, 10, 19, 5),
    );
    c.read(_testDaten.notifier).setzen(_plan(einnahmen: [hakt]));
    await bis(() => medAlarme().length == vorher - 2, grund: 'Slot abgeräumt');
  });

  test('Daten noch nicht geladen: der Dienst rührt nichts an (kein leeres Fenster, das Alarme löscht)', () async {
    await starten();
    final n = port.planungen.length;
    final g = port.geloescht;
    c.read(_testDaten.notifier).setzen(const MedDaten(ich: fixIdAdmin));
    await ruhe();
    expect(port.planungen.length, n);
    expect(port.geloescht, g);
    expect(medAlarme(), isNotEmpty, reason: 'die alten Alarme bleiben stehen');
    c.read(_testDaten.notifier).setzen(_plan());
    await ruhe();
    expect(medAlarme(), hasLength(20));
  });

  test('Tipp auf eine Medikamenten-Erinnerung öffnet die Medikamenten-Ansicht', () async {
    await starten();
    final n = c.read(medikamentOeffnenProvider);
    port.tippe('medikament|$medId');
    expect(c.read(medikamentOeffnenProvider), n + 1);
    port.tippe('medikament|keine-uuid');
    expect(c.read(medikamentOeffnenProvider), n + 1);
  });
}
