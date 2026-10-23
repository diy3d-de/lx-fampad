// Bereich "Medikamente" (Abschnitt 6k): die Ansicht "Heute" mit Tagesliste nach Tageszeit, Personenfilter ("Ich" und die eigenen Kinder), Abhaken mit Zeitstempel, Verpasst-Markierung,
// "bei Bedarf" getrennt und einer Warnkarte bei knappem Vorrat oder ablaufendem Rezept. Mobil eine Seite (Blatt "Mehr"), Desktop ein Bereich der Shell.
// Es steht nur, was diese Person ohnehin sehen darf (eigene Medikamente und die ihrer Kinder); nichts davon verlässt die App (kein Push, kein Wandtablet, keine Suche).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/medikamente/medikament_heute.dart';
import '../../data/medikamente/medikament_logik.dart';
import '../../data/medikamente/medikament_modelle.dart';
import '../../data/medikamente/medikament_repository.dart';
import '../../data/medikamente/medikament_state.dart';
import '../../ui/widgets.dart';
import '../../widgets/kopfzeile.dart';
import '../auth/auth_widgets.dart';
import '../calendar/calendar_anzeige.dart' show minutenTaktProvider;
import '../calendar/kalender_widgets.dart' show PersonKapsel;
import '../lists/list_dialogs.dart' show AuswahlKnopf, bestaetigen;
import 'medikament_anzeige.dart';
import 'medikament_detail_screen.dart';
import 'medikament_editor.dart';
import 'medikament_nachtragen.dart';

/// Gewählter Personenfilter ("Alle" = null).
class MedFilter extends Notifier<String?> {
  @override
  String? build() => null;

  void waehlen(String? id) => state = id;
}

final medFilterProvider = NotifierProvider<MedFilter, String?>(MedFilter.new);

/// Öffnet den Bereich als eigene Seite (mobil); im Desktop-Layout ist er ein Bereich der Shell (siehe `medikamenteOeffnen` in medikamente_karte.dart).
Route<void> medikamenteRoute() => MaterialPageRoute<void>(builder: (_) => const MedikamenteScreen());

