// Feiertage und Schulferien (Rheinland-Pfalz) als dezente Tageshinweise im Kalender. Rein lokal: nichts davon wird synchronisiert, nichts
// wird aus dem Netz geladen, nichts ist editierbar.
//  - Gesetzliche Feiertage werden berechnet (Ostern nach Gauß, die beweglichen Feiertage daraus), nicht als Liste gepflegt.
//  - Schulferien liegen als Asset `assets/kalender/schulferien_rlp.json` (Quelle, Stand und Hinweis "ohne Gewähr" im Dateikopf), 2026 bis 2028.
//  - Schalter "Feiertage", "Schulferien" und "Geburtstage": je lokal je Gerät in `sync_meta` (Standard: an).
// Tage sind wie überall im Kalender `DateTime.utc`-Markierungen der Familienzone.
import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database_provider.dart';
import 'expansion.dart' show tagAusText;

enum TagesHinweisArt { feiertag, ferien }

class TagesHinweis {
  final String name;
  final TagesHinweisArt art;

  /// Erster und letzter Tag (einschließlich); Feiertage: beide gleich.
  final DateTime von;
  final DateTime bis;
  const TagesHinweis({required this.name, required this.art, required this.von, required this.bis});

  bool faelltAuf(DateTime tag) => !tag.isBefore(von) && !tag.isAfter(bis);

  @override
  bool operator ==(Object other) => other is TagesHinweis && other.name == name && other.art == art && other.von == von && other.bis == bis;

  @override
  int get hashCode => Object.hash(name, art, von, bis);
}

/// Ostersonntag (Gregorianischer Kalender, Verfahren nach Gauß/Meeus).
DateTime ostersonntag(int jahr) {
  final a = jahr % 19;
  final b = jahr ~/ 100;
  final c = jahr % 100;
  final d = b ~/ 4;
  final e = b % 4;
  final f = (b + 8) ~/ 25;
  final g = (b - f + 1) ~/ 3;
  final h = (19 * a + b - d - g + 15) % 30;
  final i = c ~/ 4;
  final k = c % 4;
  final l = (32 + 2 * e + 2 * i - h - k) % 7;
  final m = (a + 11 * h + 22 * l) ~/ 451;
  final monat = (h + l - 7 * m + 114) ~/ 31;
  final tag = (h + l - 7 * m + 114) % 31 + 1;
  return DateTime.utc(jahr, monat, tag);
}

/// Gesetzliche Feiertage in Rheinland-Pfalz eines Jahres (ohne Oster- und Pfingstsonntag, die dort keine gesetzlichen Feiertage sind).
List<TagesHinweis> feiertageRlp(int jahr) {
  final ostern = ostersonntag(jahr);
  DateTime nach(int tage) => ostern.add(Duration(days: tage));
  TagesHinweis f(String name, DateTime tag) => TagesHinweis(name: name, art: TagesHinweisArt.feiertag, von: tag, bis: tag);
  return [
    f('Neujahr', DateTime.utc(jahr, 1, 1)),
    f('Karfreitag', nach(-2)),
    f('Ostermontag', nach(1)),
    f('Tag der Arbeit', DateTime.utc(jahr, 5, 1)),
    f('Christi Himmelfahrt', nach(39)),
    f('Pfingstmontag', nach(50)),
    f('Fronleichnam', nach(60)),
    f('Tag der Deutschen Einheit', DateTime.utc(jahr, 10, 3)),
    f('Allerheiligen', DateTime.utc(jahr, 11, 1)),
    f('1. Weihnachtstag', DateTime.utc(jahr, 12, 25)),
    f('2. Weihnachtstag', DateTime.utc(jahr, 12, 26)),
  ];
}

