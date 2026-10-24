// Tresor (Abschnitt 6m), Daten für die Oberfläche: die Einträge, entschlüsselt NUR solange der Tresor entsperrt ist und nur für Eltern und Admins. Gesperrt (oder ohne Recht) liefert der Anbieter
// sofort leere Daten, ohne die Tabelle zu lesen oder etwas zu entschlüsseln. Der Klartext liegt allein im Zustand dieses Anbieters (nicht im gemeinsamen Zwischenspeicher der Chat-
// Entschlüsselung) und verschwindet mit der Sperre. Dazu der Suchtext (wird mit der Sperre geleert).
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../chat/chat_krypto_state.dart' show chatKryptoProvider;
import 'tresor_logik.dart';
import 'tresor_repository.dart';
import 'tresor_sperre.dart';
import 'tresor_state.dart';

class TresorDaten {
  /// Darf gelesen werden (Rolle erlaubt UND entsperrt)?
  final bool offen;
  final bool geladen;
  final List<TresorAnsicht> eintraege;
  const TresorDaten({this.offen = false, this.geladen = false, this.eintraege = const []});

  /// Lesbare Einträge in der Reihenfolge der Liste (Kategorie, Titel).
  List<TresorAnsicht> get lesbare => tresorSortieren([for (final e in eintraege) if (e.inhalt != null) e], (e) => e.inhalt!, (e) => e.id);

  /// Einträge, die sich gerade nicht lesen lassen (Schlüssel fehlt, beschädigt, neuere App-Version).
  List<TresorAnsicht> get unlesbare => [for (final e in eintraege) if (e.inhalt == null) e];

  TresorAnsicht? eintrag(String id) {
    for (final e in eintraege) {
      if (e.id == id) return e;
    }
    return null;
  }
}

final tresorEintraegeStromProvider = StreamProvider.autoDispose<List<TresorAnsicht>>((ref) {
  final darf = ref.watch(tresorDarfProvider);
  final entsperrt = ref.watch(tresorSperreProvider.select((s) => s.entsperrt));
  if (!darf || !entsperrt) return Stream.value(const <TresorAnsicht>[]);
  ref.watch(chatKryptoProvider); // ein neuer Schlüssel (Epoche) löst das Lesen erneut aus
  final repo = ref.watch(tresorRepositoryProvider);
  return repo.zeilen().asyncMap(repo.lesen);
});

final tresorDatenProvider = Provider.autoDispose<TresorDaten>((ref) {
  final darf = ref.watch(tresorDarfProvider);
  final entsperrt = ref.watch(tresorSperreProvider.select((s) => s.entsperrt));
  if (!darf || !entsperrt) return const TresorDaten();
  final s = ref.watch(tresorEintraegeStromProvider);
  return TresorDaten(offen: true, geladen: s.hasValue, eintraege: s.value ?? const []);
});

class TresorSuche extends Notifier<String> {
  @override
  String build() {
    ref.watch(tresorSperreProvider.select((s) => s.entsperrt)); // Sperre: Suchtext weg
    return '';
  }

  void setzen(String text) => state = text;
}

final tresorSucheProvider = NotifierProvider.autoDispose<TresorSuche, String>(TresorSuche.new);

/// Treffer der Suche über die lesbaren Einträge (nur Titel, Kategorie, Bezeichnungen, nicht geheime Werte; siehe [tresorSuchen]).
List<TresorAnsicht> tresorTreffer(TresorDaten d, String anfrage) => tresorSuchen(d.lesbare, (e) => e.inhalt!, anfrage);