class MedikamenteScreen extends ConsumerWidget {
  /// Im Desktop-Layout ein Bereich der Shell (Seitenleiste und Fußzeile bleiben): ohne eigenes Gerüst, ohne Zurück-Pfeil, mit der gemeinsamen Kopfzeile.
  final bool eingebettet;
  const MedikamenteScreen({super.key, this.eingebettet = false});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final daten = ref.watch(medAnsichtProvider);
    final jetzt = ref.watch(minutenTaktProvider).value ?? DateTime.now();
    final filter = ref.watch(medFilterProvider);
    // ein Filter auf eine Person, die es (nicht mehr) gibt, gilt nicht
    final aktiv = filter != null && daten.person(filter) != null ? filter : null;
    final sichtbar = aktiv == null ? daten.eintraege : daten.von(aktiv);
    final ansicht = heuteAnsicht(sichtbar, jetzt);
    final kinder = <Widget>[
      if (daten.hatKinder) ...[_Filter(daten: daten, aktiv: aktiv), const SizedBox(height: 14)],
      ..._inhalt(context, ref, daten, sichtbar, ansicht, jetzt),
    ];
    final neu = FilledButton.icon(
      onPressed: () => medikamentEditorOeffnen(context, subjektId: aktiv),
      icon: const Icon(Icons.add),
      label: const Text('Medikament'),
      style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
    );
    if (!eingebettet) {
      return AuthSeite(label: '// ${kopfzeilenDatum()}', titel: 'Medikamente', maxBreite: kMaxContentWidth, fussleiste: neu, kinder: kinder);
    }
    return Material(
      type: MaterialType.transparency,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        children: [
          Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: kMaxContentWidth),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const TabKopfzeile(title: 'Medikamente'),
                  const SizedBox(height: 16),
                  ...kinder,
                  const SizedBox(height: 16),
                  Align(alignment: Alignment.centerLeft, child: neu),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _inhalt(BuildContext context, WidgetRef ref, MedDaten daten, List<MedEintrag> sichtbar, HeuteAnsicht a, DateTime jetzt) {
    if (!daten.geladen) return const [Padding(padding: EdgeInsets.only(top: 32), child: Center(child: CircularProgressIndicator()))];
    if (sichtbar.isEmpty) {
      return const [
        SizedBox(height: 24),
        EmptyState(
          icon: Icons.medication_outlined,
          title: 'Noch keine Medikamente',
          hint: 'Lege einen Plan an, dann erinnert dich die App zur richtigen Zeit. Namen und Dosis sind Ende-zu-Ende verschlüsselt.',
        ),
      ];
    }
    final warn = warnungen(sichtbar, jetzt);
    final nicht = sichtbar.where((e) => !e.lesbar).toList();
    return [
      Row(
        children: [
          Expanded(child: Text(a.gesamt == 0 ? 'Heute nichts geplant' : '${a.erledigt} von ${a.gesamt} erledigt', style: const TextStyle(fontFamily: kFontMono, fontSize: 12, color: kTextMuted))),
        ],
      ),
      const SizedBox(height: 10),
      if (warn.isNotEmpty) ...[_WarnKarte(warnungen: warn, daten: daten), const SizedBox(height: 14)],
      for (final g in a.gruppen) ...[
        MonoLabel('${g.zeit.label} · ${g.ab}', color: kTextMuted),
        const SizedBox(height: 6),
        for (final s in g.slots) _SlotZeile(slot: s, daten: daten, jetzt: jetzt),
        const SizedBox(height: 10),
      ],
      if (a.bedarf.isNotEmpty) ...[
        const MonoLabel('// bei bedarf', color: kTextMuted),
        const SizedBox(height: 6),
        for (final e in a.bedarf) _BedarfZeile(eintrag: e, daten: daten),
        const SizedBox(height: 10),
      ],
      if (a.gruppen.isEmpty && a.bedarf.isEmpty && nicht.isEmpty)
        const Padding(padding: EdgeInsets.symmetric(vertical: 12), child: Text('Heute ist nichts zu nehmen. Pausierte und beendete Pläne findest du unter „Alle Medikamente“.', style: TextStyle(color: kTextMuted))),
      for (final e in nicht) _NichtLesbarZeile(eintrag: e),
      const SizedBox(height: 6),
      _AllePlaene(eintraege: sichtbar, daten: daten),
    ];
  }
}

class _Filter extends ConsumerWidget {
  final MedDaten daten;
  final String? aktiv;
  const _Filter({required this.daten, required this.aktiv});

  @override
  Widget build(BuildContext context, WidgetRef ref) => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      AuswahlKnopf(text: 'Alle', gewaehlt: aktiv == null, onTap: () => ref.read(medFilterProvider.notifier).waehlen(null)),
      for (final u in daten.personen)
        PersonKapsel(
          u: u,
          gewaehlt: aktiv != null && aktiv!.toLowerCase() == u.id.toLowerCase(),
          beschriftung: u.id.toLowerCase() == daten.ich?.toLowerCase() ? 'Meine Medikamente' : 'Medikamente von ${u.displayName}',
          onTap: () => ref.read(medFilterProvider.notifier).waehlen(u.id),
        ),
    ],
  );
}

String _personName(MedDaten d, String subjektId) {
  if (subjektId.toLowerCase() == d.ich?.toLowerCase()) return 'Ich';
  final n = d.person(subjektId)?.displayName.split(RegExp(r'\s+')).first;
  return n == null || n.isEmpty ? 'Kind' : n;
}

class _WarnKarte extends StatelessWidget {
  final List<MedWarnung> warnungen;
  final MedDaten daten;
  const _WarnKarte({required this.warnungen, required this.daten});

