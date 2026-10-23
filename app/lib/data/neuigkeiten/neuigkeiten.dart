// "Neu in x.y.z": einmaliger Hinweis nach einem App-Update. Quelle ist das gebündelte Asset `assets/neuigkeiten.json`
// ({ "x.y.z": ["Stichpunkt", …] }), kein Netzabruf. Die zuletzt gesehene Version steht lokal je Gerät in `sync_meta`.
// Erststart (nichts gemerkt): nur merken, nichts zeigen. Fehler (Datei, Speicher) ergeben nie einen Dialog und nie einen Absturz.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../calendar/feiertage.dart' show feiertageSpeicherProvider;

const kNeuigkeitenSchluessel = 'neuigkeiten_version';

class Neuigkeit {
  final String version;
  final List<String> punkte;
  const Neuigkeit(this.version, this.punkte);
}

final _versionForm = RegExp(r'^\d{1,4}\.\d{1,4}\.\d{1,4}$');

/// Stichpunkte der Version [version] aus dem JSON-Text; tolerant (Fehler, fehlende Version, leere Liste: null).
Neuigkeit? neuigkeitFuer(String jsonText, String version) {
  try {
    final j = jsonDecode(jsonText);
    if (j is! Map) return null;
    final l = j[version];
    if (l is! List) return null;
    final punkte = [for (final p in l) if (p is String && p.trim().isNotEmpty) p.trim()];
    return punkte.isEmpty ? null : Neuigkeit(version, punkte);
  } catch (_) {
    return null;
  }
}

/// Entscheidet, ob für [installiert] etwas gezeigt wird: nur bei gemerkter, abweichender Version und vorhandenem Eintrag.
bool neuigkeitenFaellig({required String? installiert, required String? gemerkt}) =>
    installiert != null && _versionForm.hasMatch(installiert) && gemerkt != null && gemerkt != installiert;

/// Liefert den Text des Assets (in Tests ersetzbar).
final neuigkeitenQuelleProvider = Provider<Future<String> Function()>((ref) => () => rootBundle.loadString('assets/neuigkeiten.json'));

class NeuigkeitenDienst {
  final Ref _ref;
  NeuigkeitenDienst(this._ref);

  /// Der Hinweis zu [installiert], falls er jetzt gezeigt werden soll. Merkt beim Erststart (nichts gemerkt) die Version und liefert null.
  /// Gemerkt wird sonst erst durch [gesehen] (beim Schließen).
  Future<Neuigkeit?> pruefen(String? installiert) async {
    if (installiert == null || !_versionForm.hasMatch(installiert)) return null;
    try {
      final ablage = _ref.read(feiertageSpeicherProvider);
      final gemerkt = await ablage.lesen(schluessel: kNeuigkeitenSchluessel);
      if (gemerkt == null) {
        await ablage.schreiben(installiert, schluessel: kNeuigkeitenSchluessel);
        return null;
      }
      if (!neuigkeitenFaellig(installiert: installiert, gemerkt: gemerkt)) return null;
      final n = neuigkeitFuer(await _ref.read(neuigkeitenQuelleProvider)(), installiert);
      // kein Eintrag für diese Version: nichts zeigen, aber merken (sonst bliebe es bei jedem Start "fällig")
      if (n == null) await gesehen(installiert);
      return n;
    } catch (_) {
      return null;
    }
  }

  Future<void> gesehen(String version) async {
    try {
      await _ref.read(feiertageSpeicherProvider).schreiben(version, schluessel: kNeuigkeitenSchluessel);
    } catch (_) {
      // gilt dann nur bis zum nächsten Start
    }
  }
}

final neuigkeitenDienstProvider = Provider<NeuigkeitenDienst>(NeuigkeitenDienst.new);
