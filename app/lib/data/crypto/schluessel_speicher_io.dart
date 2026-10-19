// Android: Schlüssel im Android Keystore (flutter_secure_storage). Fehler beim Lesen (Keystore-Verlust, Backup-Wiederherstellung)
// werden wie "nicht vorhanden" behandelt; der unlesbare Eintrag wird entfernt.
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'bytes.dart';
import 'schluessel_speicher.dart';

SchluesselSpeicher schluesselSpeicherErzeugen() => SecureSchluesselSpeicher();

class SecureSchluesselSpeicher implements SchluesselSpeicher {
  static const _praefix = 'lx_fampad_';
  final FlutterSecureStorage _s;
  SecureSchluesselSpeicher([FlutterSecureStorage? storage]) : _s = storage ?? const FlutterSecureStorage();

  @override
  Future<Uint8List?> lesen(String name) async {
    try {
      final raw = await _s.read(key: '$_praefix$name');
      if (raw == null) return null;
      return base64urlDekodieren(raw);
    } on Object {
      try {
        await _s.delete(key: '$_praefix$name');
      } on Object {
        // auch Löschen kann scheitern; der nächste Versuch wiederholt es
      }
      return null;
    }
  }

  @override
  Future<void> schreiben(String name, Uint8List bytes) => _s.write(key: '$_praefix$name', value: base64urlKodieren(bytes));

  @override
  Future<void> loeschen(String name) => _s.delete(key: '$_praefix$name');

  @override
  Future<void> loescheMitPraefix(String praefix) async {
    final alle = await _s.readAll();
    Object? erster;
    for (final k in alle.keys) {
      if (!k.startsWith('$_praefix$praefix')) continue;
      try {
        await _s.delete(key: k);
      } on Object catch (e) {
        erster ??= e;
      }
    }
    if (erster != null) throw erster;
  }
}
