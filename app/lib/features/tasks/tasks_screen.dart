import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/api/models.dart';
import '../../data/app_database.dart';
import '../../data/auth/auth_state.dart';
import '../../data/lists/members.dart';
import '../../data/sync_state.dart';
import '../../data/tasks/aufgabe_logik.dart';
import '../../data/tasks/aufgabe_repository.dart';
import '../../ui/widgets.dart';
import '../../widgets/benutzer_avatar.dart';
import '../../widgets/kopfzeile.dart';
import '../../widgets/sync_hinweise.dart';
import '../calendar/calendar_anzeige.dart' show minutenTaktProvider;
import '../lists/list_dialogs.dart' show AuswahlKnopf, bestaetigen;
import 'aufgabe_editor.dart';
import 'aufgaben_anzeige.dart';
import 'tasks_state.dart';

/// Aufgaben (To-dos): schnell anlegen, abhaken, filtern, sortieren; Tippen öffnet den Editor. Alles wirkt sofort auf die lokale
/// Datenbank; der Abgleich mit dem Server läuft im Hintergrund (data/sync/).
class TasksScreen extends ConsumerStatefulWidget {
  const TasksScreen({super.key});

  @override
  ConsumerState<TasksScreen> createState() => _TasksScreenState();
}

class _TasksScreenState extends ConsumerState<TasksScreen> {
  final _neu = TextEditingController();
  final _fokus = FocusNode();

  @override
  void dispose() {
    _neu.dispose();
    _fokus.dispose();
    super.dispose();
  }

  AufgabeRepository get _repo => ref.read(aufgabeRepositoryProvider);

  Future<void> _hinzufuegen() async {
    final text = _neu.text.trim();
    if (text.isEmpty) return;
    _neu.clear();
    final ansicht = ref.read(aufgabenAnsichtProvider);
    final ich = ref.read(authProvider).user?.id;
    // in der Ansicht "Meine" bzw. einer Person: gleich dieser Person zuweisen, sonst wäre die neue Aufgabe sofort weggefiltert
    final zu = ansicht.person ?? (ansicht.filter == AufgabeFilter.meine ? ich : null);
    await _repo.schnellAnlegen(text, zustaendig: zu);
    if (mounted) _fokus.requestFocus();
  }

  Future<void> _loeschen(Aufgabe a) => _repo.loeschen(a.id);

  Future<bool> _loeschenFragen(Aufgabe a) => bestaetigen(
    context,
    titel: 'Aufgabe „${a.titel}“ löschen?',
    text: 'Die Aufgabe wird für alle gelöscht.',
    knopf: 'Löschen',
  );

