// Schnittstelle zum Betriebssystem fürs Standort teilen: Berechtigungen, Vordergrunddienst mit ständiger Benachrichtigung und die Positionen des
// Geräts. Android: eigener Kotlin-Dienst über MethodChannel/EventChannel (android/.../StandortService.kt, StandortKanal.kt), ohne Fremdpaket und
// ohne Google-Dienste (Android-LocationManager). Im Web und in Tests gibt es eine Variante ohne Wirkung bzw. einen Fake.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Eine Messung des Geräts.
class GeraetePosition {
  final double breite;
  final double laenge;

  /// Genauigkeit in Metern (null: unbekannt).
  final double? genauigkeit;
  final DateTime zeit;
  const GeraetePosition({required this.breite, required this.laenge, this.genauigkeit, required this.zeit});
}

/// Zustand der Berechtigungen und des Standortdienstes des Geräts.
class StandortStatus {
  /// Genauer Standort erlaubt.
  final bool fein;

  /// Ungefährer Standort erlaubt (Android 12+: die Person kann nur "ungefähr" erlauben).
  final bool grob;

  /// Benachrichtigungen erlaubt (nötig: die ständige Benachrichtigung zeigt das Teilen und lässt es beenden).
  final bool benachrichtigungen;

  /// Ortung des Geräts eingeschaltet.
  final bool dienstAn;
  const StandortStatus({this.fein = false, this.grob = false, this.benachrichtigungen = false, this.dienstAn = false});

  bool get erlaubt => fein || grob;
  bool get bereit => erlaubt && benachrichtigungen;
}

/// Ereignisse des Dienstes.
sealed class StandortEreignis {
  const StandortEreignis();
}

class PositionEreignis extends StandortEreignis {
  final GeraetePosition position;
  const PositionEreignis(this.position);
}

/// Die Person hat in der Benachrichtigung auf "Beenden" getippt.
class StopEreignis extends StandortEreignis {
  const StopEreignis();
}

/// Der Standortdienst des Geräts wurde ein- oder ausgeschaltet.
class DienstEreignis extends StandortEreignis {
  final bool an;
  const DienstEreignis(this.an);
}

/// Der Dienst konnte nicht laufen ([grund]: `keine_berechtigung`, `dienst_start`).
class FehlerEreignis extends StandortEreignis {
  final String grund;
  const FehlerEreignis(this.grund);
}

/// Warum das Starten nicht gelang (die Oberfläche übersetzt es in einen Satz).
enum StartFehler { keineBerechtigung, benachrichtigungenAus, dienstStart, ende }

abstract class StandortPort {
  /// Gibt es das Teilen auf diesem Gerät? Nur Android (nicht Web).
  bool get verfuegbar;

  Future<StandortStatus> status();

  /// Fragt die Berechtigungen ab (Standort im Vordergrund, ab Android 13 Benachrichtigungen) und liefert den neuen Stand.
  Future<StandortStatus> berechtigungAnfragen();

  /// Startet den Vordergrunddienst bis [ende]; null = gelungen, sonst der Grund.
  Future<StartFehler?> starten(DateTime ende);

  /// Neue Endzeit der laufenden Freigabe (verlängern).
  Future<void> verlaengern(DateTime ende);

  Future<void> stoppen();

  /// Lebenszeichen an den Dienst (er beendet sich selbst, wenn es zu lange ausbleibt). [stopAngefordert]: die Person hat in der Benachrichtigung
  /// auf "Beenden" getippt, bevor Dart es per Ereignis erfahren konnte. [laeuft] false: der Dienst läuft nicht mehr (z. B. vom System beendet).
  Future<({bool laeuft, bool stopAngefordert})> herzschlag();

  /// Positionen und Ereignisse des Dienstes (nur solange jemand zuhört).
  Stream<StandortEreignis> get ereignisse;

  Future<bool> einstellungenOeffnen();
  Future<bool> akkuEinstellungenOeffnen();
}

/// Ohne Wirkung: Web und alle Plattformen ohne Standort-Dienst.
class KeinStandortPort implements StandortPort {
  const KeinStandortPort();

  @override
  bool get verfuegbar => false;
  @override
  Future<StandortStatus> status() async => const StandortStatus();
  @override
  Future<StandortStatus> berechtigungAnfragen() async => const StandortStatus();
  @override
  Future<StartFehler?> starten(DateTime ende) async => StartFehler.dienstStart;
  @override
  Future<void> verlaengern(DateTime ende) async {}
  @override
  Future<void> stoppen() async {}
  @override
  Future<({bool laeuft, bool stopAngefordert})> herzschlag() async => (laeuft: false, stopAngefordert: false);
  @override
  Stream<StandortEreignis> get ereignisse => const Stream.empty();
  @override
  Future<bool> einstellungenOeffnen() async => false;
  @override
  Future<bool> akkuEinstellungenOeffnen() async => false;
}

