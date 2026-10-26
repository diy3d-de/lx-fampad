// Gemeinsame Bausteine der Zähler-Tests (Teil 2): Beispiel-Zähler mit Ständen relativ zu heute, aus denen ein ZaehlerDaten entsteht (ohne Datenbank und Schlüssel), und ein aufzeichnendes Repository.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lx_fampad/features/calendar/calendar_anzeige.dart' show minutenTaktProvider;
import 'package:lx_fampad/data/medikamente/medikament_logik.dart' show familienTag;
import 'package:lx_fampad/data/medikamente/medikament_modelle.dart' show tagText;
import 'package:lx_fampad/data/zaehler/zaehler_logik.dart';
import 'package:lx_fampad/data/zaehler/zaehler_modelle.dart';
import 'package:lx_fampad/data/zaehler/zaehler_monate.dart';
import 'package:lx_fampad/data/zaehler/zaehler_repository.dart';
import 'package:lx_fampad/data/zaehler/zaehler_state.dart';
import 'package:lx_fampad/data/zaehler/zaehler_uebersicht.dart';

const zStrom = 'aaaaaaaa-0000-4000-8000-000000000001';
const zKalt1 = 'aaaaaaaa-0000-4000-8000-000000000002';
const zKalt2 = 'aaaaaaaa-0000-4000-8000-000000000003';
const zWarm = 'aaaaaaaa-0000-4000-8000-000000000004';
const zSolar = 'aaaaaaaa-0000-4000-8000-000000000005';

/// Fester Zeitpunkt der Oberflächen-Tests (Samstag, 24. Oktober 2026, 12:00 Uhr in Berlin): Stände und Fälligkeiten rechnen damit, nicht mit der Uhr des Rechners.
final kJetzt = DateTime.utc(2026, 10, 24, 10);

DateTime heuteTag() => familienTag(kJetzt);

/// Der n-te Tag des Monats [monateZurueck] Monate vor dem aktuellen Monat.
DateTime tagVor(int monateZurueck, [int tag = 1]) {
  final h = heuteTag();
  return DateTime.utc(h.year, h.month - monateZurueck, tag);
}

/// Monatliche Stände ab [anzahl] Monaten zurück bis zum Ersten des aktuellen Monats; [proMonat] Einheiten Verbrauch je Monat ab [start] Einheiten.
List<Stand> monatsStaende({int anzahl = 40, double start = 1000, double proMonat = 300}) => [
  for (var i = 0; i <= anzahl; i++) Stand(tagVor(anzahl - i), ((start + proMonat * i) * 1000).round()),
];

class ZaehlerBeispiel {
  final String id;
  final ZaehlerInhalt inhalt;
  final List<Stand> staende;

  /// Nur für die Eingabeart Monatswerte.
  final List<MonatsWert> monatswerte;
  const ZaehlerBeispiel(this.id, this.inhalt, this.staende, [this.monatswerte = const []]);
}

/// Monatswerte der letzten [anzahl] vollen Monate (neuester = Vormonat) plus optional der laufende Monat als Zwischenstand; [kwh] je Monat von [start] aus um [schritt] steigend.
List<MonatsWert> monatsWerte({int anzahl = 30, double start = 20, double schritt = 1, double? laufend, bool vormonatAuslassen = false}) {
  final h = heuteTag();
  final out = <MonatsWert>[];
  for (var i = anzahl; i >= 1; i--) {
    if (i == 1 && vormonatAuslassen) continue;
    final t = DateTime.utc(h.year, h.month - i, 1);
    out.add(MonatsWert(jahr: t.year, monat: t.month, milli: ((start + schritt * (anzahl - i)) * 1000).round(), zeit: 1, id: 'm${t.year}-${t.month}'));
  }
  if (laufend != null) out.add(MonatsWert(jahr: h.year, monat: h.month, milli: (laufend * 1000).round(), zeit: 1, id: 'laufend'));
  return out;
}

/// Balkonkraftwerk ohne Zähler: Eingabeart Monatswerte.
ZaehlerBeispiel solarMonate({List<MonatsWert>? werte, String id = zSolar, String name = 'Balkonkraftwerk'}) => ZaehlerBeispiel(
  id,
  ZaehlerInhalt(
    art: ZaehlerArt.erzeugung,
    name: name,
    modus: ZaehlerModus.monat,
    preise: const [Preis(ab: '2020-01-01', arbeitspreis: 3100)],
    eigenverbrauchBp: 8000,
    anlagenkosten: 44900,
  ),
  const [],
  werte ?? monatsWerte(),
);

ZaehlerBeispiel strom({List<Stand>? staende, Ablesung? ablesung = const Ablesung.monatlich(1), String nummer = '1EMH0012345', int? warn}) => ZaehlerBeispiel(
  zStrom,
  ZaehlerInhalt(
    art: ZaehlerArt.strom,
    name: 'Strom',
    nummer: nummer,
    ablesung: ablesung,
    preise: const [Preis(ab: '2020-01-01', arbeitspreis: 3100, grundgebuehrJahr: 13800, zaehlergebuehrJahr: 2400)],
    abschlag: 9500,
    warnProzent: warn,
  ),
  staende ?? monatsStaende(),
);

ZaehlerBeispiel wasser(String id, String name, {ZaehlerArt art = ZaehlerArt.kaltwasser, String gruppe = 'Wasser Wohnung', double start = 100, double proMonat = 3, List<Stand>? staende}) => ZaehlerBeispiel(
  id,
  ZaehlerInhalt(art: art, name: name, gruppe: gruppe),
  staende ?? monatsStaende(start: start, proMonat: proMonat),
);

