// Startseite im Desktop-Layout: Kopfzeile (Datum, Begrüßung, Suche, Benachrichtigungen, "+ Neu") und Karten-Raster.
// Echte Daten gibt es für Termine, Einkaufsliste, Familie und Sync-Zustand; noch nicht gebaute Bereiche zeigen einen Leerzustand.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../constants.dart';
import '../../data/app_database.dart';
import '../../data/auth/auth_state.dart';
import '../../data/chat/chat_repository.dart';
import '../../data/chat/nachrichten_inhalt.dart';
import '../../data/lists/list_repository.dart';
import '../../data/lists/list_rights.dart';
import '../../data/lists/members.dart';
import '../../data/api/api_error.dart';
import '../../data/api/models.dart';
import '../../ui/widgets.dart';
import '../../data/calendar/termin_repository.dart';
import '../calendar/calendar_anzeige.dart';
import '../calendar/calendar_state.dart';
import '../chat/chat_anzeige.dart';
import '../lists/list_dialogs.dart';
import '../shell/shell_tab.dart';
import '../update/update_banner.dart';
import 'home_screen.dart';

/// "Guten Morgen/Tag/Abend, Vorname" (bei leerem Namen nur die Tageszeit-Begrüßung).
String tagesgruss(String? anzeigename, DateTime jetzt) {
  final gruss = jetzt.hour < 11 ? 'Guten Morgen' : (jetzt.hour < 18 ? 'Guten Tag' : 'Guten Abend');
  final v = vorname(anzeigename);
  return v == null ? gruss : '$gruss, $v';
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
    // alles Nötige vor dem await lesen: danach kann das Widget schon weg sein
    final u = ref.read(authProvider).user;
    final repo = ref.read(listenRepositoryProvider);
    final gewaehlt = ref.read(gewaehlteListeProvider.notifier);
    final tab = ref.read(shellTabProvider.notifier);
    final messenger = ScaffoldMessenger.of(context);
    final a = await neueListeDialog(context, ListenRechte(u?.role ?? Role.guest, u?.id));
    if (a == null || !context.mounted) return;
    try {
      final id = await repo.listeAnlegen(name: a.name, art: a.art, sicht: a.sicht);
      gewaehlt.waehlen(id);
      tab.waehlen(kListenTab);
    } on ApiException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } catch (_) {
      messenger.showSnackBar(const SnackBar(content: Text('Die Liste konnte nicht angelegt werden.')));
    }
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
            _TermineKarte(),
            _ChatKarte(),
            _EinkaufKarte(),
            _BaldKarte(label: '// zuletzt geteilt', icon: Icons.folder_outlined, titel: 'Noch keine Dateien', hinweis: 'Dateien kommen in einer späteren Phase.', tab: 3),
            _BaldKarte(label: '// aufgaben', icon: Icons.task_alt_outlined, titel: 'Noch keine Aufgaben', hinweis: 'Aufgaben kommen in einer späteren Phase.'),
            _FamilieKarte(),
          ],
        );
      },
    );
  }
}

