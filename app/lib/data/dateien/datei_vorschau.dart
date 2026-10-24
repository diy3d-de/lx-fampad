// Vorschaubilder der Dateiablage (Abschnitt 6n): die kleinen Bilder (höchstens 256 KiB, `thumbBlobId` der Fassung) lädt die App mit der Anmeldung der Sitzung (nie eine Adresse mit Token) in einen
// kleinen Arbeitsspeicher-Zwischenspeicher (höchstens 64 Bilder und 16 MB, die am längsten nicht gezeigten fliegen zuerst heraus). Ein Fehler (offline, keine Sicht) ergibt null: die Oberfläche zeigt
// dann das Symbol der Dateiart. Nichts davon liegt auf der Platte.
import 'dart:collection';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_state.dart';
import 'blob_lader.dart';
import 'datei_modelle.dart';

const int kVorschauMaxAnzahl = 64;
const int kVorschauMaxBytes = 16 * 1024 * 1024;

class VorschauCache {
  final BlobLader lader;
  final int maxAnzahl;
  final int maxBytes;
  VorschauCache(this.lader, {this.maxAnzahl = kVorschauMaxAnzahl, this.maxBytes = kVorschauMaxBytes});

  final LinkedHashMap<String, Uint8List> _bilder = LinkedHashMap();
  final Map<String, Future<Uint8List?>> _laufend = {};
  int _summe = 0;

  int get anzahl => _bilder.length;
  int get bytes => _summe;

  /// Das Vorschaubild zu [blobId] (null: nicht ladbar). Gleichzeitige Anfragen teilen sich einen Abruf; ein gezeigtes Bild rückt ans Ende der Reihe.
  Future<Uint8List?> holen(String blobId) {
    final da = _bilder.remove(blobId);
    if (da != null) {
      _bilder[blobId] = da;
      return Future.value(da);
    }
    return _laufend[blobId] ??= _laden(blobId).whenComplete(() => _laufend.remove(blobId));
  }

  Future<Uint8List?> _laden(String blobId) async {
    try {
      // die Größe des Vorschaubilds kennt nur der Server (höchstens 256 KiB): eine Anfrage ohne Range
      final b = await lader.ladenGanz(blobId, kMaxThumbBytes);
      if (b.isEmpty || b.length > maxBytes) return null;
      _bilder[blobId] = b;
      _summe += b.length;
      while (_bilder.length > maxAnzahl || _summe > maxBytes) {
        final alt = _bilder.entries.first;
        _summe -= alt.value.length;
        _bilder.remove(alt.key);
      }
      return b;
    } on Object {
      return null;
    }
  }

  void leeren() {
    _bilder.clear();
    _summe = 0;
  }
}

final vorschauCacheProvider = Provider<VorschauCache>((ref) {
  final c = VorschauCache(BlobLader(ref.watch(apiClientProvider)));
  ref.onDispose(c.leeren);
  return c;
});

/// Das Vorschaubild einer Fassung (null: keins oder nicht ladbar).
final vorschauBildProvider = FutureProvider.family<Uint8List?, String>((ref, blobId) => ref.watch(vorschauCacheProvider).holen(blobId));
