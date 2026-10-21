// Schnittstelle zum Android-Widget "Heute" (MainActivity.kt / HeuteWidget.kt): Zusammenfassung in den app-privaten Speicher schreiben, löschen und
// das Ziel eines Tipps auf das Widget entgegennehmen. Im Web und in Tests gibt es den Kanal nicht: jeder Aufruf ist dann ein stiller No-op.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Kanal zu MainActivity.kt; muss dort identisch sein.
const kHeuteWidgetKanal = 'dev.lx_labs.fampad/heute';

/// Ziele eines Tipps auf das Widget (Whitelist; alles andere wird ignoriert).
const kWidgetZiele = {'kalender', 'aufgaben', 'listen'};

abstract class HeuteWidgetPort {
  /// Gibt es das Widget auf dieser Plattform (nur Android)?
  bool get verfuegbar;

  /// Schreibt die Zusammenfassung (JSON) und aktualisiert vorhandene Widgets. false = fehlgeschlagen.
  Future<bool> schreiben(String json);

  /// Löscht die Zusammenfassung und aktualisiert die Widgets (sie zeigen dann nur "Bitte öffne die App").
  Future<void> loeschen();

  /// Ziel, mit dem die App per Tipp auf das Widget gestartet wurde (einmalig; danach null).
  Future<String?> startZiel();

  /// Ziele eines Tipps auf das Widget, während die App läuft.
  Stream<String> get ziele;
}

class KanalHeuteWidgetPort implements HeuteWidgetPort {
  static const _kanal = MethodChannel(kHeuteWidgetKanal);
  final _ziele = StreamController<String>.broadcast();
  bool _verbunden = false;

  @override
  bool get verfuegbar => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<T?> _aufrufen<T>(String methode, [Object? argumente]) async {
    if (!verfuegbar) return null;
    try {
      return await _kanal.invokeMethod<T>(methode, argumente);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  @override
  Future<bool> schreiben(String json) async => (await _aufrufen<bool>('aktualisieren', {'json': json})) == true;

  @override
  Future<void> loeschen() async => _aufrufen<void>('loeschen');

  @override
  Future<String?> startZiel() => _aufrufen<String>('startZiel');

  @override
  Stream<String> get ziele {
    if (verfuegbar && !_verbunden) {
      _verbunden = true;
      _kanal.setMethodCallHandler((call) async {
        if (call.method == 'ziel' && call.arguments is String) _ziele.add(call.arguments as String);
        return null;
      });
    }
    return _ziele.stream;
  }
}

/// Test-Port: merkt sich die geschriebene Zusammenfassung.
class FakeHeuteWidgetPort implements HeuteWidgetPort {
  @override
  bool verfuegbar;
  final List<String> geschrieben = [];
  int geloescht = 0;
  String? start;
  final _ziele = StreamController<String>.broadcast();
  FakeHeuteWidgetPort({this.verfuegbar = true});

  String? get letzte => geschrieben.isEmpty ? null : geschrieben.last;

  void tippe(String ziel) => _ziele.add(ziel);

  @override
  Future<bool> schreiben(String json) async {
    geschrieben.add(json);
    return true;
  }

  @override
  Future<void> loeschen() async => geloescht++;

  @override
  Future<String?> startZiel() async {
    final s = start;
    start = null;
    return s;
  }

  @override
  Stream<String> get ziele => _ziele.stream;
}

final heuteWidgetPortProvider = Provider<HeuteWidgetPort>((ref) => KanalHeuteWidgetPort());