  @override
  Widget build(BuildContext context) {
    final zeilen = [
      for (final w in warnungen.take(4))
        () {
          final name = w.eintrag.inhalt!.name;
          final wer = w.eintrag.subjektId.toLowerCase() == daten.ich?.toLowerCase() ? '' : ' (${_personName(daten, w.eintrag.subjektId)})';
          return w.art == WarnArt.vorrat ? '$name$wer: Vorrat ${vorratText(w.tage)}' : 'Rezept für $name$wer ${rezeptText(w.tage)}';
        }(),
    ];
    return Semantics(
      container: true,
      label: 'Hinweis: ${zeilen.join('. ')}',
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: kWarn.withValues(alpha: 0.10), border: Border.all(color: kWarn.withValues(alpha: 0.5)), borderRadius: BorderRadius.circular(14)),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.warning_amber_rounded, color: kWarn, size: 22),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Vorrat oder Rezept beachten', style: TextStyle(fontWeight: FontWeight.w700, color: kWarn)),
                  const SizedBox(height: 4),
                  for (final z in zeilen) Text(z, style: const TextStyle(fontSize: 13, height: 1.35)),
                  if (warnungen.length > zeilen.length) Text('+ ${warnungen.length - zeilen.length} weitere', style: const TextStyle(fontSize: 12, color: kTextMuted)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SlotZeile extends ConsumerWidget {
  final HeuteSlot slot;
  final MedDaten daten;
  final DateTime jetzt;
  const _SlotZeile({required this.slot, required this.daten, required this.jetzt});

  Future<void> _abhaken(BuildContext context, WidgetRef ref) async {
    final repo = ref.read(medikamentRepositoryProvider);
    final messenger = ScaffoldMessenger.of(context);
    try {
      if (slot.erledigt) {
        final ja = await bestaetigen(context, titel: 'Einnahme zurücknehmen?', text: 'Der Eintrag für ${slot.zeit} Uhr wird entfernt, der Slot ist danach wieder offen.', knopf: 'Zurücknehmen');
        if (!ja) return;
        await repo.slotZuruecknehmen(slot.eintrag.id, slot.slot.slot);
      } else {
        await repo.einnahmeErfassen(slot.eintrag.id, slot: slot.slot.slot);
      }
    } on Object catch (e) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(medFehlerText(e))));
    }
  }

  Future<void> _menue(BuildContext context, WidgetRef ref) async {
    final repo = ref.read(medikamentRepositoryProvider);
    final messenger = ScaffoldMessenger.of(context);
    final aktion = await showModalBottomSheet<String>(
      context: context,
      useRootNavigator: false,
      backgroundColor: kSurface,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!slot.erledigt || slot.slot.status == SlotStatus.uebersprungen) ListTile(minTileHeight: 56, leading: const Icon(Icons.check_circle_outline), title: const Text('Jetzt genommen'), onTap: () => Navigator.of(c).pop('jetzt')),
            ListTile(minTileHeight: 56, leading: const Icon(Icons.history), title: const Text('Zu anderer Zeit nachtragen'), onTap: () => Navigator.of(c).pop('nachtragen')),
            if (!slot.erledigt) ListTile(minTileHeight: 56, leading: const Icon(Icons.not_interested), title: const Text('Überspringen'), onTap: () => Navigator.of(c).pop('ueberspringen')),
            if (slot.erledigt) ListTile(minTileHeight: 56, leading: const Icon(Icons.undo), title: const Text('Zurücknehmen'), onTap: () => Navigator.of(c).pop('zurueck')),
          ],
        ),
      ),
    );
    if (aktion == null || !context.mounted) return;
    try {
      switch (aktion) {
        case 'jetzt':
          await repo.einnahmeErfassen(slot.eintrag.id, slot: slot.slot.slot);
        case 'ueberspringen':
          await repo.einnahmeErfassen(slot.eintrag.id, slot: slot.slot.slot, status: EinnahmeStatus.uebersprungen);
        case 'zurueck':
          await repo.slotZuruecknehmen(slot.eintrag.id, slot.slot.slot);
        case 'nachtragen':
          await einnahmeNachtragenOeffnen(context, ref, slot.eintrag, slot: slot.slot.slot);
      }
    } on Object catch (e) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(medFehlerText(e))));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final m = slot.eintrag.inhalt!;
    final st = slot.slot.status;
    final faellig = st == SlotStatus.offen && slot.faellig(jetzt);
    final person = _personName(daten, slot.subjektId);
    final vorrat = vorratWarnTage(slot.eintrag, jetzt);
    final (statusText, statusFarbe) = switch (st) {
      SlotStatus.genommen => ('erledigt ${slot.slot.einnahme == null ? '' : uhrzeitVon(slot.slot.einnahme!.inhalt!.um)}'.trim(), kTerminal),
      SlotStatus.uebersprungen => ('übersprungen', kTextMuted),
      SlotStatus.verpasst => ('verpasst', kDanger),
      SlotStatus.offen => (faellig ? 'fällig jetzt' : 'geplant ${slot.zeit} Uhr', faellig ? kAccent : kTextMuted),
    };
    final titel = titelText(m);
    final semantik = '$titel, $person, ${slot.zeit} Uhr, $statusText${vorrat == null ? '' : ', Vorrat ${vorratText(vorrat)}'}';
    return Container(
          margin: const EdgeInsets.only(bottom: 6),
          decoration: BoxDecoration(
            color: kSurface.withValues(alpha: 0.7),
            border: Border.all(color: faellig || st == SlotStatus.verpasst ? (st == SlotStatus.verpasst ? kDanger : kAccent).withValues(alpha: 0.7) : kBorder),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            children: [
              Semantics(
                button: true,
                label: slot.erledigt ? 'Einnahme zurücknehmen: $titel' : 'Als genommen abhaken: $titel',
                child: InkWell(
                  key: ValueKey('med-haken:${slot.eintrag.id}:${slot.slot.slot.schluessel}'),
                  borderRadius: BorderRadius.circular(14),
                  onTap: () => unawaited(_abhaken(context, ref)),
                  child: SizedBox(
                    width: 56,
                    height: 56,
                    child: Center(
                      child: Container(
                        width: 28,
                        height: 28,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: st == SlotStatus.genommen ? kTerminal : null,
                          border: Border.all(color: st == SlotStatus.genommen ? kTerminal : (faellig ? kAccent : kTextMuted), width: 2),
                        ),
                        child: st == SlotStatus.genommen ? const Icon(Icons.check, size: 18, color: kOnAccent) : (st == SlotStatus.uebersprungen ? const Icon(Icons.remove, size: 18, color: kTextMuted) : null),
                      ),
                    ),
                  ),
                ),
              ),
              Expanded(
                child: Semantics(
                  button: true,
                  label: semantik,
                  excludeSemantics: true,
                  customSemanticsActions: {const CustomSemanticsAction(label: 'Weitere Aktionen'): () => unawaited(_menue(context, ref))},
                  onTap: () => unawaited(medikamentDetailOeffnen(context, slot.eintrag.id)),
                  child: InkWell(
                  key: ValueKey('med-zeile:${slot.eintrag.id}:${slot.slot.slot.schluessel}'),
                  borderRadius: BorderRadius.circular(14),
                  onTap: () => unawaited(medikamentDetailOeffnen(context, slot.eintrag.id)),
                  onLongPress: () => unawaited(_menue(context, ref)),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 56),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(0, 8, 12, 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(titel, style: TextStyle(fontWeight: FontWeight.w600, decoration: st == SlotStatus.genommen ? TextDecoration.lineThrough : null, decorationColor: kTextMuted)),
                          const SizedBox(height: 2),
                          Wrap(
                            spacing: 8,
                            runSpacing: 2,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              Text('$person · $statusText', style: TextStyle(fontSize: 12, color: statusFarbe == kTextMuted ? kTextMuted : statusFarbe)),
                              if (vorrat != null) Text('VORRAT ${vorrat <= 0 ? 'LEER' : '$vorrat T.'}', style: const TextStyle(fontFamily: kFontMono, fontSize: 10, color: kWarn)),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
                ),
            ],
          ),
    );
  }
}