ZaehlerBeispiel solar({List<Stand>? staende}) => ZaehlerBeispiel(
  zSolar,
  ZaehlerInhalt(
    art: ZaehlerArt.erzeugung,
    name: 'Balkonkraftwerk',
    preise: const [Preis(ab: '2020-01-01', arbeitspreis: 3100)],
    eigenverbrauchBp: 8000,
    anlagenkosten: 44900,
  ),
  staende ?? monatsStaende(start: 0, proMonat: 40),
);

ZaehlerDaten datenAus(List<ZaehlerBeispiel> b, {String ich = 'a', bool geladen = true, bool darf = true}) {
  final eintraege = [
    for (final z in b)
      ZaehlerEintrag(
        ZaehlerAnsicht(id: z.id, konversationId: 'k', inhalt: z.inhalt, erstelltAt: DateTime.utc(2026, 1, 1)),
        [
          for (var i = 0; i < z.staende.length; i++)
            StandAnsicht(id: '${z.id}-s$i', zaehlerId: z.id, inhalt: StandInhalt(datum: tagText(z.staende[i].tag), milli: z.staende[i].milli, marke: z.staende[i].marke, automatisch: z.inhalt.automatisch), erstelltAt: DateTime.utc(2026, 1, 1, 0, 0, i)),
          for (final w in z.monatswerte)
            StandAnsicht(id: w.id, zaehlerId: z.id, inhalt: StandInhalt.monatswert(monat: w.schluessel, milli: w.milli, zeit: w.zeit, notiz: w.notiz), erstelltAt: DateTime.utc(2026, 1, 1)),
        ],
      ),
  ];
  final reihen = baueReihen({for (final z in b) z.id: z.inhalt}, {for (final z in b) z.id: z.staende}, monatswerte: {for (final z in b) z.id: z.monatswerte}, heute: heuteTag());
  return ZaehlerDaten(geladen: geladen, ich: ich, darf: darf, eintraege: eintraege, reihen: reihen, kacheln: baueKacheln(reihen));
}

/// Hält ZaehlerDaten in einem Provider, den ein Test überschreibt und ändert.
class TestZaehlerDaten extends Notifier<ZaehlerDaten> {
  final ZaehlerDaten start;
  TestZaehlerDaten(this.start);
  @override
  ZaehlerDaten build() => start;
  void setzen(ZaehlerDaten d) => state = d;
}

class ZaehlerRepoAttrappe implements ZaehlerRepository {
  final angelegt = <ZaehlerInhalt>[];
  final geaendert = <({String id, ZaehlerInhalt inhalt})>[];
  final erfasst = <({String id, DateTime datum, int milli, String notiz})>[];
  final standAenderungen = <({String id, DateTime? datum, int? milli})>[];
  final aufrufe = <String>[];
  final wechsel = <({String id, int ende, int start})>[];
  final monatswertErfasst = <({String id, int jahr, int monat, int milli})>[];
  Object? fehler;
  MonatswertPlausibilitaet monatswertHinweis = const MonatswertPlausibilitaet([]);

  @override
  Future<String> monatswertErfassen(String zaehlerId, {required int jahr, required int monat, required int milli, String notiz = ''}) async {
    if (fehler != null) throw fehler!;
    monatswertErfasst.add((id: zaehlerId, jahr: jahr, monat: monat, milli: milli));
    return 'm';
  }

  @override
  Future<void> monatswertLoeschen(String zaehlerId, {required int jahr, required int monat}) async => aufrufe.add('monatswertLoeschen:$zaehlerId:$jahr-$monat');

  @override
  Future<MonatswertPlausibilitaet> monatswertPruefen(String zaehlerId, {required int jahr, required int monat, required int milli}) async => monatswertHinweis;

  @override
  Future<String> anlegen(ZaehlerInhalt inhalt) async {
    if (fehler != null) throw fehler!;
    angelegt.add(inhalt);
    return 'neu${angelegt.length}';
  }

  @override
  Future<void> aendern(String id, ZaehlerInhalt neu) async {
    if (fehler != null) throw fehler!;
    geaendert.add((id: id, inhalt: neu));
  }

  @override
  Future<String> standErfassen(String zaehlerId, {required DateTime datum, required int milli, String notiz = '', StandMarke? marke, bool automatisch = false}) async {
    if (fehler != null) throw fehler!;
    erfasst.add((id: zaehlerId, datum: datum, milli: milli, notiz: notiz));
    return 's';
  }

  @override
  Future<void> standAendern(String standId, {DateTime? datum, int? milli, String? notiz}) async => standAenderungen.add((id: standId, datum: datum, milli: milli));

  @override
  Future<void> standLoeschen(String standId) async => aufrufe.add('standLoeschen:$standId');

  @override
  Future<void> archivieren(String id, {DateTime? ab}) async => aufrufe.add('archivieren:$id');

  @override
  Future<void> reaktivieren(String id) async => aufrufe.add('reaktivieren:$id');

  @override
  Future<void> loeschen(String id) async => aufrufe.add('loeschen:$id');

  @override
  Future<String> zaehlerWechseln(String alterId, {required DateTime datum, required int endstandMilli, required int startstandMilli, ZaehlerInhalt Function(ZaehlerInhalt alt)? neu}) async {
    wechsel.add((id: alterId, ende: endstandMilli, start: startstandMilli));
    return 'neu';
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError('${invocation.memberName}');
}

/// Überschreibung der Uhr der Oberfläche (Minutentakt) mit dem festen Zeitpunkt [kJetzt].
final zaehlerTestUhr = minutenTaktProvider.overrideWith((ref) => Stream.value(kJetzt));
