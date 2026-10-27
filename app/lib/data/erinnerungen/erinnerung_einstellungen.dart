// Einstellungen der Terminerinnerungen: gelten nur für dieses Gerät, liegen lokal (nie auf dem Server, nie synchronisiert).
//  - an: Erinnerungen auf diesem Gerät planen (Standard: an; die Berechtigung für Benachrichtigungen wird erst in den Einstellungen
//    angefragt, nicht beim ersten Start).
//  - aufgabenAn: auch Erinnerungen für Aufgaben planen (Standard: an; gilt zusätzlich zu "an").
//  - zaehlerAn: Ablese-Erinnerungen der Zähler planen (nur Eltern und Admins; Standard: an; eigener Schalter).
//  - medikamenteAn: Einnahme-Erinnerungen des Medikamenten-Plans planen (Standard: an; eigener Schalter, unabhängig von "an", wie bei den Abfuhrterminen).
//  - vorsorgeAn: Vorsorge- und Impf-Erinnerungen planen (Standard: an; eigener Schalter, neutraler Text, nur lokal).
//  - sperrbildschirmTitel: Titel und Ort dürfen auf dem Sperrbildschirm erscheinen (Standard: aus, dort steht dann nur ein neutraler Hinweis).
//  - standardVorlauf: Vorlaufzeit, die der Editor für NEUE Termine vorbelegt (null = keine Erinnerung).
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../crypto/sicherer_speicher.dart';

/// Auswahl für die Standard-Erinnerung (Minuten; null = keine): dieselben Werte wie im Termin-Editor (`kErinnerungen`).
const kStandardVorlaeufe = <int?>[null, 0, 5, 15, 30, 60, 1440, 10080];

/// Standard-Erinnerung, solange die Person nichts gewählt hat: 1 Stunde vorher. "Keine" ist ein eigener, gespeicherter Wert (leerer Text).
const kStandardVorlaufVorgabe = 60;

class ErinnerungEinstellungen {
  final bool an;
  final int? standardVorlauf;
  final bool sperrbildschirmTitel;
  final bool aufgabenAn;
  final bool medikamenteAn;
  final bool zaehlerAn;
  final bool vorsorgeAn;
  const ErinnerungEinstellungen({this.an = true, this.standardVorlauf = kStandardVorlaufVorgabe,this.sperrbildschirmTitel = false, this.aufgabenAn = true, this.medikamenteAn = true, this.zaehlerAn = true, this.vorsorgeAn = true});

  ErinnerungEinstellungen kopie({bool? an, Object? standardVorlauf = _keine, bool? sperrbildschirmTitel, bool? aufgabenAn, bool? medikamenteAn, bool? zaehlerAn, bool? vorsorgeAn}) => ErinnerungEinstellungen(
    an: an ?? this.an,
    standardVorlauf: identical(standardVorlauf, _keine) ? this.standardVorlauf : standardVorlauf as int?,
    sperrbildschirmTitel: sperrbildschirmTitel ?? this.sperrbildschirmTitel,
    aufgabenAn: aufgabenAn ?? this.aufgabenAn,
    medikamenteAn: medikamenteAn ?? this.medikamenteAn,
    zaehlerAn: zaehlerAn ?? this.zaehlerAn,
    vorsorgeAn: vorsorgeAn ?? this.vorsorgeAn,
  );

  @override
  bool operator ==(Object other) =>
      other is ErinnerungEinstellungen && other.an == an && other.standardVorlauf == standardVorlauf && other.sperrbildschirmTitel == sperrbildschirmTitel && other.aufgabenAn == aufgabenAn && other.medikamenteAn == medikamenteAn && other.zaehlerAn == zaehlerAn && other.vorsorgeAn == vorsorgeAn;

  @override
  int get hashCode => Object.hash(an, standardVorlauf, sperrbildschirmTitel, aufgabenAn, medikamenteAn, zaehlerAn, vorsorgeAn);
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
const _kAufgaben = 'erinnerung_aufgaben';
const _kMedikamente = 'erinnerung_medikamente';
const _kZaehler = 'erinnerung_zaehler';
const _kVorsorge = 'erinnerung_vorsorge';

/// Schlüssel der Einstellung "Titel auf dem Sperrbildschirm zeigen" (gilt auch für die Chat-Benachrichtigungen).
const kSperrbildschirmSchluessel = _kSperre;

/// Schlüssel der Einstellung "Standortfreigaben melden" (lokal; "aus" schaltet die Hinweise ab).
const kStandortHinweisSchluessel = 'standort_hinweis';

/// Schlüssel der Person, für die die geplanten Erinnerungen dieses Geräts gelten (der Dienst löscht sie bei einem anderen Konto).
const kErinnerungKontoSchluessel = 'erinnerung_konto';

/// Android: im Keystore-gestützten Speicher der App (dieselbe Abhängigkeit wie die Anmeldung; keine zusätzliche Bibliothek).
class SicherErinnerungSpeicher implements ErinnerungSpeicher {
  final FlutterSecureStorage _s;
  SicherErinnerungSpeicher([FlutterSecureStorage? s]) : _s = s ?? kSicherSpeicher;