/// Liest die Ferien aus dem Text der Asset-Datei; fehlerhafte Einträge werden übersprungen (nie ein Absturz wegen der Zusatzanzeige).
List<TagesHinweis> ferienAusJson(String text) {
  try {
    final j = jsonDecode(text);
    if (j is! Map || j['ferien'] is! List) return const [];
    final out = <TagesHinweis>[];
    for (final e in j['ferien'] as List) {
      if (e is! Map) continue;
      final name = e['name'];
      final von = tagAusText(e['von'] is String ? e['von'] as String : null);
      final bis = tagAusText(e['bis'] is String ? e['bis'] as String : null);
      if (name is! String || name.isEmpty || von == null || bis == null || bis.isBefore(von)) continue;
      out.add(TagesHinweis(name: name, art: TagesHinweisArt.ferien, von: von, bis: bis));
    }
    return out;
  } catch (_) {
    return const [];
  }
}

/// Alle Hinweise: Feiertage werden für das jeweils angezeigte Jahr berechnet (kein festes Fenster, jedes Jahr ab 1583 stimmt), Ferien kommen aus dem Asset.
class TagesHinweise {
  final List<TagesHinweis> ferien;
  final bool feiertageAn;
  final Map<int, List<TagesHinweis>> _feiertage = {};
  TagesHinweise(this.ferien, {this.feiertageAn = true});
  static final leer = TagesHinweise(const [], feiertageAn: false);

  /// Wie [TagesHinweise.new] (die Jahre ergeben sich aus den abgefragten Tagen).
  factory TagesHinweise.aus({required Iterable<TagesHinweis> ferien}) => TagesHinweise(List.of(ferien));

  bool get istLeer => ferien.isEmpty && !feiertageAn;

  List<TagesHinweis> _feiertageVon(int jahr) => feiertageAn ? _feiertage.putIfAbsent(jahr, () => feiertageRlp(jahr)) : const [];

  /// Hinweise, die an [tag] gelten (Feiertage zuerst).
  List<TagesHinweis> fuerTag(DateTime tag) => [
    for (final h in _feiertageVon(tag.year))
      if (h.faelltAuf(tag)) h,
    for (final h in ferien)
      if (h.faelltAuf(tag)) h,
  ];

  /// Agenda: Feiertage an ihrem Tag, Ferien nur am ersten sichtbaren Tag ([von] oder ihr Beginn), damit sie nicht an jedem Tag wiederholt werden.
  Map<DateTime, List<TagesHinweis>> fuerAgenda(DateTime von, DateTime bisInklusive) {
    final out = <DateTime, List<TagesHinweis>>{};
    for (var j = von.year; j <= bisInklusive.year; j++) {
      for (final h in _feiertageVon(j)) {
        if (!h.von.isBefore(von) && !h.von.isAfter(bisInklusive)) out.putIfAbsent(h.von, () => []).add(h);
      }
    }
    for (final h in ferien) {
      if (h.bis.isBefore(von) || h.von.isAfter(bisInklusive)) continue;
      out.putIfAbsent(h.von.isAfter(von) ? h.von : von, () => []).add(h);
    }
    return out;
  }
}

const kSchulferienAsset = 'assets/kalender/schulferien_rlp.json';

/// Die mitgelieferten Ferien (einmal geladen).
final ferienProvider = FutureProvider<List<TagesHinweis>>((ref) async => ferienAusJson(await rootBundle.loadString(kSchulferienAsset)));

/// Schlüssel in `sync_meta` ("nein" = aus): Feiertage; Schulferien und Geburtstage haben eigene Schlüssel (ohne eigenen Wert gilt für die
/// Ferien der Wert der Feiertage, wie vor der Trennung beider Schalter).
const kFeiertageSchluessel = 'kalender_feiertage';
const kFerienSchluessel = 'kalender_ferien';
const kGeburtstageSchluessel = 'kalender_geburtstage';

/// Zuletzt gewählte Kalender-Ansicht ("agenda", "monat", "woche"; lokal je Gerät, Standard: Monat).
const kKalenderAnsichtSchluessel = 'kalender_ansicht';

abstract class FeiertageSpeicher {
  Future<String?> lesen({String schluessel = kFeiertageSchluessel});
  Future<void> schreiben(String wert, {String schluessel = kFeiertageSchluessel});
}

class DatenbankFeiertageSpeicher implements FeiertageSpeicher {
  final Ref _ref;
  DatenbankFeiertageSpeicher(this._ref);

