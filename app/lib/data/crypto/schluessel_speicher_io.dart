// Android: Schlüssel im Android Keystore (flutter_secure_storage). "Nicht vorhanden" (null) und "Fehler" sind getrennt: Nur eindeutig dauerhafte
// Fehler (Entschlüsselung scheitert: BadPadding, AEADBadTag, MAC-Prüfung; kaputte Daten) gelten als dauerhaft, alles andere (Keystore gesperrt, E/A)
// als vorübergehend. Der Speicher löscht beim Lesen nie selbst; das entscheidet der Aufrufer. Einträge dieser Ablage stehen in einem Index, damit
// "alle Schlüssel dieser App löschen" ohne readAll auskommt.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'bytes.dart';
import 'schluessel_speicher.dart';

SchluesselSpeicher schluesselSpeicherErzeugen() => SecureSchluesselSpeicher();

class SecureSchluesselSpeicher implements SchluesselSpeicher {
  static const _praefix = 'lx_fampad_';
  static const _indexName = '__index';
  final FlutterSecureStorage _s;
  SecureSchluesselSpeicher([FlutterSecureStorage? storage]) : _s = storage ?? const FlutterSecureStorage();

  static final _dauerhaftMuster = RegExp('BadPadding|AEADBadTag|BadTag|IllegalBlockSize|MAC verification|Signature/MAC', caseSensitive: false);

  SchluesselSpeicherFehler _fehler(Object e) {
    final text = e is PlatformException ? '${e.code} ${e.message} ${e.details}' : e.toString();
    return SchluesselSpeicherFehler('Schlüsselspeicher nicht lesbar', dauerhaft: _dauerhaftMuster.hasMatch(text));
  }

  Future<String?> _rohLesen(String key) async {
    try {
      return await _s.read(key: key);
    } on Object catch (e) {
      throw _fehler(e);
    }
  }

  @override
  Future<Uint8List?> lesen(String name) async {
    final raw = await _rohLesen('$_praefix$name');
    if (raw == null) return null;
    try {
      return base64urlDekodieren(raw);
    } on Object {
      throw const SchluesselSpeicherFehler('Schlüsseleintrag beschädigt', dauerhaft: true);
    }
  }

  Future<List<String>> _index() async {
    final raw = await _rohLesen('$_praefix$_indexName');
    if (raw == null) return [];
    try {
      final l = jsonDecode(raw);
      return l is List ? [for (final e in l) if (e is String) e] : [];
    } on Object {
      return [];
    }
  }

  Future<void> _indexSchreiben(List<String> namen) => _s.write(key: '$_praefix$_indexName', value: jsonEncode(namen));

  @override
  Future<void> schreiben(String name, Uint8List bytes) async {
    // zuerst in den Index (ein Eintrag ohne Index-Zeile könnte beim Abmelden liegen bleiben), dann der Wert
    final index = await _index();
    if (!index.contains(name)) await _indexSchreiben([...index, name]);
    await _s.write(key: '$_praefix$name', value: base64urlKodieren(bytes));
  }

  @override
  Future<void> loeschen(String name) async {
    await _s.delete(key: '$_praefix$name');
    final index = await _index();
    if (index.contains(name)) await _indexSchreiben([...index]..remove(name));
  }

  @override
  Future<void> loescheMitPraefix(String praefix) async {
    final index = await _index();
    Object? erster;
    final rest = <String>[];
    for (final name in index) {
      if (!name.startsWith(praefix)) {
        rest.add(name);
        continue;
      }
      try {
        await _s.delete(key: '$_praefix$name');
      } on Object catch (e) {
        erster ??= e;
        rest.add(name); // bleibt im Index: ein späterer Versuch löscht ihn
      }
    }
    await _indexSchreiben(rest);
    if (erster != null) throw erster;
  }

  @override
  Future<List<String>> namenMitPraefix(String praefix) async => [
    for (final n in await _index())
      if (n.startsWith(praefix)) n,
  ];

  /// Roh verschieben (der abgelegte Wert bleibt, wie er ist). Lässt sich der Eintrag nicht einmal roh lesen (Keystore-Schlüssel verloren),
  /// bleibt er unberührt (false).
  @override
  Future<bool> verschiebe(String von, String nach) async {
    final String? raw;
    try {
      raw = await _rohLesen('$_praefix$von');
    } on SchluesselSpeicherFehler {
      return false;
    }
    if (raw == null) return false;
    final index = await _index();
    if (!index.contains(nach)) await _indexSchreiben([...index, nach]);
    await _s.write(key: '$_praefix$nach', value: raw);
    await loeschen(von);
    return true;
  }

  @override
  Future<SpeicherDauer> dauerhaftigkeit() async => SpeicherDauer.nichtZutreffend;

  @override
  Future<SpeicherDauer> dauerhaftAnfordern() async => SpeicherDauer.nichtZutreffend;
}
