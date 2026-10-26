import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/app_database.dart';
import '../../data/api/models.dart';
import '../../data/auth/auth_state.dart';
import '../../data/calendar/termin_repository.dart';
import '../../data/lists/list_repository.dart';
import '../../data/startseite/startseite_logik.dart';
import '../../data/startseite/startseite_state.dart';
import '../../data/sync_state.dart';
import '../../ui/widgets.dart';
import '../../widgets/kopfzeile.dart';
import '../../widgets/sync_anzeige.dart';
import '../profile/absicherung_screen.dart' show AbsicherungsKarte;
import '../calendar/calendar_anzeige.dart';
import '../calendar/calendar_state.dart';
import '../calendar/geburtstage_karte.dart';
import '../calendar/countdown_karte.dart';
import '../tasks/aufgaben_anzeige.dart';
import '../tasks/fristen_anzeige.dart' show FristenStartKarte;
import '../../data/tasks/aufgabe_repository.dart';
import '../calendar/termin_editor.dart';
import '../tasks/aufgabe_editor.dart' show aufgabeEditorOeffnen;
import '../../data/dateien/datei_state.dart' show dateienVerfuegbarProvider;
import '../shell/shell_tab.dart';
import '../muell/muell_karte.dart';
import '../medikamente/medikamente_karte.dart' show MedikamenteStartKarte;
import '../zaehler/zaehler_karte.dart' show ZaehlerStartKarte;
import '../files/dateien_start_karte.dart' show dateiSchnellHochladen;
import '../standort/standort_start_karte.dart';
import '../suche/such_einstieg.dart';
import '../update/update_banner.dart';
import '../wetter/wetter_dwd_warn_karte.dart';
import '../wetter/wetter_hinweis_karte.dart';
import '../wetter/wetter_karte.dart';
import 'startseite_verfuegbar.dart';
import 'startseite_anpassen_zeile.dart';
import 'startseite_widgets.dart';

/// Vorname für die Begrüßung: erstes Wort des Anzeigenamens, sehr lange Namen werden gekürzt; null bei leerem Namen.
String? vorname(String? anzeigename) {
  final wort = (anzeigename ?? '').trim().split(RegExp(r'\s+')).first;
  if (wort.isEmpty) return null;
  // Graphem-sicher kürzen (Emoji und kombinierte Zeichen werden nicht mitten im Zeichen geschnitten)
  final zeichen = wort.characters;
  return zeichen.length > 20 ? '${zeichen.take(19)}…' : wort;
}

/// Begrüßung mit Vorname; bei leerem Namen nur "Hallo".
String begruessung(String? anzeigename) {
  final v = vorname(anzeigename);
  return v == null ? 'Hallo' : 'Hallo, $v';
}

/// Start: Begrüßung, Sync-Status und die Kacheln (Schnellzugriffe, Einkaufsliste, Termine, ...); Reihenfolge und Ausblenden lokal je Gerät
/// (Zustand in data/startseite/), die Warn- und Hinweiskarten oben bleiben fest.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final name = ref.watch(authProvider.select((s) => s.user?.displayName));
    final anordnung = ref.watch(startseiteMobilProvider);
    final verf = ref.watch(mobilVerfuegbarProvider);
    // erst zeichnen, wenn die gemerkte Reihenfolge gelesen ist (sonst springen die Kacheln)
    final ids = anordnung.geladen ? sichtbareKacheln(reihenfolge: anordnung.reihenfolge, verfuegbar: verf, ausgeblendet: anordnung.ausgeblendet) : const <String>[];
    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
          sliver: SliverList.list(
            children: [
              TabKopfzeile(title: begruessung(name)),
              const SizedBox(height: 20),
              const UpdateAnzeige(),
              const AbsicherungsKarte(),
              const WetterHinweisKarte(),
        const WetterDwdWarnKarte(),
              const _SyncZeile(),
              const SizedBox(height: 20),
            ],
          ),
        ),
        // Kacheln: gedrückt halten und ziehen (Handy: langes Drücken, Maus: gedrückt halten); Reihenfolge und Ausblenden lokal je Gerät
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          sliver: SliverReorderableList(
            itemCount: ids.length,
            itemBuilder: (context, i) => ReorderableDelayedDragStartListener(
              key: ValueKey(ids[i]),
              index: i,
              child: Padding(padding: const EdgeInsets.only(bottom: 20), child: _kachel(ids[i])),
            ),
            proxyDecorator: (child, index, animation) => Align(
              alignment: Alignment.topCenter,
              child: SizedBox(width: double.infinity, child: StartseiteGehoben(animation: animation, child: _kachel(ids[index]))),
            ),
            onReorderItem: (alt, ziel) {
              if (ziel == alt) return;
              final liste = List.of(ids);
              liste.insert(ziel, liste.removeAt(alt));
              unawaited(ref.read(startseiteMobilProvider.notifier).teilmengeOrdnen(liste));
            },
          ),
        ),
        const SliverPadding(padding: EdgeInsets.fromLTRB(20, 0, 20, 20), sliver: SliverToBoxAdapter(child: StartseiteAnpassenZeile())),
      ],
    );
  }
}

