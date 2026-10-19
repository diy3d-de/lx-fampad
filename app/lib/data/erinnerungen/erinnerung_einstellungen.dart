// Einstellungen der Terminerinnerungen: gelten nur für dieses Gerät, liegen lokal (nie auf dem Server, nie synchronisiert).
//  - an: Erinnerungen auf diesem Gerät planen (Standard: an; die Berechtigung für Benachrichtigungen wird erst in den Einstellungen
//    angefragt, nicht beim ersten Start).
//  - standardVorlauf: Vorlaufzeit, die der Editor für NEUE Termine vorbelegt (null = keine Erinnerung).
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Auswahl für die Standard-Vorlaufzeit (Minuten; null = keine). Teilmenge der Werte, die der Termin-Editor anbietet.
const kStandardVorlaeufe = <int?>[null, 15, 60, 1440];

class ErinnerungEinstellungen {
  final bool an;
  final int? standardVorlauf;
  const ErinnerungEinstellungen({this.an = true, this.standardVorlauf});

  ErinnerungEinstellungen kopie({bool? an, Object? standardVorlauf = _keine}) =>
      ErinnerungEinstellungen(an: an ?? this.an, standardVorlauf: identical(standardVorlauf, _keine) ? this.standardVorlauf : standardVorlauf as int?);

  @override
  bool operator ==(Object other) => other is ErinnerungEinstellungen && other.an == an && other.standardVorlauf == standardVorlauf;

  @override
  int get hashCode => Object.hash(an, standardVorlauf);
}

const Object _keine = Object();

/// Ablage der Einstellungen (Schlüssel/Wert als Text). Implementierungen dürfen nie werfen müssen: der Aufrufer fängt Fehler ab.
abstract class ErinnerungSpeicher {
  Future<Map<String, String>> lesen();
  Future<void> schreiben(String schluessel, String wert);
}

const _kAn = 'erinnerung_an';
const _kVorlauf = 'erinnerung_vorlauf';

/// Android: im Keystore-gestützten Speicher der App (dieselbe Abhängigkeit wie die Anmeldung; keine zusätzliche Bibliothek).
class SicherErinnerungSpeicher implements ErinnerungSpeicher {
  final FlutterSecureStorage _s;
  SicherErinnerungSpeicher([FlutterSecureStorage? s]) : _s = s ?? const FlutterSecureStorage();

  @override
  Future<Map<String, String>> lesen() async {
    final an = await _s.read(key: _kAn);
    final v = await _s.read(key: _kVorlauf);
    return {_kAn: ?an, _kVorlauf: ?v};
  }

  @override
  Future<void> schreiben(String schluessel, String wert) => _s.write(key: schluessel, value: wert);
}

/// Arbeitsspeicher (Tests).
class MemoryErinnerungSpeicher implements ErinnerungSpeicher {
  final Map<String, String> daten = {};
  bool wirft = false;

  @override
  Future<Map<String, String>> lesen() async {
    if (wirft) throw StateError('Speicher nicht verfügbar');
    return Map.of(daten);
  }

  @override
  Future<void> schreiben(String schluessel, String wert) async {
    if (wirft) throw StateError('Speicher nicht verfügbar');
    daten[schluessel] = wert;
  }
}

// Web: nur Arbeitsspeicher (es gibt dort keine Erinnerungen; nichts im Browserspeicher ablegen)
final erinnerungSpeicherProvider = Provider<ErinnerungSpeicher>((ref) => kIsWeb ? MemoryErinnerungSpeicher() : SicherErinnerungSpeicher());

class ErinnerungEinstellungenNotifier extends Notifier<ErinnerungEinstellungen> {
  /// Fertig, sobald die gespeicherten Werte gelesen sind (der Dienst plant vorher nichts).
  late Future<void> bereit;

  @override
  ErinnerungEinstellungen build() {
    bereit = _laden();
    return const ErinnerungEinstellungen();
  }

  Future<void> _laden() async {
    ErinnerungEinstellungen neu = const ErinnerungEinstellungen();
    try {
      final m = await ref.read(erinnerungSpeicherProvider).lesen();
      final an = m[_kAn];
      final v = m[_kVorlauf];
      final vorlauf = v == null || v.isEmpty ? null : int.tryParse(v);
      neu = ErinnerungEinstellungen(an: an != 'nein', standardVorlauf: kStandardVorlaeufe.contains(vorlauf) ? vorlauf : null);
    } catch (_) {
      // Speicher nicht lesbar: Standardwerte
    }
    if (!ref.mounted) return;
    state = neu;
  }

  Future<void> anSetzen(bool an) async {
    state = state.kopie(an: an);
    await _schreiben(_kAn, an ? 'ja' : 'nein');
  }

  Future<void> vorlaufSetzen(int? minuten) async {
    state = state.kopie(standardVorlauf: minuten);
    await _schreiben(_kVorlauf, minuten?.toString() ?? '');
  }

  Future<void> _schreiben(String k, String v) async {
    try {
      await ref.read(erinnerungSpeicherProvider).schreiben(k, v);
    } catch (_) {
      // gilt dann nur bis zum Beenden der App
    }
  }
}

final erinnerungEinstellungenProvider = NotifierProvider<ErinnerungEinstellungenNotifier, ErinnerungEinstellungen>(ErinnerungEinstellungenNotifier.new);
