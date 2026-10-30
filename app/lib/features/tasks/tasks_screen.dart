import 'dart:async';

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
import '../../widgets/liste_detail.dart';
import '../../widgets/rueckgaengig.dart';
import '../../widgets/sync_hinweise.dart';
import '../calendar/calendar_anzeige.dart' show minutenTaktProvider;
import '../lists/list_dialogs.dart' show bestaetigen;
import 'aufgabe_editor.dart';
import '../../data/tasks/fristen_logik.dart';
import 'aufgaben_anzeige.dart';
import 'aufgaben_filter_blatt.dart';
import 'frist_editor.dart';
import 'fristen_anzeige.dart';
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
  final _weg = <String>{}; // weggewischte Aufgaben: sofort ausgeblendet

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _oeffnenPruefen());
  }

  /// Tippen auf eine Aufgaben-Erinnerung: öffnet den Editor der Aufgabe, sobald die Daten geladen sind (unbekannte ID: nur der Tab).
  void _oeffnenPruefen() {
    if (!mounted) return;
    final id = ref.read(aufgabeOeffnenProvider);
    if (id == null || !ref.read(aufgabenProvider).hasValue) return;
    ref.read(aufgabeOeffnenProvider.notifier).setzen(null);
    final a = ref.read(aufgabenDatenProvider).aufgabe(id);
    if (a != null) unawaited(aufgabeEditorOeffnen(_ctx, aufgabe: a));
  }

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
    // in der Ansicht "Erledigt" wäre die neue (offene) Aufgabe unsichtbar: zurück zu "Offen"
    if (ansicht.filter == AufgabeFilter.erledigt) ref.read(aufgabenAnsichtProvider.notifier).filter(AufgabeFilter.offen);
    await _repo.schnellAnlegen(text, zustaendig: zu);
    if (mounted) _fokus.requestFocus();
  }

  Future<void> _loeschen(Aufgabe a) async {
    final punkte = ref.read(aufgabenDatenProvider).punkteVon(a.id);
    // Repository und Person VOR dem Hinweis holen: die Handlung darf nach dem Abmelden nichts mehr über `ref` des Bildschirms lesen
    final repo = _repo;
    final ich = ref.read(authProvider).user?.id;
    await repo.loeschen(a.id);
    // Rückgängig legt die offene Aufgabe mit neuer ID wieder an (der Server behält die gelöschte als Tombstone)
    if (!mounted || istErledigt(a)) return;
    rueckgaengigZeigen(context, text: 'Aufgabe gelöscht', rueckgaengig: () async => repo.wiederherstellen(a, punkte, besitzer: ich));
  }

  Future<void> _haken(Aufgabe a) async {
    final warErledigt = istErledigt(a);
    final repo = _repo;
    final ich = ref.read(authProvider).user?.id;
    // Hinweis nur, wenn dieser Tipp wirklich etwas geändert hat (ein Doppeltipp ändert beim zweiten Mal nichts)
    final geaendert = await repo.erledigt(a, !warErledigt);
    if (!mounted || warErledigt || !geaendert) return;
    rueckgaengigZeigen(context, text: 'Aufgabe erledigt', rueckgaengig: () => repo.erledigtZuruecknehmen(a, besitzer: ich));
  }

  Future<bool> _loeschenFragen(Aufgabe a) => bestaetigen(
    context,
    titel: 'Aufgabe „${a.titel}“ löschen?',
    text: 'Die Aufgabe wird für alle gelöscht.',
    knopf: 'Löschen',
  );

  Future<void> _erledigteLoeschen(List<Aufgabe> erledigte) async {
    final ja = await bestaetigen(
      context,
      titel: erledigte.length == 1 ? 'Erledigte Aufgabe löschen?' : '${erledigte.length} erledigte Aufgaben löschen?',
      text: 'Sie werden für alle gelöscht.',
      knopf: 'Löschen',
    );
    if (ja) await _repo.erledigteLoeschen(erledigte);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(aufgabeOeffnenProvider, (_, _) => _oeffnenPruefen());
    ref.listen(aufgabenProvider, (_, _) => _oeffnenPruefen());
    final user = ref.watch(authProvider.select((a) => a.user));
    final rechte = AufgabeRechte(user?.role ?? Role.child, user?.id);
    final aufgabenWert = ref.watch(aufgabenProvider);
    final daten = ref.watch(aufgabenDatenProvider);
    final ansicht = ref.watch(aufgabenAnsichtProvider);
    // der Minutentakt baut die Liste nur neu, wenn sich etwas ändert: der Tag wechselt oder eine Aufgabe wird überfällig
    ref.watch(
      minutenTaktProvider.select((v) {
        final t = v.value ?? DateTime.now();
        return '${tagVon(t).toIso8601String()}|${[for (final a in daten.aufgaben) if (istUeberfaellig(a, t)) a.id].join(',')}';
      }),
    );
    final jetzt = DateTime.now();
    final mitgliederListe = daten.aufgaben.isEmpty ? const <UserDto>[] : (ref.watch(mitgliederProvider).value ?? const <UserDto>[]);
    final mitglieder = Mitglieder(mitgliederListe);

    final notifier = ref.read(aufgabenAnsichtProvider.notifier);
    final aktiv = aktiveAufgabenFilter(ansicht);
    final fristenAnsicht = ansicht.filter == AufgabeFilter.fristen;
    final gefiltert = filtereAufgaben(daten.aufgaben, filter: ansicht.filter, person: ansicht.person, ich: user?.id);
    final sichtbar = [
      for (final a in fristenAnsicht ? offeneFristen(gefiltert) : sortiereAufgaben(gefiltert, ansicht.sortierung))
        if (!_weg.contains(a.id)) a, // gerade weggewischt: sofort weg, auch wenn die Datenbank noch nachzieht
    ];
    final offen = daten.aufgaben.where((a) => !istErledigt(a)).length;
    final erledigt = daten.aufgaben.length - offen;
    final lesefehler = aufgabenWert.hasError && !aufgabenWert.hasValue;
    final ladend = !aufgabenWert.hasValue && !aufgabenWert.hasError;
    final loeschbar = ansicht.filter == AufgabeFilter.erledigt ? [for (final a in sichtbar) if (rechte.darfAendern(a)) a] : const <Aufgabe>[];

    final kopf = <Widget>[
      const TabKopfzeile(title: 'Aufgaben'),
      const SizedBox(height: 12),
      const SyncHinweise(),
      Row(
        children: [
          Expanded(
            child: Wrap(
              spacing: 12,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (daten.aufgaben.isNotEmpty) Text('$offen offen · $erledigt erledigt', style: const TextStyle(fontFamily: kFontSans, fontFeatures: kZiffern, fontSize: 13, color: kTextMuted)),
                if (rechte.darfAnlegen && fristenAnsicht)
                  FilledButton.icon(
                    style: FilledButton.styleFrom(minimumSize: const Size(44, 48)),
                    onPressed: () => fristEditorOeffnen(_ctx),
                    icon: const Icon(Icons.add),
                    label: const Text('Neue Frist'),
                  ),
              ],
            ),
          ),
          IconButton(
            style: IconButton.styleFrom(minimumSize: const Size(48, 48), backgroundColor: aktiv > 0 ? kAccentSoft : kSurface),
            tooltip: aktiv == 0 ? 'Filter und Anzeige' : 'Filter und Anzeige, $aktiv aktiv',
            onPressed: () => aufgabenFilterBlattOeffnen(context),
            icon: Badge(
              isLabelVisible: aktiv > 0,
              label: Text('$aktiv'),
              backgroundColor: kAccent,
              textColor: kOnAccent,
              child: Icon(Icons.filter_list, color: aktiv > 0 ? kAccent : kText),
            ),
          ),
        ],
      ),
      const SizedBox(height: 8),
      if (rechte.darfAnlegen && !fristenAnsicht) ...[
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
            IconButton(tooltip: 'Aufgabe mit Details anlegen', onPressed: () => aufgabeEditorOeffnen(_ctx), icon: const Icon(Icons.tune, color: kAccent)),
          ],
        ),
        const SizedBox(height: 12),
      ],
      if (aktiv > 0)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (ansicht.filter != AufgabeFilter.offen) _FilterChip(text: 'Status: ${ansicht.filter.label}', onEntfernen: () => notifier.filter(AufgabeFilter.offen)),
              if (ansicht.person != null)
                _FilterChip(text: 'Person: ${mitglieder[ansicht.person]?.displayName.split(RegExp(r'\s+')).first ?? 'unbekannt'}', onEntfernen: () => notifier.person(null)),
              if (ansicht.sortierung != AufgabeSortierung.faelligkeit && !fristenAnsicht)
                _FilterChip(text: 'Nach ${ansicht.sortierung.label}', onEntfernen: () => notifier.sortierung(AufgabeSortierung.faelligkeit)),
              TextButton(style: TextButton.styleFrom(minimumSize: const Size(44, 44)), onPressed: notifier.zuruecksetzen, child: const Text('Zurücksetzen')),
            ],
          ),
        ),
      if (loeschbar.isNotEmpty)
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            style: TextButton.styleFrom(foregroundColor: kDanger, minimumSize: const Size(44, 44)),
            onPressed: () => _erledigteLoeschen(loeschbar),
            icon: const Icon(Icons.delete_sweep_outlined),
            label: Text(loeschbar.length == 1 ? 'Erledigte löschen' : 'Erledigte löschen (${loeschbar.length})'),
          ),
        ),
      const SizedBox(height: 8),
      if (lesefehler)
        const EmptyState(icon: Icons.error_outline, title: 'Aufgaben nicht lesbar', hint: 'Die lokale Datenbank konnte nicht gelesen werden.')
      else if (ladend)
        const LadePlatzhalter(karten: 2)
      else if (fristenAnsicht && sichtbar.isEmpty && !daten.aufgaben.any((a) => a.frist))
        EmptyState(
          icon: Icons.event_available_outlined,
          title: 'Noch keine Fristen',
          hint: 'Lege Ablaufdaten an, z. B. Reisepass, TÜV oder Versicherung.',
          knopf: rechte.darfAnlegen ? 'Frist anlegen' : null,
          onKnopf: rechte.darfAnlegen ? () => fristEditorOeffnen(_ctx) : null,
        )
      else if (daten.aufgaben.isEmpty)
        EmptyState(
          icon: Icons.task_alt_outlined,
          title: 'Noch keine Aufgaben',
          hint: 'Schreib oben auf, was zu tun ist.',
          knopf: rechte.darfAnlegen ? 'Aufgabe hinzufügen' : null,
          onKnopf: rechte.darfAnlegen ? _fokus.requestFocus : null,
        )
      else if (sichtbar.isEmpty && aktiv > 0)
        EmptyState(
          icon: Icons.filter_alt_off_outlined,
          title: 'Keine Aufgaben mit diesen Filtern',
          hint: 'Ändere die Filter oder setze sie zurück.',
          knopf: 'Filter zurücksetzen',
          onKnopf: notifier.zuruecksetzen,
        )
      else if (sichtbar.isEmpty)
        EmptyState(
          icon: Icons.task_alt_outlined,
          title: 'Alles erledigt',
          hint: 'Es ist nichts mehr offen.',
          knopf: rechte.darfAnlegen && !fristenAnsicht ? 'Aufgabe hinzufügen' : null,
          onKnopf: rechte.darfAnlegen && !fristenAnsicht ? _fokus.requestFocus : null,
        ),
    ];

    final liste = Builder(
      builder: (innen) {
        _innen = innen; // Kontext innerhalb des Zweispalters: Editoren öffnen in der rechten Spalte
        return _listeMitAktualisieren(kopf, sichtbar, daten, rechte, mitglieder, jetzt, lesefehler || ladend);
      },
    );
    return ListeDetail(
      liste: liste,
      leer: _KeinDetail(darfAnlegen: rechte.darfAnlegen),
    );
  }

  /// Der Kontext für das Öffnen von Editoren: innerhalb des Zweispalters (rechte Spalte), sonst der eigene.
  BuildContext get _ctx => (_innen != null && _innen!.mounted) ? _innen! : context;
  BuildContext? _innen;

  Widget _listeMitAktualisieren(List<Widget> kopf, List<Aufgabe> sichtbar, AufgabenDaten daten, AufgabeRechte rechte, Mitglieder mitglieder, DateTime jetzt, bool ohneZeilen) {
    return RefreshIndicator(
      color: kAccent,
      backgroundColor: kSurface,
      onRefresh: () => ref.read(syncProvider.notifier).synchronisieren(manuell: true),
      // Kopf und Zeilen in einer lazy gebauten Liste: bei vielen Aufgaben werden nur die sichtbaren Zeilen gebaut
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        itemCount: kopf.length + (ohneZeilen ? 0 : sichtbar.length),
        itemBuilder: (context, i) {
          if (i < kopf.length) return kopf[i];
          final a = sichtbar[i - kopf.length];
          return Padding(
            key: ValueKey('aufgabe-${a.id}'),
            padding: const EdgeInsets.only(bottom: 6),
            child: _Zeile(
              aufgabe: a,
              punkte: daten.punkteVon(a.id),
              darf: rechte.darfAendern(a),
              statusDarf: rechte.darfStatus(a),
              person: mitglieder[a.assigneeId],
              jetzt: jetzt,
              onHaken: () => unawaited(_haken(a)),
              gewaehlt: DetailSpalte.maybeOf(context)?.auswahl == a.id,
              onOeffnen: () => aufgabeEditorOeffnen(context, aufgabe: a),
              onLoeschenFragen: () => _loeschenFragen(a),
              onLoeschen: () {
                setState(() => _weg.add(a.id));
                unawaited(_loeschen(a));
              },
            ),
          );
        },
      ),
    );
  }
}