  Future<void> _personWaehlen(List<UserDto> personen, String? aktuell) async {
    final wahl = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (c) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(c).height * 0.7),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
            children: [
              const Padding(padding: EdgeInsets.fromLTRB(12, 0, 12, 8), child: MonoLabel('// person')),
              ListTile(
                minTileHeight: 52,
                leading: const Icon(Icons.groups_outlined, color: kTextMuted),
                title: const Text('Alle Personen'),
                selected: aktuell == null,
                onTap: () => Navigator.of(c).pop(''),
              ),
              for (final p in personen)
                ListTile(
                  minTileHeight: 52,
                  leading: BenutzerAvatar(user: p, size: 32),
                  title: Text(p.displayName),
                  selected: p.id == aktuell,
                  onTap: () => Navigator.of(c).pop(p.id),
                ),
            ],
          ),
        ),
      ),
    );
    if (wahl == null) return;
    ref.read(aufgabenAnsichtProvider.notifier).person(wahl.isEmpty ? null : wahl);
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(authProvider.select((a) => a.user));
    final rechte = AufgabeRechte(user?.role ?? Role.child, user?.id);
    final aufgabenWert = ref.watch(aufgabenProvider);
    final daten = ref.watch(aufgabenDatenProvider);
    final ansicht = ref.watch(aufgabenAnsichtProvider);
    final jetzt = ref.watch(minutenTaktProvider).value ?? DateTime.now();
    final mitgliederListe = daten.aufgaben.isEmpty ? const <UserDto>[] : (ref.watch(mitgliederProvider).value ?? const <UserDto>[]);
    final mitglieder = Mitglieder(mitgliederListe);

    final sichtbar = sortiereAufgaben(filtereAufgaben(daten.aufgaben, filter: ansicht.filter, person: ansicht.person, ich: user?.id), ansicht.sortierung);
    final offen = daten.aufgaben.where((a) => !istErledigt(a)).length;
    final erledigt = daten.aufgaben.length - offen;
    final lesefehler = aufgabenWert.hasError && !aufgabenWert.hasValue;
    final ladend = !aufgabenWert.hasValue && !aufgabenWert.hasError;

    return RefreshIndicator(
      color: kAccent,
      backgroundColor: kSurface,
      onRefresh: () => ref.read(syncProvider.notifier).synchronisieren(manuell: true),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        children: [
          const TabKopfzeile(title: 'Aufgaben'),
          const SizedBox(height: 12),
          const SyncHinweise(),
          if (rechte.darfAnlegen) ...[
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _neu,
                    focusNode: _fokus,
                    maxLength: 200,
                    textInputAction: TextInputAction.done,
                    textCapitalization: TextCapitalization.sentences,
                    onSubmitted: (_) => _hinzufuegen(),
                    decoration: const InputDecoration(hintText: 'Neue Aufgabe', counterText: ''),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(tooltip: 'Aufgabe hinzufügen', onPressed: _hinzufuegen, icon: const Icon(Icons.add)),
                IconButton(tooltip: 'Aufgabe mit Details anlegen', onPressed: () => aufgabeEditorOeffnen(context), icon: const Icon(Icons.tune, color: kAccent)),
              ],
            ),
            const SizedBox(height: 12),
          ],
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final f in AufgabeFilter.values) AuswahlKnopf(text: f.label, gewaehlt: ansicht.filter == f, onTap: () => ref.read(aufgabenAnsichtProvider.notifier).filter(f)),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (mitgliederListe.length > 1)
                _PersonFilter(person: mitglieder[ansicht.person], aktiv: ansicht.person != null, onTap: () => _personWaehlen(mitgliederListe, ansicht.person)),
              for (final s in AufgabeSortierung.values)
                AuswahlKnopf(text: 'Nach ${s.label}', gewaehlt: ansicht.sortierung == s, onTap: () => ref.read(aufgabenAnsichtProvider.notifier).sortierung(s)),
            ],
          ),
          const SizedBox(height: 8),
          if (daten.aufgaben.isNotEmpty)
            Text('$offen offen · $erledigt erledigt', style: const TextStyle(fontFamily: kFontMono, fontSize: 11, color: kTextMuted)),
          const SizedBox(height: 8),
          if (lesefehler)
            const EmptyState(icon: Icons.error_outline, title: 'Aufgaben nicht lesbar', hint: 'Die lokale Datenbank konnte nicht gelesen werden.')
          else if (ladend)
            const Padding(padding: EdgeInsets.only(top: 32), child: Center(child: CircularProgressIndicator()))
          else if (daten.aufgaben.isEmpty)
            const EmptyState(icon: Icons.task_alt_outlined, title: 'Noch keine Aufgaben', hint: 'Schreib oben auf, was zu tun ist.')
          else if (sichtbar.isEmpty)
            EmptyState(
              icon: Icons.filter_alt_off_outlined,
              title: ansicht.filter == AufgabeFilter.erledigt ? 'Noch nichts erledigt' : 'Nichts gefunden',
              hint: switch (ansicht.filter) {
                AufgabeFilter.meine => 'Dir ist gerade nichts zugewiesen.',
                AufgabeFilter.offen => 'Es ist nichts mehr offen.',
                AufgabeFilter.erledigt => 'Erledigte Aufgaben erscheinen hier.',
                AufgabeFilter.alle => 'Für diese Person gibt es keine Aufgaben.',
              },
            )
          else
            for (final a in sichtbar)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: _Zeile(
                  key: ValueKey('aufgabe-${a.id}'),
                  aufgabe: a,
                  punkte: daten.punkteVon(a.id),
                  darf: rechte.darfAendern(a),
                  person: mitglieder[a.assigneeId],
                  jetzt: jetzt,
                  onHaken: () => _repo.erledigt(a, !istErledigt(a)),
                  onOeffnen: () => aufgabeEditorOeffnen(context, aufgabe: a),
                  onLoeschenFragen: () => _loeschenFragen(a),
                  onLoeschen: () => _loeschen(a),
                ),
              ),
        ],
      ),
    );
  }
}