/// Die Kachel zu einer Kennung (siehe [kMobilKacheln]).
Widget _kachel(String id) => switch (id) {
  'schnellzugriff' => const _SchnellzugriffReihe(),
  'einkauf' => const _EinkaufKarte(),
  'termine' => const _NaechsteKarte(),
  'geburtstage' => const GeburtstageKarte(),
  'countdown' => const CountdownKarte(),
  'aufgaben' => const _AufgabenKarte(),
  'fristen' => const FristenStartKarte(),
  'medikamente' => const MedikamenteStartKarte(),
  'zaehler' => const ZaehlerStartKarte(),
  'muell' => const MuellStartKarte(),
  'wetter' => const WetterStartKarte(),
  'standort' => const StandortStartKarte(),
  _ => const SizedBox.shrink(),
};

/// Sync-Streifen und rechts daneben der Such-Knopf (eine Zeile, fest, keine Kachel).
class _SyncZeile extends StatelessWidget {
  const _SyncZeile();

  @override
  Widget build(BuildContext context) => const Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Expanded(child: _SyncLeiste()),
      SizedBox(width: 8),
      SuchKnopf(),
    ],
  );
}

/// Stand des Abgleichs (fest, keine Kachel): bei "synchron" nur ein kleiner Punkt, sonst ein ruhiger Satz. Die Zahl offener Änderungen steht
/// nur im Bedienhilfe-Text. Der Sync-Zustand steht auf der Startseite nur hier (die Kopfzeile zeigt ihn mobil als Symbol).
class _SyncLeiste extends ConsumerWidget {
  const _SyncLeiste();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sync = ref.watch(syncProvider);
    final (bedienText, farbe) = syncAnzeige(sync);
    final hinweis = syncHinweis(sync);
    if (hinweis == null) {
      return Semantics(
        label: 'Sync: $bedienText',
        child: SizedBox(
          height: 44,
          child: Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.only(left: 14),
              child: ExcludeSemantics(child: Container(width: 8, height: 8, decoration: BoxDecoration(shape: BoxShape.circle, color: farbe))),
            ),
          ),
        ),
      );
    }
    return Semantics(
      label: 'Sync: $bedienText',
      excludeSemantics: true,
      child: Container(
        constraints: const BoxConstraints(minHeight: 44),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(color: farbe.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(18)),
        child: Row(
          children: [
            Icon(sync.status == SyncStatus.wartung ? Icons.build_outlined : Icons.cloud_off, size: 16, color: farbe),
            const SizedBox(width: 10),
            Expanded(child: Text(hinweis, style: TextStyle(fontSize: 13, color: farbe == kTextMuted ? kText : farbe))),
          ],
        ),
      ),
    );
  }
}

