// Gemeinsame Bausteine der Tresor-Oberflächentests: Beispiel-Einträge (nur erfundene Werte), ein aufzeichnendes Repository, eine Zwischenablage zum Beobachten und die Überschreibungen
// (Daten ohne Schlüsselmaterial, Bestätigung, Uhr). Die Daten folgen dem Sperrzustand wie im echten Anbieter: gesperrt = leer.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:lx_fampad/data/tresor/tresor_daten.dart';
import 'package:lx_fampad/data/tresor/tresor_modelle.dart';
import 'package:lx_fampad/data/tresor/tresor_repository.dart';
import 'package:lx_fampad/data/tresor/tresor_sperre.dart';
import 'package:lx_fampad/data/tresor/tresor_zwischenablage.dart';
import 'package:lx_fampad/features/tresor/tresor_bausteine.dart';

/// Erfundene Geheimnisse der Beispieldaten (Tests suchen danach im Widgetbaum und in der Bedienhilfe).
const geheimWlan = 'Sonne-Mond-4711!';
const geheimVertrag = 'HV-0048213-GEHEIM';
const geheimNotiz = 'Gästenetz: gast / Notiz-GEHEIM';
const offenNetz = 'FamilieNetz';

TresorAnsicht ansicht(String id, TresorInhalt i, {bool lokalNeu = false}) =>
    TresorAnsicht(id: id, konversationId: 'k', inhalt: i, hinweis: null, bearbeiterId: 'a', erstelltAt: DateTime.utc(2026, 1, 1), lokalNeu: lokalNeu);

TresorInhalt wlan() => const TresorInhalt(
  kategorie: TresorKategorie.haushalt,
  titel: 'WLAN Zuhause',
  felder: [
    TresorFeld(bezeichnung: 'Netzname', wert: offenNetz),
    TresorFeld(bezeichnung: 'Passwort', wert: geheimWlan, geheim: true),
    TresorFeld(bezeichnung: 'Router-Adresse', wert: '192.168.178.1'),
  ],
  notiz: geheimNotiz,
  vorlage: TresorVorlage.wlan,
  geaendert: 1789000000000, // 2026-09-10
);

List<TresorAnsicht> beispiele() => [
  ansicht('e-wlan', wlan()),
  ansicht(
    'e-haftpflicht',
    const TresorInhalt(
      kategorie: TresorKategorie.dokumente,
      titel: 'Haftpflicht Familie',
      felder: [TresorFeld(bezeichnung: 'Versicherer', wert: 'Allianz'), TresorFeld(bezeichnung: 'Vertragsnummer', wert: geheimVertrag, geheim: true)],
      vorlage: TresorVorlage.versicherung,
    ),
  ),
  ansicht('e-arzt', const TresorInhalt(kategorie: TresorKategorie.notfall, titel: 'Kinderarzt Emil', felder: [TresorFeld(bezeichnung: 'Praxis', wert: 'Dr. Muster'), TresorFeld(bezeichnung: 'Telefon', wert: '06131 123456')])),
  ansicht('e-alarm', const TresorInhalt(kategorie: TresorKategorie.zugang, titel: 'Alarmanlage', felder: [TresorFeld(bezeichnung: 'Code', wert: '9911', geheim: true)])),
  ansicht('e-hobby', const TresorInhalt(kategorie: TresorKategorie.eigene, kategorieName: 'Hobby', titel: 'Vereinskonto', felder: [TresorFeld(bezeichnung: 'Verein', wert: 'Ruderclub')])),
];

/// Hält die Einträge in einem Provider, den ein Test ändert.
class TestTresorEintraege extends Notifier<List<TresorAnsicht>> {
  final List<TresorAnsicht> start;
  TestTresorEintraege(this.start);
  @override
  List<TresorAnsicht> build() => start;
  void setzen(List<TresorAnsicht> d) => state = d;
}

class TresorRepoAttrappe implements TresorRepository {
  final angelegt = <TresorInhalt>[];
  final geaendert = <({String id, TresorInhalt inhalt})>[];
  final geloescht = <String>[];
  Object? fehler;

  @override
  Future<String> anlegen(TresorInhalt inhalt) async {
    if (fehler != null) throw fehler!;
    angelegt.add(inhalt);
    return 'neu${angelegt.length}';
  }

  @override
  Future<void> aendern(String id, TresorInhalt neu) async {
    if (fehler != null) throw fehler!;
    geaendert.add((id: id, inhalt: neu));
  }

  @override
  Future<void> loeschen(String id) async {
    if (fehler != null) throw fehler!;
    geloescht.add(id);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError('${invocation.memberName}');
}

/// Zwischenablage zum Beobachten (nur Text), mit der echten Logik von [TresorZwischenablage].
class ZwischenablageAttrappe {
  String? inhalt;
  final kopiert = <String>[];
  bool lesbar = true;
  late final TresorZwischenablage dienst = TresorZwischenablage(
    setzen: (t, g) async {
      inhalt = t;
      kopiert.add(t);
    },
    lesen: () async {
      if (!lesbar) throw StateError('nicht lesbar');
      return inhalt;
    },
    leeren: () async => inhalt = '',
  );
}

/// Überschreibungen für den Tresor: Einträge, Bestätigung (zählt Aufrufe), feste Uhr, Zwischenablage, Repository.
class TresorTestAufbau {
  final TresorRepoAttrappe repo = TresorRepoAttrappe();
  final ZwischenablageAttrappe ablage = ZwischenablageAttrappe();
  late final NotifierProvider<TestTresorEintraege, List<TresorAnsicht>> eintraege;
  var bestaetigungen = 0;
  var bestaetigungOk = true;

  /// Ohne Ersatz der Bestätigung: der echte Step-up-Dialog läuft gegen den Fake-Server.
  final bool echteBestaetigung;

  TresorTestAufbau({List<TresorAnsicht>? daten, this.echteBestaetigung = false}) {
    final start = daten ?? beispiele();
    eintraege = NotifierProvider<TestTresorEintraege, List<TresorAnsicht>>(() => TestTresorEintraege(start));
  }

  List<Override> get overrides => [
    tresorDatenProvider.overrideWith((ref) {
      // wie der echte Anbieter: gesperrt (oder ohne Recht) ist alles leer
      if (!ref.watch(tresorSperreProvider.select((s) => s.entsperrt))) return const TresorDaten();
      return TresorDaten(offen: true, geladen: true, eintraege: ref.watch(eintraege));
    }),
    tresorRepositoryProvider.overrideWithValue(repo),
    tresorZwischenablageProvider.overrideWithValue(ablage.dienst),
    if (!echteBestaetigung)
      tresorBestaetigenProvider.overrideWithValue((context) async {
        bestaetigungen++;
        return bestaetigungOk;
      }),
    tresorJetztProvider.overrideWithValue(() => DateTime(2026, 10, 24, 14, 0)),
  ];
}
