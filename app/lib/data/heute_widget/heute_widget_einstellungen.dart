// Einstellungen des Widgets "Heute" (nur dieses Gerät, nie auf dem Server, nie synchronisiert), gemerkt in der lokalen Datenbank (`sync_meta`):
//  - titel: Titel im Widget zeigen (Standard: an; aus = neutrale Wörter, siehe heute_zusammenfassung.dart),
//  - liste: ID der Liste, deren offene Einträge das Widget zeigt (leer = keine Liste, Standard).
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database_provider.dart';

const kWidgetTitelSchluessel = 'widget_titel';
const kWidgetListeSchluessel = 'widget_liste';

class HeuteWidgetEinstellungen {
  final bool titel;

  /// null = keine Liste im Widget.
  final String? liste;
  const HeuteWidgetEinstellungen({this.titel = true, this.liste});

  HeuteWidgetEinstellungen kopie({bool? titel, Object? liste = _keine}) =>
      HeuteWidgetEinstellungen(titel: titel ?? this.titel, liste: identical(liste, _keine) ? this.liste : liste as String?);

  @override
  bool operator ==(Object other) => other is HeuteWidgetEinstellungen && other.titel == titel && other.liste == liste;

  @override
  int get hashCode => Object.hash(titel, liste);
}

const Object _keine = Object();

abstract class HeuteWidgetSpeicher {
  Future<String?> lesen(String schluessel);
  Future<void> schreiben(String schluessel, String wert);
}

class DatenbankHeuteWidgetSpeicher implements HeuteWidgetSpeicher {
  final Ref _ref;
  DatenbankHeuteWidgetSpeicher(this._ref);

  @override
  Future<String?> lesen(String schluessel) => _ref.read(appDatabaseProvider).metaLesen(schluessel);

  @override
  Future<void> schreiben(String schluessel, String wert) => _ref.read(appDatabaseProvider).metaSchreiben(schluessel, wert);
}

class MemoryHeuteWidgetSpeicher implements HeuteWidgetSpeicher {
  final Map<String, String> daten;
  MemoryHeuteWidgetSpeicher([Map<String, String>? start]) : daten = start ?? {};

  @override
  Future<String?> lesen(String schluessel) async => daten[schluessel];

  @override
  Future<void> schreiben(String schluessel, String wert) async => daten[schluessel] = wert;
}

final heuteWidgetSpeicherProvider = Provider<HeuteWidgetSpeicher>((ref) => DatenbankHeuteWidgetSpeicher(ref));

class HeuteWidgetEinstellungenNotifier extends Notifier<HeuteWidgetEinstellungen> {
  bool _titelGesetzt = false;
  bool _listeGesetzt = false;

  @override
  HeuteWidgetEinstellungen build() {
    _titelGesetzt = false;
    _listeGesetzt = false;
    _laden();
    return const HeuteWidgetEinstellungen();
  }

  Future<void> _laden() async {
    try {
      final speicher = ref.read(heuteWidgetSpeicherProvider);
      final t = await speicher.lesen(kWidgetTitelSchluessel);
      final l = await speicher.lesen(kWidgetListeSchluessel);
      if (!ref.mounted) return;
      state = HeuteWidgetEinstellungen(
        titel: _titelGesetzt ? state.titel : t != 'nein',
        liste: _listeGesetzt ? state.liste : (l == null || l.isEmpty ? null : l),
      );
    } catch (_) {
      // nicht lesbar: Standardwerte
    }
  }

  Future<void> titelSetzen(bool an) async {
    _titelGesetzt = true;
    state = state.kopie(titel: an);
    try {
      await ref.read(heuteWidgetSpeicherProvider).schreiben(kWidgetTitelSchluessel, an ? 'ja' : 'nein');
    } catch (_) {
      // gilt dann nur bis zum Schließen der App
    }
  }

  Future<void> listeSetzen(String? id) async {
    _listeGesetzt = true;
    state = state.kopie(liste: id);
    try {
      await ref.read(heuteWidgetSpeicherProvider).schreiben(kWidgetListeSchluessel, id ?? '');
    } catch (_) {
      // gilt dann nur bis zum Schließen der App
    }
  }
}

final heuteWidgetEinstellungenProvider = NotifierProvider<HeuteWidgetEinstellungenNotifier, HeuteWidgetEinstellungen>(HeuteWidgetEinstellungenNotifier.new);
