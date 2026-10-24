// Die Schwellen der Wetter-Hinweise stehen in docs/wetter-hinweis-schwellen.json; Server (server/test/weather-alerts.test.ts) und App vergleichen dieselbe Datei,
// damit beide Seiten immer mit denselben Werten rechnen.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/api/models.dart';
import 'package:lx_fampad/data/wetter/wetter_hinweise.dart';
import 'package:lx_fampad/data/wetter/wetter_logik.dart';

void main() {
  final datei = File('../docs/wetter-hinweis-schwellen.json');
  final j = jsonDecode(datei.readAsStringSync()) as Map<String, dynamic>;

  test('Konstanten der App sind gleich der gemeinsamen Datei', () {
    expect(kFrostGrenze, j['frostUnterGradC']);
    expect(kWindBoeenGrenze, j['windBoeenUeberKmh']);
    expect(kHitzeGrenze, j['hitzeUeberGradC']);
    expect(kDruckAbfallGrenze, j['druckAbfallMehrAlsHpa3h']);
    expect(kWetterHinweisMaxAlter.inMinutes, j['maxAlterMinuten']);
    expect(kWetterHinweisAbstand.inHours, j['abstandStunden']);
  });

  WetterDto dto({double temp = 10, double boeen = 10}) => WetterDto.fromJson({
    'available': true,
    'place': 'X',
    'current': {'measuredAt': DateTime.now().toUtc().toIso8601String(), 'stale': false, 'temperature': temp, 'gustKmh': boeen},
    'series': <Object>[],
  });

  test('Grenzwerte: genau die Schwelle löst nicht aus, knapp darüber/darunter schon', () {
    final alle = WetterHinweisArt.values.toSet();
    Set<WetterHinweisArt> arten(WetterDto d) => aktiveHinweise(d, alle).map((h) => h.art).toSet();
    final frost = (j['frostUnterGradC'] as num).toDouble();
    final hitze = (j['hitzeUeberGradC'] as num).toDouble();
    final wind = (j['windBoeenUeberKmh'] as num).toDouble();
    expect(arten(dto(temp: frost)), isNot(contains(WetterHinweisArt.frost)));
    expect(arten(dto(temp: frost - 0.1)), contains(WetterHinweisArt.frost));
    expect(arten(dto(temp: hitze)), isNot(contains(WetterHinweisArt.hitze)));
    expect(arten(dto(temp: hitze + 0.1)), contains(WetterHinweisArt.hitze));
    expect(arten(dto(boeen: wind)), isNot(contains(WetterHinweisArt.wind)));
    expect(arten(dto(boeen: wind + 1)), contains(WetterHinweisArt.wind));
  });
}
