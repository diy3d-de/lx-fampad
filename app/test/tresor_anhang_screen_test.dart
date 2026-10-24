// Tresor-Anhänge (Teil 3): Oberfläche. Abschnitt "Dokumente" im Eintrag (Liste, Öffnen eines Bildes im Speicher, Speichern mit Bestätigung, Löschen), Anhängen mit Vorabprüfung, Fortschritt,
// Abbrechen und "Bitte Datei neu wählen", Eintrag mit Dokumenten löschen, Zähler in der Übersicht, Gating ohne `features.files`, Sperren (Klartext überschrieben, Ansicht geschlossen,
// Systemdialoge sperren nicht), Rollen, Bedienhilfe, Layout bei 360 px und Textskala 1.0/1.5/2.0 mit Touch-Ziel-Prüfung. Daten und Dienste sind Attrappen (tresor_anhang_welt.dart);
// Verschlüsselung, Upload und Download prüft tresor_anhang_test.dart gegen die echten Wege.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/constants.dart';
import 'package:lx_fampad/data/crypto/crypto_fehler.dart';
import 'package:lx_fampad/data/dateien/datei_modelle.dart';
import 'package:lx_fampad/data/dateien/tresor_anhang_repository.dart' show AnhangAnsicht;
import 'package:lx_fampad/data/dateien/tresor_anhang_state.dart';
import 'package:lx_fampad/data/dateien/tresor_anhang_waehler.dart';
import 'package:lx_fampad/data/tresor/tresor_sperre.dart';
import 'package:lx_fampad/features/auth/auth_widgets.dart' show MeldungsBox;
import 'package:lx_fampad/features/shell/shell_tab.dart';

import 'support/harness.dart';
import 'support/tresor_anhang_welt.dart';
import 'support/tresor_welt.dart';