/// Android: spricht den Kotlin-Dienst an. Fehler der Kanäle werden abgefangen und als "nicht gelungen" gemeldet.
class AndroidStandortPort implements StandortPort {
  static const _methoden = MethodChannel('dev.lx_labs.fampad/standort');
  static const _ereignisse = EventChannel('dev.lx_labs.fampad/standort_ereignisse');

  const AndroidStandortPort();

  @override
  bool get verfuegbar => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static StandortStatus _status(Object? roh) {
    if (roh is! Map) return const StandortStatus();
    bool b(String k) => roh[k] == true;
    return StandortStatus(fein: b('fein'), grob: b('grob'), benachrichtigungen: b('benachrichtigungen'), dienstAn: b('dienstAn'));
  }

  Future<T?> _sicher<T>(Future<T?> Function() f) async {
    try {
      return await f();
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  @override
  Future<StandortStatus> status() async => _status(await _sicher(() => _methoden.invokeMethod<Object>('status')));

  @override
  Future<StandortStatus> berechtigungAnfragen() async => _status(await _sicher(() => _methoden.invokeMethod<Object>('berechtigungAnfragen')));

  @override
  Future<StartFehler?> starten(DateTime ende) async {
    final r = await _sicher(() => _methoden.invokeMethod<Object>('start', {'ende': ende.millisecondsSinceEpoch}));
    if (r is! Map) return StartFehler.dienstStart;
    if (r['ok'] == true) return null;
    return switch (r['grund']) {
      'keine_berechtigung' => StartFehler.keineBerechtigung,
      'benachrichtigungen_aus' => StartFehler.benachrichtigungenAus,
      'ende' => StartFehler.ende,
      _ => StartFehler.dienstStart,
    };
  }

  @override
  Future<void> verlaengern(DateTime ende) async {
    await _sicher(() => _methoden.invokeMethod<void>('verlaengern', {'ende': ende.millisecondsSinceEpoch}));
  }

  @override
  Future<void> stoppen() async {
    await _sicher(() => _methoden.invokeMethod<void>('stop'));
  }

  @override
  Future<({bool laeuft, bool stopAngefordert})> herzschlag() async {
    final r = await _sicher(() => _methoden.invokeMethod<Object>('herzschlag'));
    if (r is! Map) return (laeuft: false, stopAngefordert: false);
    return (laeuft: r['laeuft'] == true, stopAngefordert: r['stopAngefordert'] == true);
  }

  @override
  Stream<StandortEreignis> get ereignisse => _ereignisse.receiveBroadcastStream().map<StandortEreignis?>(_ereignis).where((e) => e != null).cast<StandortEreignis>();

  static StandortEreignis? _ereignis(Object? roh) {
    if (roh is! Map) return null;
    switch (roh['art']) {
      case 'position':
        final breite = roh['breite'];
        final laenge = roh['laenge'];
        if (breite is! num || laenge is! num) return null;
        final g = roh['genauigkeit'];
        final t = roh['zeit'];
        return PositionEreignis(
          GeraetePosition(
            breite: breite.toDouble(),
            laenge: laenge.toDouble(),
            genauigkeit: g is num ? g.toDouble() : null,
            zeit: t is int ? DateTime.fromMillisecondsSinceEpoch(t) : DateTime.now(),
          ),
        );
      case 'stop':
        return const StopEreignis();
      case 'dienst':
        return DienstEreignis(roh['an'] == true);
      case 'fehler':
        return FehlerEreignis('${roh['grund']}');
    }
    return null;
  }

  @override
  Future<bool> einstellungenOeffnen() async => await _sicher(() => _methoden.invokeMethod<bool>('einstellungenOeffnen')) ?? false;

  @override
  Future<bool> akkuEinstellungenOeffnen() async => await _sicher(() => _methoden.invokeMethod<bool>('akkuEinstellungenOeffnen')) ?? false;
}

/// Der Anschluss ans Gerät; in Tests wird er überschrieben.
StandortPort standortPortErzeugen() => !kIsWeb && defaultTargetPlatform == TargetPlatform.android ? const AndroidStandortPort() : const KeinStandortPort();