/// Aktiver Filter als kleine Fläche; das Kreuz entfernt ihn (Touch-Ziel 44 px).
class _FilterChip extends StatelessWidget {
  final String text;
  final VoidCallback onEntfernen;
  const _FilterChip({required this.text, required this.onEntfernen});

  @override
  Widget build(BuildContext context) => Container(
    constraints: const BoxConstraints(minHeight: 44),
    padding: const EdgeInsets.only(left: 12),
    decoration: BoxDecoration(color: kAccentSoft, borderRadius: BorderRadius.circular(12)),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(child: Text(text, softWrap: true, style: const TextStyle(fontSize: 13, color: kAccent))),
        IconButton(
          constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
          tooltip: 'Filter entfernen: $text',
          onPressed: onEntfernen,
          icon: const Icon(Icons.close, size: 16, color: kAccent),
        ),
      ],
    ),
  );
}

class _Zeile extends StatelessWidget {
  final Aufgabe aufgabe;
  final List<AufgabePunkt> punkte;
  final bool darf;
  final bool statusDarf;
  final UserDto? person;
  final DateTime jetzt;
  final VoidCallback onHaken;
  final VoidCallback onOeffnen;

  /// Das Detail dieser Aufgabe ist im Zweispalter rechts offen: hellere Fläche.
  final bool gewaehlt;
  final Future<bool> Function() onLoeschenFragen;
  final VoidCallback onLoeschen;
  const _Zeile({
    required this.aufgabe,
    required this.punkte,
    required this.darf,
    required this.statusDarf,
    required this.person,
    required this.jetzt,
    required this.onHaken,
    required this.onOeffnen,
    this.gewaehlt = false,
    required this.onLoeschenFragen,
    required this.onLoeschen,
  });

