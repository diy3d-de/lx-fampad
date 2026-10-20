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
import '../../data/sync_state.dart';
import '../../ui/widgets.dart';
import '../../widgets/kopfzeile.dart';
import '../../widgets/sync_anzeige.dart';
import '../calendar/calendar_anzeige.dart';
import '../calendar/calendar_state.dart';
import '../calendar/termin_editor.dart';
import '../shell/shell_tab.dart';
import '../standort/standort_start_karte.dart';
import '../update/update_banner.dart';

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

/// Start: Begrüßung, Sync-Status, Schnellzugriffe, Einkaufsliste (echte Daten), "Als Nächstes".
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sync = ref.watch(syncProvider);
    final name = ref.watch(authProvider.select((s) => s.user?.displayName));
    final verbunden = sync.status == SyncStatus.synchron;
    final (statusText, farbe) = syncAnzeige(sync);
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
      children: [
        TabKopfzeile(title: begruessung(name)),
        const SizedBox(height: 20),
        const UpdateAnzeige(),
        Container(
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
        ),
        const SizedBox(height: 20),
        GridView(
          // feste Höhe statt Seitenverhältnis: wächst nicht mit der Breite und bleibt bei großer Schrift bedienbar
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 4,
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            mainAxisExtent: 96,
          ),
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          children: const [
            _Schnellzugriff('Termin', Icons.calendar_today_outlined, zumTerminEditor: true),
            _Schnellzugriff('Eintrag', Icons.checklist_outlined, zumListenTab: true),
            _Schnellzugriff('Foto', Icons.image_outlined),
            _Schnellzugriff('Datei', Icons.upload_outlined),
          ],
        ),
        const SizedBox(height: 20),
        const _EinkaufKarte(),
        const SizedBox(height: 20),
        const _NaechsteKarte(),
        const SizedBox(height: 20),
        const StandortStartKarte(),
      ],
    );
  }
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
