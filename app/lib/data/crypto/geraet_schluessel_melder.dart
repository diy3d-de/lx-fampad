// Meldet dem Server den Schlüsselstand dieses Geräts, damit der Betreiber die Schlüssel-Ampel zeigen kann ("Hat jede Person mehr als einen Weg zu ihrem Schlüssel?").
// Gemeldet wird NUR eine Zahl (`PUT /me/device-key`): die Schlüsselversion, die dieses Gerät hat, oder 0 für "dieses Gerät hat keinen (passenden) Schlüssel";
// nie Schlüsselmaterial, nie ein Hinweis auf Inhalte. Die Meldung ist eine Angabe des Geräts und kein Beweis.
//
// Regeln:
//  - Gemeldet wird beim Start und nach jeder Änderung des Stands (Schlüssel eingerichtet, Gerät verbunden, Schlüsselwechsel), sowie beim Zurückkehren in die App,
//    wenn die letzte Meldung über 12 Stunden her ist (der Server wertet eine Meldung 30 Tage lang als Beleg; die Shell ruft [GeraetSchluesselMelder.auffrischen]).
//  - Solange der Stand unklar ist (wird geprüft, Verschlüsselung nicht verfügbar), wird nichts gemeldet: eine falsche "kein Schlüssel"-Meldung wäre schlimmer als keine.
//  - Tolerant gegenüber alten Servern: 404 (Route unbekannt) oder 409 (kein Gerät zur Sitzung) beenden die Versuche für diese Sitzung (nach Abmelden/Anmelden beginnt es neu); jeder andere Fehler
//    (offline, Server gestört) bleibt still, der nächste Auslöser versucht es erneut.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_error.dart';
import '../api/fampad_api.dart';
import '../api/models.dart' show UserDto;
import '../auth/auth_state.dart';
import 'e2ee_state.dart';

/// Welche Zahl meldet dieses Gerät? null: noch unklar, nichts melden.
int? geraetSchluesselStand(E2eeState s) => switch (s.status) {
  E2eeStatus.bereit => s.serverSchluessel?.version,
  // kein Schlüssel auf dem Gerät, oder einer, der nicht (mehr) zum Konto passt: das Gerät hat keinen passenden Schlüssel
  E2eeStatus.keinSchluessel || E2eeStatus.geraetNichtVerbunden || E2eeStatus.abweichend => 0,
  E2eeStatus.laedt || E2eeStatus.nichtVerfuegbar => null,
};

/// Merkt, was schon gemeldet wurde (je Person und Zahl), damit nicht bei jeder Zustandsänderung gesendet wird.
///
/// - Kommt während eines laufenden Aufrufs ein neuer Stand, wird er gemerkt und danach nachgeholt (kein Verlust, kein paralleler Aufruf).
/// - Das Gemerkte (und ein 404/409) gilt nur für die aktuelle Sitzung: wechselt die Geräte-Kennung (Abmelden, andere Person, neue Anmeldung), beginnt alles neu.
class GeraetSchluesselMelder {
  /// [sitzung] liefert die Kennung der aktuellen Sitzung (Geräte-ID aus dem Token-Speicher); ohne sie gilt eine einzige Sitzung.
  GeraetSchluesselMelder({Future<String?> Function()? sitzung}) : _sitzung = sitzung ?? (() async => null);

  final Future<String?> Function() _sitzung;
  bool _sitzungGelesen = false;
  String? _sitzungKennung;
  String? _gemeldet;
  DateTime? _gemeldetAm;
  bool _nichtUnterstuetzt = false;
  bool _laeuft = false;
  ({FampadApi api, String person, int stand, bool erzwingen})? _wartend;

  /// Meldet [stand] für [person], wenn es neu ist (oder mit [erzwingen]). Wirft nie.
  Future<void> melden(FampadApi api, String person, int stand, {bool erzwingen = false}) async {
    if (_laeuft) {
      // der neueste Stand gewinnt; ein erzwungener Auftrag bleibt erzwungen
      _wartend = (api: api, person: person, stand: stand, erzwingen: erzwingen || (_wartend?.erzwingen ?? false));
      return;
    }
    _laeuft = true;
    try {
      var auftrag = (api: api, person: person, stand: stand, erzwingen: erzwingen);
      while (true) {
        _wartend = null;
        await _einmal(auftrag.api, auftrag.person, auftrag.stand, auftrag.erzwingen);
        final naechster = _wartend;
        if (naechster == null) break;
        auftrag = naechster;
      }
    } finally {
      _laeuft = false;
    }
  }

  Future<void> _einmal(FampadApi api, String person, int stand, bool erzwingen) async {
    String? kennung;
    try {
      kennung = await _sitzung();
    } catch (_) {
      kennung = null;
    }
    if (!_sitzungGelesen || kennung != _sitzungKennung) {
      // andere Sitzung: nichts Gemerktes übernehmen, auch kein früheres 404/409
      _sitzungGelesen = true;
      _sitzungKennung = kennung;
      _gemeldet = null;
      _gemeldetAm = null;
      _nichtUnterstuetzt = false;
    }
    final schluessel = '$person:$stand';
    if (_nichtUnterstuetzt || (!erzwingen && _gemeldet == schluessel)) return;
    try {
      await api.geraetSchluesselMelden(stand);
      _gemeldet = schluessel;
      _gemeldetAm = DateTime.now();
    } on ApiException catch (e) {
      // ältere Server kennen die Route nicht (404), die Sitzung hat kein Gerät (409): für diese Sitzung nicht weiter versuchen
      if (e.status == 404 || e.status == 409) _nichtUnterstuetzt = true;
    } catch (_) {
      // still: der nächste Auslöser versucht es erneut
    }
  }
}

/// Meldet erneut, wenn die letzte Meldung über [abstand] her ist (Rückkehr in die App). Wirft nie.
extension GeraetSchluesselAuffrischen on GeraetSchluesselMelder {
  Future<void> auffrischen(FampadApi api, UserDto? person, E2eeState e2ee, {Duration abstand = const Duration(hours: 12)}) async {
    final stand = geraetSchluesselStand(e2ee);
    if (person == null || stand == null) return;
    final zuletzt = _gemeldetAm;
    if (zuletzt != null && DateTime.now().difference(zuletzt) < abstand) return;
    await melden(api, person.id, stand, erzwingen: true);
  }
}

final geraetSchluesselMelderZustandProvider = Provider<GeraetSchluesselMelder>(
  (ref) => GeraetSchluesselMelder(sitzung: () async => (await ref.read(tokenStoreProvider).readTokens())?.deviceId),
);

/// Wird am Wurzel-Widget beobachtet (siehe app.dart).
final geraetSchluesselMelderProvider = Provider<void>((ref) {
  final ich = ref.watch(authProvider.select((s) => s.status == AuthStatus.angemeldet ? s.user?.id : null));
  if (ich == null) return;
  final stand = ref.watch(e2eeProvider.select(geraetSchluesselStand));
  if (stand == null) return;
  final melder = ref.read(geraetSchluesselMelderZustandProvider);
  Future.microtask(() {
    if (ref.mounted) unawaited(melder.melden(ref.read(apiProvider), ich, stand));
  });
});