  @override
  Widget build(BuildContext context) {
    final a = aufgabe;
    final erledigt = istErledigt(a);
    final ueberfaellig = istUeberfaellig(a, jetzt);
    final ampel = fristAmpel(a, jetzt);
    final fristOffen = a.frist && !erledigt;
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
          Flexible(child: Text(text, softWrap: true, style: TextStyle(fontFamily: kFontSans, fontFeatures: kZiffern, fontSize: 11, color: farbe))),
        ],
      ),
    );

    final beschreibung = [
      a.titel,
      erledigt ? 'erledigt' : 'offen',
      if (fristOffen) 'Frist, ${fristAmpelWort(ampel)}, ${fristKurzText(a, jetzt)}' else if (hatFaellig) (ueberfaellig ? 'überfällig, ${faelligText(a, jetzt)}' : 'fällig ${faelligText(a, jetzt)}'),
      if (prio != AufgabePrio.keine) 'Priorität ${prio.label.toLowerCase()}',
      if (person != null) 'zuständig ${person!.displayName}',
    ].join(', ');

    final karte = Container(
      constraints: const BoxConstraints(minHeight: 56),
      decoration: BoxDecoration(
        color: gewaehlt ? kSurface2 : (erledigt ? null : kSurface),
        border: Border.all(color: ueberfaellig ? kDanger.withValues(alpha: 0.6) : (fristOffen && ampel == FristAmpel.bald ? kWarn.withValues(alpha: 0.6) : Colors.transparent)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Semantics(
            checked: erledigt,
            enabled: statusDarf,
            label: erledigt ? '${a.titel}, erledigt. Zum Zurücksetzen tippen' : '${a.titel}, offen. Zum Abhaken tippen',
            excludeSemantics: true,
            onTap: statusDarf ? onHaken : null,
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: statusDarf ? onHaken : null,
              child: SizedBox(
                width: 48,
                height: 56,
                child: Icon(erledigt ? Icons.check_box : Icons.check_box_outline_blank, color: erledigt ? kTerminal : (statusDarf ? kTextMuted : kTextFaint)),
              ),
            ),
          ),
          Expanded(
            child: Semantics(
              button: true,
              selected: gewaehlt,
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
                      if (hatFaellig || prio != AufgabePrio.keine || stand.gesamt > 0 || wdh != AufgabeWdh.keine || a.fristMonate != null) ...[
                        const SizedBox(height: 3),
                        Wrap(
                          spacing: 10,
                          runSpacing: 2,
                          children: [
                            if (fristOffen)
                              meta(
                                ampel == FristAmpel.ueberfaellig ? Icons.warning_amber_rounded : Icons.event_repeat_outlined,
                                fristKurzText(a, jetzt),
                                fristFarbe(ampel),
                                semantik: 'Frist ${fristAmpelWort(ampel)}, ${fristKurzText(a, jetzt)}',
                              )
                            else if (hatFaellig)
                              meta(
                                ueberfaellig ? Icons.warning_amber_rounded : Icons.event_outlined,
                                ueberfaellig ? 'überfällig · ${faelligText(a, jetzt)}' : faelligText(a, jetzt),
                                ueberfaellig ? kDanger : kTextMuted,
                                semantik: 'Fällig ${faelligText(a, jetzt)}',
                              ),
                            if (prio != AufgabePrio.keine) meta(Icons.flag_outlined, prio.label, prioFarbe(prio), semantik: 'Priorität ${prio.label}'),
                            if (stand.gesamt > 0) meta(Icons.checklist, '${stand.erledigt}/${stand.gesamt}', kTextMuted, semantik: '${stand.erledigt} von ${stand.gesamt} Unteraufgaben erledigt'),
                            if (wdh != AufgabeWdh.keine) meta(Icons.repeat, wdh.label, kTextMuted),
                            if (a.frist && a.fristMonate != null) meta(Icons.repeat, fristWiederholungText(a.fristMonate), kTextMuted),
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

/// Rechte Spalte ohne geöffnete Aufgabe (nur im Zweispalter): Leerzustand mit Handlung.
class _KeinDetail extends ConsumerWidget {
  final bool darfAnlegen;
  const _KeinDetail({required this.darfAnlegen});

  @override
  Widget build(BuildContext context, WidgetRef ref) => EmptyState(
    icon: Icons.task_alt_outlined,
    title: 'Wähle links eine Aufgabe',
    hint: 'Hier siehst du dann alle Einzelheiten. Oder lege gleich eine neue an.',
    knopf: darfAnlegen ? 'Aufgabe hinzufügen' : null,
    onKnopf: darfAnlegen ? () => unawaited(aufgabeEditorOeffnen(context)) : null,
  );
}
