// Android-Vordergrunddienst (Typ dataSync) für Datei-Übertragungen über den Methodenkanal `dev.lx_labs.fampad/transfer` (TransferKanal.kt / TransferService.kt).
// Es gehen nur Zahlen hinüber (Anzahl, Prozent), nie Dateinamen oder Inhalte; die Benachrichtigung hat einen festen Text. Fehler des Kanals stören eine Übertragung nie.
import 'dart:io' show Platform;

import 'package:flutter/services.dart';

import 'transfer_modelle.dart';

/// Auf Android der echte Dienst, sonst (Desktop, Tests) keiner.
TransferHintergrundPort transferHintergrundStandard() => Platform.isAndroid ? const AndroidTransferHintergrund() : const KeinTransferHintergrund();

class AndroidTransferHintergrund implements TransferHintergrundPort {
  const AndroidTransferHintergrund({MethodChannel kanal = _kanal}) : _k = kanal;

  static const MethodChannel _kanal = MethodChannel('dev.lx_labs.fampad/transfer');
  final MethodChannel _k;

  Future<void> _senden(String methode, [Map<String, Object?>? args]) async {
    try {
      await _k.invokeMethod<Object?>(methode, args);
    } on PlatformException {
      // der Dienst ist nur eine Hilfe: die Übertragung läuft in der App weiter
    } on MissingPluginException {
      // keine Android-Seite (z. B. Test)
    }
  }

  @override
  Future<void> starten({required int anzahl}) => _senden('start', {'anzahl': anzahl, 'prozent': 0});

  @override
  Future<void> aktualisieren({required int anzahl, required int prozent}) => _senden('update', {'anzahl': anzahl, 'prozent': prozent.clamp(0, 100)});

  @override
  Future<void> beenden() => _senden('stop');
}