  @override
  Future<Map<String, String>> lesen() async {
    final an = await _s.read(key: _kAn);
    final v = await _s.read(key: _kVorlauf);
    final sp = await _s.read(key: _kSperre);
    final au = await _s.read(key: _kAufgaben);
    final me = await _s.read(key: _kMedikamente);
    final za = await _s.read(key: _kZaehler);
    final vo = await _s.read(key: _kVorsorge);
    final k = await _s.read(key: kErinnerungKontoSchluessel);
    final sh = await _s.read(key: kStandortHinweisSchluessel);
    return {_kAn: ?an, _kVorlauf: ?v, _kSperre: ?sp, _kAufgaben: ?au, _kMedikamente: ?me, _kZaehler: ?za, _kVorsorge: ?vo, kErinnerungKontoSchluessel: ?k, kStandortHinweisSchluessel: ?sh};
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
  bool _aufgabenGesetzt = false;
  bool _medikamenteGesetzt = false;
  bool _zaehlerGesetzt = false;
  bool _vorsorgeGesetzt = false;

  Future<void> _laden() async {
    var neu = const ErinnerungEinstellungen();
    try {
      final m = await ref.read(erinnerungSpeicherProvider).lesen();
      final an = m[_kAn];
      final v = m[_kVorlauf];
      // nie gesetzt = Vorgabe (1 Stunde), leer = bewusst "Keine", unlesbar = Vorgabe
      final vorlauf = v == null ? kStandardVorlaufVorgabe : (v.isEmpty ? null : int.tryParse(v));
      neu = ErinnerungEinstellungen(
        an: an != 'nein',
        standardVorlauf: kStandardVorlaeufe.contains(vorlauf) ? vorlauf : kStandardVorlaufVorgabe,
        sperrbildschirmTitel: m[_kSperre] == 'ja',
        aufgabenAn: m[_kAufgaben] != 'nein',
        medikamenteAn: m[_kMedikamente] != 'nein',
        zaehlerAn: m[_kZaehler] != 'nein',
        vorsorgeAn: m[_kVorsorge] != 'nein',
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
      aufgabenAn: _aufgabenGesetzt ? jetzt.aufgabenAn : neu.aufgabenAn,
      medikamenteAn: _medikamenteGesetzt ? jetzt.medikamenteAn : neu.medikamenteAn,
      zaehlerAn: _zaehlerGesetzt ? jetzt.zaehlerAn : neu.zaehlerAn,
      vorsorgeAn: _vorsorgeGesetzt ? jetzt.vorsorgeAn : neu.vorsorgeAn,
    );
  }

  Future<void> anSetzen(bool an) async {
    _anGesetzt = true;
    state = state.kopie(an: an);
    await _schreiben(_kAn, an ? 'ja' : 'nein');
  }

  Future<void> aufgabenAnSetzen(bool an) async {
    _aufgabenGesetzt = true;
    state = state.kopie(aufgabenAn: an);
    await _schreiben(_kAufgaben, an ? 'ja' : 'nein');
  }

  Future<void> medikamenteAnSetzen(bool an) async {
    _medikamenteGesetzt = true;
    state = state.kopie(medikamenteAn: an);
    await _schreiben(_kMedikamente, an ? 'ja' : 'nein');
  }

  Future<void> zaehlerAnSetzen(bool an) async {
    _zaehlerGesetzt = true;
    state = state.kopie(zaehlerAn: an);
    await _schreiben(_kZaehler, an ? 'ja' : 'nein');
  }

  Future<void> vorsorgeAnSetzen(bool an) async {
    _vorsorgeGesetzt = true;
    state = state.kopie(vorsorgeAn: an);
    await _schreiben(_kVorsorge, an ? 'ja' : 'nein');
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