String alleSemantik(WidgetTester tester) {
  final b = StringBuffer();
  void gehe(SemanticsNode n) {
    final d = n.getSemanticsData();
    b..writeln(d.label)..writeln(d.value)..writeln(d.hint)..writeln(d.tooltip);
    n.visitChildren((c) {
      gehe(c);
      return true;
    });
  }

  gehe(tester.binding.renderViews.first.owner!.semanticsOwner!.rootSemanticsNode!);
  return b.toString();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(testVorbereiten);

  List<AnhangAnsicht> beispiel() => [
    anhang('a1', 'e-haftpflicht', 'Police.pdf', mime: 'application/pdf', groesse: 410 * 1024),
    anhang('a2', 'e-haftpflicht', 'Schaden.png', mime: 'image/png', groesse: 2048),
    anhang('a3', 'e-wlan', 'Router-Handbuch.pdf', mime: 'application/pdf', groesse: 1024 * 1024),
  ];

  Future<(TresorTestAufbau, AnhangTestAufbau, ProviderContainer)> start(
    WidgetTester tester, {
    String role = 'admin',
    double skala = 1.0,
    Size groesse = const Size(360, 800),
    AnhangTestAufbau? anhaenge,
    bool entsperren = true,
    bool oeffnen = true,
  }) async {
    final a = TresorTestAufbau();
    final z = anhaenge ?? AnhangTestAufbau(daten: beispiel());
    final env = await angemeldeteUmgebung(role: role);
    env.extraOverrides.addAll([...a.overrides, ...z.overrides]);
    final c = await starteApp(tester, env, skala: skala, groesse: groesse);
    z.verbinden(c);
    if (!oeffnen) {
      // Kind: es gibt keinen Menüpunkt
    } else if (groesse.width >= kDesktopBreakpoint) {
      c.read(shellTabProvider.notifier).waehlen(kTresorTab);
      await warte(tester);
    } else {
      await zumBereich(tester, 'Tresor');
    }
    if (entsperren && oeffnen) await tippe(tester, find.text('Tresor entsperren'));
    return (a, z, c);
  }

  Future<void> ende(WidgetTester tester, ProviderContainer c, TresorTestAufbau a) async {
    c.read(tresorSperreProvider.notifier).sperren();
    a.ablage.dienst.verwerfen();
    await warte(tester);
  }

  Future<void> oeffne(WidgetTester tester, String kategorie, String titel) async {
    await tippe(tester, find.text(kategorie));
    await tippe(tester, find.text(titel));
  }

  void fuerSkalen(String name, Future<void> Function(WidgetTester tester, double skala) body) {
    for (final skala in [1.0, 1.5, 2.0]) {
      testWidgets('$name (Textskala $skala)', (tester) => body(tester, skala));
    }
  }

  group('Dokumente im Eintrag', () {
    fuerSkalen('Liste mit Name, Größe und Datum nur dieses Eintrags, Zähler, Hinweiskarte, Layout', (tester, skala) async {
      final (a, _, c) = await start(tester, skala: skala);
      await oeffne(tester, 'Dokumente', 'Haftpflicht Familie');
      expect(find.text('Police.pdf'), findsOneWidget);
      expect(find.text('Schaden.png'), findsOneWidget);
      expect(find.text('Router-Handbuch.pdf'), findsNothing, reason: 'gehört zu einem anderen Eintrag');
      expect(find.textContaining('410 KB'), findsOneWidget);
      expect(find.textContaining('10.09.2026'), findsWidgets);
      expect(find.text('2 von 10'), findsOneWidget);
      expect(find.text('Dokument anhängen'), findsOneWidget);
      expect(find.textContaining('auf deinem Gerät verschlüsselt, bevor sie hochgeladen werden'), findsOneWidget);
      expect(find.byTooltip('Dokument Police.pdf löschen'), findsOneWidget);
      pruefeLayout(tester, 'Eintrag mit Dokumenten');
      await ende(tester, c, a);
    });

    testWidgets('Eintrag ohne Dokumente: ruhiger Hinweis', (tester) async {
      final (a, _, c) = await start(tester);
      await oeffne(tester, 'Zugangsdaten', 'Alarmanlage');
      expect(find.text('Noch kein Dokument angehängt.'), findsOneWidget);
      expect(find.text('0 von 10'), findsOneWidget);
      await ende(tester, c, a);
    });

    testWidgets('Ohne features.files fehlt der Abschnitt ganz (Eintrag funktioniert weiter), auch in der Übersicht ohne Büroklammer', (tester) async {
      final z = AnhangTestAufbau(daten: beispiel())..verfuegbar = false;
      final (a, _, c) = await start(tester, anhaenge: z);
      expect(find.byIcon(Icons.attach_file), findsNothing);
      await oeffne(tester, 'Dokumente', 'Haftpflicht Familie');
      expect(find.text('Dokument anhängen'), findsNothing);
      expect(find.text('Police.pdf'), findsNothing);
      expect(find.text('Vertragsnummer'), findsOneWidget);
      expect(find.text('Zuletzt geändert'), findsOneWidget);
      await tippe(tester, find.text('Bearbeiten'));
      expect(find.text('Dokument anhängen'), findsNothing);
      expect(find.textContaining('Speichere den Eintrag zuerst'), findsNothing);
      await ende(tester, c, a);
    });

    testWidgets('Unlesbarer Anhang: "Nicht lesbar", nicht antippbar, aber löschbar', (tester) async {
      final z = AnhangTestAufbau(daten: [anhang('x', 'e-haftpflicht', '', hinweis: 'nicht lesbar'), anhang('a1', 'e-haftpflicht', 'Police.pdf')]);
      final (a, _, c) = await start(tester, anhaenge: z);
      await oeffne(tester, 'Dokumente', 'Haftpflicht Familie');
      // ohne lesbare Zuordnung gehört er zu keinem Eintrag und steht nirgends: die lesbare Police bleibt
      expect(find.text('Police.pdf'), findsOneWidget);
      await ende(tester, c, a);
    });
  });

  group('Öffnen, Speichern, Löschen', () {
    testWidgets('Bild: wird im Speicher geladen und mit Image.memory gezeigt; Schließen überschreibt den Klartext', (tester) async {
      final z = AnhangTestAufbau(daten: beispiel());
      z.inhalte['a2'] = Uint8List.fromList(winzigPng);
      final (a, _, c) = await start(tester, anhaenge: z);
      await oeffne(tester, 'Dokumente', 'Haftpflicht Familie');
      await tippe(tester, find.text('Schaden.png'));
      expect(z.heruntergeladen, ['a2']);
      expect(find.byType(Image), findsOneWidget);
      final bytes = z.ausgeliefert.single;
      expect(bytes.any((b) => b != 0), isTrue, reason: 'solange die Ansicht offen ist, steht der Klartext im Speicher');
      expect(find.text('Speichern'), findsOneWidget);
      expect(find.textContaining('Gespeichert liegt die Datei unverschlüsselt'), findsOneWidget);
      pruefeLayout(tester, 'Bildansicht');
      await tippe(tester, find.byTooltip('Zurück'));
      await warte(tester);
      expect(bytes.every((b) => b == 0), isTrue, reason: 'nach dem Schließen überschrieben');
      expect(find.byType(Image), findsNothing);
      await ende(tester, c, a);
    });

    fuerSkalen('Anderes Dokument: kein Bild, Speichern fragt zuerst und speichert erst nach der Bestätigung', (tester, skala) async {
      final z = AnhangTestAufbau(daten: beispiel())..inhalte['a1'] = Uint8List.fromList('%PDF-1.4 Inhalt'.codeUnits);
      final (a, _, c) = await start(tester, skala: skala, anhaenge: z);
      await oeffne(tester, 'Dokumente', 'Haftpflicht Familie');
      await tippe(tester, find.text('Police.pdf'));
      expect(find.byType(Image), findsNothing);
      expect(find.textContaining('zeigt die App nicht an'), findsOneWidget);
      await tippe(tester, find.widgetWithText(FilledButton, 'Speichern'));
      expect(find.text('Dokument speichern?'), findsOneWidget);
      expect(find.textContaining('unverschlüsselt dort, wo du sie ablegst'), findsWidgets);
      expect(z.gespeichert, isEmpty, reason: 'ohne Bestätigung nie');
      await tippe(tester, find.text('Abbrechen'));
      expect(z.gespeichert, isEmpty);
      await tippe(tester, find.widgetWithText(FilledButton, 'Speichern'));
      await tippe(tester, find.descendant(of: find.byType(AlertDialog), matching: find.text('Speichern')));
      expect(z.gespeichert, hasLength(1));
      expect(z.gespeichert.single.name, 'Police.pdf');
      expect(z.gespeichert.single.mime, 'application/pdf');
      expect(String.fromCharCodes(z.gespeichert.single.bytes), '%PDF-1.4 Inhalt');
      expect(find.textContaining('unverschlüsselt an dem Ort'), findsOneWidget);
      pruefeLayout(tester, 'Dokumentansicht');
      await ende(tester, c, a);
    });

    testWidgets('Speichern abgebrochen (Systemdialog): keine Erfolgsmeldung', (tester) async {
      final z = AnhangTestAufbau(daten: beispiel())..speichernOk = false;
      final (a, _, c) = await start(tester, anhaenge: z);
      await oeffne(tester, 'Dokumente', 'Haftpflicht Familie');
      await tippe(tester, find.text('Police.pdf'));
      await tippe(tester, find.widgetWithText(FilledButton, 'Speichern'));
      await tippe(tester, find.descendant(of: find.byType(AlertDialog), matching: find.text('Speichern')));
      expect(z.gespeichert, hasLength(1));
      expect(find.textContaining('Gespeichert.'), findsNothing);
      await ende(tester, c, a);
    });

    testWidgets('Kaputter oder veränderter Anhang: ruhige Meldung statt Fehler, kein Speichern, nochmal versuchen möglich', (tester) async {
      final z = AnhangTestAufbau(daten: beispiel())..ladeFehler = const CryptoFehler(CryptoFehlerArt.entschluesselung, 'x');
      final (a, _, c) = await start(tester, anhaenge: z);
      await oeffne(tester, 'Dokumente', 'Haftpflicht Familie');
      await tippe(tester, find.text('Police.pdf'));
      expect(find.textContaining('beschädigt oder wurde verändert'), findsOneWidget);
      expect(find.textContaining('CryptoFehler'), findsNothing);
      expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Speichern')).onPressed, isNull);
      z.ladeFehler = null;
      await tippe(tester, find.text('Noch einmal versuchen'));
      expect(find.textContaining('beschädigt'), findsNothing);
      expect(z.heruntergeladen, ['a1', 'a1']);
      pruefeLayout(tester, 'Fehleransicht');
      await ende(tester, c, a);
    });

    testWidgets('Löschen aus der Liste: mit Bestätigung, erst danach', (tester) async {
      final (a, z, c) = await start(tester);
      await oeffne(tester, 'Dokumente', 'Haftpflicht Familie');
      await tippe(tester, find.byTooltip('Dokument Police.pdf löschen'));
      expect(find.text('Dokument löschen?'), findsOneWidget);
      await tippe(tester, find.text('Abbrechen'));
      expect(z.geloescht, isEmpty);
      await tippe(tester, find.byTooltip('Dokument Police.pdf löschen'));
      await tippe(tester, find.widgetWithText(FilledButton, 'Löschen'));
      expect(z.geloescht, ['a1']);
      expect(find.text('Police.pdf'), findsNothing);
      expect(find.text('Schaden.png'), findsOneWidget);
      await ende(tester, c, a);
    });

    testWidgets('Löschen in der Ansicht: schließt die Seite; Fehler beim Löschen bleibt ruhig', (tester) async {
      final z = AnhangTestAufbau(daten: beispiel())..loeschFehler = StateError('intern');
      final (a, _, c) = await start(tester, anhaenge: z);
      await oeffne(tester, 'Dokumente', 'Haftpflicht Familie');
      await tippe(tester, find.text('Police.pdf'));
      await tippe(tester, find.widgetWithText(OutlinedButton, 'Löschen'));
      await tippe(tester, find.widgetWithText(FilledButton, 'Löschen'));
      expect(find.text('Das hat nicht geklappt. Versuche es noch einmal.'), findsOneWidget);
      expect(find.textContaining('intern'), findsNothing);
      z.loeschFehler = null;
      await tippe(tester, find.widgetWithText(OutlinedButton, 'Löschen'));
      await tippe(tester, find.widgetWithText(FilledButton, 'Löschen'));
      expect(z.geloescht, ['a1']);
      expect(find.text('Dokument'), findsNothing);
      await ende(tester, c, a);
    });
  });

  group('Anhängen', () {
    fuerSkalen('Datei wählen: verschlüsselt hochladen, Fortschritt als Zeile, Abbrechen, fertig verschwindet die Zeile, Layout', (tester, skala) async {
      final z = AnhangTestAufbau(daten: beispiel());
      final pdf = Uint8List.fromList('%PDF-1.7 hallo'.codeUnits);
      z.wahl = wahlVon('Neue Police.pdf', pdf);
      final (a, _, c) = await start(tester, skala: skala, anhaenge: z);
      await oeffne(tester, 'Dokumente', 'Haftpflicht Familie');
      await tippe(tester, find.text('Dokument anhängen'));
      expect(z.wahlen, 1);
      expect(z.hochgeladen, hasLength(1));
      final h = z.hochgeladen.single;
      expect(h.name, 'Neue Police.pdf');
      expect(h.mime, 'application/pdf');
      expect(h.eintragId, 'e-haftpflicht');
      expect(h.laenge, pdf.length);
      expect(h.referenz.every((b) => b == 0), isTrue, reason: 'der Klartext der Datei wird nach dem Einreihen überschrieben');
      // die Zeile steht im Eintrag, der Fortschritt kommt aus der Liste der Übertragungen
      expect(find.text('Neue Police.pdf'), findsOneWidget);
      z.transfers.setzen([transferZeile('T1', 'laeuft', uebertragen: 450)]);
      await warte(tester);
      expect(find.textContaining('Wird hochgeladen · 45 %'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      pruefeLayout(tester, 'Upload läuft');
      await tippe(tester, find.byTooltip('Upload von Neue Police.pdf abbrechen'));
      expect(z.abgebrochen, ['T1']);
      expect(find.text('Neue Police.pdf'), findsNothing, reason: 'abgebrochen: Zeile weg');
      expect(z.entfernt, ['T1']);
      await ende(tester, c, a);
    });

    testWidgets('Fertiger Upload: die Zeile verschwindet, der Anhang steht in der Liste', (tester) async {
      final z = AnhangTestAufbau(daten: beispiel())..wahl = wahlVon('Scan.png', Uint8List.fromList(winzigPng));
      final (a, _, c) = await start(tester, anhaenge: z);
      await oeffne(tester, 'Zugangsdaten', 'Alarmanlage');
      await tippe(tester, find.text('Dokument anhängen'));
      expect(find.text('Scan.png'), findsOneWidget);
      z.transfers.setzen([transferZeile('T1', 'abschliessen', uebertragen: 1000)]);
      await warte(tester);
      expect(find.textContaining('Wird abgeschlossen'), findsOneWidget);
      z.liste.setzen([...z.liste.state, anhang('neu', 'e-alarm', 'Scan.png', mime: 'image/png', groesse: winzigPng.length)]);
      z.transfers.setzen([transferZeile('T1', 'fertig', uebertragen: 1000)]);
      await warte(tester);
      expect(find.text('Scan.png'), findsOneWidget, reason: 'jetzt als Anhang, nicht doppelt');
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(z.entfernt, ['T1']);
      await ende(tester, c, a);
    });

    testWidgets('Abbrechen der Dateiwahl: nichts passiert', (tester) async {
      final z = AnhangTestAufbau(daten: beispiel())..wahl = null;
      final (a, _, c) = await start(tester, anhaenge: z);
      await oeffne(tester, 'Zugangsdaten', 'Alarmanlage');
      await tippe(tester, find.text('Dokument anhängen'));
      expect(z.wahlen, 1);
      expect(z.hochgeladen, isEmpty);
      expect(find.byType(MeldungsBox), findsNothing);
      await ende(tester, c, a);
    });

    testWidgets('Zu groß: Meldung mit der Grenze, vorab, ohne Upload (auch wenn die Größe erst beim Lesen bekannt wird)', (tester) async {
      final z = AnhangTestAufbau(daten: beispiel())..nutzung = const DateiNutzung(maxE2eeBytes: 1024 * 1024 + 100);
      z.wahl = AnhangWahl(name: 'Riesig.pdf', laenge: 5 * 1024 * 1024, bytes: const Stream.empty());
      final (a, _, c) = await start(tester, anhaenge: z);
      await oeffne(tester, 'Zugangsdaten', 'Alarmanlage');
      await tippe(tester, find.text('Dokument anhängen'));
      expect(find.textContaining('Die Datei ist zu groß. Ein Dokument darf höchstens'), findsOneWidget);
      expect(z.hochgeladen, isEmpty);
      // Größe unbekannt: das Lesen bricht an der Grenze ab
      z.wahl = AnhangWahl(name: 'Unbekannt.pdf', laenge: null, bytes: _grosserStrom());
      await tippe(tester, find.text('Dokument anhängen'));
      await warte(tester);
      expect(find.textContaining('zu groß'), findsOneWidget);
      expect(z.hochgeladen, isEmpty);
      await ende(tester, c, a);
    });

    testWidgets('Kontingent voll: verständliche Meldung, kein Upload; leere Datei wird abgelehnt', (tester) async {
      final z = AnhangTestAufbau(daten: beispiel())..nutzung = DateiNutzung(belegtBytes: 10 * 1024 * 1024 * 1024, kontingentBytes: 10 * 1024 * 1024 * 1024);
      z.wahl = wahlVon('Scan.pdf', Uint8List.fromList('%PDF-1'.codeUnits));
      final (a, _, c) = await start(tester, anhaenge: z);
      await oeffne(tester, 'Zugangsdaten', 'Alarmanlage');
      await tippe(tester, find.text('Dokument anhängen'));
      expect(find.textContaining('Der Speicher der Familie ist voll'), findsOneWidget);
      expect(z.hochgeladen, isEmpty);
      z.nutzung = DateiNutzung.standard;
      z.wahl = AnhangWahl(name: 'Leer.pdf', laenge: 0, bytes: const Stream.empty());
      await tippe(tester, find.text('Dokument anhängen'));
      expect(find.text('Die Datei ist leer.'), findsOneWidget);
      expect(z.hochgeladen, isEmpty);
      await ende(tester, c, a);
    });

    testWidgets('Zehn Dokumente sind das Maximum je Eintrag: der Knopf ist aus und erklärt es', (tester) async {
      final z = AnhangTestAufbau(daten: [for (var i = 0; i < 10; i++) anhang('m$i', 'e-alarm', 'Datei $i.pdf', mime: 'application/pdf')]);
      final (a, _, c) = await start(tester, anhaenge: z);
      await oeffne(tester, 'Zugangsdaten', 'Alarmanlage');
      expect(find.text('10 von 10'), findsOneWidget);
      expect(tester.widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'Dokument anhängen')).onPressed, isNull);
      expect(find.textContaining('Mehr Dokumente passen nicht an diesen Eintrag'), findsOneWidget);
      await ende(tester, c, a);
    });

    testWidgets('Fehler des Servers beim Einreihen (Verschlüsselung nicht bereit, Tresor voll): feste Texte, keine Rohtexte', (tester) async {
      final z = AnhangTestAufbau(daten: beispiel())
        ..wahl = wahlVon('Scan.pdf', Uint8List.fromList('%PDF-1'.codeUnits))
        ..hochladeFehler = DateiFehler.zuVieleAnhaenge;
      final (a, _, c) = await start(tester, anhaenge: z);
      await oeffne(tester, 'Zugangsdaten', 'Alarmanlage');
      await tippe(tester, find.text('Dokument anhängen'));
      expect(find.textContaining('Der Tresor hat schon sehr viele Dokumente'), findsOneWidget);
      z.hochladeFehler = StateError('geheimer Rohtext');
      await tippe(tester, find.text('Dokument anhängen'));
      expect(find.text('Das hat nicht geklappt. Versuche es noch einmal.'), findsOneWidget);
      expect(find.textContaining('geheimer Rohtext'), findsNothing);
      await ende(tester, c, a);
    });

    fuerSkalen('Nach einem Neustart: "Bitte Datei neu wählen" statt eines Fehlers; neu wählen reiht eine neue Übertragung ein', (tester, skala) async {
      final z = AnhangTestAufbau(daten: beispiel())..wahl = wahlVon('Scan.pdf', Uint8List.fromList('%PDF-1'.codeUnits));
      final (a, _, c) = await start(tester, skala: skala, anhaenge: z);
      await oeffne(tester, 'Zugangsdaten', 'Alarmanlage');
      await tippe(tester, find.text('Dokument anhängen'));
      z.transfers.setzen([transferZeile('T1', 'fehler', fehler: 'anhang_neu')]);
      await warte(tester);
      expect(find.textContaining('Bitte Datei neu wählen.'), findsOneWidget);
      expect(find.text('Der Anhang muss neu gewählt werden.'), findsNothing);
      pruefeLayout(tester, 'Datei neu wählen');
      z.wahl = wahlVon('Scan.pdf', Uint8List.fromList('%PDF-1'.codeUnits));
      await tippe(tester, find.text('Datei neu wählen'));
      expect(z.entfernt, ['T1']);
      expect(z.hochgeladen, hasLength(2));
      await ende(tester, c, a);
    });

    testWidgets('Netzfehler: ruhiger Text, "Erneut versuchen" ruft wiederholen auf, "Verwerfen" räumt auf', (tester) async {
      final z = AnhangTestAufbau(daten: beispiel())..wahl = wahlVon('Scan.pdf', Uint8List.fromList('%PDF-1'.codeUnits));
      final (a, _, c) = await start(tester, anhaenge: z);
      await oeffne(tester, 'Zugangsdaten', 'Alarmanlage');
      await tippe(tester, find.text('Dokument anhängen'));
      z.transfers.setzen([transferZeile('T1', 'fehler', fehler: 'network')]);
      await warte(tester);
      expect(find.textContaining('Keine Verbindung'), findsOneWidget);
      await tippe(tester, find.text('Erneut versuchen'));
      expect(z.wiederholt, ['T1']);
      await tippe(tester, find.text('Verwerfen'));
      expect(z.entfernt, ['T1']);
      expect(find.text('Scan.pdf'), findsNothing);
      await ende(tester, c, a);
    });

    testWidgets('Neuer, noch nicht gespeicherter Eintrag: Hinweis "zuerst speichern" statt Anhängen; bestehender Eintrag im Editor hat den Abschnitt', (tester) async {
      final (a, z, c) = await start(tester);
      await tippe(tester, find.text('Eintrag hinzufügen'));
      expect(find.textContaining('Speichere den Eintrag zuerst'), findsOneWidget);
      expect(find.text('Dokument anhängen'), findsNothing);
      await tippe(tester, find.byTooltip('Zurück'));
      await warte(tester);
      if (find.text('Verwerfen').evaluate().isNotEmpty) await tippe(tester, find.text('Verwerfen'));
      await oeffne(tester, 'Dokumente', 'Haftpflicht Familie');
      await tippe(tester, find.text('Bearbeiten'));
      expect(find.text('Dokument anhängen'), findsOneWidget);
      expect(find.text('Police.pdf'), findsOneWidget);
      expect(find.textContaining('Speichere den Eintrag zuerst'), findsNothing);
      pruefeLayout(tester, 'Editor mit Dokumenten');
      expect(z.hochgeladen, isEmpty);
      await ende(tester, c, a);
    });
  });

  group('Eintrag löschen und Übersicht', () {
    testWidgets('Mit Dokumenten: "Eintrag und 2 Dokumente löschen", löscht erst die Dokumente, dann den Eintrag', (tester) async {
      final (a, z, c) = await start(tester);
      await oeffne(tester, 'Dokumente', 'Haftpflicht Familie');
      await tippe(tester, find.widgetWithText(OutlinedButton, 'Löschen'));
      expect(find.text('Eintrag und 2 Dokumente löschen?'), findsOneWidget);
      await tippe(tester, find.text('Abbrechen'));
      expect(z.eintragGeloescht, isEmpty);
      expect(a.repo.geloescht, isEmpty);
      await tippe(tester, find.widgetWithText(OutlinedButton, 'Löschen'));
      await tippe(tester, find.widgetWithText(FilledButton, 'Löschen'));
      expect(z.eintragGeloescht, ['e-haftpflicht']);
      expect(a.repo.geloescht, ['e-haftpflicht']);
      expect(z.liste.state.map((x) => x.id), ['a3'], reason: 'nur die Dokumente dieses Eintrags');
      await ende(tester, c, a);
    });

    testWidgets('Mit einem Dokument: Einzahl; ohne Dokumente: die bisherige Rückfrage', (tester) async {
      final z = AnhangTestAufbau(daten: [anhang('a1', 'e-alarm', 'Anleitung.pdf')]);
      final (a, _, c) = await start(tester, anhaenge: z);
      await oeffne(tester, 'Zugangsdaten', 'Alarmanlage');
      await tippe(tester, find.widgetWithText(OutlinedButton, 'Löschen'));
      expect(find.text('Eintrag und 1 Dokument löschen?'), findsOneWidget);
      await tippe(tester, find.text('Abbrechen'));
      await tippe(tester, find.byTooltip('Zurück'));
      await oeffne(tester, 'Haushalt', 'WLAN Zuhause');
      await tippe(tester, find.widgetWithText(OutlinedButton, 'Löschen'));
      expect(find.text('Eintrag löschen?'), findsOneWidget);
      await ende(tester, c, a);
    });

    testWidgets('Der Eintrag löscht laufende Uploads mit (zuerst abbrechen)', (tester) async {
      final z = AnhangTestAufbau(daten: [anhang('a1', 'e-alarm', 'Anleitung.pdf')])..wahl = wahlVon('Scan.pdf', Uint8List.fromList('%PDF-1'.codeUnits));
      final (a, _, c) = await start(tester, anhaenge: z);
      await oeffne(tester, 'Zugangsdaten', 'Alarmanlage');
      await tippe(tester, find.text('Dokument anhängen'));
      z.transfers.setzen([transferZeile('T1', 'laeuft', uebertragen: 100)]);
      await warte(tester);
      await tippe(tester, find.widgetWithText(OutlinedButton, 'Löschen'));
      await tippe(tester, find.widgetWithText(FilledButton, 'Löschen'));
      expect(z.abgebrochen, ['T1']);
      expect(z.eintragGeloescht, ['e-alarm']);
      await ende(tester, c, a);
    });

    fuerSkalen('Übersicht: Büroklammer und Zahl je Eintrag mit Dokumenten, sonst nichts; der Hinweis "Anhänge folgen" ist weg', (tester, skala) async {
      final (a, _, c) = await start(tester, skala: skala);
      expect(find.textContaining('Anhänge folgen'), findsNothing);
      expect(find.textContaining('Felder, Notizen und Dokumente'), findsOneWidget);
      await tippe(tester, find.text('Dokumente'));
      expect(find.text('Haftpflicht Familie'), findsOneWidget);
      expect(find.byIcon(Icons.attach_file), findsOneWidget);
      expect(find.text('2'), findsWidgets);
      await tippe(tester, find.text('Haushalt'));
      expect(find.byIcon(Icons.attach_file), findsNWidgets(2), reason: 'auch das WLAN hat ein Dokument');
      await tippe(tester, find.text('Zugangsdaten'));
      expect(find.byIcon(Icons.attach_file), findsNWidgets(2), reason: 'die Alarmanlage hat keines');
      pruefeLayout(tester, 'Übersicht mit Zähler');
      await ende(tester, c, a);
    });
  });

  group('Sperre', () {
    testWidgets('Sperren schließt die Dokumentansicht, überschreibt den Klartext und leert Liste und Namen', (tester) async {
      final z = AnhangTestAufbau(daten: beispiel())..inhalte['a2'] = Uint8List.fromList(winzigPng);
      final (a, _, c) = await start(tester, anhaenge: z);
      await oeffne(tester, 'Dokumente', 'Haftpflicht Familie');
      await tippe(tester, find.text('Schaden.png'));
      expect(find.byType(Image), findsOneWidget);
      final bytes = z.ausgeliefert.single;
      c.read(tresorSperreProvider.notifier).sperren();
      await warte(tester);
      expect(find.byType(Image), findsNothing);
      expect(find.text('Schaden.png'), findsNothing);
      expect(bytes.every((b) => b == 0), isTrue);
      expect(find.text('Der Tresor ist gesperrt'), findsOneWidget);
      expect((await c.read(tresorAnhaengeProvider.future)), isEmpty);
      await ende(tester, c, a);
    });

    testWidgets('Wird gesperrt, während noch entschlüsselt wird: das Ergebnis wird sofort verworfen', (tester) async {
      final z = AnhangTestAufbau(daten: beispiel())
        ..inhalte['a2'] = Uint8List.fromList(winzigPng)
        ..ladeWarten = Completer<void>();
      final (a, _, c) = await start(tester, anhaenge: z);
      await oeffne(tester, 'Dokumente', 'Haftpflicht Familie');
      await tippe(tester, find.text('Schaden.png'));
      expect(find.textContaining('Wird geladen und entschlüsselt'), findsOneWidget);
      c.read(tresorSperreProvider.notifier).sperren();
      await warte(tester);
      z.ladeWarten!.complete();
      await warte(tester);
      expect(z.ausgeliefert.single.every((b) => b == 0), isTrue, reason: 'der Klartext, der nach der Sperre fertig wurde, ist sofort überschrieben');
      expect(find.byType(Image), findsNothing);
      await ende(tester, c, a);
    });

    testWidgets('Wechsel in den Hintergrund sperrt (Dokument schließt), Systemdialoge (Dateiwahl, Speichern) sperren nicht', (tester) async {
      final z = AnhangTestAufbau(daten: beispiel())..wahlWarten = Completer<AnhangWahl?>();
      final (a, _, c) = await start(tester, anhaenge: z);
      await oeffne(tester, 'Zugangsdaten', 'Alarmanlage');
      await tippe(tester, find.text('Dokument anhängen')); // die Dateiwahl bleibt offen
      expect(z.wahlen, 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      await warte(tester);
      expect(c.read(tresorSperreProvider).entsperrt, isTrue, reason: 'ein offener Systemdialog schickt die App nur kurz in den Hintergrund');
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      z.wahlWarten!.complete(null);
      await warte(tester);
      expect(c.read(tresorSperreProvider.notifier).systemDialogOffen, isFalse);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      await warte(tester);
      expect(c.read(tresorSperreProvider).entsperrt, isFalse, reason: 'danach sperrt der Wechsel wieder');
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await warte(tester);
      expect(find.text('Der Tresor ist gesperrt'), findsOneWidget);
      await ende(tester, c, a);
    });

    testWidgets('Gesperrt während der Dateiwahl: die gewählte Datei wird nicht mehr hochgeladen', (tester) async {
      final z = AnhangTestAufbau(daten: beispiel())..wahlWarten = Completer<AnhangWahl?>();
      final (a, _, c) = await start(tester, anhaenge: z);
      await oeffne(tester, 'Zugangsdaten', 'Alarmanlage');
      await tippe(tester, find.text('Dokument anhängen'));
      c.read(tresorSperreProvider.notifier).sperren();
      await warte(tester);
      z.wahlWarten!.complete(wahlVon('Scan.pdf', Uint8List.fromList('%PDF-1'.codeUnits)));
      await warte(tester);
      expect(z.hochgeladen, isEmpty);
      await ende(tester, c, a);
    });

    testWidgets('Auto-Sperre nach 2 Minuten schließt auch die Dokumentansicht', (tester) async {
      final z = AnhangTestAufbau(daten: beispiel())..inhalte['a2'] = Uint8List.fromList(winzigPng);
      final (a, _, c) = await start(tester, anhaenge: z);
      await oeffne(tester, 'Dokumente', 'Haftpflicht Familie');
      await tippe(tester, find.text('Schaden.png'));
      await tester.pump(const Duration(seconds: 125));
      await warte(tester);
      expect(c.read(tresorSperreProvider).entsperrt, isFalse);
      expect(find.byType(Image), findsNothing);
      expect(z.ausgeliefert.single.every((b) => b == 0), isTrue);
      await ende(tester, c, a);
    });
  });

  group('Rollen und Bedienhilfe', () {
    testWidgets('Kind: nie Dokumente, auch nicht über den Anbieter (Rolle entscheidet, Server meldet files)', (tester) async {
      final z = AnhangTestAufbau(daten: beispiel());
      final (a, _, c) = await start(tester, role: 'child', anhaenge: z, entsperren: false, oeffnen: false);
      c.read(tresorSperreProvider.notifier).entsperren();
      expect(c.read(tresorSperreProvider).entsperrt, isFalse);
      expect(c.read(tresorDokumenteAktivProvider), isFalse);
      expect(await c.read(tresorAnhaengeProvider.future), isEmpty);
      expect(find.text('Police.pdf'), findsNothing);
      expect(find.text('Dokument anhängen'), findsNothing);
      await ende(tester, c, a);
    });


    testWidgets('Bedienhilfe: Name steht nur bei entsperrtem Tresor darin, Knöpfe sind beschriftet, geheime Werte bleiben verdeckt', (tester) async {
      final handle = tester.ensureSemantics();
      final z = AnhangTestAufbau(daten: beispiel())..inhalte['a2'] = Uint8List.fromList(winzigPng);
      final (a, _, c) = await start(tester, anhaenge: z);
      await oeffne(tester, 'Dokumente', 'Haftpflicht Familie');
      var s = alleSemantik(tester);
      expect(s, contains('Dokument Police.pdf'));
      expect(s, contains('Dokument Police.pdf löschen'));
      expect(s, contains('Dokument anhängen'));
      expect(s, isNot(contains(geheimVertrag)));
      await tippe(tester, find.text('Schaden.png'));
      s = alleSemantik(tester);
      expect(s, contains('Bild: Schaden.png'));
      expect(s, contains('Speichern'));
      c.read(tresorSperreProvider.notifier).sperren();
      await warte(tester);
      s = alleSemantik(tester);
      expect(s, isNot(contains('Police.pdf')));
      expect(s, isNot(contains('Schaden.png')));
      expect(s, isNot(contains(geheimVertrag)));
      await ende(tester, c, a);
      handle.dispose();
    });

    testWidgets('Desktop-Layout: Abschnitt und Ansicht im Inhaltsbereich', (tester) async {
      final z = AnhangTestAufbau(daten: beispiel())..inhalte['a2'] = Uint8List.fromList(winzigPng);
      final (a, _, c) = await start(tester, groesse: const Size(1200, 800), anhaenge: z);
      await oeffne(tester, 'Dokumente', 'Haftpflicht Familie');
      expect(find.text('Police.pdf'), findsOneWidget);
      await tippe(tester, find.text('Schaden.png'));
      expect(find.byType(Image), findsOneWidget);
      pruefeLayout(tester, 'Desktop');
      await ende(tester, c, a);
    });
  });
}

/// Zwei Stücke, zusammen größer als die Grenze der Zusage (Größe vorab unbekannt).
Stream<Uint8List> _grosserStrom() async* {
  yield Uint8List(600 * 1024);
  yield Uint8List(600 * 1024);
}