  @override
  Future<String?> lesen({String schluessel = kFeiertageSchluessel}) => _ref.read(appDatabaseProvider).metaLesen(schluessel);

  @override
  Future<void> schreiben(String wert, {String schluessel = kFeiertageSchluessel}) => _ref.read(appDatabaseProvider).metaSchreiben(schluessel, wert);
}

class MemoryFeiertageSpeicher implements FeiertageSpeicher {
  final Map<String, String> werte = {};
  MemoryFeiertageSpeicher([String? wert, Map<String, String> weitere = const {}]) {
    if (wert != null) werte[kFeiertageSchluessel] = wert;
    werte.addAll(weitere);
  }

  @override
  Future<String?> lesen({String schluessel = kFeiertageSchluessel}) async => werte[schluessel];

  @override
  Future<void> schreiben(String w, {String schluessel = kFeiertageSchluessel}) async => werte[schluessel] = w;
}

final feiertageSpeicherProvider = Provider<FeiertageSpeicher>((ref) => DatenbankFeiertageSpeicher(ref));

/// Lokaler Ein/Aus-Schalter der Kalenderanzeige (Standard: an; je Gerät in `sync_meta`).
abstract class AnzeigeSchalter extends Notifier<bool> {
  String get schluessel;

  /// Ersatzschlüssel, wenn der eigene Wert fehlt.
  String? get ersatzSchluessel => null;
  bool _gesetzt = false;

  @override
  bool build() {
    _gesetzt = false;
    _laden();
    return true;
  }

  Future<void> _laden() async {
    try {
      final speicher = ref.read(feiertageSpeicherProvider);
      var w = await speicher.lesen(schluessel: schluessel);
      if (w == null && ersatzSchluessel != null) w = await speicher.lesen(schluessel: ersatzSchluessel!);
      if (ref.mounted && !_gesetzt && w == 'nein') state = false;
    } catch (_) {
      // nicht lesbar: Standard (an)
    }
  }

  Future<void> setzen(bool an) async {
    _gesetzt = true;
    state = an;
    try {
      await ref.read(feiertageSpeicherProvider).schreiben(an ? 'ja' : 'nein', schluessel: schluessel);
    } catch (_) {
      // gilt dann nur bis zum Schließen der App
    }
  }
}

/// Schalter "Feiertage anzeigen".
class FeiertageAnzeigenNotifier extends AnzeigeSchalter {
  @override
  String get schluessel => kFeiertageSchluessel;
}

/// Schalter "Schulferien anzeigen".
class FerienAnzeigenNotifier extends AnzeigeSchalter {
  @override
  String get schluessel => kFerienSchluessel;
  @override
  String? get ersatzSchluessel => kFeiertageSchluessel;
}

/// Schalter "Geburtstage anzeigen" (blendet Geburtstage in Agenda, Monat und Woche aus; sie bleiben als Termine bestehen).
class GeburtstageAnzeigenNotifier extends AnzeigeSchalter {
  @override
  String get schluessel => kGeburtstageSchluessel;
}

final feiertageAnzeigenProvider = NotifierProvider<FeiertageAnzeigenNotifier, bool>(FeiertageAnzeigenNotifier.new);
final ferienAnzeigenProvider = NotifierProvider<FerienAnzeigenNotifier, bool>(FerienAnzeigenNotifier.new);
final geburtstageAnzeigenProvider = NotifierProvider<GeburtstageAnzeigenNotifier, bool>(GeburtstageAnzeigenNotifier.new);

/// Hinweise für die Oberfläche: Feiertage sofort, Ferien sobald das Asset geladen ist; je nach Schalter.
final tagesHinweiseProvider = Provider.autoDispose<TagesHinweise>((ref) {
  final feiertage = ref.watch(feiertageAnzeigenProvider);
  final ferien = ref.watch(ferienAnzeigenProvider);
  if (!feiertage && !ferien) return TagesHinweise.leer;
  return TagesHinweise(ferien ? (ref.watch(ferienProvider).value ?? const <TagesHinweis>[]) : const <TagesHinweis>[], feiertageAn: feiertage);
});