/// "Heute & morgen" mit echten Terminen (lokale Datenbank, auch offline); Tippen öffnet den Kalender.
class _TermineKarte extends ConsumerWidget {
  const _TermineKarte();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final daten = ref.watch(kalenderDatenProvider);
    final mitglieder = mitgliederFuer(ref, daten);
    final jetzt = ref.watch(minutenTaktProvider).value ?? DateTime.now();
    final heute = heuteTag(jetzt);
    final morgenEnde = heute.add(const Duration(days: 2));
    // heute und morgen: Vorkommen, die vor dem Ende von morgen beginnen
    final liste = [for (final v in anstehende(daten, jetzt, tage: 2)) if (v.startWand.isBefore(morgenEnde)) v];
    return _Karte(
      label: '// heute & morgen',
      zaehler: liste.isEmpty ? null : '${liste.length}',
      semantik: liste.isEmpty ? 'Heute und morgen: keine Termine. Kalender öffnen' : 'Heute und morgen: ${liste.length} Termine. Kalender öffnen',
      onTap: () => ref.read(shellTabProvider.notifier).waehlen(kKalenderTab),
      child: liste.isEmpty
          ? const EmptyState(icon: Icons.event_available_outlined, title: 'Keine Termine', hint: 'Heute und morgen steht nichts an.')
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [for (final v in liste) AnstehenderTermin(v: v, mitglieder: mitglieder, heute: heute)],
            ),
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
    focusable: onTap != null,
    onTap: onTap,
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
          // Überstand wird nicht abgeschnitten, sondern scrollt innerhalb der Karte
          Expanded(
            child: LayoutBuilder(
              builder: (context, c) => SingleChildScrollView(
                child: ConstrainedBox(constraints: BoxConstraints(minHeight: c.maxHeight), child: child),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

/// Letzte Chats mit den neuesten Nachrichten (lokale Datenbank, auch offline); es erscheinen nur Chats, die die Person sehen darf
/// (der Server liefert nichts anderes). Tippen öffnet den Chat-Bereich.
class _ChatKarte extends ConsumerWidget {
  const _ChatKarte();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(chatUebersichtProvider);
    final mitglieder = chatMitglieder(ref, async.value ?? const <ChatEintrag>[]);
    final ich = ref.watch(authProvider.select((s) => s.user?.id));
    final inhalt = ref.watch(nachrichtenInhaltProvider);
    final fehler = async.hasError;
    final laedt = !fehler && !async.hasValue;
    final mitNachricht = [for (final e in async.value ?? const <ChatEintrag>[]) if (e.letzte != null) e]..sort((a, b) => b.aktivitaet.compareTo(a.aktivitaet));
    final ungelesen = mitNachricht.fold<int>(0, (s, e) => s + e.ungelesen);
    return _Karte(
      label: '// chat · familie',
      zaehler: ungelesen > 0 ? '$ungelesen neu' : null,
      semantik: fehler
          ? 'Chat, nicht geladen. Öffnen'
          : laedt
          ? 'Chat, lädt. Öffnen'
          : mitNachricht.isEmpty
          ? 'Chat, noch keine Nachrichten. Öffnen'
          : 'Chat, $ungelesen ungelesen. Öffnen',
      onTap: () => ref.read(shellTabProvider.notifier).waehlen(kChatTab),
      child: fehler
          ? _fehler('Der Chat konnte nicht geladen werden.')
          : laedt
          ? _laedt()
          : mitNachricht.isEmpty
          ? const EmptyState(icon: Icons.chat_bubble_outline, title: 'Noch keine Nachrichten', hint: 'Schreib die erste Nachricht an die Familie.')
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final e in mitNachricht.take(4))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Row(
                      children: [
                        ChatAvatar(
                          art: e.art,
                          person: e.art == ChatArt.direct ? mitglieder[e.teilnehmer.where((t) => t != ich).firstOrNull] : null,
                          name: chatName(e.konversation, e.teilnehmer, mitglieder, ich, inhalt),
                          size: 32,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(chatName(e.konversation, e.teilnehmer, mitglieder, ich, inhalt), maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: e.ungelesen > 0 ? FontWeight.w800 : FontWeight.w600)),
                              Text(chatVorschau(e, mitglieder, ich, inhalt), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, color: kTextMuted)),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(zeitKurz(e.letzte!.createdAt), style: const TextStyle(fontFamily: kFontMono, fontSize: 11, color: kTextMuted)),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }
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

/// Kartenkörper für Laden und Fehler (kein falscher Leerzustand, solange Daten fehlen).
Widget _laedt() => const Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)));
Widget _fehler(String text) => Text(text, style: const TextStyle(color: kDanger));

/// Einkaufsliste mit echten Daten: offene Einträge der ersten Einkaufsliste (lokale Datenbank, auch offline).
class _EinkaufKarte extends ConsumerWidget {
  const _EinkaufKarte();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final u = ref.watch(authProvider.select((s) => s.user));
    final darfAnlegen = ListenRechte(u?.role ?? Role.guest, u?.id).darfListeAnlegen;
    final listenAsync = ref.watch(listenProvider);
    final eintraegeAsync = ref.watch(alleEintraegeProvider);
    final fehler = listenAsync.hasError || eintraegeAsync.hasError;
    final laedt = !fehler && (!listenAsync.hasValue || !eintraegeAsync.hasValue);
    final listen = listenAsync.value ?? const <Liste>[];
    final alle = eintraegeAsync.value ?? const <Listeneintrag>[];
    final einkauf = listen.where((l) => l.kind == 'shopping').firstOrNull;
    final offen = einkauf == null ? <Listeneintrag>[] : sortiereEintraege(alle.where((e) => e.listId == einkauf.id && e.doneAt == null).toList());
    final erledigt = einkauf == null ? 0 : alle.where((e) => e.listId == einkauf.id && e.doneAt != null).length;
    return _Karte(
      label: '// einkaufsliste',
      zaehler: !fehler && !laedt && einkauf != null ? '${offen.length} offen' : null,
      semantik: fehler
          ? 'Einkaufsliste, nicht geladen. Öffnen'
          : laedt
          ? 'Einkaufsliste, lädt. Öffnen'
          : einkauf == null
          ? 'Einkaufsliste, noch keine Liste. Öffnen'
          : 'Einkaufsliste, ${offen.length} offen. Öffnen',
      onTap: () {
        if (einkauf != null) ref.read(gewaehlteListeProvider.notifier).waehlen(einkauf.id);
        ref.read(shellTabProvider.notifier).waehlen(kListenTab);
      },
      child: fehler
          ? _fehler('Die Einkaufsliste konnte nicht geladen werden.')
          : laedt
          ? _laedt()
          : einkauf == null
          ? Text(darfAnlegen ? 'Noch keine Einkaufsliste – klicken zum Anlegen' : 'Noch keine Einkaufsliste', style: const TextStyle(color: kTextMuted))
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
    final async = ref.watch(mitgliederProvider);
    final mitglieder = async.value ?? const <UserDto>[];
    final bereit = async.hasValue;
    return _Karte(
      label: '// familie & orte',
      zaehler: bereit && mitglieder.isNotEmpty ? '${mitglieder.length}' : null,
      semantik: bereit ? 'Familie, ${mitglieder.length} Mitglieder. Standort kommt später' : 'Familie. Standort kommt später',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (async.hasError)
            _fehler('Die Mitglieder konnten nicht geladen werden.')
          else if (!bereit)
            SizedBox(height: 120, child: _laedt())
          else if (mitglieder.isEmpty)
            const Text('Keine Mitglieder geladen', style: TextStyle(color: kTextMuted))
          else ...[
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
            if (mitglieder.length > 5) Text('+ ${mitglieder.length - 5} weitere', style: const TextStyle(fontFamily: kFontMono, fontSize: 11, color: kTextMuted)),
          ],
          const SizedBox(height: 8),
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
