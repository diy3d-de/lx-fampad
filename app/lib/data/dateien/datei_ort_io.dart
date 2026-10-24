// Android/Desktop: Dateien im Cache-Ordner der App (path_provider: Ordner für Anwendungsdaten, privat). Der Ordner heißt `datei_cache`; Dateinamen sind Blob-IDs. Teil-Downloads enden auf `.teil`.
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as c;
import 'package:path_provider/path_provider.dart';

import 'datei_ort.dart';

class DateiOrtIo implements DateiOrt {
  final Future<Directory> Function() _basis;
  Directory? _ordner;

  /// [basis] liefert den Ordner (Standard: `datei_cache` unter dem Ordner für Anwendungsdaten der App); Tests setzen einen Wegwerf-Ordner.
  DateiOrtIo([Future<Directory> Function()? basis]) : _basis = basis ?? _standardBasis;

  static Future<Directory> _standardBasis() async => Directory('${(await getApplicationSupportDirectory()).path}${Platform.pathSeparator}datei_cache');

  Future<Directory> _ordnerHolen() async {
    final o = _ordner ??= await _basis();
    if (!await o.exists()) await o.create(recursive: true);
    return o;
  }

  @override
  bool get verfuegbar => true;

  @override
  Future<String?> pfad(String name) async {
    // nur einfache Namen (Blob-IDs, `.teil`): nie ein Pfadteil von außen
    if (name.isEmpty || name.contains('/') || name.contains('\\') || name.contains('..')) throw ArgumentError('Ungültiger Dateiname');
    return '${(await _ordnerHolen()).path}${Platform.pathSeparator}$name';
  }

  @override
  Future<bool> existiert(String pfad) => File(pfad).exists();

  @override
  Future<int> laenge(String pfad) async {
    final f = File(pfad);
    return await f.exists() ? await f.length() : 0;
  }

  @override
  Future<void> anhaengen(String pfad, Uint8List bytes) async {
    final f = await File(pfad).open(mode: FileMode.append);
    try {
      await f.writeFrom(bytes);
      await f.flush();
    } finally {
      await f.close();
    }
  }

  @override
  Future<Uint8List> lesen(String pfad) => File(pfad).readAsBytes();

  @override
  Future<void> umbenennen(String von, String nach) async {
    await File(von).rename(nach);
  }

  @override
  Future<void> loeschen(String pfad) async {
    final f = File(pfad);
    if (await f.exists()) await f.delete();
  }

  @override
  Future<String> sha256(String pfad) async {
    final ausgabe = _HashSenke();
    final eingabe = c.sha256.startChunkedConversion(ausgabe);
    await for (final teil in File(pfad).openRead()) {
      eingabe.add(teil);
    }
    eingabe.close();
    return ausgabe.wert.toString();
  }

  @override
  Future<void> alleLoeschen() async {
    final o = _ordner ??= await _basis();
    if (await o.exists()) await o.delete(recursive: true);
  }
}

class _HashSenke implements Sink<c.Digest> {
  late c.Digest wert;
  @override
  void add(c.Digest data) => wert = data;
  @override
  void close() {}
}

DateiOrt dateiOrtErzeugen() => DateiOrtIo();