class _BedarfZeile extends ConsumerWidget {
  final MedEintrag eintrag;
  final MedDaten daten;
  const _BedarfZeile({required this.eintrag, required this.daten});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final m = eintrag.inhalt!;
    final person = _personName(daten, eintrag.subjektId);
    final letzte = ([...eintrag.einnahmen.where((e) => e.inhalt != null)]..sort((a, b) => b.inhalt!.um.compareTo(a.inhalt!.um))).firstOrNull;
    final titel = titelText(m);
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(color: kSurface.withValues(alpha: 0.7), border: Border.all(color: kBorder), borderRadius: BorderRadius.circular(14)),
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              button: true,
              label: '$titel, $person, bei Bedarf. Details',
              excludeSemantics: true,
              child: InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: () => unawaited(medikamentDetailOeffnen(context, eintrag.id)),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 56),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(titel, style: const TextStyle(fontWeight: FontWeight.w600)),
                        Text(letzte == null ? '$person · bei Bedarf' : '$person · zuletzt ${uhrzeitVon(letzte.inhalt!.um)} Uhr', style: const TextStyle(fontSize: 12, color: kTextMuted)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: TextButton(
              key: ValueKey('med-bedarf:${eintrag.id}'),
              style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: () async {
                final messenger = ScaffoldMessenger.of(context);
                try {
                  await ref.read(medikamentRepositoryProvider).einnahmeErfassen(eintrag.id);
                  messenger
                    ..hideCurrentSnackBar()
                    ..showSnackBar(const SnackBar(content: Text('Einnahme eingetragen. Zurücknehmen kannst du sie in den Details.')));
                } on Object catch (e) {
                  messenger
                    ..hideCurrentSnackBar()
                    ..showSnackBar(SnackBar(content: Text(medFehlerText(e))));
                }
              },
              child: const Text('Genommen'),
            ),
          ),
        ],
      ),
    );
  }
}

