import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

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
import '../tasks/aufgaben_anzeige.dart';
import '../../data/tasks/aufgabe_repository.dart';
import '../calendar/termin_editor.dart';
import '../shell/shell_tab.dart';
import '../muell/muell_karte.dart';
import '../standort/standort_start_karte.dart';
import '../update/update_banner.dart';
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
              const _SyncLeiste(),
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
  'aufgaben' => const _AufgabenKarte(),
  'muell' => const MuellStartKarte(),
  'wetter' => const WetterStartKarte(),
  'standort' => const StandortStartKarte(),
  _ => const SizedBox.shrink(),
};

/// Streifen mit dem Stand des Abgleichs (fest, keine Kachel).
class _SyncLeiste extends ConsumerWidget {
  const _SyncLeiste();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sync = ref.watch(syncProvider);
    final verbunden = sync.status == SyncStatus.synchron;
    final (statusText, farbe) = syncAnzeige(sync);
    return Container(
      constraints: const BoxConstraints(minHeight: 44),
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: farbe.withValues(alpha: 0.08),
        border: Border.all(color: farbe.withValues(alpha: 0.4)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(verbunden || sync.status == SyncStatus.laeuft ? Icons.sync : Icons.cloud_off, size: 16, color: farbe),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              statusText,
              style: TextStyle(fontFamily: kFontMono, fontSize: 12, color: farbe),
            ),
          ),
          Text(
            sync.letzterAbgleich == null ? '' : DateFormat('HH:mm').format(sync.letzterAbgleich!),
            style: const TextStyle(fontFamily: kFontMono, fontSize: 12, color: kTextMuted),
          ),
        ],
      ),
    );
  }
}

/// Kachel "Schnellzugriff": vier Knöpfe in einer Reihe.
class _SchnellzugriffReihe extends StatelessWidget {
  const _SchnellzugriffReihe();

  @override
  Widget build(BuildContext context) => GridView(
    // feste Höhe statt Seitenverhältnis: wächst nicht mit der Breite und bleibt bei großer Schrift bedienbar
    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 4, mainAxisSpacing: 10, crossAxisSpacing: 10, mainAxisExtent: 96),
    shrinkWrap: true,
    physics: const NeverScrollableScrollPhysics(),
    children: const [
      _Schnellzugriff('Termin', Icons.calendar_today_outlined, zumTerminEditor: true),
      _Schnellzugriff('Eintrag', Icons.checklist_outlined, zumListenTab: true),
      _Schnellzugriff('Foto', Icons.image_outlined),
      _Schnellzugriff('Datei', Icons.upload_outlined),
    ],
  );
}

class _Schnellzugriff extends ConsumerWidget {
  final String label;
  final IconData icon;
  final bool zumListenTab;
  final bool zumTerminEditor;
  const _Schnellzugriff(this.label, this.icon, {this.zumListenTab = false, this.zumTerminEditor = false});

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
          } else {
            zeigePhase1Hinweis(context);
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
                const Expanded(child: MonoLabel('// einkaufsliste')),
                if (einkauf != null) Text('${offen.length} offen', style: const TextStyle(fontFamily: kFontMono, fontSize: 11, color: kTextMuted)),
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
              if (offen.length > 4) Text('+ ${offen.length - 4} weitere', style: const TextStyle(fontFamily: kFontMono, fontSize: 11, color: kTextMuted)),
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
            const MonoLabel('// aufgaben'),
            const SizedBox(height: 12),
            if (zeigen.isEmpty)
              Text(alle.any((a) => a.erledigtAt == null) ? 'Nichts fällig' : 'Keine offenen Aufgaben', style: const TextStyle(color: kTextMuted))
            else
              for (final a in zeigen) AufgabeKurzzeile(aufgabe: a, mitglieder: mitglieder, jetzt: jetzt),
            if (faellig.length > zeigen.length) Text('+ ${faellig.length - zeigen.length} weitere', style: const TextStyle(fontFamily: kFontMono, fontSize: 11, color: kTextMuted)),
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
            const MonoLabel('// als nächstes'),
            const SizedBox(height: 12),
            if (zeigen.isEmpty)
              const Text('Keine anstehenden Termine', style: TextStyle(color: kTextMuted))
            else
              for (final v in zeigen) AnstehenderTermin(v: v, mitglieder: mitglieder, heute: heute),
            if (kommende.length > zeigen.length) Text('+ ${kommende.length - zeigen.length} weitere', style: const TextStyle(fontFamily: kFontMono, fontSize: 11, color: kTextMuted)),
          ],
        ),
      ),
    );
  }
}
