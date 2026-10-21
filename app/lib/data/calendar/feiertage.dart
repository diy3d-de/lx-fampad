// Feiertage und Schulferien (Rheinland-Pfalz) als dezente Tageshinweise im Kalender. Rein lokal: nichts davon wird synchronisiert, nichts
// wird aus dem Netz geladen, nichts ist editierbar.
//  - Gesetzliche Feiertage werden berechnet (Ostern nach Gauß, die beweglichen Feiertage daraus), nicht als Liste gepflegt.
//  - Schulferien liegen als Asset `assets/kalender/schulferien_rlp.json` (Quelle, Stand und Hinweis "ohne Gewähr" im Dateikopf), 2026 bis 2028.
//  - Schalter "Feiertage und Ferien anzeigen": lokal je Gerät in `sync_meta` (Standard: an).
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

/// Alle Hinweise (Feiertage berechnet, Ferien gelesen) für die Jahre, die der Kalender sinnvoll zeigt.
class TagesHinweise {
  final List<TagesHinweis> alle;
  const TagesHinweise(this.alle);
  static const leer = TagesHinweise([]);

  /// Feiertage der Jahre [vonJahr] bis [bisJahr] und die übergebenen Ferien.
  factory TagesHinweise.aus({required Iterable<TagesHinweis> ferien, required int vonJahr, required int bisJahr}) {
    final liste = <TagesHinweis>[for (var j = vonJahr; j <= bisJahr; j++) ...feiertageRlp(j), ...ferien];
    liste.sort((a, b) {
      final t = a.von.compareTo(b.von);
      return t != 0 ? t : a.art.index.compareTo(b.art.index);
    });
    return TagesHinweise(liste);
  }

  bool get istLeer => alle.isEmpty;

  /// Hinweise, die an [tag] gelten (Feiertage zuerst).
  List<TagesHinweis> fuerTag(DateTime tag) => [
    for (final h in alle)
      if (h.faelltAuf(tag)) h,
  ]..sort((a, b) => a.art.index.compareTo(b.art.index));

  /// Agenda: Feiertage an ihrem Tag, Ferien nur am ersten sichtbaren Tag ([von] oder ihr Beginn), damit sie nicht an jedem Tag wiederholt werden.
  Map<DateTime, List<TagesHinweis>> fuerAgenda(DateTime von, DateTime bisInklusive) {
    final out = <DateTime, List<TagesHinweis>>{};
    for (final h in alle) {
      if (h.bis.isBefore(von) || h.von.isAfter(bisInklusive)) continue;
      final tag = h.art == TagesHinweisArt.feiertag || h.von.isAfter(von) ? h.von : von;
      out.putIfAbsent(tag, () => []).add(h);
    }
    return out;
  }
}

const kSchulferienAsset = 'assets/kalender/schulferien_rlp.json';

/// Die mitgelieferten Ferien (einmal geladen).
final ferienProvider = FutureProvider<List<TagesHinweis>>((ref) async => ferienAusJson(await rootBundle.loadString(kSchulferienAsset)));

/// Schlüssel in `sync_meta` ("nein" = aus).
const kFeiertageSchluessel = 'kalender_feiertage';

abstract class FeiertageSpeicher {
  Future<String?> lesen();
  Future<void> schreiben(String wert);
}

class DatenbankFeiertageSpeicher implements FeiertageSpeicher {
  final Ref _ref;
  DatenbankFeiertageSpeicher(this._ref);

  @override
  Future<String?> lesen() => _ref.read(appDatabaseProvider).metaLesen(kFeiertageSchluessel);

  @override
  Future<void> schreiben(String wert) => _ref.read(appDatabaseProvider).metaSchreiben(kFeiertageSchluessel, wert);
}

class MemoryFeiertageSpeicher implements FeiertageSpeicher {
  String? wert;
  MemoryFeiertageSpeicher([this.wert]);

  @override
  Future<String?> lesen() async => wert;

  @override
  Future<void> schreiben(String w) async => wert = w;
}

final feiertageSpeicherProvider = Provider<FeiertageSpeicher>((ref) => DatenbankFeiertageSpeicher(ref));

/// Schalter "Feiertage und Ferien anzeigen" (Standard: an; lokal je Gerät).
class FeiertageAnzeigenNotifier extends Notifier<bool> {
  bool _gesetzt = false;

  @override
  bool build() {
    _gesetzt = false;
    _laden();
    return true;
  }

  Future<void> _laden() async {
    try {
      final w = await ref.read(feiertageSpeicherProvider).lesen();
      if (ref.mounted && !_gesetzt && w == 'nein') state = false;
    } catch (_) {
      // nicht lesbar: Standard (an)
    }
  }

  Future<void> setzen(bool an) async {
    _gesetzt = true;
    state = an;
    try {
      await ref.read(feiertageSpeicherProvider).schreiben(an ? 'ja' : 'nein');
    } catch (_) {
      // gilt dann nur bis zum Schließen der App
    }
  }
}

final feiertageAnzeigenProvider = NotifierProvider<FeiertageAnzeigenNotifier, bool>(FeiertageAnzeigenNotifier.new);

/// Hinweise für die Oberfläche: leer, solange der Schalter aus ist; Feiertage sofort, Ferien sobald das Asset geladen ist.
final tagesHinweiseProvider = Provider.autoDispose<TagesHinweise>((ref) {
  if (!ref.watch(feiertageAnzeigenProvider)) return TagesHinweise.leer;
  final ferien = ref.watch(ferienProvider).value ?? const <TagesHinweis>[];
  final jahr = DateTime.now().year;
  return TagesHinweise.aus(ferien: ferien, vonJahr: jahr - 1, bisJahr: jahr + 5);
});
