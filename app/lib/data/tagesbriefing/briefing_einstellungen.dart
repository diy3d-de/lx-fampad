// Einstellungen des Tagesbriefings: nur lokal je Gerät in `sync_meta` (nie synchronisiert, kein Server, kein Schema).
//  - kachelAn: Kachel "Heute im Überblick" auf der Startseite (Standard: AUS, seit 0.28.0 übernimmt der Block „Jetzt wichtig“ die Übersicht; wer sie bewusst eingeschaltet hat (gespeichert `ja`), behält sie; sie erscheint nur, wenn es etwas zu zeigen gibt).
//  - morgensAn: lokale Benachrichtigung am Morgen (nur Android; Standard: AUS), minuten: Uhrzeit in Minuten ab Mitternacht (Standard 07:00).
// Lese- und Schreibfehler ergeben die Standardwerte bzw. gelten nur bis zum Schließen der App.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../calendar/feiertage.dart' show feiertageSpeicherProvider;

const kBriefingKachelSchluessel = 'tagesbriefing_kachel';
const kBriefingMorgensSchluessel = 'tagesbriefing_morgens';
const kBriefingZeitSchluessel = 'tagesbriefing_zeit';

/// Standardzeit der Benachrichtigung (07:00), in Minuten ab Mitternacht.
const kBriefingStandardZeit = 7 * 60;

class BriefingEinstellungen {
  final bool kachelAn;
  final bool morgensAn;
  final int minuten;
  const BriefingEinstellungen({this.kachelAn = false, this.morgensAn = false, this.minuten = kBriefingStandardZeit});

  BriefingEinstellungen kopie({bool? kachelAn, bool? morgensAn, int? minuten}) =>
      BriefingEinstellungen(kachelAn: kachelAn ?? this.kachelAn, morgensAn: morgensAn ?? this.morgensAn, minuten: minuten ?? this.minuten);

  @override
  bool operator ==(Object other) => other is BriefingEinstellungen && other.kachelAn == kachelAn && other.morgensAn == morgensAn && other.minuten == minuten;

  @override
  int get hashCode => Object.hash(kachelAn, morgensAn, minuten);
}

/// "07:00" aus Minuten ab Mitternacht.
String briefingUhrzeit(int minuten) => '${(minuten ~/ 60).toString().padLeft(2, '0')}:${(minuten % 60).toString().padLeft(2, '0')}';

class BriefingEinstellungenNotifier extends Notifier<BriefingEinstellungen> {
  /// Fertig, sobald die gespeicherten Werte gelesen sind (der Erinnerungsdienst plant vorher nichts).
  late Future<void> bereit;
  int _generation = 0;

  @override
  BriefingEinstellungen build() {
    final gen = ++_generation;
    bereit = _laden(gen);
    return const BriefingEinstellungen();
  }

  Future<void> _laden(int gen) async {
    var neu = const BriefingEinstellungen();
    try {
      final s = ref.read(feiertageSpeicherProvider);
      final kachel = await s.lesen(schluessel: kBriefingKachelSchluessel);
      final morgens = await s.lesen(schluessel: kBriefingMorgensSchluessel);
      final zeit = int.tryParse(await s.lesen(schluessel: kBriefingZeitSchluessel) ?? '');
      neu = BriefingEinstellungen(kachelAn: kachel == 'ja', morgensAn: morgens == 'ja', minuten: zeit != null && zeit >= 0 && zeit < 1440 ? zeit : kBriefingStandardZeit);
    } catch (_) {
      // nicht lesbar: Standardwerte
    }
    if (!ref.mounted || gen != _generation) return;
    state = neu;
  }

  Future<void> _schreiben(String schluessel, String wert) async {
    try {
      await ref.read(feiertageSpeicherProvider).schreiben(wert, schluessel: schluessel);
    } catch (_) {
      // gilt dann nur bis zum Schließen der App
    }
  }

  // Eine Änderung wartet, bis der gespeicherte Stand gelesen ist (sonst überschriebe das späte Lesen die Eingabe der Person)
  Future<void> kachelSetzen(bool an) async {
    final gen = _generation;
    await bereit;
    if (!ref.mounted || gen != _generation) return;
    state = state.kopie(kachelAn: an);
    await _schreiben(kBriefingKachelSchluessel, an ? 'ja' : 'nein');
  }

  Future<void> morgensSetzen(bool an) async {
    final gen = _generation;
    await bereit;
    if (!ref.mounted || gen != _generation) return;
    state = state.kopie(morgensAn: an);
    await _schreiben(kBriefingMorgensSchluessel, an ? 'ja' : 'nein');
  }

  Future<void> zeitSetzen(int minuten) async {
    if (minuten < 0 || minuten >= 1440) return;
    final gen = _generation;
    await bereit;
    if (!ref.mounted || gen != _generation) return;
    state = state.kopie(minuten: minuten);
    await _schreiben(kBriefingZeitSchluessel, '$minuten');
  }
}

final briefingEinstellungenProvider = NotifierProvider<BriefingEinstellungenNotifier, BriefingEinstellungen>(BriefingEinstellungenNotifier.new);