/// Kachel "Schnellzugriff": vier Knöpfe in einer Reihe.
class _SchnellzugriffReihe extends ConsumerWidget {
  const _SchnellzugriffReihe();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Foto und Datei gibt es nur mit Dateiablage; sonst steht an ihrer Stelle "Aufgabe" (keine Knöpfe ohne Funktion)
    final dateienDa = ref.watch(dateienVerfuegbarProvider).value ?? false;
    // feste Höhe statt Seitenverhältnis: wächst nicht mit der Breite, aber mit der Schrift; bei stark vergrößerter Schrift zwei Knöpfe je Reihe,
    // damit die Beschriftungen nicht mitten im Wort brechen
    final skala = MediaQuery.textScalerOf(context).scale(1.0);
    final spalten = skala >= 1.75 ? 2 : (dateienDa ? 4 : 3);
    final hoehe = (24 + 36 + 8 + 12 * skala * 1.4 + 4).ceilToDouble();
    return GridView(
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: spalten, mainAxisSpacing: 10, crossAxisSpacing: 10, mainAxisExtent: hoehe < 96 ? 96 : hoehe),
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      children: [
        const _Schnellzugriff('Termin', Icons.calendar_today_outlined, zumTerminEditor: true),
        const _Schnellzugriff('Eintrag', Icons.checklist_outlined, zumListenTab: true),
        if (dateienDa) ...const [
          _Schnellzugriff('Foto', Icons.image_outlined, zumFoto: true),
          _Schnellzugriff('Datei', Icons.upload_outlined, zumDatei: true),
        ] else
          const _Schnellzugriff('Aufgabe', Icons.task_alt_outlined, zumAufgabeEditor: true),
      ],
      );
  }
}

class _Schnellzugriff extends ConsumerWidget {
  final String label;
  final IconData icon;
  final bool zumListenTab;
  final bool zumTerminEditor;
  final bool zumAufgabeEditor;
  final bool zumFoto;
  final bool zumDatei;
  const _Schnellzugriff(this.label, this.icon, {this.zumListenTab = false, this.zumTerminEditor = false, this.zumAufgabeEditor = false, this.zumFoto = false, this.zumDatei = false});

  @override
  Widget build(BuildContext context, WidgetRef ref) => LxCard(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
        onTap: () {
          if (zumListenTab) {
            ref.read(shellTabProvider.notifier).waehlen(kListenTab);
          } else if (zumTerminEditor) {
            final u = ref.read(authProvider).user;
            if (TerminRechte(u?.role ?? Role.child, u?.id).darfAnlegen) {
              unawaited(terminEditorOeffnen(context));
            } else {
              ref.read(shellTabProvider.notifier).waehlen(kKalenderTab);
            }
          } else if (zumAufgabeEditor) {
            final u = ref.read(authProvider).user;
            if (AufgabeRechte(u?.role ?? Role.child, u?.id).darfAnlegen) {
              unawaited(aufgabeEditorOeffnen(context));
            } else {
              ref.read(shellTabProvider.notifier).waehlen(kAufgabenTab);
            }
          } else if (zumFoto || zumDatei) {
            dateiSchnellHochladen(context, ref, nurBilder: zumFoto);
          }
        },
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(color: kAccent.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(10)),
              child: Icon(icon, size: 18, color: kAccent),
            ),
            const SizedBox(height: 8),
            Text(label, style: const TextStyle(fontSize: 12)),
          ],
        ),
      );
}

/// Karte "Einkaufsliste" mit echten Daten: offene Einträge der ersten Einkaufsliste (lokale Datenbank, auch offline).
class _EinkaufKarte extends ConsumerWidget {
  const _EinkaufKarte();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final listen = ref.watch(listenProvider).value ?? const <Liste>[];
    final alle = ref.watch(alleEintraegeProvider).value ?? const <Listeneintrag>[];
    final einkauf = listen.where((l) => l.kind == 'shopping').firstOrNull;
    final offen = einkauf == null ? <Listeneintrag>[] : sortiereEintraege(alle.where((e) => e.listId == einkauf.id && e.doneAt == null).toList());
    final erledigt = einkauf == null ? 0 : alle.where((e) => e.listId == einkauf.id && e.doneAt != null).length;
    void oeffnen() {
      if (einkauf != null) ref.read(gewaehlteListeProvider.notifier).waehlen(einkauf.id);
      ref.read(shellTabProvider.notifier).waehlen(kListenTab);
    }