class _NichtLesbarZeile extends StatelessWidget {
  final MedEintrag eintrag;
  const _NichtLesbarZeile({required this.eintrag});

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    label: 'Ein Medikament lässt sich gerade nicht lesen. ${eintrag.med.hinweis ?? ''}',
    excludeSemantics: true,
    child: Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: kSurface.withValues(alpha: 0.5), border: Border.all(color: kBorder), borderRadius: BorderRadius.circular(14)),
      child: Row(
        children: [
          const Icon(Icons.lock_outline, size: 18, color: kTextMuted),
          const SizedBox(width: 10),
          Expanded(child: Text('Nicht lesbar${eintrag.med.hinweis == null ? '' : ': ${eintrag.med.hinweis}'}', style: const TextStyle(fontSize: 13, color: kTextMuted))),
        ],
      ),
    ),
  );
}

/// Alle Pläne der Auswahl (auch pausierte und beendete), zum Öffnen der Details.
class _AllePlaene extends StatefulWidget {
  final List<MedEintrag> eintraege;
  final MedDaten daten;
  const _AllePlaene({required this.eintraege, required this.daten});

  @override
  State<_AllePlaene> createState() => _AllePlaeneState();
}

class _AllePlaeneState extends State<_AllePlaene> {
  var _offen = false;

  @override
  Widget build(BuildContext context) {
    final lesbar = [for (final e in widget.eintraege) if (e.lesbar) e]..sort((a, b) => a.inhalt!.name.toLowerCase().compareTo(b.inhalt!.name.toLowerCase()));
    if (lesbar.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          button: true,
          expanded: _offen,
          label: 'Alle Medikamente, ${lesbar.length}',
          excludeSemantics: true,
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => setState(() => _offen = !_offen),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: Row(
                children: [
                  Expanded(child: MonoLabel('// alle medikamente · ${lesbar.length}', color: kTextMuted)),
                  Icon(_offen ? Icons.expand_less : Icons.expand_more, color: kTextMuted),
                ],
              ),
            ),
          ),
        ),
        if (_offen)
          for (final e in lesbar) _PlanZeile(eintrag: e, daten: widget.daten),
      ],
    );
  }
}

class _PlanZeile extends StatelessWidget {
  final MedEintrag eintrag;
  final MedDaten daten;
  const _PlanZeile({required this.eintrag, required this.daten});

  @override
  Widget build(BuildContext context) {
    final m = eintrag.inhalt!;
    final zustand = switch (m.zustand) {
      MedikamentZustand.aktiv => rhythmusText(m),
      MedikamentZustand.pausiert => 'pausiert',
      MedikamentZustand.beendet => 'beendet',
    };
    final person = _personName(daten, eintrag.subjektId);
    return Semantics(
      button: true,
      label: '${titelText(m)}, $person, $zustand. Details',
      excludeSemantics: true,
      child: InkWell(
        key: ValueKey('med-plan:${eintrag.id}'),
        borderRadius: BorderRadius.circular(12),
        onTap: () => unawaited(medikamentDetailOeffnen(context, eintrag.id)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 52),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(titelText(m), style: const TextStyle(fontWeight: FontWeight.w600)),
                      Text('$person · $zustand', style: const TextStyle(fontSize: 12, color: kTextMuted)),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right, color: kTextMuted),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