class _PersonFilter extends StatelessWidget {
  final UserDto? person;
  final bool aktiv;
  final VoidCallback onTap;
  const _PersonFilter({required this.person, required this.aktiv, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final text = aktiv ? (person?.displayName.split(RegExp(r'\s+')).first ?? 'Person') : 'Alle Personen';
    return Semantics(
      button: true,
      selected: aktiv,
      label: 'Person filtern, $text',
      excludeSemantics: true,
      onTap: onTap,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 44),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: aktiv ? kAccentSoft : null,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: aktiv ? kAccent.withValues(alpha: 0.4) : kBorder),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (aktiv && person != null) ...[BenutzerAvatar(user: person, size: 24), const SizedBox(width: 8)] else ...[const Icon(Icons.person_outline, size: 18, color: kTextMuted), const SizedBox(width: 6)],
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 160),
                child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14, color: aktiv ? kAccent : kTextMuted)),
              ),
              const Icon(Icons.arrow_drop_down, size: 20, color: kTextMuted),
            ],
          ),
        ),
      ),
    );
  }
}

class _Zeile extends StatelessWidget {
  final Aufgabe aufgabe;
  final List<AufgabePunkt> punkte;
  final bool darf;
  final UserDto? person;
  final DateTime jetzt;
  final VoidCallback onHaken;
  final VoidCallback onOeffnen;
  final Future<bool> Function() onLoeschenFragen;
  final VoidCallback onLoeschen;
  const _Zeile({
    super.key,
    required this.aufgabe,
    required this.punkte,
    required this.darf,
    required this.person,
    required this.jetzt,
    required this.onHaken,
    required this.onOeffnen,
    required this.onLoeschenFragen,
    required this.onLoeschen,
  });