    return Semantics(
      button: true,
      label: einkauf == null ? 'Einkaufsliste, noch keine Liste. Öffnen' : 'Einkaufsliste, ${offen.length} offen. Öffnen',
      excludeSemantics: true,
      child: LxCard(
        onTap: oeffnen,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(child: MonoLabel('Einkaufsliste')),
                if (einkauf != null) Text('${offen.length} offen', style: const TextStyle(fontFamily: kFontSans, fontFeatures: kZiffern, fontSize: 11, color: kTextMuted)),
              ],
            ),
            const SizedBox(height: 12),
            if (einkauf == null)
              const Text('Noch keine Einkaufsliste – tippen zum Anlegen', style: TextStyle(color: kTextMuted))
            else if (offen.isEmpty)
              Text(erledigt == 0 ? 'Nichts auf der Liste' : 'Alles erledigt', style: const TextStyle(color: kTextMuted))
            else ...[
              for (final e in offen.take(4))
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    children: [
                      const Icon(Icons.check_box_outline_blank, size: 18, color: kTextMuted),
                      const SizedBox(width: 10),
                      Expanded(child: Text(e.inhalt, maxLines: 1, overflow: TextOverflow.ellipsis)),
                    ],
                  ),
                ),
              if (offen.length > 4) Text('+ ${offen.length - 4} weitere', style: const TextStyle(fontFamily: kFontSans, fontFeatures: kZiffern, fontSize: 11, color: kTextMuted)),
            ],
          ],
        ),
      ),
    );
  }
}

/// Karte "Aufgaben": überfällige und bald fällige offene Aufgaben (lokale Datenbank, auch offline). Tippen öffnet die Aufgaben.
class _AufgabenKarte extends ConsumerWidget {
  const _AufgabenKarte();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final alle = ref.watch(aufgabenProvider).value ?? const <Aufgabe>[];
    final jetzt = ref.watch(minutenTaktProvider).value ?? DateTime.now();
    final faellig = startseitenAufgaben(alle, jetzt, nurFaellig: true);
    final zeigen = faellig.take(4).toList();
    final mitglieder = mitgliederFuerAufgaben(ref, zeigen);
    return Semantics(
      button: true,
      label: zeigen.isEmpty ? 'Aufgaben: nichts fällig. Aufgaben öffnen' : 'Aufgaben: ${faellig.length} fällig. Aufgaben öffnen',
      excludeSemantics: true,
      child: LxCard(
        onTap: () => ref.read(shellTabProvider.notifier).waehlen(kAufgabenTab),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const MonoLabel('Aufgaben'),
            const SizedBox(height: 12),
            if (zeigen.isEmpty)
              Text(alle.any((a) => a.erledigtAt == null) ? 'Nichts fällig' : 'Keine offenen Aufgaben', style: const TextStyle(color: kTextMuted))
            else
              for (final a in zeigen) AufgabeKurzzeile(aufgabe: a, mitglieder: mitglieder, jetzt: jetzt),
            if (faellig.length > zeigen.length) Text('+ ${faellig.length - zeigen.length} weitere', style: const TextStyle(fontFamily: kFontSans, fontFeatures: kZiffern, fontSize: 11, color: kTextMuted)),
          ],
        ),
      ),
    );
  }
}

/// Karte "Als Nächstes": die nächsten Termine aus der lokalen Datenbank (auch offline), laufende zuerst. Tippen öffnet den Kalender.
class _NaechsteKarte extends ConsumerWidget {
  const _NaechsteKarte();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final daten = ref.watch(kalenderDatenProvider);
    final mitglieder = mitgliederFuer(ref, daten);
    final jetzt = ref.watch(minutenTaktProvider).value ?? DateTime.now();
    final heute = heuteTag(jetzt);
    final kommende = anstehende(daten, jetzt);
    final zeigen = kommende.take(4).toList();
    return Semantics(
      button: true,
      label: zeigen.isEmpty ? 'Als Nächstes: keine anstehenden Termine. Kalender öffnen' : 'Als Nächstes: ${zeigen.length} Termine. Kalender öffnen',
      excludeSemantics: true,
      child: LxCard(
        onTap: () => ref.read(shellTabProvider.notifier).waehlen(kKalenderTab),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const MonoLabel('Als nächstes'),
            const SizedBox(height: 12),
            if (zeigen.isEmpty)
              const Text('Keine anstehenden Termine', style: TextStyle(color: kTextMuted))
            else
              for (final v in zeigen) AnstehenderTermin(v: v, mitglieder: mitglieder, heute: heute),
            if (kommende.length > zeigen.length) Text('+ ${kommende.length - zeigen.length} weitere', style: const TextStyle(fontFamily: kFontSans, fontFeatures: kZiffern, fontSize: 11, color: kTextMuted)),
          ],
        ),
      ),
    );
  }
}
