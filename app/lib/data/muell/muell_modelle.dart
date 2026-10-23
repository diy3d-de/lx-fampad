// Abfuhrtermine ("Müll"): Modelle der Antwort von `GET /waste` und die festen Abfallarten mit Namen, Symbol und Farbe. Die Arten kommen
// als feste Codes vom Server (nie ein Text der Quelle); Unbekanntes einer neueren Server-Version erscheint als "Sonstiges".
import 'package:flutter/material.dart';

import '../../constants.dart';
import '../api/models.dart' show asJson;

/// Die Abfallarten (Reihenfolge = Reihenfolge in Filter und Einstellungen).
enum MuellArt {
  rest('rest', 'Restabfall', 'Rest', Icons.delete_outline, kMuellRest),
  bio('bio', 'Bioabfall', 'Bio', Icons.eco_outlined, kMuellBio),
  gelb('gelb', 'Gelber Sack', 'Gelb', Icons.shopping_bag_outlined, kMuellGelb),
  papier('papier', 'Altpapier', 'Papier', Icons.description_outlined, kMuellPapier),
  gruen('gruen', 'Grünabfall', 'Grün', Icons.grass, kMuellGruen),
  sonder('sonder', 'Sonderabfall', 'Sonder', Icons.warning_amber_rounded, kMuellSonder),
  sperr('sperr', 'Sperrmüll', 'Sperr', Icons.weekend_outlined, kMuellSperr),
  baum('baum', 'Weihnachtsbäume', 'Bäume', Icons.park_outlined, kMuellBaum),
  sonst('sonst', 'Sonstiges', 'Sonst.', Icons.inventory_2_outlined, kMuellSonst);

  final String code;
  final String name;

  /// Kurzer Name für die Filter-Chips.
  final String kurz;
  final IconData icon;
  final Color farbe;
  const MuellArt(this.code, this.name, this.kurz, this.icon, this.farbe);

  /// Unbekannte Codes (neuere Server-Version) werden zu [sonst].
  static MuellArt aus(Object? code) => MuellArt.values.firstWhere((a) => a.code == code, orElse: () => MuellArt.sonst);
}

/// Arten, für die die Erinnerung standardmäßig an ist: die regelmäßigen Tonnen, Sperrmüll und Weihnachtsbäume; aus für Sonderabfall und Sonstiges.
const kMuellStandardErinnerung = <MuellArt>{
  MuellArt.rest,
  MuellArt.bio,
  MuellArt.gelb,
  MuellArt.papier,
  MuellArt.gruen,
  MuellArt.sperr,
  MuellArt.baum,
};

/// Eine Abholung: ein Tag mit einer oder mehreren Arten (Tag als `DateTime.utc`-Markierung wie überall im Kalender).
class MuellTag {
  final DateTime tag;
  final List<MuellArt> arten;
  const MuellTag(this.tag, this.arten);
}

enum MuellJahrStatus { geladen, nichtVerfuegbar, fehler }

class MuellJahr {
  final int jahr;
  final MuellJahrStatus status;
  final int anzahlTermine;

  /// Letzte Prüfung dieses Jahres durch den Server.
  final DateTime? geprueft;

  /// Fester Code des letzten Fehlers (nur zur Unterscheidung, nie als Text gezeigt).
  final String? fehlerCode;
  const MuellJahr({required this.jahr, required this.status, this.anzahlTermine = 0, this.geprueft, this.fehlerCode});
}

/// Stand der Prüfung ("Jetzt nach neuer Datei suchen") und der automatischen Prüfung.
class MuellPruefung {
  /// Eine Prüfung ist angefordert und der Dienst hat sie noch nicht abgearbeitet.
  final bool angefordert;
  final DateTime? letzte;
  final DateTime? naechste;

  /// Frühestens ab dann darf wieder angefordert werden (null: jederzeit).
  final DateTime? naechsteAnforderung;
  const MuellPruefung({this.angefordert = false, this.letzte, this.naechste, this.naechsteAnforderung});
}

class MuellDto {
  /// Der Server hat die Abfuhrtermine eingeschaltet (404 = nicht).
  final bool verfuegbar;
  final String ort;
  final List<MuellJahr> jahre;
  final List<MuellTag> tage;
  final MuellPruefung pruefung;
  const MuellDto({required this.verfuegbar, this.ort = '', this.jahre = const [], this.tage = const [], this.pruefung = const MuellPruefung()});

  static const nichtVerfuegbar = MuellDto(verfuegbar: false);

  /// Jahre mit geladenen Terminen.
  Set<int> get geladeneJahre => {for (final j in jahre) if (j.status == MuellJahrStatus.geladen) j.jahr};

  MuellJahr? jahr(int j) => jahre.where((x) => x.jahr == j).firstOrNull;

  static DateTime? _zeit(Object? v) => v is String ? DateTime.tryParse(v) : null;

  /// Tolerant: eine kaputte Zeile wird übersprungen, nie ein Absturz wegen der Zusatzanzeige.
  factory MuellDto.fromJson(Object? raw) {
    final m = asJson(raw);
    final jahre = <MuellJahr>[];
    final jl = m['years'];
    if (jl is List) {
      for (final e in jl) {
        if (e is! Map<String, dynamic>) continue;
        final y = e['year'];
        if (y is! int) continue;
        final status = switch (e['status']) {
          'loaded' => MuellJahrStatus.geladen,
          'unavailable' => MuellJahrStatus.nichtVerfuegbar,
          _ => MuellJahrStatus.fehler,
        };
        jahre.add(MuellJahr(jahr: y, status: status, anzahlTermine: e['eventCount'] is int ? e['eventCount'] as int : 0, geprueft: _zeit(e['checkedAt']), fehlerCode: e['errorCode'] is String ? e['errorCode'] as String : null));
      }
    }
    final tage = <MuellTag>[];
    final tl = m['events'];
    if (tl is List) {
      for (final e in tl) {
        if (e is! Map<String, dynamic>) continue;
        final d = e['date'];
        final k = e['kinds'];
        if (d is! String || k is! List) continue;
        final p = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(d);
        if (p == null) continue;
        final arten = <MuellArt>{for (final c in k) MuellArt.aus(c)}.toList()..sort((a, b) => a.index.compareTo(b.index));
        if (arten.isEmpty) continue;
        tage.add(MuellTag(DateTime.utc(int.parse(p[1]!), int.parse(p[2]!), int.parse(p[3]!)), arten));
      }
      tage.sort((a, b) => a.tag.compareTo(b.tag));
    }
    final c = m['check'];
    final cm = c is Map<String, dynamic> ? c : const <String, dynamic>{};
    return MuellDto(
      verfuegbar: true,
      ort: m['place'] is String ? m['place'] as String : '',
      jahre: jahre,
      tage: tage,
      pruefung: MuellPruefung(angefordert: cm['pending'] == true, letzte: _zeit(cm['lastCheckAt']), naechste: _zeit(cm['nextCheckAt']), naechsteAnforderung: _zeit(cm['nextRequestAt'])),
    );
  }
}