  @override
  Widget build(BuildContext context) {
    final a = aufgabe;
    final erledigt = istErledigt(a);
    final ueberfaellig = istUeberfaellig(a, jetzt);
    final prio = AufgabePrio.von(a.prioritaet);
    final stand = punkteStand(punkte);
    final hatFaellig = a.faelligDate != null || a.faelligUtc != null;
    final wdh = AufgabeWdh.von(a.wiederholung);
    final zugewiesen = a.assigneeId != null;

    Widget meta(IconData icon, String text, Color farbe, {String? semantik}) => Semantics(
      label: semantik ?? text,
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: farbe),
          const SizedBox(width: 3),
          Flexible(child: Text(text, softWrap: true, style: TextStyle(fontFamily: kFontMono, fontSize: 11, color: farbe))),
        ],
      ),
    );

    final beschreibung = [
      a.titel,
      erledigt ? 'erledigt' : 'offen',
      if (hatFaellig) (ueberfaellig ? 'überfällig, ${faelligText(a, jetzt)}' : 'fällig ${faelligText(a, jetzt)}'),
      if (prio != AufgabePrio.keine) 'Priorität ${prio.label.toLowerCase()}',
      if (person != null) 'zuständig ${person!.displayName}',
    ].join(', ');

    final karte = Container(
      constraints: const BoxConstraints(minHeight: 56),
      decoration: BoxDecoration(
        color: erledigt ? null : kSurface.withValues(alpha: 0.7),
        border: Border.all(color: ueberfaellig ? kDanger.withValues(alpha: 0.6) : kBorder),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Semantics(
            checked: erledigt,
            enabled: darf,
            label: erledigt ? '${a.titel}, erledigt. Zum Zurücksetzen tippen' : '${a.titel}, offen. Zum Abhaken tippen',
            excludeSemantics: true,
            onTap: darf ? onHaken : null,
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: darf ? onHaken : null,
              child: SizedBox(
                width: 48,
                height: 56,
                child: Icon(erledigt ? Icons.check_box : Icons.check_box_outline_blank, color: erledigt ? kTerminal : (darf ? kTextMuted : kTextFaint)),
              ),
            ),
          ),
          Expanded(
            child: Semantics(
              button: true,
              label: beschreibung,
              hint: 'Öffnen',
              excludeSemantics: true,
              onTap: onOeffnen,
              child: InkWell(
                onTap: onOeffnen,
                child: Container(
                  constraints: const BoxConstraints(minHeight: 56),
                  alignment: Alignment.centerLeft,
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        a.titel,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 15,
                          color: erledigt ? kTextMuted : kText,
                          decoration: erledigt ? TextDecoration.lineThrough : null,
                          decorationColor: kTextMuted,
                        ),
                      ),
                      if (hatFaellig || prio != AufgabePrio.keine || stand.gesamt > 0 || wdh != AufgabeWdh.keine) ...[
                        const SizedBox(height: 3),
                        Wrap(
                          spacing: 10,
                          runSpacing: 2,
                          children: [
                            if (hatFaellig)
                              meta(
                                ueberfaellig ? Icons.warning_amber_rounded : Icons.event_outlined,
                                ueberfaellig ? 'überfällig · ${faelligText(a, jetzt)}' : faelligText(a, jetzt),
                                ueberfaellig ? kDanger : kTextMuted,
                                semantik: 'Fällig ${faelligText(a, jetzt)}',
                              ),
                            if (prio != AufgabePrio.keine) meta(Icons.flag_outlined, prio.label.toLowerCase(), prioFarbe(prio), semantik: 'Priorität ${prio.label}'),
                            if (stand.gesamt > 0) meta(Icons.checklist, '${stand.erledigt}/${stand.gesamt}', kTextMuted, semantik: '${stand.erledigt} von ${stand.gesamt} Unteraufgaben erledigt'),
                            if (wdh != AufgabeWdh.keine) meta(Icons.repeat, wdh.label.toLowerCase(), kTextMuted),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (zugewiesen)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Tooltip(message: 'Zuständig: ${person?.displayName ?? 'unbekannt'}', child: BenutzerAvatar(user: person, size: 30)),
            )
          else
            const SizedBox(width: 12),
        ],
      ),
    );

    if (!darf) return karte;
    // Wischen nach links löscht (mit Rückfrage); für Tastatur und Screenreader steht "Löschen" als Aktion bereit und im Editor als Knopf
    return Semantics(
      customSemanticsActions: {
        const CustomSemanticsAction(label: 'Löschen'): () async {
          if (await onLoeschenFragen()) onLoeschen();
        },
      },
      child: Dismissible(
        key: ValueKey('wischen-${a.id}'),
        direction: DismissDirection.endToStart,
        confirmDismiss: (_) => onLoeschenFragen(),
        onDismissed: (_) => onLoeschen(),
        background: Container(
          alignment: Alignment.centerRight,
          padding: const EdgeInsets.only(right: 20),
          decoration: BoxDecoration(color: kDanger.withValues(alpha: 0.25), borderRadius: BorderRadius.circular(12)),
          child: const Icon(Icons.delete_outline, color: kDanger),
        ),
        child: karte,
      ),
    );
  }
}
