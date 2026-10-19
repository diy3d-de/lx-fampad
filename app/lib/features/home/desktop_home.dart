// Startseite im Desktop-Layout: Kopfzeile (Datum, Begrüßung, Suche, Benachrichtigungen, "+ Neu") und Karten-Raster.
// Echte Daten gibt es für Einkaufsliste, Familie und Sync-Zustand; noch nicht gebaute Bereiche zeigen einen Leerzustand.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../constants.dart';
import '../../data/app_database.dart';
import '../../data/auth/auth_state.dart';
import '../../data/lists/list_repository.dart';
import '../../data/lists/list_rights.dart';
import '../../data/lists/members.dart';
import '../../data/api/models.dart';
import '../../ui/widgets.dart';
import '../lists/list_dialogs.dart';
import '../shell/shell_tab.dart';
import '../update/update_banner.dart';
import 'home_screen.dart';

/// "Guten Morgen/Tag/Abend, Vorname" (bei leerem Namen nur die Tageszeit-Begrüßung).
String tagesgruss(String? anzeigename, DateTime jetzt) {
  final gruss = jetzt.hour < 11 ? 'Guten Morgen' : (jetzt.hour < 18 ? 'Guten Tag' : 'Guten Abend');
  final b = begruessung(anzeigename); // "Hallo" oder "Hallo, Vorname"
  return b.length > 5 ? '$gruss${b.substring(5)}' : gruss;
}

class DesktopHome extends ConsumerWidget {
  const DesktopHome({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final name = ref.watch(authProvider.select((s) => s.user?.displayName));
    final jetzt = DateTime.now();
    final heute = DateFormat('E, d. MMM', 'de_DE').format(jetzt).toLowerCase();
    return ListView(
      padding: const EdgeInsets.fromLTRB(32, 24, 32, 24),
      children: [
        _Kopfzeile(label: '// $heute', gruss: tagesgruss(name, jetzt)),
        const SizedBox(height: 24),
        const UpdateAnzeige(),
        const _Raster(),
      ],
    );
  }
}

class _Kopfzeile extends ConsumerWidget {
  final String label;
  final String gruss;
  const _Kopfzeile({required this.label, required this.gruss});

  Future<void> _neueListe(BuildContext context, WidgetRef ref) async {
    final u = ref.read(authProvider).user;
    final a = await neueListeDialog(context, ListenRechte(u?.role ?? Role.guest, u?.id));
    if (a == null) return;
    final id = await ref.read(listenRepositoryProvider).listeAnlegen(name: a.name, art: a.art, sicht: a.sicht);
    ref.read(gewaehlteListeProvider.notifier).waehlen(id);
    ref.read(shellTabProvider.notifier).waehlen(kListenTab);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rolle = ref.watch(authProvider.select((s) => s.user?.role)) ?? Role.guest;
    return Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 16,
      runSpacing: 12,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            MonoLabel(label),
            const SizedBox(height: 4),
            Semantics(
              header: true,
              child: Text(gruss, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800, letterSpacing: -0.7, color: kTextStrong)),
            ),
          ],
        ),
        Wrap(
          spacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Tooltip(
              message: 'Die Suche kommt in einer späteren Phase',
              child: Semantics(
                label: 'Suche, noch nicht verfügbar',
                excludeSemantics: true,
                child: const SizedBox(
                  width: 240,
                  height: 44,
                  child: TextField(
                    enabled: false,
                    decoration: InputDecoration(hintText: 'Suchen …', prefixIcon: Icon(Icons.search, size: 20), isDense: true),
                  ),
                ),
              ),
            ),
            IconButton(
              tooltip: 'Benachrichtigungen',
              constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
              icon: const Icon(Icons.notifications_none),
              onPressed: () => ScaffoldMessenger.of(context)
                ..hideCurrentSnackBar()
                ..showSnackBar(const SnackBar(content: Text('Benachrichtigungen kommen mit Push in einer späteren Phase'))),
            ),
            if (rolle != Role.guest)
              PopupMenuButton<String>(
                tooltip: 'Neu anlegen',
                color: kSurface,
                onSelected: (_) => _neueListe(context, ref),
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'liste', height: 44, child: Row(children: [Icon(Icons.checklist_outlined, size: 18, color: kAccent), SizedBox(width: 10), Text('Neue Liste')])),
                ],
                child: Container(
                  constraints: const BoxConstraints(minHeight: 44),
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  decoration: BoxDecoration(color: kAccent, borderRadius: BorderRadius.circular(12)),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.add, size: 18, color: kOnAccent),
                      SizedBox(width: 6),
                      Text('Neu', style: TextStyle(fontWeight: FontWeight.w700, color: kOnAccent)),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// Karten-Raster: 3 Spalten ab ca. 840 px Inhaltsbreite, sonst 2 bzw. 1; Kartenhöhe wächst mit der Textskalierung.
class _Raster extends StatelessWidget {
  const _Raster();

  @override
  Widget build(BuildContext context) {
    final skala = MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 2.0);
    return LayoutBuilder(
      builder: (context, c) {
        final spalten = c.maxWidth >= 840 ? 3 : (c.maxWidth >= 520 ? 2 : 1);
        return GridView(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: spalten, mainAxisSpacing: 16, crossAxisSpacing: 16, mainAxisExtent: 300 * skala),
          children: const [
            _BaldKarte(label: '// heute & morgen', icon: Icons.calendar_month_outlined, titel: 'Noch keine Termine', hinweis: 'Der Kalender kommt in Phase 1c-2.', tab: 1),
            _BaldKarte(label: '// chat · familie', icon: Icons.chat_bubble_outline, titel: 'Noch keine Nachrichten', hinweis: 'Der Chat kommt in einer der nächsten Phasen von Phase 1.', tab: 2),
            _EinkaufKarte(),
            _BaldKarte(label: '// zuletzt geteilt', icon: Icons.folder_outlined, titel: 'Noch keine Dateien', hinweis: 'Dateien kommen in einer der nächsten Phasen von Phase 1.', tab: 3),
            _BaldKarte(label: '// aufgaben', icon: Icons.task_alt_outlined, titel: 'Noch keine Aufgaben', hinweis: 'Aufgaben kommen in einer der nächsten Phasen von Phase 1.'),
            _FamilieKarte(),
          ],
        );
      },
    );
  }
}

