// Einstellungen der Terminerinnerungen: gelten nur für dieses Gerät, liegen lokal (nie auf dem Server, nie synchronisiert).
//  - an: Erinnerungen auf diesem Gerät planen (Standard: an; die Berechtigung für Benachrichtigungen wird erst in den Einstellungen
//    angefragt, nicht beim ersten Start).
//  - sperrbildschirmTitel: Titel und Ort dürfen auf dem Sperrbildschirm erscheinen (Standard: aus, dort steht dann nur ein neutraler Hinweis).
//  - standardVorlauf: Vorlaufzeit, die der Editor für NEUE Termine vorbelegt (null = keine Erinnerung).
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Auswahl für die Standard-Vorlaufzeit (Minuten; null = keine). Teilmenge der Werte, die der Termin-Editor anbietet.
const kStandardVorlaeufe = <int?>[null, 15, 60, 1440];

class ErinnerungEinstellungen {
  final bool an;
  final int? standardVorlauf;
  final bool sperrbildschirmTitel;
  const ErinnerungEinstellungen({this.an = true, this.standardVorlauf, this.sperrbildschirmTitel = false});

  ErinnerungEinstellungen kopie({bool? an, Object? standardVorlauf = _keine, bool? sperrbildschirmTitel}) => ErinnerungEinstellungen(
    an: an ?? this.an,
    standardVorlauf: identical(standardVorlauf, _keine) ? this.standardVorlauf : standardVorlauf as int?,
    sperrbildschirmTitel: sperrbildschirmTitel ?? this.sperrbildschirmTitel,
  );

  @override
  bool operator ==(Object other) =>
      other is ErinnerungEinstellungen && other.an == an && other.standardVorlauf == standardVorlauf && other.sperrbildschirmTitel == sperrbildschirmTitel;

  @override
  int get hashCode => Object.hash(an, standardVorlauf, sperrbildschirmTitel);
}

const Object _keine = Object();

/// Ablage der Einstellungen (Schlüssel/Wert als Text). Implementierungen dürfen nie werfen müssen: der Aufrufer fängt Fehler ab.
abstract class ErinnerungSpeicher {
  Future<Map<String, String>> lesen();
  Future<void> schreiben(String schluessel, String wert);
}

const _kAn = 'erinnerung_an';
const _kVorlauf = 'erinnerung_vorlauf';
const _kSperre = 'erinnerung_sperrbildschirm';

/// Schlüssel der Person, für die die geplanten Erinnerungen dieses Geräts gelten (der Dienst löscht sie bei einem anderen Konto).
const kErinnerungKontoSchluessel = 'erinnerung_konto';

/// Android: im Keystore-gestützten Speicher der App (dieselbe Abhängigkeit wie die Anmeldung; keine zusätzliche Bibliothek).
class SicherErinnerungSpeicher implements ErinnerungSpeicher {
  final FlutterSecureStorage _s;
  SicherErinnerungSpeicher([FlutterSecureStorage? s]) : _s = s ?? const FlutterSecureStorage();

  @override
  Future<Map<String, String>> lesen() async {
    final an = await _s.read(key: _kAn);
    final v = await _s.read(key: _kVorlauf);
    final sp = await _s.read(key: _kSperre);
    final k = await _s.read(key: kErinnerungKontoSchluessel);
    return {_kAn: ?an, _kVorlauf: ?v, _kSperre: ?sp, kErinnerungKontoSchluessel: ?k};
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

  // Was die Person schon gesetzt hat, bevor das Lesen fertig war: überschreibt das spätere Ergebnis des Lesens nicht
  bool _anGesetzt = false;
  bool _vorlaufGesetzt = false;
  bool _sperreGesetzt = false;

  Future<void> _laden() async {
    var neu = const ErinnerungEinstellungen();
    try {
      final m = await ref.read(erinnerungSpeicherProvider).lesen();
      final an = m[_kAn];
      final v = m[_kVorlauf];
      final vorlauf = v == null || v.isEmpty ? null : int.tryParse(v);
      neu = ErinnerungEinstellungen(
        an: an != 'nein',
        standardVorlauf: kStandardVorlaeufe.contains(vorlauf) ? vorlauf : null,
        sperrbildschirmTitel: m[_kSperre] == 'ja',
      );
    } catch (_) {
      // Speicher nicht lesbar: Standardwerte
    }
    if (!ref.mounted) return;
    final jetzt = state;
    state = ErinnerungEinstellungen(
      an: _anGesetzt ? jetzt.an : neu.an,
      standardVorlauf: _vorlaufGesetzt ? jetzt.standardVorlauf : neu.standardVorlauf,
      sperrbildschirmTitel: _sperreGesetzt ? jetzt.sperrbildschirmTitel : neu.sperrbildschirmTitel,
    );
  }

  Future<void> anSetzen(bool an) async {
    _anGesetzt = true;
    state = state.kopie(an: an);
    await _schreiben(_kAn, an ? 'ja' : 'nein');
  }

  Future<void> vorlaufSetzen(int? minuten) async {
    _vorlaufGesetzt = true;
    state = state.kopie(standardVorlauf: minuten);
    await _schreiben(_kVorlauf, minuten?.toString() ?? '');
  }

  Future<void> sperrbildschirmSetzen(bool zeigen) async {
    _sperreGesetzt = true;
    state = state.kopie(sperrbildschirmTitel: zeigen);
    await _schreiben(_kSperre, zeigen ? 'ja' : 'nein');
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
