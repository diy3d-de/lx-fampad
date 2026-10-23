// Zähler (Abschnitt 6l), Zustand für die Oberfläche und die Erinnerungen: die lesbaren Zähler und Stände dieses Haushalts, zusammengefasst zu Reihen (Wechsel-Ketten) und Kacheln (Gruppen).
//
// Zugriff NUR für Eltern und Admins (Rolle `admin`/`parent` der angemeldeten Person; der Server erzwingt dieselbe Regel). Für alle anderen liefert [zaehlerDatenProvider] sofort
// leere Daten, OHNE die Tabellen zu lesen oder etwas zu entschlüsseln; es gibt dann auch keine Zahl für das Badge und keine Kachel. Die Datenbank hält ohnehin nur, was der Server
// dieser Person liefert. Entschlüsselt wird nicht blockierend über den Zwischenspeicher ([NachrichtenInhalt.zusatz]): bis der Schlüssel da ist, kommt ein Eintrag ohne Inhalt mit Hinweis.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/models.dart' show Role;
import '../app_database.dart';
import '../auth/auth_state.dart';
import '../chat/chat_repository.dart' show ChatArt;
import '../chat/nachrichten_inhalt.dart';
import '../database_provider.dart';
import '../medikamente/medikament_logik.dart' show familienTag;
import 'zaehler_logik.dart';
import 'zaehler_modelle.dart';
import 'zaehler_repository.dart';
import 'zaehler_uebersicht.dart';

/// Darf die angemeldete Person die Zähler sehen (Rolle Elternteil oder Admin)? Rein nach der Rolle der Sitzung, nie nach Familienrolle oder Betreiber-Flag.
bool darfRolleZaehler(Role? rolle) => rolle == Role.admin || rolle == Role.parent;

final zaehlerDarfProvider = Provider<bool>((ref) => darfRolleZaehler(ref.watch(authProvider.select((a) => a.user?.role))));

/// Ein Zähler (gelesen oder mit Hinweis, warum nicht) mit seinen Ständen (Anlage-Reihenfolge).
class ZaehlerEintrag {
  final ZaehlerAnsicht ansicht;
  final List<StandAnsicht> staende;
  const ZaehlerEintrag(this.ansicht, this.staende);

  String get id => ansicht.id;
  ZaehlerInhalt? get inhalt => ansicht.inhalt;
  bool get lesbar => inhalt != null;

  /// Die lesbaren Stände als Rechen-Stände.
  List<Stand> get rechenStaende => [
    for (final s in staende)
      if (s.inhalt?.tag != null) Stand(s.inhalt!.tag!, s.inhalt!.milli, marke: s.inhalt!.marke),
  ];
}

class ZaehlerDaten {
  /// Datenbank ist gelesen (vorher darf nichts geplant oder gelöscht werden).
  final bool geladen;
  final String? ich;
  final bool darf;
  final List<ZaehlerEintrag> eintraege;
  final List<ZaehlerReihe> reihen;
  final List<ZaehlerKachel> kacheln;
  const ZaehlerDaten({this.geladen = false, this.ich, this.darf = false, this.eintraege = const [], this.reihen = const [], this.kacheln = const []});

  bool get leer => eintraege.isEmpty;

  ZaehlerEintrag? eintrag(String id) => eintraege.where((e) => e.id == id).firstOrNull;

  ZaehlerReihe? reihe(String id) => reihen.where((r) => r.id == id || r.ids.contains(id)).firstOrNull;

  List<ZaehlerReihe> get archiviert => [for (final r in reihen) if (r.archiviert) r];

  List<ZaehlerEintrag> get nichtLesbar => [for (final e in eintraege) if (!e.lesbar) e];

  /// Die Inhalte aller lesbaren Zähler (ID -> Inhalt).
  Map<String, ZaehlerInhalt> get inhalte => {for (final e in eintraege) if (e.inhalt != null) e.id: e.inhalt!};

  ZaehlerKachel? kachel(String schluessel) => kacheln.where((k) => k.schluessel == schluessel).firstOrNull;

  /// Die Kachel, die diese Reihe enthält.
  ZaehlerKachel? kachelVon(String reiheId) => kacheln.where((k) => k.reihen.any((r) => r.id == reiheId)).firstOrNull;
}

final zaehlerZeilenProvider = StreamProvider<List<ZaehlerZeile>>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return db.select(db.zaehler).watch();
});

final zaehlerstandZeilenProvider = StreamProvider<List<ZaehlerstandZeile>>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return db.select(db.zaehlerstaende).watch();
});

/// Die Zähler dieses Haushalts (leer ohne Anmeldung und für alle, die keine Eltern oder Admins sind; dann wird nichts gelesen).
final zaehlerDatenProvider = Provider<ZaehlerDaten>((ref) {
  final me = ref.watch(authProvider.select((a) => a.user?.id));
  final darf = ref.watch(zaehlerDarfProvider);
  if (me == null || !darf) return ZaehlerDaten(ich: me, geladen: me != null);
  final zeilen = ref.watch(zaehlerZeilenProvider);
  final staende = ref.watch(zaehlerstandZeilenProvider);
  if (!zeilen.hasValue || !staende.hasValue) return ZaehlerDaten(ich: me, darf: true);
  if (zeilen.value!.isEmpty) return ZaehlerDaten(geladen: true, ich: me, darf: true);
  final inhalt = ref.watch(nachrichtenInhaltProvider); // erst bei vorhandenen Zählern (startet die Entschlüsselung)
  final repo = ref.read(zaehlerRepositoryProvider);
  final nachZaehler = <String, List<StandAnsicht>>{};
  for (final s in staende.value!) {
    (nachZaehler[s.zaehlerId] ??= []).add(repo.standAnsicht(s, inhalt));
  }
  final liste = [
    for (final z in zeilen.value!) ZaehlerEintrag(repo.ansicht(z, inhalt), List.unmodifiable(nachZaehler[z.id] ?? const [])),
  ];
  final inhalte = {for (final e in liste) if (e.inhalt != null) e.id: e.inhalt!};
  final reihen = baueReihen(inhalte, {for (final e in liste) if (e.lesbar) e.id: e.rechenStaende});
  return ZaehlerDaten(geladen: true, ich: me, darf: true, eintraege: liste, reihen: reihen, kacheln: baueKacheln(reihen));
});

/// Heute (Kalendertag der Familienzone) zu einem Zeitpunkt.
DateTime zaehlerHeute(DateTime jetzt) => familienTag(jetzt);

/// Die verborgene Zähler-Konversation (nur für die Teilnehmerpflege; ohne sie gibt es nichts zu pflegen).
final zaehlerKonversationProvider = StreamProvider<List<Konversation>>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return (db.select(db.konversationen)..where((k) => k.art.equals(ChatArt.zaehler.wire))).watch();
});
