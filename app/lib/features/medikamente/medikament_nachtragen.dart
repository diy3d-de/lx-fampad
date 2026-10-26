// Einnahme nachtragen (Medikamenten-Plan): Tag, Slot (oder "außer der Reihe") und Uhrzeit wählen. Höchstens 120 Tage zurück, nie in der Zukunft (die Datenschicht prüft es noch einmal).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/calendar/zeitzonen.dart';
import '../../data/medikamente/medikament_logik.dart';
import '../../data/medikamente/medikament_modelle.dart';
import '../../data/medikamente/medikament_repository.dart';
import '../../data/medikamente/medikament_state.dart';
import '../../ui/widgets.dart';
import '../lists/list_dialogs.dart' show AuswahlKnopf;
import 'medikament_anzeige.dart';

/// Öffnet den Dialog; [slot] belegt Tag, Slot und Uhrzeit vor. Liefert true, wenn etwas gespeichert wurde.
Future<bool> einnahmeNachtragenOeffnen(BuildContext context, WidgetRef ref, MedEintrag e, {Slot? slot}) async {
  final m = e.inhalt;
  if (m == null) return false;
  final erfasst = await showDialog<bool>(
    context: context,
    useRootNavigator: false,
    builder: (_) => _NachtragenDialog(eintrag: e, slot: slot),
  );
  return erfasst == true;
}

class _NachtragenDialog extends ConsumerStatefulWidget {
  final MedEintrag eintrag;
  final Slot? slot;
  const _NachtragenDialog({required this.eintrag, this.slot});

  @override
  ConsumerState<_NachtragenDialog> createState() => _NachtragenDialogState();
}

class _NachtragenDialogState extends ConsumerState<_NachtragenDialog> {
  late DateTime _tag;
  Slot? _slot;
  late int _minute;
  var _ausserDerReihe = false;
  String? _fehler;
  var _speichert = false;

  MedikamentInhalt get _m => widget.eintrag.inhalt!;

  @override
  void initState() {
    super.initState();
    final jetzt = DateTime.now();
    final w = wandUhr(jetzt.toUtc(), familienOrt);
    final s = widget.slot;
    if (s != null) {
      _tag = tagLesen(s.tag)!;
      _slot = s;
      _minute = zeitMinuten(s.zeit) ?? 0;
    } else {
      _tag = DateTime.utc(w.year, w.month, w.day);
      _minute = w.hour * 60 + w.minute;
      _ausserDerReihe = !_m.rhythmus.festeZeiten;
    }
  }

  List<Slot> get _slots => slotsAmTag(_m, _tag);

  Future<void> _tagWaehlen() async {
    final heute = familienTag(DateTime.now());
    final d = await showDatePicker(
      useRootNavigator: false,
      context: context,
      initialDate: DateTime(_tag.year, _tag.month, _tag.day),
      firstDate: DateTime(heute.year, heute.month, heute.day).subtract(const Duration(days: kEinnahmenAufbewahrungTage)),
      lastDate: DateTime(heute.year, heute.month, heute.day),
      locale: const Locale('de', 'DE'),
    );
    if (d == null || !mounted) return;
    setState(() {
      _tag = DateTime.utc(d.year, d.month, d.day);
      _slot = null;
      _ausserDerReihe = !_m.rhythmus.festeZeiten || _slots.isEmpty;
      if (_slots.length == 1) {
        _slot = _slots.first;
        _minute = zeitMinuten(_slot!.zeit) ?? _minute;
      }
    });
  }

  Future<void> _zeitWaehlen() async {
    final t = await showTimePicker(useRootNavigator: false, context: context, initialTime: TimeOfDay(hour: _minute ~/ 60, minute: _minute % 60));
    if (t != null && mounted) setState(() => _minute = t.hour * 60 + t.minute);
  }

  Future<void> _speichern() async {
    if (_speichert) return;
    if (_slot == null && !_ausserDerReihe) {
      setState(() => _fehler = 'Wähle den Zeitpunkt aus dem Plan oder „Außer der Reihe“.');
      return;
    }
    final um = instantAusWand(DateTime.utc(_tag.year, _tag.month, _tag.day, _minute ~/ 60, _minute % 60), familienOrt);
    final nav = Navigator.of(context);
    setState(() {
      _speichert = true;
      _fehler = null;
    });
    try {
      await ref.read(medikamentRepositoryProvider).einnahmeErfassen(widget.eintrag.id, slot: _ausserDerReihe ? null : _slot, um: um);
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          _speichert = false;
          _fehler = medFehlerText(e);
        });
      }
      return;
    }
    if (mounted) nav.pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final slots = _slots;
    return AlertDialog(
      title: const Text('Einnahme nachtragen'),
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const MonoLabel('Tag'),
          const SizedBox(height: 6),
          _Feld(icon: Icons.event, text: datumKurz(_tag), semantik: 'Tag, ${datumKurz(_tag)}. Ändern', onTap: _tagWaehlen),
          const SizedBox(height: 14),
          const MonoLabel('Zeitpunkt im Plan'),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final s in slots)
                AuswahlKnopf(
                  text: s.zeit,
                  gewaehlt: !_ausserDerReihe && _slot == s,
                  onTap: () => setState(() {
                    _slot = s;
                    _ausserDerReihe = false;
                    _minute = zeitMinuten(s.zeit) ?? _minute;
                  }),
                ),
              AuswahlKnopf(text: 'Außer der Reihe', gewaehlt: _ausserDerReihe, onTap: () => setState(() => _ausserDerReihe = true)),
            ],
          ),
          const SizedBox(height: 14),
          const MonoLabel('Genommen um'),
          const SizedBox(height: 6),
          _Feld(icon: Icons.schedule, text: zeitText(_minute), semantik: 'Uhrzeit, ${zeitText(_minute)}. Ändern', onTap: _zeitWaehlen),
          if (_fehler != null) ...[const SizedBox(height: 12), Text(_fehler!, style: const TextStyle(color: kDanger, fontSize: 13))],
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Abbrechen')),
        FilledButton(onPressed: _speichert ? null : _speichern, child: const Text('Speichern')),
      ],
    );
  }
}

class _Feld extends StatelessWidget {
  final IconData icon;
  final String text;
  final String semantik;
  final VoidCallback onTap;
  const _Feld({required this.icon, required this.text, required this.semantik, required this.onTap});

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: semantik,
    excludeSemantics: true,
    onTap: onTap,
    child: InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: 48),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(color: kSurface, borderRadius: BorderRadius.circular(12)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: kTextMuted),
            const SizedBox(width: 8),
            Flexible(child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis)),
          ],
        ),
      ),
    ),
  );
}