/// Rahmen einer Karte: Mono-Label, optionaler Zähler rechts, Inhalt füllt den Rest (überstehender Inhalt wird abgeschnitten).
class _Karte extends StatelessWidget {
  final String label;
  final String? zaehler;
  final String semantik;
  final VoidCallback? onTap;
  final Widget child;
  const _Karte({required this.label, required this.semantik, required this.child, this.zaehler, this.onTap});

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    button: onTap != null,
    label: semantik,
    excludeSemantics: onTap != null,
    child: LxCard(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: MonoLabel(label)),
              if (zaehler != null) Text(zaehler!, style: const TextStyle(fontFamily: kFontMono, fontSize: 11, color: kTextMuted)),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(child: ClipRect(child: child)),
        ],
      ),
    ),
  );
}

/// Karte für einen Bereich, den es noch nicht gibt: sauberer Leerzustand statt erfundener Daten.
class _BaldKarte extends ConsumerWidget {
  final String label;
  final IconData icon;
  final String titel;
  final String hinweis;
  final int? tab;
  const _BaldKarte({required this.label, required this.icon, required this.titel, required this.hinweis, this.tab});

  @override
  Widget build(BuildContext context, WidgetRef ref) => _Karte(
    label: label,
    semantik: '${label.substring(3)}. $titel. $hinweis',
    onTap: tab == null ? null : () => ref.read(shellTabProvider.notifier).waehlen(tab!),
    child: EmptyState(icon: icon, title: titel, hint: hinweis),
  );
}

/// Einkaufsliste mit echten Daten: offene Einträge der ersten Einkaufsliste (lokale Datenbank, auch offline).
class _EinkaufKarte extends ConsumerWidget {
  const _EinkaufKarte();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final listen = ref.watch(listenProvider).value ?? const <Liste>[];
    final alle = ref.watch(alleEintraegeProvider).value ?? const <Listeneintrag>[];
    final einkauf = listen.where((l) => l.kind == 'shopping').firstOrNull;
    final offen = einkauf == null ? <Listeneintrag>[] : sortiereEintraege(alle.where((e) => e.listId == einkauf.id && e.doneAt == null).toList());
    final erledigt = einkauf == null ? 0 : alle.where((e) => e.listId == einkauf.id && e.doneAt != null).length;
    return _Karte(
      label: '// einkaufsliste',
      zaehler: einkauf == null ? null : '${offen.length} offen',
      semantik: einkauf == null ? 'Einkaufsliste, noch keine Liste. Öffnen' : 'Einkaufsliste, ${offen.length} offen. Öffnen',
      onTap: () {
        if (einkauf != null) ref.read(gewaehlteListeProvider.notifier).waehlen(einkauf.id);
        ref.read(shellTabProvider.notifier).waehlen(kListenTab);
      },
      child: einkauf == null
          ? const Text('Noch keine Einkaufsliste – klicken zum Anlegen', style: TextStyle(color: kTextMuted))
          : offen.isEmpty
          ? Text(erledigt == 0 ? 'Nichts auf der Liste' : 'Alles erledigt', style: const TextStyle(color: kTextMuted))
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final e in offen.take(6))
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
                if (offen.length > 6) Text('+ ${offen.length - 6} weitere', style: const TextStyle(fontFamily: kFontMono, fontSize: 11, color: kTextMuted)),
              ],
            ),
    );
  }
}

/// Familienmitglieder (echt, mit Personenfarbe); der Standort kommt erst in Phase 2.
class _FamilieKarte extends ConsumerWidget {
  const _FamilieKarte();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mitglieder = ref.watch(mitgliederProvider).value ?? const <UserDto>[];
    return _Karte(
      label: '// familie & orte',
      zaehler: mitglieder.isEmpty ? null : '${mitglieder.length}',
      semantik: 'Familie, ${mitglieder.length} Mitglieder. Standort kommt später',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: mitglieder.isEmpty
                ? const Text('Keine Mitglieder geladen', style: TextStyle(color: kTextMuted))
                : ListView(
                    physics: const NeverScrollableScrollPhysics(),
                    children: [
                      for (final u in mitglieder.take(5))
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Row(
                            children: [
                              PersonAvatar(name: u.displayName, colorIndex: u.colorIndex, size: 32),
                              const SizedBox(width: 10),
                              Expanded(child: Text(u.displayName, maxLines: 1, overflow: TextOverflow.ellipsis)),
                              Text(u.role.label.toLowerCase(), style: const TextStyle(fontFamily: kFontMono, fontSize: 11, color: kTextMuted)),
                            ],
                          ),
                        ),
                    ],
                  ),
          ),
          const Row(
            children: [
              Icon(Icons.place_outlined, size: 16, color: kTextFaint),
              SizedBox(width: 6),
              Expanded(child: Text('Standort teilen: kommt in Phase 2', style: TextStyle(fontFamily: kFontMono, fontSize: 11, color: kTextFaint))),
            ],
          ),
        ],
      ),
    );
  }
}
